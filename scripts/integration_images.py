#!/usr/bin/env python3
"""Phase 2: real PostgreSQL -> Crystal -> BuildKit -> containerd -> gVisor.
Requires a dedicated TEST_DATABASE_URL, running BuildKit/containerd, and built binaries.
Cleans only its own sandboxes/images; preserves metadata tombstones for inspection.
"""
import base64
import concurrent.futures
import fcntl
import io
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import tarfile
import tempfile
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
ADDRESS = os.environ.get('SANDCUBE_CONTAINERD', '/run/sandcube-containerd/containerd.sock')
DATABASE = os.environ['TEST_DATABASE_URL']
TOKEN = secrets.token_hex(32)
NAMESPACE = 'sandcube-test'
images, sandboxes, processes = [], [], []
lock = (ROOT / '.integration.lock').open('a')
fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)


def api(method, path, body=None, expected=200, content_type='application/json'):
    data = body if isinstance(body, bytes) else json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(base + path, data=data, method=method,
        headers={'Authorization': 'Bearer ' + TOKEN, 'Content-Type': content_type})
    try:
        with urllib.request.urlopen(req, timeout=90) as r:
            code, raw = r.status, r.read()
    except urllib.error.HTTPError as e:
        code, raw = e.code, e.read()
    assert code == expected, (method, path, code, raw.decode())
    return json.loads(raw)


def archive(name='proof.txt', content=b'original\n', kind=tarfile.REGTYPE):
    out = io.BytesIO()
    with tarfile.open(fileobj=out, mode='w:gz', format=tarfile.USTAR_FORMAT) as tar:
        entry = tarfile.TarInfo(name)
        entry.type = kind
        entry.size = len(content) if kind == tarfile.REGTYPE else 0
        entry.linkname = '/tmp' if kind in (tarfile.SYMTYPE, tarfile.LNKTYPE) else ''
        entry.mode = 0o644
        tar.addfile(entry, io.BytesIO(content) if entry.size else None)
    return out.getvalue()


def submit(dockerfile, context=None, multipart=False):
    if multipart:
        boundary = 'sandcube-' + secrets.token_hex(12)
        fields = [('dockerfile', dockerfile.encode()), ('build_args', b'{"MARKER":"installed-once"}'), ('context', context)]
        body = b''.join(b'--' + boundary.encode() + b'\r\nContent-Disposition: form-data; name="' + name.encode() + b'"\r\n\r\n' + data + b'\r\n' for name, data in fields)
        body += b'--' + boundary.encode() + b'--\r\n'
        result = api('POST', '/v1/images', body, 202, 'multipart/form-data; boundary=' + boundary)
    else:
        body = {'dockerfile': dockerfile}
        if context is not None:
            body['context_tar_gz'] = base64.b64encode(context).decode()
        result = api('POST', '/v1/images', body, 202)
    assert result['status'] == 'BUILDING'
    images.append(result['id'])
    return result['id']


def wait_image(iid, expected='READY'):
    deadline = time.monotonic() + 300
    while time.monotonic() < deadline:
        result = api('GET', '/v1/images/' + iid)
        if result['status'] != 'BUILDING':
            assert result['status'] == expected, result
            return result
        time.sleep(.2)
    raise AssertionError('Build timed out: ' + iid)


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


def health():
    for _ in range(100):
        try:
            api('GET', '/health')
            return
        except (OSError, AssertionError):
            time.sleep(.1)
    raise AssertionError('Services did not become healthy')


def execute(sid, command):
    result = api('POST', f'/v1/sandboxes/{sid}/exec', {'command': command})
    assert result['exit_code'] == 0, result
    return result['stdout']


def ctr(*args, check=True):
    return subprocess.run(['ctr', '--address', ADDRESS, '-n', NAMESPACE, *args], text=True, capture_output=True, check=check)


