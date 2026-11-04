#!/usr/bin/env python3
"""Local reference-code tests. Fake VPN only; no external network or credentials."""
import os, sys, subprocess, tempfile, time, socket, select, signal, json
from pathlib import Path

base=Path(__file__).resolve().parents[1]/'build'
ref=base/'libexec'
bindir=base/'bin'
results=[]
fake_oc=r'''#!/usr/bin/env python3
import sys,os,time,signal,subprocess,shlex,datetime,getpass
if '--authenticate' in sys.argv:
    if '--passwd-on-stdin' in sys.argv: password=sys.stdin.readline().strip()
    else: password=getpass.getpass('Fake VPN password: ')
    if password!='offline-password':sys.exit(3)
    if os.environ.get('MOCK_AUTH_FAIL')=='1':sys.exit(3)
    print("COOKIE='OFFLINE-COOKIE-NEVER-REAL'")
    print("HOST='vpn.example.invalid'")
    print("CONNECT_URL='https://vpn.example.invalid/'")
    print("FINGERPRINT='sha256:"+'a'*64+"'")
    print('RESOLVE=')
    sys.exit(0)
cookie=sys.stdin.readline().strip()
assert cookie=='OFFLINE-COOKIE-NEVER-REAL'
assert not any(cookie in value for value in list(os.environ.values())+sys.argv)
parts=shlex.split(sys.argv[sys.argv.index('--script')+1])
assert parts.pop(0)=='exec'
p=subprocess.Popen(parts,preexec_fn=os.setpgrp)
def stop(*args):
    p.terminate()
    try:p.wait(timeout=2)
    except subprocess.TimeoutExpired:p.kill();p.wait()
    sys.exit(0)
signal.signal(signal.SIGINT,stop);signal.signal(signal.SIGTERM,stop)
print('Configured as 10.0.0.2, with SSL connected and DTLS in progress',flush=True)
expiry=datetime.datetime.utcnow()+datetime.timedelta(seconds=30)
print('Session authentication will expire at '+expiry.strftime('%a %b %d %H:%M:%S %Y'),flush=True)
deadline=time.time()+float(os.environ.get('MOCK_SESSION_SECONDS','8'))
while time.time()<deadline:time.sleep(.1)
p.terminate();p.wait();sys.exit(2)
'''
fake_proxy=r'''#!/usr/bin/env python3
import socket,sys,signal,os,threading,time
p=int(sys.argv[sys.argv.index('-D')+1]);s=socket.socket()
s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(('127.0.0.1',p));s.listen()
signal.signal(signal.SIGTERM,lambda *x:sys.exit(0))
def recvn(c,n):
    d=b''
    while len(d)<n:
        x=c.recv(n-len(d))
        if not x:raise EOFError
        d+=x
    return d
def serve(c):
    try:
        c.settimeout(5)
        hdr=recvn(c,2);recvn(c,hdr[1])
        c.sendall(b'\x05\x00')
        h=recvn(c,4);assert h[3]==3
        n=recvn(c,1)[0];host=recvn(c,n);port=int.from_bytes(recvn(c,2),'big')
        with open(os.environ['MOCK_SOCKS_LOG'],'a') as f:f.write('%s:%d\\n'%(host.decode(),port))
        fail=os.path.exists(os.environ['MOCK_SOCKS_FAIL'])
        c.sendall(b'\x05'+(b'\x04' if fail else b'\x00')+b'\x00\x01\x00\x00\x00\x00\x00\x00')
    except Exception:pass
    finally:c.close()
while True:
    c,_=s.accept();threading.Thread(target=serve,args=(c,),daemon=True).start()
'''

def wait_for(check,seconds=12):
    deadline=time.time()+seconds
    while time.time()<deadline:
        if check():return
        time.sleep(.1)
    raise AssertionError('Timed out waiting for expected state')

def login(env):
    # A real terminal is required by vpn-login. Only fake credentials enter it.
    import pty
    master,slave=pty.openpty()
    p=subprocess.Popen(['bash',str(bindir/'vpn-login')],stdin=slave,stdout=slave,stderr=slave,env=env,start_new_session=True)
    os.close(slave);out=b'';sent=False;deadline=time.time()+20
    while time.time()<deadline:
        if select.select([master],[],[],.1)[0]:
            try:chunk=os.read(master,8192)
            except OSError:break
            if not chunk:break
            out+=chunk
            if b'Fake VPN password:' in out and not sent:
                os.write(master,b'offline-password\n');sent=True
        if p.poll() is not None:break
    if p.poll() is None:p.kill()
    code=p.wait();os.close(master)
    assert b'OFFLINE-COOKIE-NEVER-REAL' not in out
    assert b'offline-password' not in out
    return code,out.decode(errors='replace')

