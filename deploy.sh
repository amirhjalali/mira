#!/bin/bash
# MIRA remote deployer. Builds + selftests locally, assembles and signs the
# MIRA.app bundle, then pushes it (plus config + daemon LaunchAgent) to the
# peer Macs over SSH and (re)starts the daemon there.
#
# Usage:  bash deploy.sh [air] [mini]     (no args => both)
#
# Idempotent: safe to re-run. Each target ends "<target>: OK" or fails loudly.
set -e
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$PWD"

# ---- target table -----------------------------------------------------------
air_user="amirjalali";  air_host="100.118.137.45"
mini_user="gabooja";    mini_host="100.105.19.90"

# ---- resolve target list ----------------------------------------------------
TARGETS=()
if [ "$#" -eq 0 ]; then
  TARGETS=(air mini)
else
  for t in "$@"; do
    case "$t" in
      air|mini) TARGETS+=("$t") ;;
      *) echo "deploy.sh: unknown target '$t' (want: air, mini)" >&2; exit 2 ;;
    esac
  done
fi

# ---- 1) build + selftest gate ----------------------------------------------
echo "1) Build + selftest…"
bash tests/run.sh build.noindex/mira

# ---- 2) assemble + sign the bundle locally ---------------------------------
echo "2) Bundle MIRA.app…"
APP=build.noindex/MIRA.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp build.noindex/mira "$APP/Contents/MacOS/MIRA"
mkdir -p "$APP/Contents/Resources"
cp app/AppIcon.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.amir.mira</string>
  <key>CFBundleName</key><string>MIRA 2</string>
  <key>CFBundleExecutable</key><string>MIRA</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleIconFile</key><string>AppIcon</string>\n  <key>CFBundleShortVersionString</key><string>2.0</string>
</dict></plist>
PLIST
if security find-identity -p codesigning 2>/dev/null | grep -q "MIRA Signing"; then
  echo "   signing with MIRA Signing identity"
  codesign --force --sign "MIRA Signing" "$APP"
else
  echo "   signing ad-hoc (no MIRA Signing identity found)"
  codesign --force --sign - "$APP"
fi

# ---- 3) per-target push -----------------------------------------------------
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=10"

