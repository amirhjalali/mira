#!/usr/bin/env python3
"""Canary acceptance: change a running passenger's canvas and restore it.

Requires an active driver and a ready Mini, and briefly changes its display.
The resulting receipt gates deployment to the rest of the fleet.
"""
import base64,hashlib,json,pathlib,shlex,subprocess,sys,time,uuid
ROOT=pathlib.Path(__file__).resolve().parents[1]

def verify(machine):
    cfg=json.loads((ROOT/'config/machines.json').read_text())
    peer=next(m for m in cfg['machines'] if m['id']==machine)
    host=peer['user']+'@'+peer['tailscale']
    def remote(command, check=True):
        return subprocess.run(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=5',host,command],text=True,capture_output=True,check=check,timeout=20).stdout
    def read(name): return json.loads(remote('cat "$HOME/Library/Application Support/MIRA/'+name+'.json"'))
    initial=read('runtime'); original=read('ride'); session=initial['session']
    manifest=json.loads((ROOT/'build.noindex/release.json').read_text())
    assert initial['state']=='ready' and time.time()-initial['ts']<15, 'Canary must be ready before live switching'
    assert initial['build']==manifest['build'], 'Canary must run the release under test'
    assert session=={'driver':original['driver'],'claim':original['claimedAt']}, 'Canary owner changed'
    digest=remote('shasum -a 256 "$HOME/Applications/MIRA.app/Contents/MacOS/MIRA"').split()[0]
    assert digest==manifest['binarySHA256'], 'Installed binary differs from release'
    print('BEFORE',json.dumps(initial),flush=True)
    results=[]
    def request(kind,ride=None,owner=session):
        now=time.time()
        payload={'id':str(uuid.uuid4()),'created':now,'kind':kind,'explicit':False,'session':owner}
        if ride is not None: payload['ride']={**ride,'driver':owner['driver'],'claimedAt':owner['claim'],'ts':now}
        encoded=base64.b64encode(json.dumps(payload).encode()).decode()
        return json.loads(remote('"$HOME/Applications/MIRA.app/Contents/MacOS/MIRA" control '+shlex.quote(encoded),check=False))
    def converge(ride):
        canvas=cfg['canvases'][ride['canvas']]
        w,h=ride.get('canvasW') or canvas['width'],ride.get('canvasH') or canvas['height']
        factor=2 if ride['hidpi'] and canvas['hidpi'] else 1
        start=time.time(); last=0
        while time.time()-start<45:
            if time.time()-last>5:
                reply=request('ride',ride); last=time.time()
                if not reply['ok'] and reply.get('message')=='Outdated lease ignored': continue
                assert reply['ok'], reply
            observed=read('runtime')
            assert observed['pid']==initial['pid'], 'Daemon restarted during live resize'
            assert observed['session']==session, 'Driver changed during live test'
            if observed['ts']>start and observed['state']=='ready' and [observed.get(k) for k in ['width','height','pixelWidth','pixelHeight']]==[w,h,w*factor,h*factor]:
                print('PASS',json.dumps(observed),flush=True); results.append(observed); return
            time.sleep(1)
        raise RuntimeError('Resize failed: '+json.dumps(observed))
    try:
        for name in ['laptop-air13','ultrawide','laptop-air13']:
            canvas=cfg['canvases'][name]
            converge({**original,'canvas':name,'canvasW':canvas['width'],'canvasH':canvas['height'],'hidpi':True})
        converge(original)
        stale={**session,'claim':session['claim']-1}
        assert not request('ride',original,stale)['ok'], 'Older driver ride was accepted'
        request('release',owner=stale)
        assert read('ride')['claimedAt']==session['claim'], 'Older release displaced the active driver'
        print('PASS stale ride and stale release preserve current owner',flush=True)
    finally:
        # This uses the original owner. A newer driver wins at the receiver;
        # the test cannot seize it back while restoring its temporary canvas.
        print('RESTORE',json.dumps(request('ride',original)),flush=True)
    receipt={'build':manifest['build'],'binarySHA256':digest,'machine':machine,'verifiedAt':time.time(),'session':session,'initial':initial,'transitions':results}
    (ROOT/'build.noindex/live-switch.json').write_text(json.dumps(receipt,indent=2)+'\n')
    print('Canary acceptance recorded for '+manifest['build'],flush=True)

if __name__=='__main__':
    if len(sys.argv)!=2 or sys.argv[1]!='mini': raise SystemExit('Usage: verify-live-switch.py mini')
    verify(sys.argv[1])