with tempfile.TemporaryDirectory(prefix='vpn-handoff-test-') as work:
    root=Path(work);runtime=root/'runtime';runtime.mkdir(mode=0o700)
    oc=root/'fake-openconnect';oc.write_text(fake_oc);oc.chmod(0o700)
    proxy=root/'fake-proxy';proxy.write_text(fake_proxy);proxy.chmod(0o700)
    port_probe=socket.socket();port_probe.bind(('127.0.0.1',0));port=port_probe.getsockname()[1];port_probe.close()
    env=os.environ.copy()
    for k in list(env):
        if k.startswith(('OPENCONNECT_','VPN_','AUTH_MODE')):env.pop(k,None)
    env.update(VPN_LIBEXEC=str(ref),VPN_RUNTIME=str(runtime),OPENCONNECT_BIN=str(oc),OCPROXY_BIN=str(proxy),
               OPENCONNECT_URL='https://vpn.example.invalid',VPN_PROXY_PORT=str(port),MOCK_SESSION_SECONDS='8')
    # Imported shell variables must not turn the captured response into env data.
    env.update(auth='unrelated-exported-value',COOKIE='unrelated-cookie-value')
    raw="COOKIE='$(touch " + str(root/'must-not-exist') + ")'\nHOST='vpn.example.invalid'\nCONNECT_URL='https://vpn.example.invalid'\nFINGERPRINT='sha256:"+'a'*64+"'\nRESOLVE=\n"
    command='source "$VPN_LIBEXEC/vpn-common"; raw=$(cat); parse_session "$raw"'
    r=subprocess.run(['bash','-c',command],input=raw.encode(),env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    assert r.returncode==0 and not (root/'must-not-exist').exists()
    for bad in [raw+"COOKIE='duplicate'\n",raw+"UNEXPECTED='field'\n",raw.replace("HOST='vpn.example.invalid'","HOST='bad\tcontrol'"),raw.replace("RESOLVE=","RESOLVE='bad' trailing")]:
        r=subprocess.run(['bash','-c',command],input=bad.encode(),env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        assert r.returncode!=0
    results.append('PASS strict session parsing; literal command substitution is never executed; duplicates/control characters/extra fields rejected')
    log=root/'supervisor.log'
    with log.open('w') as output:
        service=subprocess.Popen(['bash',str(bindir/'vpn-service')],env=env,stdout=output,stderr=subprocess.STDOUT)
        try:
            wait_for(lambda:(runtime/'control').exists())
            assert 'state=AUTH_REQUIRED' in (runtime/'status').read_text()
            assert subprocess.call(['bash',str(bindir/'vpn-status'),'--health'],env=env)!=0
            code,text=login(env);assert code==0,text
            wait_for(lambda:'state=CONNECTED' in (runtime/'status').read_text())
            pid1=(runtime/'status').read_text().split('tunnel_pid=')[1].splitlines()[0]
            assert subprocess.call(['bash',str(bindir/'vpn-status'),'--health'],env=env)==0
            assert service.poll() is None
            results.append('PASS detached supervisor survives temporary interactive login; startup and health status work')
            bad_env=env.copy();bad_env['MOCK_AUTH_FAIL']='1'
            code,text=login(bad_env);assert code!=0
            assert 'tunnel_pid='+pid1 in (runtime/'status').read_text()
            results.append('PASS failed renewal leaves existing tunnel running')
            code,text=login(env);assert code==0,text
            wait_for(lambda:('tunnel_pid='+pid1) not in (runtime/'status').read_text())
            wait_for(lambda:'state=CONNECTED' in (runtime/'status').read_text())
            results.append('PASS successful renewal replaces tunnel and preserves the service')
            wait_for(lambda:'state=AUTH_REQUIRED' in (runtime/'status').read_text(),seconds=15)
            assert service.poll() is None
            assert 'expires soon' in log.read_text()
            assert not list(runtime.glob('req.*'))
            for f in runtime.iterdir():
                if f.is_file() and not f.is_fifo():
                    assert b'OFFLINE-COOKIE-NEVER-REAL' not in f.read_bytes(),f
                    assert b'offline-password' not in f.read_bytes(),f
            results.append('PASS expiry reminder, expired-session login state, request cleanup, and no credentials in runtime regular files')
        finally:
            service.terminate()
            try:service.wait(timeout=10)
            except subprocess.TimeoutExpired:service.kill();service.wait()
    assert not (runtime/'control').exists()
    assert b'OFFLINE-COOKIE-NEVER-REAL' not in log.read_bytes()
    results.append('PASS supervisor shutdown and no cookies in public service log')
    # Stale request cleanup: removed at startup, but never while a login holds the lock.
    import fcntl
    def stale():
        d=runtime/'req.ABCD1234';d.mkdir(mode=0o700)
        os.mkfifo(d/'payload',0o600);os.mkfifo(d/'ack',0o600);return d
    for locked in (True,False):
        d=stale()
        lock=open(runtime/'login.lock','w')
        if locked:fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        lock.close() if not locked else None
        service=subprocess.Popen(['bash',str(bindir/'vpn-service')],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.STDOUT)
        try:
            wait_for(lambda:(runtime/'control').exists())
            assert d.exists()==locked,(locked,d.exists())
        finally:
            service.terminate();service.wait(timeout=10)
            if locked:lock.close()
            if d.exists():
                for f in d.iterdir():f.unlink()
                d.rmdir()
    results.append('PASS stale request directories are cleaned at startup and an active login lock protects them')
    # Periodic health probe: RECONNECTING on failures, recovery, and AUTH_REQUIRED once the path stays down.
    fail=root/'socks-fail';socks_log=root/'socks.log'
    penv=env.copy()
    penv.update(VPN_HEALTH_URL='https://internal.example.invalid:8443/',VPN_HEALTH_INTERVAL='1',VPN_HEALTH_FAILURES='2',
                VPN_HEALTH_FAIL_SECONDS='8',MOCK_SESSION_SECONDS='120',MOCK_SOCKS_FAIL=str(fail),MOCK_SOCKS_LOG=str(socks_log))
    for k in ('AUTH_MODE','OPENCONNECT_PASSWORD','OPENCONNECT_MFA_CODE'):penv.pop(k,None)
    penv['AUTH_MODE']='terminal'
    plog=root/'probe.log'
    with plog.open('w') as output:
        service=subprocess.Popen(['bash',str(bindir/'vpn-service')],env=penv,stdout=output,stderr=subprocess.STDOUT)
        try:
            wait_for(lambda:(runtime/'control').exists())
            code,text=login(penv);assert code==0,text
            wait_for(lambda:'state=CONNECTED' in (runtime/'status').read_text())
            assert 'internal.example.invalid:8443' in socks_log.read_text()
            fail.touch()
            wait_for(lambda:'state=RECONNECTING' in (runtime/'status').read_text())
            assert subprocess.call(['bash',str(bindir/'vpn-status'),'--health'],env=penv)!=0
            fail.unlink()
            wait_for(lambda:'state=CONNECTED' in (runtime/'status').read_text())
            fail.touch()
            wait_for(lambda:'state=AUTH_REQUIRED' in (runtime/'status').read_text(),seconds=30)
            assert 'reason=health-check-failed' in (runtime/'status').read_text()
            assert service.poll() is None and 'vpn-login to authenticate again' in plog.read_text()
            fail.unlink()
            code,text=login(penv);assert code==0,text
            wait_for(lambda:'state=CONNECTED' in (runtime/'status').read_text())
            results.append('PASS periodic SOCKS health probe: RECONNECTING, recovery, AUTH_REQUIRED after sustained failure, and re-login restores the service')
        finally:
            service.terminate()
            try:service.wait(timeout=10)
            except subprocess.TimeoutExpired:service.kill();service.wait()
    for bad in ('http://x.example','https://user@x.example/','https://x.example/?token=1','https://x.example:99999/'):
        r=subprocess.run(['bash','-c','source "$VPN_LIBEXEC/vpn-common"; config_args'],env={**env,'VPN_HEALTH_URL':bad},stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        assert r.returncode!=0,bad
    results.append('PASS unsafe VPN_HEALTH_URL values are rejected')
    # Compatibility mode: no terminal, one attempt, warning, no real credentials.
    env.update(AUTH_MODE='env',OPENCONNECT_USER='offline-user',OPENCONNECT_PASSWORD='offline-password',
               OPENCONNECT_MFA_CODE='offline-code',VPN_LOGIN_BIN=str(bindir/'vpn-login'),MOCK_SESSION_SECONDS='30')
    def lock_free():
        with open(runtime/'service.lock','a') as handle:
            try:fcntl.flock(handle,fcntl.LOCK_EX|fcntl.LOCK_NB);return True
            except OSError:return False
    wait_for(lock_free)
    (runtime/'status').unlink(missing_ok=True)
    with log.open('w') as output:
        service=subprocess.Popen(['bash',str(bindir/'vpn-service')],env=env,stdout=output,stderr=subprocess.STDOUT)
        try:
            try: wait_for(lambda:(runtime/'status').exists() and 'state=CONNECTED' in (runtime/'status').read_text())
            except AssertionError: print('LOG>>',log.read_text(),(runtime/'status').read_text() if (runtime/'status').exists() else 'nostatus'); raise
            assert 'COMPATIBILITY MODE' in log.read_text()
            assert 'offline-password' not in log.read_text()
            results.append('PASS environment compatibility starts without a TTY and prints a warning without printing supplied secrets')
        finally:
            service.terminate()
            try:service.wait(timeout=10)
            except subprocess.TimeoutExpired:service.kill();service.wait()

print('\n'.join(results)+'\nNo real VPN or external network was used.')
