#!/usr/bin/env python3
"""Real Crystal -> Unix socket -> containerd -> gVisor acceptance test.
Requires root, built binaries, and busybox:1.37.0 unpacked in sandcube-test.
Only deletes sandbox IDs created by this run. Leaves the reusable image intact.
"""
import concurrent.futures
import fcntl
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
from phase3_checks import check_phase3

ROOT = Path(__file__).resolve().parents[1]
IMAGE = 'docker.io/library/busybox:1.37.0'
NAMESPACE = 'sandcube-test'
ADDRESS = os.environ.get('SANDCUBE_CONTAINERD', '/run/sandcube-containerd/containerd.sock')
ids = []
processes = []
baseline = set()
# Prevent concurrent runs from mistaking each other's creates for leaked state.
run_lock = (ROOT / ".integration.lock").open("a")
fcntl.flock(run_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)


def ctr(*args, check=True):
    return subprocess.run(['ctr', '--address', ADDRESS, '-n', NAMESPACE, *args], text=True, capture_output=True, check=check)


def api(method, path, body=None, expected=200):
    if method == 'POST' and path == '/v1/sandboxes' and isinstance(body, dict):
        body = dict(body, disk_mb=body.get('disk_mb', 64))
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(base + path, data=data, method=method,
        headers={'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=60) as response:
            code, raw = response.status, response.read()
    except urllib.error.HTTPError as ex:
        code, raw = ex.code, ex.read()
    assert code == expected, (method, path, code, raw.decode())
    return json.loads(raw)


def execute(sid, command, **kwargs):
    return api('POST', f'/v1/sandboxes/{sid}/exec', {'command': command, **kwargs})


def start(binary, args, env, log):
    p = subprocess.Popen([str(ROOT / 'bin' / binary), *args], env=env, stdout=log, stderr=log)
    processes.append(p)
    return p


def stop(p):
    p.terminate()
    try:
        p.wait(timeout=15)
    except subprocess.TimeoutExpired:
        p.kill()
        p.wait()


with tempfile.TemporaryDirectory(prefix='sandcube-test-') as work:
    # Runtime FIFO/socket directories must be short; public service is localhost only.
    sock = work + '/runtime.sock'
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0))
        port = probe.getsockname()[1]
    base = f'http://127.0.0.1:{port}'
    env = dict(os.environ, SANDCUBE_DATA_DIR=work + '/data', SANDCUBE_CAPACITY_CPU='2', SANDCUBE_CAPACITY_MEMORY_MB='512', SANDCUBE_CAPACITY_DISK_MB='256', SANDCUBE_RUNTIME_SOCKET=sock, SANDCUBE_PORT=str(port))
    baseline = set(ctr('containers', 'list', '-q').stdout.split())
    assert not baseline, 'Use an empty dedicated test namespace'

    with open(work + '/services.log', 'w+') as log:
        try:
            adapter = start('containerd-runtime', ['-socket', sock, '-containerd', ADDRESS, '-namespace', NAMESPACE, '-runsc-config', str(ROOT / 'infra/gvisor/runsc.toml'), '-history-root', work + '/history'], env, log)
            crystal = start('sandcube-api', [], env, log)
            for _ in range(100):
                try:
                    if not os.path.exists(sock):
                        raise OSError('Runtime socket is not ready')
                    api('GET', '/health')
                    break
                except (OSError, AssertionError):
                    if adapter.poll() is not None or crystal.poll() is not None:
                        raise RuntimeError('Service exited during startup')
                    time.sleep(.1)
            else:
                raise RuntimeError('Services did not become healthy')
            assert os.stat(sock).st_mode & 0o777 == 0o600
            api('GET', '/health')
            print('PASS: API without authentication and private Unix socket', flush=True)
            before_failed_create = set(ctr('containers', 'list', '-q').stdout.split())
            before_failed_snapshots = ctr('snapshots', 'list').stdout
            api('POST', '/v1/sandboxes', {'image': IMAGE, 'command': ['/does-not-exist']}, expected=500)
            assert set(ctr('containers', 'list', '-q').stdout.split()) == before_failed_create
            assert ctr('snapshots', 'list').stdout == before_failed_snapshots
            api('POST', '/v1/sandboxes', {'image': 'sandcube.local/images/missing:latest', 'command': ['/bin/true']}, expected=404)
            print('PASS: failed creation rolls back container and snapshot', flush=True)
            for _ in range(2):
                sb = api('POST', '/v1/sandboxes', {'image': IMAGE, 'command': ['/bin/sleep', 'infinity']}, expected=201)
                ids.append(sb['id'])
                assert sb['status'] == 'running'
            sid, other = ids
            def reconnect_api():
                global crystal
                stop(crystal)
                crystal = start('sandcube-api', [], env, log)
                for _ in range(100):
                    try:
                        api('GET', '/health')
                        return
                    except (OSError, AssertionError):
                        time.sleep(.1)
                raise RuntimeError('API did not restart')
            check_phase3(api, execute, base, sid, other, reconnect_api)
            prefix = f'/v1/sandboxes/{sid}'
            info = json.loads(ctr('containers', 'info', sid).stdout)
            assert info['Runtime']['Name'] == 'io.containerd.runsc.v1', info
            spec = info['Spec']
            assert spec['annotations']['io.kubernetes.cri.container-type'] == 'sandbox'
            assert spec['annotations']['io.kubernetes.cri.sandbox-id'] == sid
            assert spec['process']['noNewPrivileges'] is True
            assert not spec['process']['capabilities'].get('bounding', [])
            assert any(n['type'] == 'network' and n.get('path', '').startswith('/run/netns/scn') for n in spec['linux']['namespaces'])
            assert spec['linux']['resources']['memory']['limit'] == 256 * 1024 * 1024
            assert spec['linux']['resources']['pids']['limit'] == 128
            cgroup = Path('/sys/fs/cgroup') / spec['linux']['cgroupsPath'].lstrip('/')
            assert (cgroup / 'memory.max').read_text().strip() == str(256 * 1024 * 1024)
            assert (cgroup / 'cpu.max').read_text().strip() == '100000 100000'
            assert (cgroup / 'pids.max').read_text().strip() == '128'
            result = execute(sid, ['/bin/dmesg'])
            assert 'gVisor' in result['stdout'], result
            assert execute(sid, ['/bin/sh', '-c', 'test ! -S /run/containerd/containerd.sock && test ! -e /root/sandcube/build.md'])['exit_code'] == 0
            assert 'default via ' in execute(sid, ['/bin/ip', 'route'])['stdout']
            marker = secrets.token_hex(24)
            result = execute(sid, ['/bin/sh', '-c', 'mkdir -p /workspace; printf "%s" "$MARKER" > /workspace/proof; echo stderr >&2; exit 7'], env={'MARKER': marker})
            assert result['exit_code'] == 7 and result['stderr'] == 'stderr\n', result
            assert execute(other, ['/bin/test', '!', '-e', '/workspace/proof'])['exit_code'] == 0
            assert execute(sid, ['/bin/pwd'], cwd='/workspace')['stdout'] == '/workspace\n'
            print('PASS: gVisor, resource configuration, exec output/exit/cwd/env, independent filesystems', flush=True)
            result = execute(sid, ['/bin/sleep', '30'], timeout_seconds=1)
            assert result['timed_out'] and result['exit_code'] != 0, result
            result = execute(sid, ['/bin/sh', '-c', 'head -c 1100000 /dev/zero'])
            assert result['truncated'] and len(result['stdout']) == 1048576, len(result['stdout'])
            print('PASS: command timeout and bounded output', flush=True)
            assert execute(sid, ['/bin/sh', '-c', '/bin/sleep 777 >/dev/null 2>&1 &'])['exit_code'] == 0
            assert 'sleep 777' in execute(sid, ['/bin/ps', '-o', 'args'])['stdout']
            for _ in range(2):
                assert api('POST', prefix + '/stop')['status'] == 'stopped'
            assert sid not in ctr('tasks', 'list', '-q').stdout.split()
            assert sid in ctr('containers', 'list', '-q').stdout.split()
            ctr('snapshots', 'info', sid)
            api('POST', prefix + '/exec', {'command': ['/bin/true']}, expected=409)
            # Prove persistence does not depend on either service's memory.
            stop(crystal)
            stop(adapter)
            adapter = start('containerd-runtime', ['-socket', sock, '-containerd', ADDRESS, '-namespace', NAMESPACE, '-runsc-config', str(ROOT / 'infra/gvisor/runsc.toml'), '-history-root', work + '/history'], env, log)
            crystal = start('sandcube-api', [], env, log)
            for _ in range(100):
                try:
                    if not os.path.exists(sock):
                        raise OSError('Runtime socket is not ready')
                    api('GET', '/health')
                    break
                except (OSError, AssertionError):
                    time.sleep(.1)
            assert api('GET', prefix)['snapshot_key'] == sid
            with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
                results = list(pool.map(lambda _: api('POST', prefix + '/start'), range(4)))
            assert all(s['status'] == 'running' for s in results)
            assert execute(sid, ['/bin/cat', '/workspace/proof'])['stdout'] == marker
            assert 'sleep 777' not in execute(sid, ['/bin/ps', '-o', 'args'])['stdout']
            assert api('POST', prefix + '/restart')['status'] == 'running'
            assert execute(sid, ['/bin/cat', '/workspace/proof'])['stdout'] == marker
            print('PASS: stop/start and service-restart persistence, repeated and concurrent lifecycle calls', flush=True)
            for _ in range(2):
                assert api('DELETE', prefix)['status'] == 'deleted'
            assert api('GET', prefix)['status'] == 'deleted'
            assert ctr('snapshots', 'info', sid, check=False).returncode != 0
            assert sid not in ctr('containers', 'list', '-q').stdout.split()
            assert execute(other, ['/bin/true'])['exit_code'] == 0
            assert IMAGE in ctr('images', 'list', '-q').stdout.split()
            print('PASS: idempotent deletion removes snapshot/container, preserves image and other sandbox', flush=True)
        except BaseException:
            log.flush()
            log.seek(0)
            print(log.read())
            raise
        finally:
            cleanup_failed = False
            # Capture creates whose HTTP response was lost. This dedicated namespace
            # must not be used by another integration run concurrently.
            discovered = set(ctr('containers', 'list', '-q').stdout.split()) - baseline
            for sid in sorted(set(ids) | {s for s in discovered if s.startswith('sbx_')}):
                try:
                    api('DELETE', f'/v1/sandboxes/{sid}')
                except Exception as ex:
                    cleanup_failed = True
                    print(f'Cleanup failed for {sid}: {ex}')
            for p in reversed(processes):
                if p.poll() is None:
                    stop(p)
            if cleanup_failed:
                raise RuntimeError('Integration cleanup incomplete; inspect reported IDs')
print('All runtime milestone integration checks passed.')
