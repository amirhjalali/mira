#!/usr/bin/env python3
"""Build, stage, verify, install and retain a rollback on each named Mac."""
import hashlib,json,os,pathlib,plistlib,shlex,shutil,subprocess,sys,time
ROOT=pathlib.Path(__file__).resolve().parents[1]
BUILD='20260930.1'; VERSION='2.2.0'
FLEET={m['id']:(m['user'],m['tailscale']) for m in json.loads((ROOT/'config/machines.json').read_text())['machines'] if m.get('type','mac')=='mac'}
identity=pathlib.Path.home()/'.config/mira/machine-id'
LOCAL_ID=identity.read_text().strip() if identity.exists() else 'pro'
APP=ROOT/'build.noindex/MIRA.app'
def run(args,**kwargs):
    return subprocess.run(args,check=True,**kwargs)
def build():
    inputs=[ROOT/'app/MIRA.swift',ROOT/'app/Reliability.swift',ROOT/'app/shim.h',ROOT/'config/machines.json']
    source_hashes={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
    run(['bash','tests/run.sh'],cwd=ROOT)
    # Never replace a working installation when its signing identity is absent.
    identities=run(['security','find-identity','-p','codesigning'],capture_output=True,text=True).stdout
    if 'MIRA Signing' not in identities: raise RuntimeError('MIRA Signing identity unavailable; no installation changed')
    app=APP
    app.mkdir(parents=True,exist_ok=True)
    (app/'Contents/MacOS').mkdir(parents=True,exist_ok=True)
    (app/'Contents/Resources').mkdir(parents=True,exist_ok=True)
    shutil.copy2(ROOT/'build.noindex/mira',app/'Contents/MacOS/MIRA')
    shutil.copy2(ROOT/'app/AppIcon.icns',app/'Contents/Resources/AppIcon.icns')
    (app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'com.amir.mira','CFBundleName':'MIRA','CFBundleExecutable':'MIRA','CFBundlePackageType':'APPL','CFBundleShortVersionString':VERSION,'CFBundleVersion':BUILD,'LSUIElement':True,'CFBundleIconFile':'AppIcon'}))
    run(['codesign','--force','--sign','MIRA Signing',str(app)])
    run(['codesign','--verify','--strict',str(app)])
    if source_hashes != {str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}: raise RuntimeError('Sources changed during build; refusing mismatched release')
    digest=hashlib.sha256((app/'Contents/MacOS/MIRA').read_bytes()).hexdigest()
    manifest={'build':BUILD,'version':VERSION,'binarySHA256':digest,'sources':{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [ROOT/'app/MIRA.swift',ROOT/'app/Reliability.swift',ROOT/'app/shim.h',ROOT/'config/machines.json']}}
    (ROOT/'build.noindex/release.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print('Built',BUILD,digest,flush=True)

def install_script(machine,digest):
    # shell script is transmitted as stdin; names originate in the fixed fleet.
    return '''set -eu
id=ID_VALUE
build=BUILD_VALUE
expected=HASH_VALUE
stage="$HOME/.mira-stage-$build"
backup="$HOME/Library/Application Support/MIRA/releases/$build-before"
if [ "$id" = pro ]; then app=/Applications/MIRA.app; else app="$HOME/Applications/MIRA.app"; fi
uid=$(id -u)
plist="$HOME/Library/LaunchAgents/com.amir.mira.plist"
menuplist="$HOME/Library/LaunchAgents/com.amir.mira.menu.plist"
actual=$(shasum -a 256 "$stage/MIRA.app/Contents/MacOS/MIRA" | awk '{print $1}')
[ "$actual" = "$expected" ] || { echo 'staged checksum mismatch' >&2; exit 1; }
codesign --verify --strict "$stage/MIRA.app"
# Preserve the first pre-upgrade bundle, config, state and agents on this Mac.
mkdir -p "$backup" "$HOME/.config/mira" "$HOME/Library/LaunchAgents" "$(dirname "$app")"
if [ ! -d "$backup/MIRA.app" ] && [ -d "$app" ]; then cp -R "$app" "$backup/MIRA.app"; fi
if [ ! -e "$backup/daemon.plist" ] && [ -f "$plist" ]; then cp "$plist" "$backup/daemon.plist"; fi
if [ ! -e "$backup/menu.plist" ] && [ -f "$menuplist" ]; then cp "$menuplist" "$backup/menu.plist"; fi
if [ ! -d "$backup/config" ]; then cp -R "$HOME/.config/mira" "$backup/config"; fi
# Validate the replacement before stopping either process.
"$stage/MIRA.app/Contents/MacOS/MIRA" version
launchctl bootout "gui/$uid/com.amir.mira" 2>/dev/null || true
launchctl bootout "gui/$uid/com.amir.mira.menu" 2>/dev/null || true
# Match executable argv, not a shell's command text, and not the daemon suffix.
menu_pattern='^.*MIRA[.]app/Contents/MacOS/MIRA$'
pkill -f "$menu_pattern" 2>/dev/null || true
for attempt in 1 2 3; do
    if ! pgrep -f "$menu_pattern" >/dev/null; then break; fi
    sleep 1
done
# Old AppKit processes may ignore TERM. Retire only the exact menu executable.
if pgrep -f "$menu_pattern" >/dev/null; then pkill -KILL -f "$menu_pattern"; fi
if [ -d "$app" ]; then mv "$app" "$stage/previous-$build-$(date +%s).app"; fi
cp -R "$stage/MIRA.app" "$app"
[ "$(shasum -a 256 "$app/Contents/MacOS/MIRA" | awk '{print $1}')" = "$expected" ]
codesign --verify --strict "$app"
cp "$stage/machines.json" "$HOME/.config/mira/machines.json"
printf '%s\n' "$id" > "$HOME/.config/mira/machine-id"
mkdir -p "$HOME/.local/bin"
ln -sfn "$app/Contents/MacOS/MIRA" "$HOME/.local/bin/mira"
cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>Label</key><string>com.amir.mira</string>
<key>ProgramArguments</key><array><string>$app/Contents/MacOS/MIRA</string><string>--daemon</string></array>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
<key>StandardOutPath</key><string>/tmp/mira-daemon.log</string><key>StandardErrorPath</key><string>/tmp/mira-daemon.log</string>
</dict></plist>
PLIST
cat > "$menuplist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>Label</key><string>com.amir.mira.menu</string>
<key>ProgramArguments</key><array><string>$app/Contents/MacOS/MIRA</string></array>
<key>RunAtLoad</key><true/>
<key>StandardOutPath</key><string>/tmp/mira-menu.log</string><key>StandardErrorPath</key><string>/tmp/mira-menu.log</string>
</dict></plist>
PLIST
start_agent() {
    label=$1
    agent=$2
    for attempt in 1 2 3 4 5; do
        if launchctl bootstrap "gui/$uid" "$agent"; then break; fi
        if launchctl print "gui/$uid/$label" >/dev/null 2>&1; then break; fi
        sleep 1
    done
    launchctl kickstart "gui/$uid/$label"
}
start_agent com.amir.mira "$plist"
start_agent com.amir.mira.menu "$menuplist"
printf '%s\n' "Installed $id; rollback at $backup"
'''.replace('ID_VALUE',shlex.quote(machine)).replace('BUILD_VALUE',shlex.quote(BUILD)).replace('HASH_VALUE',shlex.quote(digest))

def ssh(machine,args,**kw):
    user,host=FLEET[machine]
    return run(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=5','-o','ServerAliveInterval=3','-o','ServerAliveCountMax=2',f'{user}@{host}',*args],**kw)

def require_canary(manifest):
    receipt_path=ROOT/'build.noindex/live-switch.json'
    receipt=json.loads(receipt_path.read_text()) if receipt_path.exists() else {}
    if (receipt.get('binarySHA256')!=manifest['binarySHA256'] or receipt.get('build')!=manifest['build']
        or receipt.get('machine')!='mini' or time.time()-receipt.get('verifiedAt',0)>86400):
        raise RuntimeError('Fleet deployment requires a passing live Mini transition test for this binary: bash deploy.sh --verify-switch mini')

def verify_switch():
    run([sys.executable,str(ROOT/'scripts/verify-live-switch.py'),'mini'])

def deploy(machine):
    manifest=json.loads((ROOT/'build.noindex/release.json').read_text())
    if machine!='mini': require_canary(manifest)
    for relative,digest in manifest['sources'].items():
        if hashlib.sha256((ROOT/relative).read_bytes()).hexdigest()!=digest: raise RuntimeError('Source changed since tests/build: '+relative)
    local=machine==LOCAL_ID
    stage=pathlib.Path.home()/f'.mira-stage-{BUILD}'
    if local:
        stage.mkdir(exist_ok=True)
        shutil.copytree(APP,stage/'MIRA.app',dirs_exist_ok=True)
        shutil.copy2(ROOT/'config/machines.json',stage/'machines.json')
        run(['/bin/bash'],input=install_script(machine,manifest['binarySHA256']),text=True)
    else:
        user,host=FLEET[machine]
        ssh(machine,[f'mkdir -p "$HOME/.mira-stage-{BUILD}"'])
        run(['scp','-O','-q','-r',str(APP),str(ROOT/'config/machines.json'),f'{user}@{host}:.mira-stage-{BUILD}/'])
        ssh(machine,['/bin/bash'],input=install_script(machine,manifest['binarySHA256']),text=True)
    # launchd can finish removing an old registration after bootstrap returns.
    # Re-register a missing job during bounded verification; never reinstall or
    # reset session/display state merely because launchd raced the restart.
    repair_agents = r'''uid=$(id -u)
for label in com.amir.mira com.amir.mira.menu; do
    if ! launchctl print "gui/$uid/$label" >/dev/null 2>&1; then
        launchctl bootstrap "gui/$uid" "$HOME/Library/LaunchAgents/$label.plist"
        launchctl kickstart "gui/$uid/$label"
    fi
done
'''
    # A running PID is insufficient: require this build's fresh runtime report.
    for attempt in range(20):
        time.sleep(1)
        if attempt in (0, 5, 10):
            if local: subprocess.run(['/bin/bash'],input=repair_agents,text=True,check=False)
            else:
                try: ssh(machine,['/bin/bash'],input=repair_agents,text=True)
                except subprocess.CalledProcessError: pass
        try:
            if local: report=json.loads((pathlib.Path.home()/'Library/Application Support/MIRA/runtime.json').read_text())
            else: report=json.loads(ssh(machine,['cat "$HOME/Library/Application Support/MIRA/runtime.json"'],capture_output=True,text=True).stdout)
            if report['build']==BUILD and report['machine']==machine and time.time()-report['ts']<15:
                print(json.dumps({'installed':machine,'runtime':report}),flush=True)
                return
        except (OSError,ValueError,KeyError,subprocess.CalledProcessError): pass
    raise RuntimeError(f'{machine}: installed but new daemon did not publish fresh state; use retained rollback')

if __name__=='__main__':
    args=sys.argv[1:]
    if args and args[0]=='--to':
        if len(args)!=4 or not args[1].replace('-','').isalnum(): raise SystemExit('Usage: --to <id> <user> <host>')
        FLEET[args[1]]=(args[2],args[3]); args=[args[1]]
    if args==['--build']: build()
    elif args==['--verify-switch','mini']: verify_switch()
    else:
        if args and args[0]=='--skip-build': args=args[1:]
        else: build()
        all_targets=not args
        for target in args or ['mini','air15','pro','air13']:
            if target=='local': target='pro'
            if target not in FLEET: raise SystemExit('Unknown target '+target)
            deploy(target)
            if all_targets and target=='mini': verify_switch()