with tempfile.TemporaryDirectory(prefix='sc-images-') as work:
    root = Path(work) / 'builds'
    sock = work + '/runtime.sock'
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0))
        port = probe.getsockname()[1]
    base = f'http://127.0.0.1:{port}'
    env = dict(os.environ, DATABASE_URL=DATABASE, SANDCUBE_RUNTIME_SOCKET=sock, SANDCUBE_API_KEY=TOKEN,
        SANDCUBE_PORT=str(port), SANDCUBE_BUILD_ROOT=str(root))
    with open(work + '/services.log', 'w+') as log:
        try:
            adapter = start('containerd-runtime', ['-socket', sock, '-containerd', ADDRESS, '-namespace', NAMESPACE,
                '-runsc-config', str(ROOT / 'infra/gvisor/runsc.toml'), '-build-root', str(root)], env, log)
            service = start('sandcube', [], env, log)
            health()
            # Includes RUN package installation, COPY, ARG, ENV, and WORKDIR semantics.
            dockerfile = '''FROM alpine:3.22
RUN apk add --no-cache curl
ARG MARKER
ENV IMAGE_MARKER=$MARKER
WORKDIR /workspace
COPY proof.txt /workspace/proof.txt
RUN echo built > /workspace/build-marker
'''
            iid = submit(dockerfile, archive(), multipart=True)
            ready = wait_image(iid)
            assert ready['oci_digest'].startswith('sha256:')
            assert not list(root.glob('build-*'))
            print('PASS: multipart Dockerfile/context/arguments, BuildKit build, OCI import, READY metadata, cleanup', flush=True)

            # Break the buildctl command after building: later creations must not invoke it.
            stop(service)
            env['SANDCUBE_BUILDCTL'] = '/does-not-exist-buildctl'
            service = start('sandcube', [], env, log)
            health()
            assert api('GET', '/v1/images/' + iid)['oci_digest'] == ready['oci_digest']
            for _ in range(2):
                result = api('POST', '/v1/sandboxes', {'image_id': iid, 'command': ['/bin/sleep', 'infinity']}, 201)
                sandboxes.append(result['id'])
                assert result['image_id'] == iid
                assert 'curl ' in execute(result['id'], ['curl', '--version'])
                assert execute(result['id'], ['/bin/cat', '/workspace/proof.txt']) == 'original\n'
                assert execute(result['id'], ['/bin/sh', '-c', 'echo "$IMAGE_MARKER"; pwd']) == 'installed-once\n/workspace\n'
            first, second = sandboxes
            execute(first, ['/bin/sh', '-c', 'echo changed > /workspace/proof.txt'])
            assert execute(second, ['/bin/cat', '/workspace/proof.txt']) == 'original\n'
            api('POST', f'/v1/sandboxes/{first}/stop')
            assert api('DELETE', '/v1/images/' + iid, expected=409)['error']['code'] == 'IMAGE_IN_USE'
            # Runtime independently checks references even if the metadata API is bypassed.
            req = json.dumps({'reference': ready['oci_reference']}).encode()
            with socket.socket(socket.AF_UNIX) as conn:
                conn.connect(sock)
                conn.sendall(b'POST /images/delete HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: ' + str(len(req)).encode() + b'\r\n\r\n' + req)
                response = b''
                while chunk := conn.recv(4096):
                    response += chunk
            assert b'409 Conflict' in response and b'IMAGE_IN_USE' in response, response
            api('POST', f'/v1/sandboxes/{first}/start')
            assert execute(first, ['/bin/cat', '/workspace/proof.txt']) == 'changed\n'
            print('PASS: two gVisor sandboxes, no rebuild possible, tools/files/ENV/WORKDIR, independent snapshots, stopped references protected', flush=True)

            stop(service)
            env['SANDCUBE_BUILDCTL'] = os.environ.get('SANDCUBE_BUILDCTL', 'buildctl')
            service = start('sandcube', [], env, log)
            health()
            failed = submit('FROM alpine:3.22\nRUN echo intentional-failure >&2; exit 23\n')
            failure = wait_image(failed, 'ERROR')
            assert 'intentional-failure' in failure['error_message']
            assert not list(root.glob('build-*'))
            assert ctr('images', 'list', '-q').stdout.find(failure['oci_reference']) == -1
            api('POST', '/v1/sandboxes', {'image_id': failed, 'command': ['sleep']}, 409)
            api('POST', '/v1/sandboxes', {'image_id': 'img_missing', 'command': ['sleep']}, 404)
            for name, kind in [('../escape', tarfile.REGTYPE), ('/tmp/escape', tarfile.REGTYPE), ('x/../../escape', tarfile.REGTYPE), ('link', tarfile.SYMTYPE), ('hard', tarfile.LNKTYPE)]:
                api('POST', '/v1/images', {'dockerfile': 'FROM scratch', 'context_tar_gz': base64.b64encode(archive(name, kind=kind)).decode()}, 400)
                assert not list(root.glob('build-*'))
            print('PASS: failed RUN persists ERROR/logs, rejected missing/failed images, traversal/absolute/link archives, failure cleanup', flush=True)

            # Rollback must release image reservations when no container survives.
            api('POST', '/v1/sandboxes', {'image_id': iid, 'command': ['/does-not-exist']}, 500)
            api('DELETE', '/v1/sandboxes/' + first)
            sandboxes.remove(first)
            api('DELETE', '/v1/images/' + iid, expected=409)
            api('DELETE', '/v1/sandboxes/' + second)
            sandboxes.remove(second)
            api('DELETE', '/v1/images/' + iid)
            api('DELETE', '/v1/images/' + iid)
            assert api('GET', '/v1/images/' + iid)['status'] == 'DELETED'
            assert ready['oci_reference'] not in ctr('images', 'list', '-q').stdout.split()
            assert first not in ctr('snapshots', 'list').stdout and second not in ctr('snapshots', 'list').stdout
            api('POST', '/v1/sandboxes', {'image_id': iid, 'command': ['sleep']}, 409)
            print('PASS: failed-start rollback, final-reference deletion, idempotency, runtime image/snapshot removal', flush=True)
        except BaseException:
            log.flush()
            log.seek(0)
            print(log.read())
            raise
        finally:
            for sid in sandboxes:
                try:
                    api('DELETE', '/v1/sandboxes/' + sid)
                except Exception as e:
                    print('Sandbox cleanup failed:', sid, e)
            for iid in images:
                try:
                    api('DELETE', '/v1/images/' + iid)
                except Exception as e:
                    print('Image cleanup failed:', iid, e)
            for process in reversed(processes):
                if process.poll() is None:
                    stop(process)
