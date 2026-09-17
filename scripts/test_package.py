#!/usr/bin/env python3
"""Check the actual release payload, and run CLI commands from an unrelated cwd."""
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / 'bin/sandcube'
MAGIC = b'SANDCUBE_BUNDLE_V1\n'


class PackageTest(unittest.TestCase):
    def test_both_binaries_are_embedded_exactly(self):
        with BINARY.open('rb') as bundle:
            bundle.seek(-len(MAGIC), 2)
            self.assertEqual(bundle.read(), MAGIC)
            bundle.seek(-len(MAGIC) - 8, 2)
            size, = struct.unpack('<Q', bundle.read(8))
            bundle.seek(-len(MAGIC) - 8 - size, 2)
            manifest = json.loads(bundle.read(size))
            sources = {'sandcube-api': ROOT / 'bin/sandcube-api',
                       'containerd-runtime': ROOT / 'bin/containerd-runtime',
                       'install-deps.sh': ROOT / 'scripts/install-deps.sh'}
            self.assertEqual({entry['name'] for entry in manifest['entries']}, set(sources))
            for entry in manifest['entries']:
                bundle.seek(entry['offset'])
                payload = bundle.read(entry['size'])
                self.assertEqual(hashlib.sha256(payload).hexdigest(), entry['sha256'])
                self.assertEqual(payload, sources[entry['name']].read_bytes())

    def test_version_and_help_work_without_database_or_source_tree(self):
        with tempfile.TemporaryDirectory(prefix='sandcube-package-test-') as work:
            for args in (['version'], ['init', '--help'], ['serve', '--help'], ['doctor', '--help']):
                result = subprocess.run([str(BINARY), *args], cwd=work, env={'PATH': '/usr/bin:/bin'},
                                        capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run([str(BINARY), 'serve', '--config', work + '/missing.env'],
                                    cwd=work, capture_output=True, text=True, timeout=10)
            self.assertNotEqual(result.returncode, 0)


if __name__ == '__main__':
    unittest.main()
