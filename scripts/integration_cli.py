#!/usr/bin/env python3
"""Opt-in real packaged-CLI acceptance test on a prepared disposable host.

Requires root and installed runtime dependencies. SANDCUBE_TEST_STORAGE may
point at an empty XFS/prjquota mount. Otherwise init provisions a 768 MiB local
image in a new private directory. Leaves test state/logs for inspection.
"""
import json
import os
from pathlib import Path
import secrets
import signal
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / 'bin/sandcube'
IMAGE = 'docker.io/library/busybox:1.37.0'
PATH = '/usr/local/lib/sandcube/deps/bin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'


def main():
    assert os.geteuid() == 0, 'Run this acceptance test as root'
    assert not Path('/etc/systemd/system/sandcube.service').exists(), 'Use a disposable host without an installed Sandcube unit'
    custom = os.environ.get('SANDCUBE_TEST_STORAGE')
    root = Path(tempfile.mkdtemp(prefix='.cli-acceptance-', dir=ROOT))
    storage = Path(custom).resolve() if custom else root / 'data'
    if custom:
        assert storage.is_mount() and not list(storage.iterdir()), 'Use an empty, disposable mount'
    env = dict(os.environ, PATH=PATH)
    config = root / 'config.env'
    runtime = Path('/run/sandcube-cli-test-' + secrets.token_hex(5))
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0))
        port = probe.getsockname()[1]
    storage_args = ['--storage', str(storage)] if custom else ['--storage-size-mb', '768']
    subprocess.run([str(BINARY), 'init', '--config', str(config), *storage_args,
                    '--run-dir', str(runtime), '--port', str(port), '--capacity-cpu', '1',
                    '--capacity-memory-mb', '256', '--capacity-disk-mb', '64'], env=env, check=True)
    values = dict((key, json.loads(value)) for key, value in
                  (line.split('=', 1) for line in config.read_text().splitlines()))
    assert 'SANDCUBE_API_KEY' not in values and 'DATABASE_URL' not in values
    assert (storage / 'sandcube.db').is_file()
    assert config.stat().st_mode & 0o777 == 0o600
    subprocess.run([str(BINARY), 'doctor', '--config', str(config)], env=env, check=True)
    base = f'http://127.0.0.1:{port}'

    def api(method, path, body=None, expected=200):
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(base + path, data, method=method,
                                        headers={'Content-Type': 'application/json'})
        try:
            response = urllib.request.urlopen(request, timeout=60)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            raw = response.read()
            assert response.status == expected, (response.status, raw)
            return json.loads(raw)

    def start(log):
        process = subprocess.Popen([str(BINARY), 'serve', '--config', str(config)], env=env,
                                   stdout=log, stderr=log)
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            assert process.poll() is None, 'serve failed; inspect cli-acceptance.log'
            try:
                api('GET', '/health')
                return process
            except (OSError, AssertionError):
                time.sleep(.2)
        stop(process)
        raise AssertionError('API readiness timed out')

    def stop(process, sig=signal.SIGTERM):
        if process.poll() is None:
            process.send_signal(sig)
            try:
                return process.wait(timeout=75)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
                raise
        return process.returncode

    process = None
    sandbox = None
    with (root / 'cli-acceptance.log').open('a') as log:
        try:
            process = start(log)
            api('POST', '/v1/images', {}, expected=503)
            duplicate = subprocess.run([str(BINARY), 'serve', '--config', str(config)], env=env,
                                       stdout=log, stderr=log, timeout=20)
            assert duplicate.returncode != 0
            sandbox = api('POST', '/v1/sandboxes', {'image': IMAGE, 'command': ['/bin/sleep', 'infinity'],
                          'cpu': 1, 'memory_mb': 128, 'disk_mb': 32, 'pids': 64}, expected=201)['id']
            api('POST', f'/v1/sandboxes/{sandbox}/exec', {'command': ['/bin/sh', '-c', 'echo durable >/proof']})
            assert stop(process, signal.SIGINT) == 0
            process = start(log)
            proof = api('POST', f'/v1/sandboxes/{sandbox}/exec', {'command': ['/bin/cat', '/proof']})
            assert proof['stdout'] == 'durable\n'
            api('DELETE', f'/v1/sandboxes/{sandbox}')
            sandbox = None
            children = [int(pid) for pid in Path(f'/proc/{process.pid}/task/{process.pid}/children').read_text().split()]
            adapter = next(pid for pid in children if Path(f'/proc/{pid}/cmdline').read_bytes().split(b'\0')[0].endswith(b'/containerd-runtime'))
            os.kill(adapter, signal.SIGKILL)
            assert process.wait(timeout=75) != 0, 'Unexpected child exit must fail the supervisor'
            assert all(not Path(f'/proc/{pid}').exists() for pid in children), 'Supervisor left a child running'
            process = start(log)
            assert stop(process) == 0
            if not custom:
                # With all sandboxes removed, simulate a reboot's lost mount.
                subprocess.run(['umount', str(storage)], env=env, check=True)
                process = start(log)
                assert stop(process) == 0
        finally:
            try:
                if sandbox and process and process.poll() is None:
                    api('DELETE', f'/v1/sandboxes/{sandbox}')
            finally:
                if process:
                    stop(process)
    print(f'Packaged CLI acceptance passed; test state and logs retained in {root}')


if __name__ == '__main__':
    main()
