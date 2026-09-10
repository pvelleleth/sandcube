"""Phase 3 checks reused by the real runtime acceptance harness."""
import concurrent.futures
import time
import urllib.error
import urllib.parse
import urllib.request


def check_phase3(api, execute, base, token, sid, other, reconnect_api):
    prefix = f'/v1/sandboxes/{sid}'

    def file(method, path, data=None, content=True, expected=200, mode=None):
        url = base + prefix + '/files' + ('/content' if content else '')
        url += '?' + urllib.parse.urlencode({'path': path})
        if mode is not None:
            url += '&mode=' + mode
        req = urllib.request.Request(url, data=data, method=method,
            headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/octet-stream'})
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                status, result = r.status, r.read()
        except urllib.error.HTTPError as e:
            status, result = e.code, e.read()
        assert status == expected, (method, path, status, result[:1000])
        return result

    def start(argv):
        return api('POST', prefix + '/processes', {'command': argv}, expected=202)

    def wait(pid):
        for _ in range(200):
            p = api('GET', prefix + '/processes/' + pid)
            if p['status'] != 'running':
                return p
            time.sleep(.05)
        raise AssertionError('process did not finish: ' + pid)

    file('POST', '/phase3', content=False)
    payload = bytes(range(256)) * 1024
    file('PUT', '/phase3/binary', payload)
    assert file('GET', '/phase3/binary') == payload
    assert execute(sid, ['/bin/cat', '/phase3/binary'])['exit_code'] == 0
    file('PUT', '/phase3/binary', b'replaced')
    replaced = execute(sid, ['/bin/cat', '/phase3/binary'])
    assert replaced['stdout'] == 'replaced', (replaced['stdout'][:100], replaced['stderr'])
    file('PUT', '/phase3/binary', payload)
    file('PUT', '/phase3/empty', b'')
    assert file('GET', '/phase3/empty') == b''
    file('DELETE', '/phase3', content=False, expected=409)
    file('GET', '/phase3/missing', expected=404)
    file('PUT', '/phase3/binary', b'x' * (16 * 1024 * 1024 + 1), expected=413)
    assert file('GET', '/phase3/binary') == payload
    for path in ['/../etc/passwd', '/phase3/../../etc/passwd', '../host']:
        file('GET', path, expected=400)
        file('PUT', path, b'attack', expected=400)
    setup = execute(sid, ['/bin/sh', '-c', 'ln -s /etc /phase3/absolute; ln -s ../../etc /phase3/relative; ln -s /proc/1/root /phase3/magic; mkfifo /phase3/fifo'])
    assert setup['exit_code'] == 0, setup
    for path in ['/phase3/absolute/passwd', '/phase3/relative/passwd', '/phase3/magic/etc/passwd']:
        file('GET', path, expected=400)
        file('PUT', path, b'attack', expected=400)
    file('DELETE', '/phase3/absolute', content=False)
    assert execute(sid, ['/bin/test', '-f', '/etc/passwd'])['exit_code'] == 0
    print('PASS: binary/empty transfers, atomic oversized rejection, traversal, symlinks, live cache coherence and directory operations', flush=True)

    # Failed launch must neither hang nor leave a tracked process behind.
    previous = api('GET', prefix + '/processes')
    api('POST', prefix + '/processes', {'command': ['/does-not-exist']}, expected=500)
    history = api('GET', prefix + '/processes')
    failures = [p for p in history if p['id'] not in {old['id'] for old in previous}]
    assert len(failures) == 1 and failures[0]['status'] == 'error'

    # Upload a generic small application; each API call opens a fresh connection.
    file('PUT', '/phase3/app.sh', b'#!/bin/sh\necho ready; echo diagnostic >&2; echo artifact > /phase3/generated; exec sleep 600\n', mode='0755')
    before = time.monotonic()
    app = start(['/phase3/app.sh'])
    assert time.monotonic() - before < 10 and app['id'].startswith('proc_'), app
    pid = app['id']
    reconnect_api()  # Public API restart also must not terminate detached work.
    time.sleep(.3)
    logs = api('GET', prefix + '/processes/' + pid + '/logs')
    assert logs['stdout'] == 'ready\n' and logs['stderr'] == 'diagnostic\n', logs
    assert file('GET', '/phase3/generated') == b'artifact\n'
    assert pid in [p['id'] for p in api('GET', prefix + '/processes')]
    api('GET', f'/v1/sandboxes/{other}/processes/{pid}', expected=404)
    killed = api('POST', prefix + '/processes/' + pid + '/kill')
    assert killed['status'] == 'exited' and killed['exit_code'] != 0, killed
    assert api('POST', prefix + '/processes/' + pid + '/kill')['exit_code'] == killed['exit_code']
    print('PASS: upload application, detached start, disconnect/reconnect, logs/artifacts and idempotent cancellation', flush=True)

    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        active = list(pool.map(lambda i: start(['/bin/sh', '-c', f'echo process-{i}; sleep 1; exit {i}']), range(8)))
    for i, p in enumerate(active):
        result = wait(p['id'])
        assert result['exit_code'] == i, result
        assert api('GET', prefix + '/processes/' + p['id'] + '/logs')['stdout'] == f'process-{i}\n'
    noisy = start(['/bin/sh', '-c', 'head -c 5000000 /dev/zero; head -c 5000000 /dev/zero >&2'])
    assert wait(noisy['id'])['exit_code'] == 0
    logs = api('GET', prefix + '/processes/' + noisy['id'] + '/logs')
    assert logs['truncated'] and len(logs['stdout']) == len(logs['stderr']) == 1048576
    print('PASS: concurrent processes, independent exit codes/logs and large output draining', flush=True)

    active = [start(['/bin/sleep', '600']) for _ in range(3)]
    api('POST', prefix + '/stop')
    # Files are available even while stopped, without launching an environment.
    assert file('GET', '/phase3/binary') == payload
    file('PUT', '/phase3/stopped', b'written while stopped')
    for p in active:
        assert api('GET', prefix + '/processes/' + p['id'])['status'] == 'exited'
    api('POST', prefix + '/processes', {'command': ['/bin/true']}, expected=409)
    api('POST', prefix + '/start')
    assert file('GET', '/phase3/stopped') == b'written while stopped'
    assert file('GET', '/phase3/generated') == b'artifact\n'
    assert all(p['status'] != 'running' for p in api('GET', prefix + '/processes'))
    assert 'sleep 600' not in execute(sid, ['/bin/ps', '-o', 'args'])['stdout']
    print('PASS: stop/start preserves uploaded/generated files, permits stopped file access, and never resumes previous processes', flush=True)

    # A separate sandbox proves deletion handles active processes and does not
    # hold a lock for the lifetime of a detached command.
    api('POST', f'/v1/sandboxes/{other}/stop')
    doomed = api('POST', '/v1/sandboxes', {'image': 'docker.io/library/busybox:1.37.0', 'command': ['/bin/sleep', 'infinity']}, expected=201)['id']
    dp = f'/v1/sandboxes/{doomed}'
    try:
        for _ in range(3):
            api('POST', dp + '/processes', {'command': ['/bin/sleep', '600']}, expected=202)
        api('DELETE', dp)
        assert api('GET', dp)['status'] == 'deleted'
        api('GET', dp + '/processes', expected=404)
    finally:
        api('DELETE', dp)
        api('POST', f'/v1/sandboxes/{other}/start')
    print('PASS: delete with running processes', flush=True)
