#!/usr/bin/env python3
"""Phase 4 real PostgreSQL/containerd/gVisor SIGKILL and lost-response tests.
Requires a dedicated TEST_DATABASE_URL and empty sandcube-test namespace.
The Unix HTTP proxy injects faults without adding production fault switches.
"""
import concurrent.futures
import fcntl
import http.client
import http.server
import json
import os
from pathlib import Path
import secrets
import socket
import socketserver
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
ADDRESS = os.environ.get('SANDCUBE_CONTAINERD', '/run/sandcube-containerd/containerd.sock')
DATABASE = os.environ['TEST_DATABASE_URL']
IMAGE = 'docker.io/library/busybox:1.37.0'
NS = 'sandcube-test'
TOKEN = secrets.token_hex(32)
children = []
fault = None
api_process = adapter = None
lock = (ROOT / '.integration.lock').open('a')
fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)

def ctr(*args):
    return subprocess.run(['ctr', '--address', ADDRESS, '-n', NS, *args], capture_output=True, text=True, check=True).stdout

def sql(query):
    return subprocess.run(['psql', DATABASE, '-v', 'ON_ERROR_STOP=1', '-At'], input=query, text=True, capture_output=True, check=True).stdout.strip()

def kill(p):
    if p and p.poll() is None:
        p.kill()
        p.wait(timeout=15)

def launch(binary, args, env, log):
    p = subprocess.Popen([str(ROOT / 'bin' / binary), *args], env=env, stdout=log, stderr=log)
    children.append(p)
    return p

class UnixConnection(http.client.HTTPConnection):
    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(60)
        self.sock.connect(real_socket)

