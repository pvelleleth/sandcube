#!/usr/bin/env python3
"""Run the real installer with real RSA verification and a simulated host.

No network access, package installs, systemd changes or writes outside the test
directory. curl/sudo/uname/id are replaced; openssl and hashing are real.
"""
import base64
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

MOCK = r'''#!/usr/bin/env python3
import json, os, pathlib, shutil, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
work = pathlib.Path(os.environ['INSTALL_TEST_ROOT'])
if name == 'id':
    print('1000')
elif name == 'uname':
    print('Linux' if args == ['-s'] else os.environ.get('INSTALL_TEST_ARCH', 'x86_64'))
elif name == 'curl':
    url = next(a for a in args if a.startswith('https://'))
    assert url.startswith('https://github.com/example/sandcube/releases/download/v0.1.0/')
    shutil.copyfile(work / 'assets' / url.rsplit('/', 1)[1], args[args.index('-o') + 1])
elif name == 'sudo':
    with (work / 'actions').open('a') as f:
        f.write(json.dumps(args) + '\n')
    def host(path):
        return work / 'host' / path.lstrip('/')
    if args[0] == 'install':
        target = host(args[-1])
        if '-d' in args:
            target.mkdir(parents=True, exist_ok=True)
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(args[-2], target)
    elif args[0] == 'mv':
        host(args[-2]).rename(host(args[-1]))
    elif args[0] not in ('sh', 'systemctl'):
        raise AssertionError(args)
else:
    raise AssertionError(name)
'''


class InstallerTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='sandcube-installer-test-')
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.assets = self.work / 'assets'
        self.assets.mkdir()
        self.key = self.work / 'key.pem'
        subprocess.run(['openssl', 'genpkey', '-algorithm', 'RSA', '-pkeyopt',
                        'rsa_keygen_bits:2048', '-out', str(self.key)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        public = subprocess.check_output(['openssl', 'pkey', '-in', str(self.key), '-pubout'])
        for name in ('sandcube-linux-amd64', 'sandcube-linux-arm64', 'install-deps.sh', 'sandcube.service'):
            (self.assets / name).write_bytes(('verified-' + name).encode())
        checksums = ''.join(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n'
                            for p in sorted(self.assets.iterdir()))
        (self.assets / 'SHA256SUMS').write_text(checksums)
        subprocess.run(['openssl', 'dgst', '-sha256', '-sign', str(self.key), '-out',
                        str(self.assets / 'SHA256SUMS.sig'), str(self.assets / 'SHA256SUMS')], check=True)
        template = (ROOT / 'scripts/install.sh').read_text()
        self.installer = self.work / 'install.sh'
        self.installer.write_text(template.replace('@REPOSITORY@', 'example/sandcube')
                                  .replace('@VERSION@', '0.1.0')
                                  .replace('@PUBLIC_KEY_BASE64@', base64.b64encode(public).decode()))
        mockbin = self.work / 'mockbin'
        mockbin.mkdir()
        for name in ('curl', 'sudo', 'id', 'uname'):
            path = mockbin / name
            path.write_text(MOCK)
            path.chmod(0o755)
        self.env = dict(os.environ, PATH=str(mockbin) + ':' + os.environ['PATH'],
                        INSTALL_TEST_ROOT=str(self.work))

    def run_installer(self, *args):
        return subprocess.run(['sh', str(self.installer), *args], env=self.env,
                              capture_output=True, text=True, timeout=20)

    def test_signed_install_systemd_and_builds(self):
        result = self.run_installer('--systemd')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.work / 'host/usr/local/bin/sandcube').read_bytes(),
                         b'verified-sandcube-linux-amd64')
        actions = (self.work / 'actions').read_text()
        self.assertIn('install-deps.sh', actions)
        self.assertNotIn('--enable-builds', actions)
        self.assertIn('daemon-reload', actions)
        self.assertIn('enable', actions)
        self.assertNotIn('start', actions)

    def test_arm64_and_no_dependencies(self):
        self.env['INSTALL_TEST_ARCH'] = 'aarch64'
        result = self.run_installer('--no-deps')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.work / 'host/usr/local/bin/sandcube').read_bytes(),
                         b'verified-sandcube-linux-arm64')
        self.assertNotIn('install-deps', (self.work / 'actions').read_text())

    def test_bad_signature_prevents_all_installation(self):
        (self.assets / 'SHA256SUMS').write_text('tampered manifest\n')
        result = self.run_installer()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.work / 'actions').exists())

    def test_bad_binary_checksum_prevents_all_installation(self):
        (self.assets / 'sandcube-linux-amd64').write_bytes(b'corrupted')
        result = self.run_installer()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Checksum mismatch', result.stderr)
        self.assertFalse((self.work / 'actions').exists())

    def test_bad_dependency_checksum_prevents_all_installation(self):
        (self.assets / 'install-deps.sh').write_bytes(b'corrupted')
        result = self.run_installer()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.work / 'actions').exists())

    def test_unsupported_architecture_fails_before_installation(self):
        self.env['INSTALL_TEST_ARCH'] = 'riscv64'
        result = self.run_installer()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.work / 'actions').exists())

    def test_bad_systemd_unit_prevents_all_installation(self):
        (self.assets / 'sandcube.service').write_bytes(b'corrupted')
        result = self.run_installer('--systemd')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.work / 'actions').exists())

    def test_release_script_generates_a_verifiable_installer_and_manifest(self):
        release = self.work / 'release'
        (release / 'dist').mkdir(parents=True)
        (release / 'scripts').mkdir()
        (release / 'infra/systemd').mkdir(parents=True)
        for name in ('sandcube-linux-amd64', 'sandcube-linux-arm64'):
            shutil.copyfile(self.assets / name, release / 'dist' / name)
        for name in ('install.sh', 'install-deps.sh', 'release.sh'):
            shutil.copyfile(ROOT / 'scripts' / name, release / 'scripts' / name)
        shutil.copyfile(ROOT / 'infra/systemd/sandcube.service', release / 'infra/systemd/sandcube.service')
        env = dict(os.environ, RELEASE_VERSION='0.1.0', RELEASE_REPOSITORY='example/sandcube',
                   RELEASE_SIGNING_KEY=str(self.key))
        result = subprocess.run(['sh', 'scripts/release.sh'], cwd=release, env=env,
                                capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        generated = (release / 'dist/install.sh').read_text()
        self.assertNotIn('@PUBLIC_KEY_BASE64@', generated)
        self.assertNotIn('PRIVATE KEY', generated)
        subprocess.run(['openssl', 'dgst', '-sha256', '-verify', 'release.pem',
                        '-signature', 'SHA256SUMS.sig', 'SHA256SUMS'], cwd=release / 'dist',
                       check=True, stdout=subprocess.DEVNULL)
        subprocess.run(['sha256sum', '-c', 'SHA256SUMS'], cwd=release / 'dist',
                       check=True, stdout=subprocess.DEVNULL)


if __name__ == '__main__':
    unittest.main()
