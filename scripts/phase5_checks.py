"""Real API/containerd/XFS/netns acceptance; imported by the crash harness."""
import concurrent.futures
import hashlib
import http.server
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import threading
import time


def check_phase5(g):
    api, restart, eventually, ctr = (g[k] for k in ('api', 'restart', 'eventually', 'ctr'))
    body = dict(g['body'])
    def execute(sid, command, timeout=15):
        return api('POST', f'/v1/sandboxes/{sid}/exec', {'command': command, 'timeout_seconds': timeout})
    def shell(sid, script, timeout=15):
        return execute(sid, ['/bin/sh', '-c', script], timeout)
    def name(sid):
        return 'scn' + hashlib.sha256((g['NS'] + '/' + sid).encode()).hexdigest()[:12]
    def network(sid):
        return json.loads((Path(g['work'])/'history'/g['NS']/'.networks'/f'{sid}.json').read_text())
    def clean(sid):
        assert not Path('/run/netns', name(sid)).exists()
        tables = subprocess.check_output(['nft', '-j', 'list', 'tables'], text=True)
        assert name(sid) not in tables
        assert not (Path(g['work'])/'history'/g['NS']/'.quotas'/f'{sid}.json').exists()
        assert not (Path(g['work'])/'history'/g['NS']/'.networks'/f'{sid}.json').exists()
    def delete(sid):
        api('DELETE', '/v1/sandboxes/' + sid)
        clean(sid)

    # Every capacity dimension has separate database race tests. Exercise the
    # actual API boundary, stop semantics and concurrent admission here too.
    sb = api('POST', '/v1/sandboxes', dict(body, cpu=2), expected=201)
    sid = sb['id']
    assert sb['disk_mb'] == 32
    api('POST', '/v1/sandboxes', body, expected=409)
    api('POST', f'/v1/sandboxes/{sid}/stop')
    assert 'sandcube_allocated_cpu 0\n' in api('GET', '/metrics')
    assert 'sandcube_allocated_disk_mb 32\n' in api('GET', '/metrics')
    other = api('POST', '/v1/sandboxes', dict(body, cpu=2), expected=201)['id']
    api('POST', f'/v1/sandboxes/{sid}/start', expected=409)
    delete(other)
    api('POST', f'/v1/sandboxes/{sid}/start')
    delete(sid)
    def create_racer(i):
        try:
            return api('POST', '/v1/sandboxes', dict(body,cpu=2), expected=201)
        except AssertionError as ex:
            assert '409' in str(ex) and 'INSUFFICIENT_CAPACITY' in str(ex)
            return None
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        rows = [row for row in pool.map(create_racer,range(4)) if row]
    assert len(rows)==1
    delete(rows[0]['id'])
    print('PASS: real concurrent admission, stop/start reservation semantics and deletion release', flush=True)

    sid = api('POST', '/v1/sandboxes', body, expected=201)['id']
    other = api('POST', '/v1/sandboxes', body, expected=201)['id']
    # Download a real package over public DNS/HTTPS and verify it is an archive.
    url = os.environ.get('SANDCUBE_TEST_PACKAGE_URL', 'https://dl-cdn.alpinelinux.org/alpine/v3.22/main/x86_64/APKINDEX.tar.gz')
    result = execute(sid, ['/bin/wget', '-T', '15', '-O', '/package.tar.gz', url], 40)
    assert result['exit_code']==0, result
    assert shell(sid, 'tar -tzf /package.tar.gz | grep APKINDEX')['exit_code']==0
    # Serve a known reachable host endpoint and another sandbox endpoint. Test
    # both private and public host addresses; fib lookup covers changing IPs.
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200); self.end_headers(); self.wfile.write(b'protected')
        def log_message(self,*args):
            pass
    server = http.server.ThreadingHTTPServer(('0.0.0.0',0),Handler)
    threading.Thread(target=server.serve_forever,daemon=True).start()
    port=server.server_port
    api('POST', f'/v1/sandboxes/{other}/processes', {'command':['/bin/httpd','-f','-p',str(port)]}, expected=202)
    try:
        addresses = json.loads(subprocess.check_output(['ip','-j','-4','addr','show'],text=True))
        targets = [a['local'] for link in addresses for a in link.get('addr_info',[]) if a['scope']=='global']
        targets += [network(sid)['Gateway'], network(other)['Guest'], '169.254.169.254', '100.100.100.200', '168.63.129.16', '10.0.0.1', '172.16.0.1', '192.168.0.1']
        for address in dict.fromkeys(targets):
            result=execute(sid,['/bin/wget','-T','1','-O','/dev/null',f'http://{address}:{port}/'],5)
            assert result['exit_code']!=0, (address,result)
        # DNS rebinding/hostnames cannot bypass packet destination enforcement.
        assert shell(sid, f"echo '{network(other)['Guest']} protected.test' >> /etc/hosts; wget -T 1 -O /dev/null http://protected.test:{port}/")['exit_code']!=0
        assert shell(sid, 'wget -T 1 -O /dev/null http://[fd00:ec2::254]/')['exit_code']!=0
        rules=subprocess.check_output(['nft','list','table','inet',name(sid)],text=True)
        assert 'counter packets 0 bytes 0 drop' in rules  # unused defenses exist
        assert any('counter packets ' in line and 'counter packets 0 ' not in line for line in rules.splitlines()), rules
        restart()
        assert execute(sid,['/bin/wget','-T','1','-O','/dev/null',f'http://{network(other)["Guest"]}:{port}/'],5)['exit_code']!=0
        assert execute(sid,['/bin/wget','-T','15','-O','/package.tar.gz',url],40)['exit_code']==0
    finally:
        server.shutdown(); server.server_close()
    print('PASS: package download, DNS, host/public/private/metadata/peer blocking and crash persistence', flush=True)

    # Fill physical blocks (not a sparse file): root inside gVisor cannot bypass
    # project quotas. The same hard limit must hold for stopped API writes.
    result=shell(sid,'dd if=/dev/zero of=/fill bs=1048576 count=64',30)
    assert result['exit_code']!=0 and ('quota' in result['stderr'].lower() or 'space' in result['stderr'].lower()), result
    assert int(shell(sid,'stat -c %s /fill')['stdout']) <= 32*1024*1024
    restart()
    result=shell(sid,'dd if=/dev/zero of=/more bs=1048576 count=4',10)
    assert result['exit_code']!=0, result
    guest=network(sid)['Guest']
    tracked=subprocess.run(['conntrack','-L','-f','ipv4','--orig-src',guest],capture_output=True,text=True,check=True).stdout
    assert 'src='+guest in tracked, tracked
    api('POST',f'/v1/sandboxes/{sid}/stop')
    assert not subprocess.run(['conntrack','-L','-f','ipv4','--orig-src',guest],capture_output=True,text=True,check=True).stdout.strip()
    # Write enough binary data through the public API to exceed remaining space.
    import urllib.request, urllib.error
    req=urllib.request.Request(g['base']+f'/v1/sandboxes/{sid}/files/content?path=/api-fill',data=b'x'*(4<<20),method='PUT',headers={'Content-Type':'application/octet-stream'})
    try:
        urllib.request.urlopen(req,timeout=30)
        raise AssertionError('stopped file API bypassed project quota')
    except urllib.error.HTTPError as ex:
        assert ex.code==413, (ex.code,ex.read())
    api('DELETE',f'/v1/sandboxes/{sid}/files?path=/fill')
    api('POST',f'/v1/sandboxes/{sid}/start')
    assert shell(sid,'echo recovered >/proof; cat /proof')['stdout']=='recovered\n'
    delete(sid); delete(other)
    assert 'sandcube_allocated_disk_mb 0\n' in api('GET','/metrics')
    print('PASS: guest/stopped-API disk enforcement, crash/stop/start persistence, physical cleanup', flush=True)

    # Exercise cgroups with real CPU load and a bounded memory OOM workload.
    sid=api('POST','/v1/sandboxes',dict(body,memory_mb=128),expected=201)['id']
    info=json.loads(ctr('containers','info',sid))
    cg=Path('/sys/fs/cgroup')/info['Spec']['linux']['cgroupsPath'].lstrip('/')
    assert (cg/'cpu.max').read_text().strip()=='100000 100000'
    assert (cg/'memory.max').read_text().strip()==str(128<<20)
    assert (cg/'memory.swap.max').read_text().strip()=='0'
    assert (cg/'memory.oom.group').read_text().strip()=='1'
    assert (cg/'pids.max').read_text().strip()=='128'
    def stat(file):
        return dict((k,int(v)) for k,v in (line.split() for line in (cg/file).read_text().splitlines()))
    before=stat('cpu.stat')['usage_usec']; started=time.monotonic()
    result=shell(sid,'while :; do :; done & a=$!; while :; do :; done & b=$!; sleep 3; kill $a $b; wait; true',10)
    elapsed=time.monotonic()-started
    used=(stat('cpu.stat')['usage_usec']-before)/1e6
    assert result['exit_code']==0 and used>0.1 and used<=elapsed*1.25+0.1, (result,used,elapsed)
    api('POST',f'/v1/sandboxes/{sid}/processes',{'command':['/bin/awk','BEGIN { s="xxxxxxxxxxxxxxxx"; for(j=0;j<16;j++) s=s s; for(i=0;;i++) a[i]=s i }']},expected=202)
    eventually(lambda: stat('memory.events')['oom_kill']>0)
    # The entire sentry may be killed; reconciliation must release compute while
    # preserving disk until deletion has reclaimed the stopped environment.
    eventually(lambda: api('GET','/v1/sandboxes/'+sid)['status']=='stopped')
    assert 'sandcube_allocated_cpu 0\n' in api('GET','/metrics')
    delete(sid)
    print('PASS: CPU budget under load, kernel memory OOM enforcement, compute recovery and disk cleanup',flush=True)

    # A quota-bearing snapshot can outlive container metadata after a crash.
    # Startup must reclaim it, while the database conservatively retains its
    # reservation until the explicit delete operation verifies completion.
    sid=api('POST','/v1/sandboxes',body,expected=201)['id']
    api('POST',f'/v1/sandboxes/{sid}/stop')
    record=json.loads((Path(g['work'])/'history'/g['NS']/'.quotas'/f'{sid}.json').read_text())
    assert Path(record['Parent']).exists()
    ctr('containers','delete',sid)
    restart()
    eventually(lambda: not Path(record['Parent']).exists())
    assert 'sandcube_allocated_disk_mb 32\n' in api('GET','/metrics')
    delete(sid)
    print('PASS: quota-bearing orphan snapshot reclamation and conservative reservation recovery',flush=True)

    # Kill the adapter at internal network side effects using executable wrappers.
    # No production fault flags. Every operation is really executed by ip/nft.
    wrappers=Path(g['work'])/'wrappers'; wrappers.mkdir()
    marker=wrappers/'armed.json'
    for tool in ('ip','nft','conntrack'):
        real=subprocess.check_output(['which',tool],text=True).strip()
        wrapper=wrappers/tool
        wrapper.write_text('''#!/usr/bin/python3
import json,os,signal,subprocess,sys
from pathlib import Path
marker=Path(%r)
args=sys.argv[1:]
result=subprocess.run([%r,*args])
if result.returncode==0 and marker.exists():
    wanted=json.loads(marker.read_text())
    if wanted[0]==%r and args[:len(wanted)-1]==wanted[1:]:
        marker.unlink()
        os.kill(os.getppid(),signal.SIGKILL)
sys.exit(result.returncode)
''' % (str(marker),real,tool))
        wrapper.chmod(0o755)
    g['env']['PATH']=str(wrappers)+':'+g['env']['PATH']
    restart()
    for stage in [('nft','-f','-'),('ip','netns','add'),('ip','link','add'),('ip','addr','add'),('ip','link','set')]:
        marker.write_text(json.dumps(stage))
        key=secrets.token_hex(12)
        try:
            api('POST','/v1/sandboxes',body,key,201)
            raise AssertionError('network crash was not injected')
        except (AssertionError,OSError) as ex:
            assert not marker.exists(), ex
        restart()
        sid=api('POST','/v1/sandboxes',body,key,201)['id']
        assert execute(sid,['/bin/wget','-T','15','-O','/package.tar.gz',url],40)['exit_code']==0
        delete(sid)
    # Crash during conntrack reclamation and between firewall deletion and
    # removal of its durable ownership record.
    for stage in [('conntrack','-D'),('nft','delete','table')]:
        sid=api('POST','/v1/sandboxes',body,expected=201)['id']
        assert execute(sid,['/bin/wget','-T','15','-O','/package.tar.gz',url],40)['exit_code']==0
        marker.write_text(json.dumps(stage))
        try:
            api('DELETE','/v1/sandboxes/'+sid)
            raise AssertionError('cleanup crash was not injected')
        except (AssertionError,OSError) as ex:
            assert not marker.exists(), ex
        restart()
        eventually(lambda: api('GET','/v1/sandboxes/'+sid)['status']=='deleted')
        clean(sid)
    assert not list((Path(g['work'])/'history'/g['NS']/'.networks').glob('*.json'))
    assert not list((Path(g['work'])/'history'/g['NS']/'.quotas').glob('*.json'))
    print('PASS: SIGKILL during firewall/netns/veth/address/link setup and conntrack/firewall cleanup; journals fully reclaimed', flush=True)