class Proxy(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass
    def forward(self):
        global fault
        body = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        armed = fault
        matches = armed and self.command == armed[0] and (self.path == armed[1] or (armed[1].startswith('*') and self.path.endswith(armed[1][1:])))
        if matches:
            fault = None
            if not armed[2]:
                kill(api_process)
                kill(adapter)
                return
        conn = UnixConnection('localhost', timeout=60)
        try:
            conn.request(self.command, self.path, body, {'Content-Type': 'application/json'})
            response = conn.getresponse()
            raw = response.read()
            if matches:
                assert response.status < 300, (response.status, raw)
                kill(api_process)
                kill(adapter)
                return
            self.send_response(response.status)
            self.send_header('Content-Length', str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)
        except (OSError, http.client.HTTPException):
            self.close_connection = True
        finally:
            conn.close()
    do_GET = do_POST = do_DELETE = forward

class UnixServer(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True

def api(method, path, body=None, key=None, expected=200, base_url=None):
    headers = {'Authorization': 'Bearer ' + TOKEN, 'Content-Type': 'application/json'}
    if key:
        headers['Idempotency-Key'] = key
    req = urllib.request.Request((base_url or base) + path, data=json.dumps(body).encode() if body is not None else None, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=90) as response:
            code, raw = response.status, response.read()
    except urllib.error.HTTPError as ex:
        code, raw = ex.code, ex.read()
    assert code == expected, (method, path, code, raw)
    return raw.decode() if path == '/metrics' else json.loads(raw)

def healthy():
    for _ in range(150):
        try:
            api('GET', '/health')
            return
        except (OSError, AssertionError, http.client.HTTPException):
            time.sleep(.1)
    raise AssertionError('services not healthy')

def restart():
    global api_process, adapter
    kill(api_process)
    kill(adapter)
    adapter = launch('containerd-runtime', ['-socket', real_socket, '-containerd', ADDRESS, '-namespace', NS, '-runsc-config', str(ROOT / 'infra/gvisor/runsc.toml'), '-history-root', work + '/history'], env, log)
    for _ in range(100):
        try:
            c = UnixConnection('localhost'); c.request('GET', '/health'); r = c.getresponse(); r.read(); c.close()
            if r.status == 200:
                break
        except (OSError, http.client.HTTPException):
            pass
        time.sleep(.1)
    api_process = launch('sandcube', [], env, log)
    healthy()

def eventually(fn):
    for _ in range(150):
        if fn():
            return
        time.sleep(.1)
    raise AssertionError('eventual convergence failed')

assert not ctr('containers', 'list', '-q').strip(), 'Use an empty dedicated test namespace'
# Refuse to sweep someone else's records in a shared database.
assert sql("SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_name='sandboxes'") == '0' or sql("SELECT count(*) FROM sandboxes WHERE status!='deleted'") == '0', 'Use a dedicated test database'
with tempfile.TemporaryDirectory(prefix='sc-p4-') as work:
    real_socket = work + '/runtime.sock'
    proxy_socket = work + '/proxy.sock'
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0)); port = probe.getsockname()[1]
    base = f'http://127.0.0.1:{port}'
    env = dict(os.environ, DATABASE_URL=DATABASE, SANDCUBE_RUNTIME_SOCKET=proxy_socket, SANDCUBE_API_KEY=TOKEN, SANDCUBE_PORT=str(port), SANDCUBE_RECONCILE_SECONDS='1')
    proxy = UnixServer(proxy_socket, Proxy)
    threading.Thread(target=proxy.serve_forever, daemon=True).start()
    with open(work + '/services.log', 'w+') as log:
        try:
            restart()
            body = {'image': IMAGE, 'command': ['/bin/sleep', 'infinity']}
            for after in (False, True):
                for action in ('create', 'start', 'stop', 'delete'):
                    key = secrets.token_hex(12)
                    if action == 'create':
                        method, path, payload, expected = 'POST', '/v1/sandboxes', body, 201
                        target = '/containers'
                    else:
                        sandbox = api('POST', '/v1/sandboxes', body, expected=201)
                        sid = sandbox['id']
                        if action == 'start':
                            api('POST', f'/v1/sandboxes/{sid}/stop')
                        method = 'DELETE' if action == 'delete' else 'POST'
                        path = f'/v1/sandboxes/{sid}' + ('' if action == 'delete' else '/' + action)
                        payload, expected = None, 200
                        target = path.replace('/v1/sandboxes', '/containers')
                    fault = (method, target, after)
                    try:
                        api(method, path, payload, key, expected)
                        raise AssertionError('injected request unexpectedly completed')
                    except (OSError, http.client.HTTPException):
                        pass
                    assert fault is None
                    restart()
                    result = api(method, path, payload, key, expected)
                    assert result['status'] == {'create': 'running', 'start': 'running', 'stop': 'stopped', 'delete': 'deleted'}[action]
                    assert api(method, path, payload, key, expected) == result
                    api('POST', '/v1/sandboxes', {'image': IMAGE, 'command': ['/bin/true']}, key, 409)
                    api('DELETE', '/v1/sandboxes/' + result['id'])
                    print(f'PASS: SIGKILL {"after" if after else "before"} {action}, convergence and stable retry', flush=True)
            # Concurrent creates return one identity, including retries after service death.
            key = secrets.token_hex(12)
            with socket.socket() as probe:
                probe.bind(('127.0.0.1', 0)); second_port = probe.getsockname()[1]
            second_base = f'http://127.0.0.1:{second_port}'
            second_api = launch('sandcube', [], dict(env, SANDCUBE_PORT=str(second_port), SANDCUBE_IMAGE_API_ENABLED='false'), log)
            for _ in range(100):
                try:
                    api('GET', '/health', base_url=second_base)
                    break
                except (OSError, http.client.HTTPException):
                    time.sleep(.1)
            with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
                rows = list(pool.map(lambda i: api('POST', '/v1/sandboxes', body, key, 201, second_base if i % 2 else base), range(6)))
            kill(second_api)
            assert len({r['id'] for r in rows}) == 1
            sid = rows[0]['id']; prefix = '/v1/sandboxes/' + sid
            finished = api('POST', prefix + '/processes', {'command': ['/bin/sh', '-c', 'echo completed; echo err-completed >&2; exit 23']}, expected=202)
            eventually(lambda: api('GET', prefix + '/processes/' + finished['id'])['status'] == 'exited')
            live = api('POST', prefix + '/processes', {'command': ['/bin/sh', '-c', 'echo before; sleep 2; echo during; echo err-during >&2; echo preserved >/proof; sleep 2; echo after; exit 17']}, expected=202)
            kill(api_process); kill(adapter)
            time.sleep(5)
            restart()
            for proc, code in ((finished, 23), (live, 17)):
                pp = prefix + '/processes/' + proc['id']
                eventually(lambda: api('GET', pp)['status'] == 'exited')
                assert api('GET', pp)['exit_code'] == code
            logs = api('GET', prefix + '/processes/' + live['id'] + '/logs')
            assert logs['stdout'] == 'before\nduring\nafter\n' and logs['stderr'] == 'err-during\n', logs
            assert api('POST', prefix + '/exec', {'command': ['/bin/cat', '/proof']})['stdout'] == 'preserved\n'
            api('POST', prefix + '/stop'); restart(); api('POST', prefix + '/start')
            assert api('POST', prefix + '/exec', {'command': ['/bin/cat', '/proof']})['stdout'] == 'preserved\n'
            live_key = secrets.token_hex(12)
            live_body = {'command': ['/bin/sh', '-c', 'echo once >>/launches; echo alive; sleep 600']}
            active = api('POST', prefix + '/processes', live_body, live_key, 202)
            kill(api_process); kill(adapter)
            record = Path(work) / 'history' / NS / sid / active['id'] / 'process.json'
            pending = json.loads(record.read_text()); pending['status'] = 'starting'
            record.write_text(json.dumps(pending))
            restart()
            retry = api('POST', prefix + '/processes', live_body, live_key, 202)
            assert retry['id'] == active['id'] and retry['status'] == 'running'
            api('POST', prefix + '/processes', {'command': ['/bin/true']}, live_key, 409)
            api('POST', prefix + '/processes/' + active['id'] + '/kill')
            assert api('POST', prefix + '/exec', {'command': ['/bin/cat', '/launches']})['stdout'] == 'once\n'
            exec_key = secrets.token_hex(12)
            exec_body = {'command': ['/bin/sh', '-c', 'echo once >>/exec-retries; cat /exec-retries']}
            fault = ('POST', '/containers/' + sid + '/exec', True)
            try:
                api('POST', prefix + '/exec', exec_body, exec_key)
                raise AssertionError('exec fault missed')
            except (OSError, http.client.HTTPException):
                pass
            restart()
            assert api('POST', prefix + '/exec', exec_body, exec_key)['stdout'] == 'once\n'
            assert api('POST', prefix + '/exec', {'command': ['/bin/cat', '/exec-retries']})['stdout'] == 'once\n'
            print('PASS: completed/live history, exit during outage, separate logs, files and stop/start persistence', flush=True)
            metrics = api('GET', '/metrics')
            assert 'sandcube_runtime_up 1' in metrics and 'sandcube_snapshot_bytes' in metrics and 'sandcube_processes_retained' in metrics
            assert 'sandcube_memory_usage_bytes' in metrics and 'sandcube_cpu_usage_seconds_total' in metrics, metrics
            api('DELETE', prefix)
            for stopped in (False, True):
                sb = api('POST', '/v1/sandboxes', dict(body, ttl_seconds=3), expected=201)
                if stopped:
                    api('POST', '/v1/sandboxes/' + sb['id'] + '/stop')
                eventually(lambda: api('GET', '/v1/sandboxes/' + sb['id'])['status'] == 'deleted')
            # Make a labelled orphan through the adapter, bypassing PostgreSQL.
            orphan = 'sbx_' + secrets.token_hex(16)
            c = UnixConnection('localhost');c.request('POST', '/containers', json.dumps(dict(id=orphan,image=IMAGE,command=['/bin/sleep','infinity'],cpu=1,memory_mb=256,pids=128)));r=c.getresponse();r.read();assert r.status==201;c.close()
            eventually(lambda: orphan not in ctr('containers','list','-q'))
            snapshot = 'sbx_' + secrets.token_hex(16)
            foreign = 'foreign_' + secrets.token_hex(16)
            ctr('snapshots', 'prepare', snapshot)
            ctr('snapshots', 'label', snapshot, 'sandcube.managed=true')
            ctr('snapshots', 'prepare', foreign)
            try:
                eventually(lambda: snapshot not in ctr('snapshots','list'))
                assert foreign in ctr('snapshots','list')
            finally:
                ctr('snapshots','remove',foreign)
            assert IMAGE in ctr('images','list','-q')
            assert not ctr('containers','list','-q').strip()
            print('PASS: metrics, running/stopped TTL, orphan cleanup, reusable image preserved', flush=True)
        except BaseException:
            log.flush();log.seek(0);print(log.read()[-16000:])
            raise
        finally:
            fault = None
            for p in children:
                kill(p)
            proxy.shutdown();proxy.server_close()
            # This test requires an empty namespace and owns everything it creates.
            for sid in ctr('containers','list','-q').split():
                subprocess.run(['ctr','--address',ADDRESS,'-n',NS,'tasks','kill','--signal','SIGKILL',sid],capture_output=True)
                subprocess.run(['ctr','--address',ADDRESS,'-n',NS,'tasks','delete',sid],capture_output=True)
                subprocess.run(['ctr','--address',ADDRESS,'-n',NS,'containers','delete',sid],capture_output=True)
                subprocess.run(['ctr','--address',ADDRESS,'-n',NS,'snapshots','remove',sid],capture_output=True)
