#!/bin/bash
# MIRA remote deployer. Builds + selftests locally, assembles and signs the
# MIRA.app bundle, then pushes it (plus config + daemon LaunchAgent) to the
# peer Macs over SSH and (re)starts the daemon there.
#
# Usage:  bash deploy.sh [air15] [air13] [mini]   (no args => whole fleet)
#
# Idempotent: safe to re-run. Each target ends "<target>: OK" or fails loudly.
set -e
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$PWD"

# ---- target table -----------------------------------------------------------
air15_user="amirjalali";  air15_host="100.118.137.45"
air13_user="amirhjalali"; air13_host="100.112.227.24"
mini_user="gabooja";      mini_host="100.105.19.90"

# ---- resolve target list ----------------------------------------------------
# "--to <id> <user> <host>" deploys to an arbitrary machine (used by
# add-machine.sh for onboarding); otherwise named targets from the table.
# "local" (re)installs on this machine; the no-arg run covers the whole fleet.
TARGETS=()
if [ "${1:-}" = "--to" ]; then
  [ -n "${2:-}" ] && [ -n "${3:-}" ] && [ -n "${4:-}" ] || {
    echo "deploy.sh: --to <id> <user> <host>" >&2; exit 2; }
  eval "${2}_user=\"$3\""; eval "${2}_host=\"$4\""
  TARGETS=("$2")
elif [ "$#" -eq 0 ]; then
  TARGETS=(local air15 air13 mini)
else
  for t in "$@"; do
    case "$t" in
      local|air15|air13|mini) TARGETS+=("$t") ;;
      *) echo "deploy.sh: unknown target '$t' (want: local, air15, air13, mini, or --to)" >&2; exit 2 ;;
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
  <key>CFBundleName</key><string>MIRA</string>
  <key>CFBundleExecutable</key><string>MIRA</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>2.1</string>
</dict></plist>
PLIST
if security find-identity -p codesigning 2>/dev/null | grep -q "MIRA Signing"; then
  echo "   signing with MIRA Signing identity"
  codesign --force --sign "MIRA Signing" "$APP"
else
  echo "   signing ad-hoc (no MIRA Signing identity found)"
  codesign --force --sign - "$APP"
fi

# ---- 3) local install (the machine running the deploy) ----------------------
# The Pro used to run whatever build was copied by hand — deploy now installs
# here too so the driver is never behind the passengers.
deploy_local() {
  echo "=== local ($(hostname -s)) ==="
  local dst="/Applications/MIRA.app"

  # menu app restarts after the swap; daemon restarts via launchctl below
  pkill -f "$dst/Contents/MacOS/MIRA$" 2>/dev/null || true
  rm -rf "$dst"
  cp -R "$APP" "$dst"
  if security find-identity -p codesigning 2>/dev/null | grep -q "MIRA Signing"; then
    codesign --force --sign "MIRA Signing" "$dst"
  else
    echo "   ERROR: MIRA Signing identity missing locally — refusing ad-hoc (would drop TCC grants)" >&2
    return 1
  fi

  # standalone config fallback (repo checkout still wins when present)
  mkdir -p "$HOME/.config/mira"
  cp config/machines.json "$HOME/.config/mira/machines.json"

  # daemon LaunchAgent: keep an existing plist (it may pin MIRA_DIR on the dev
  # box); write the standalone default only when absent
  local plist="$HOME/Library/LaunchAgents/com.amir.mira.plist"
  if [ ! -f "$plist" ]; then
    cat > "$plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.amir.mira</string>
  <key>ProgramArguments</key>
  <array><string>$dst/Contents/MacOS/MIRA</string><string>--daemon</string></array>
  <key>StandardOutPath</key><string>/tmp/mira-daemon.log</string>
  <key>StandardErrorPath</key><string>/tmp/mira-daemon.log</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
</dict></plist>
PL
  fi
  # CLI on PATH (~/.local/bin is in the user's PATH; no sudo territory)
  mkdir -p "$HOME/.local/bin"
  ln -sf "$dst/Contents/MacOS/MIRA" "$HOME/.local/bin/mira"

  local uid; uid=$(id -u)
  launchctl bootout "gui/$uid" "$plist" 2>/dev/null || true
  launchctl bootstrap "gui/$uid" "$plist"
  # RunAtLoad is a hint, not a guarantee — launchd left the air daemon
  # unspawned after bootstrap (2026-08-13); kickstart forces the start.
  launchctl kickstart "gui/$uid/com.amir.mira" 2>/dev/null || true
  open -a "$dst"

  for i in 1 2 3 4 5; do
    pgrep -f "MIRA --daemon" >/dev/null && { echo "local: OK"; return 0; }
    sleep 1
  done
  echo "local: FAILED — daemon not running (see /tmp/mira-daemon.log)" >&2
  return 1
}