# sign_mode: "identity" => must sign with the stable "MIRA Signing" identity
# (a silent ad-hoc fall-back would change the designated requirement and drop the
# target's Accessibility/TCC grant); "adhoc" => ad-hoc signing is intentional.
deploy_one() {
  local name="$1" user="$2" host="$3" sign_mode="$4"
  local tgt="$user@$host"
  echo "=== $name ($tgt) ==="

  # connectivity check (harmless)
  ssh $SSH_OPTS "$tgt" 'echo ok' >/dev/null

  # stage bundle to a scratch path in the target home, then swap into place
  ssh $SSH_OPTS "$tgt" 'rm -rf "$HOME/.mira-stage" && mkdir -p "$HOME/.mira-stage"'
  scp -O -r "$APP" "$tgt:.mira-stage/MIRA.app"
  ssh $SSH_OPTS "$tgt" '
    set -e
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/MIRA.app"
    mv "$HOME/.mira-stage/MIRA.app" "$HOME/Applications/MIRA.app"
    rmdir "$HOME/.mira-stage" 2>/dev/null || true
  '

  # remote re-sign. For an identity target, a stable "MIRA Signing" signature is
  # required — never silently degrade to ad-hoc (that changes the designated
  # requirement and revokes the Accessibility grant). Ad-hoc only where intended.
  ssh $SSH_OPTS "$tgt" "SIGN_MODE='$sign_mode' bash -s" <<'REMOTE_SIGN'
    set -e
    APP="$HOME/Applications/MIRA.app"
    if [ "$SIGN_MODE" = "identity" ]; then
      # Unlock login keychain if a GUI session hasn't already (harmless if locked
      # non-interactively — the failure is caught below, not silently ad-hoc'd).
      security unlock-keychain "$HOME/Library/Keychains/login.keychain-db" 2>/dev/null || true
      if codesign --force --sign "MIRA Signing" "$APP"; then
        echo "   signed with MIRA Signing identity"
      else
        echo "   ERROR: MIRA Signing unavailable — refusing ad-hoc (would drop Accessibility grant)" >&2
        exit 3
      fi
    else
      echo "   signing ad-hoc (intentional for this target)"
      codesign --force --sign - "$APP"
    fi
REMOTE_SIGN

  # push config to ~/.config/mira/machines.json
  ssh $SSH_OPTS "$tgt" 'mkdir -p "$HOME/.config/mira"'
  scp -O config/machines.json "$tgt:.config/mira/machines.json"

  # write the daemon LaunchAgent with an absolute home path, then (re)load it
  ssh $SSH_OPTS "$tgt" '
    set -e
    mkdir -p "$HOME/Library/LaunchAgents"
    PLIST="$HOME/Library/LaunchAgents/com.amir.mira.plist"
    EXE="$HOME/Applications/MIRA.app/Contents/MacOS/MIRA"
    cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.amir.mira</string>
  <key>ProgramArguments</key>
  <array><string>$EXE</string><string>--daemon</string></array>
  <key>StandardOutPath</key><string>/tmp/mira-daemon.log</string>
  <key>StandardErrorPath</key><string>/tmp/mira-daemon.log</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
</dict></plist>
PL
    # Load into the user Aqua/GUI domain (gui/<uid>), NOT the SSH session
    # bootstrap context — the daemon needs a WindowServer connection for every
    # CGVirtualDisplay / mirror / setMain call, which the SSH context lacks.
    uid=$(id -u)
    launchctl bootout "gui/$uid" "$PLIST" 2>/dev/null || true
    launchctl bootstrap "gui/$uid" "$PLIST"

    # retire the transitional MIRA2 generation and v1 leftovers
    launchctl bootout "gui/$uid" "$HOME/Library/LaunchAgents/com.amir.mira2.plist" 2>/dev/null || true
    rm -f "$HOME/Library/LaunchAgents/com.amir.mira2.plist"           "$HOME/Library/LaunchAgents/com.amir.mira-display.plist"           "$HOME/Library/LaunchAgents/com.amir.dockwatch.plist"
    rm -rf "$HOME/Applications/MIRA2.app" "/Applications/MIRA2.app" 2>/dev/null || true
    # v1 shell-era app (bundle id com.amir.macrig) lived in /Applications on viewers
    if plutil -p "/Applications/MIRA.app/Contents/Info.plist" 2>/dev/null | grep -q com.amir.macrig; then
      rm -rf "/Applications/MIRA.app"
    fi
    rm -f "$HOME/ensure-ultrawide.sh" "$HOME/mira-set-display.sh"           "$HOME/collapse-displays.sh" "$HOME/restore-displays.sh"
    # remove legacy raw binary if present
    rm -f "$HOME/bin/mira"
  '

  # verify the daemon is up — RunAtLoad exec can lag, so retry a few times
  # before declaring failure.
  if ssh $SSH_OPTS "$tgt" '
    for i in 1 2 3 4 5; do
      pgrep -f "MIRA --daemon" >/dev/null && exit 0
      sleep 1
    done
    exit 1
  '; then
    echo "$name: OK"
  else
    echo "$name: FAILED — daemon not running (see /tmp/mira-daemon.log on $host)" >&2
    return 1
  fi
}

# Isolate targets: one host failing must not abort the other (set -e would
# otherwise stop the loop before the second target is attempted).
fail=0
for name in "${TARGETS[@]}"; do
  case "$name" in
    air)  deploy_one air  "$air_user"  "$air_host" identity || fail=1 ;;
    mini) deploy_one mini "$mini_user" "$mini_host" adhoc    || fail=1 ;;
  esac
done

if [ "$fail" -ne 0 ]; then
  echo "Done with failures." >&2
  exit 1
fi
echo "Done."