# ---- 4) per-target push -----------------------------------------------------
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=10"

# sign_mode: "identity" => must sign with the stable "MIRA Signing" identity
# (a silent ad-hoc fall-back would change the designated requirement and drop the
# target's Accessibility/TCC grant); "adhoc" => ad-hoc signing is intentional.
deploy_one() {
  local name="$1" user="$2" host="$3" sign_mode="$4"
  local tgt="$user@$host"
  echo "=== $name ($tgt) ==="

  # NOTE: set -e is suppressed inside a function invoked under `|| fail=1`
  # (bash semantics) — every critical step needs explicit `|| return`.

  # connectivity check (harmless)
  ssh $SSH_OPTS "$tgt" 'echo ok' >/dev/null || { echo "$name: unreachable" >&2; return 1; }

  # stage bundle to a scratch path in the target home, then swap into place
  ssh $SSH_OPTS "$tgt" 'rm -rf "$HOME/.mira-stage" && mkdir -p "$HOME/.mira-stage"' || return 1
  scp -O -r "$APP" "$tgt:.mira-stage/MIRA.app" || return 1
  ssh $SSH_OPTS "$tgt" '
    set -e
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/MIRA.app"
    mv "$HOME/.mira-stage/MIRA.app" "$HOME/Applications/MIRA.app"
    rmdir "$HOME/.mira-stage" 2>/dev/null || true
  ' || return 1

  # remote re-sign. For an identity target, a stable "MIRA Signing" signature is
  # required — never silently degrade to ad-hoc (that changes the designated
  # requirement and revokes the Accessibility grant). Ad-hoc only where intended.
  # Leaf-cert fingerprint of the local MIRA Signing identity: the remote check
  # pins the shipped signature to this exact cert (codesign prints no
  # Authority= line for a self-signed cert, so grep the requirement instead).
  local leaf
  leaf=$(security find-certificate -c "MIRA Signing" -Z 2>/dev/null | awk '/SHA-1 hash:/{print $3}')

  ssh $SSH_OPTS "$tgt" "SIGN_MODE='$sign_mode' LEAF='$leaf' bash -s" <<'REMOTE_SIGN' || return 1
    set -e
    APP="$HOME/Applications/MIRA.app"
    if [ "$SIGN_MODE" = "identity" ]; then
      # The fleet shares one "MIRA Signing" cert, so the signature made on the
      # build machine is already the right designated requirement here. Accept
      # it when it verifies; re-sign only a broken/foreign signature (scp can
      # not corrupt it, but belt and braces).
      if codesign --verify "$APP" 2>/dev/null && [ -n "$LEAF" ] && \
         codesign -d -r- "$APP" 2>&1 | grep -qi "certificate leaf = H\"$LEAF\""; then
        echo "   shipped MIRA Signing signature verified — no re-sign needed"
      else
        # Re-sign needs the login keychain; over SSH this only works when the
        # console session has it unlocked. Never silently degrade to ad-hoc
        # (that changes the designated requirement and drops the TCC grants).
        security unlock-keychain "$HOME/Library/Keychains/login.keychain-db" 2>/dev/null || true
        if codesign --force --sign "MIRA Signing" "$APP"; then
          echo "   re-signed with MIRA Signing identity"
        else
          echo "   ERROR: shipped signature invalid and MIRA Signing unavailable — aborting this target" >&2
          exit 3
        fi
      fi
    else
      echo "   signing ad-hoc (intentional for this target)"
      codesign --force --sign - "$APP"
    fi
REMOTE_SIGN

  # push config to ~/.config/mira/machines.json
  ssh $SSH_OPTS "$tgt" 'mkdir -p "$HOME/.config/mira"' || return 1
  scp -O config/machines.json "$tgt:.config/mira/machines.json" || return 1

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
    # RunAtLoad is a hint, not a guarantee — launchd left the air daemon
    # unspawned after bootstrap (2026-08-13); kickstart forces the start.
    launchctl kickstart "gui/$uid/com.amir.mira" 2>/dev/null || true

    # The menu app is a SEPARATE process that launchd does not manage, and it is
    # the one the user actually clicks "Drive from Here" in. Restarting only the
    # daemon left 4-day-old drive() logic running through every deploy of
    # 2026-08-17 — new code shipped, old code still handling the click. The $
    # anchor matters: it must not match the "--daemon" process above.
    pkill -f "Applications/MIRA.app/Contents/MacOS/MIRA$" 2>/dev/null || true
    sleep 1
    open -a "$HOME/Applications/MIRA.app" 2>/dev/null || \
      echo "   note: menu app not relaunched (no GUI session?) — open MIRA.app there"

    # retire the transitional MIRA2 generation and v1 leftovers
    launchctl bootout "gui/$uid" "$HOME/Library/LaunchAgents/com.amir.mira2.plist" 2>/dev/null || true
    launchctl bootout "gui/$uid" "$HOME/Library/LaunchAgents/com.gabooja.ultrawide.plist" 2>/dev/null || true
    rm -f "$HOME/Library/LaunchAgents/com.amir.mira2.plist"           "$HOME/Library/LaunchAgents/com.amir.mira-display.plist"           "$HOME/Library/LaunchAgents/com.amir.dockwatch.plist"           "$HOME/Library/LaunchAgents/com.gabooja.ultrawide.plist"
    rm -rf "$HOME/Applications/MIRA2.app" "/Applications/MIRA2.app" 2>/dev/null || true
    # v1 shell-era app (bundle id com.amir.macrig) lived in /Applications on viewers
    if plutil -p "/Applications/MIRA.app/Contents/Info.plist" 2>/dev/null | grep -q com.amir.macrig; then
      rm -rf "/Applications/MIRA.app"
    fi
    rm -f "$HOME/ensure-ultrawide.sh" "$HOME/mira-set-display.sh"           "$HOME/collapse-displays.sh" "$HOME/restore-displays.sh"
    # retire the pre-rename state dir and stray v1 leftovers
    rm -rf "$HOME/Library/Application Support/MacRig"
    rm -f "$HOME/.mira-display-v1" "$HOME/.mira-display-v2" "$HOME/.macrig-display-v3" \
          "$HOME/ensure-ultrawide.log" "$HOME/Jump_Desktop_Mac_License.jdlicense" 2>/dev/null || true
    # remove legacy raw binary if present
    rm -f "$HOME/bin/mira"
  ' || return 1

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
    local) deploy_local || fail=1 ;;
    air15) deploy_one air15 "$air15_user" "$air15_host" identity || fail=1 ;;
    air13) deploy_one air13 "$air13_user" "$air13_host" identity || fail=1 ;;
    mini)  deploy_one mini  "$mini_user"  "$mini_host"  adhoc    || fail=1 ;;
    *)    # --to onboarding target: user/host were eval'd into <id>_user/<id>_host
          u="${name}_user"; h="${name}_host"
          deploy_one "$name" "${!u}" "${!h}" adhoc || fail=1 ;;
  esac
done

if [ "$fail" -ne 0 ]; then
  echo "Done with failures." >&2
  exit 1
fi
echo "Done."
