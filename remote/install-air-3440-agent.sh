#!/bin/bash
# install-air-3440-agent.sh
# Remote helper: the login agent and display script installed here run ON the
# remote Mac, not the viewer machine. Run this from a shell that can SSH there.
#
# Run this ONCE to make the remote Mac auto-rebuild its 3440x1440 (21:9)
# display on every login, so it survives reboots.
#
#   bash remote/install-air-3440-agent.sh
#
set -e
REMOTE_USER="EDIT_ME_REMOTE_USER"
REMOTE_HOST="EDIT_ME_REMOTE_HOST.local"
if [ "$REMOTE_USER" = "EDIT_ME_REMOTE_USER" ] || [ "$REMOTE_HOST" = "EDIT_ME_REMOTE_HOST.local" ]; then
  echo "Edit REMOTE_USER and REMOTE_HOST at the top of this script first." >&2
  exit 1
fi
AIR="$REMOTE_USER@$REMOTE_HOST"
SSH=(ssh -o AddressFamily=inet -o ConnectTimeout=10 "$AIR")

echo "Installing display script on the Air..."
"${SSH[@]}" "cat > ~/ensure-ultrawide.sh" <<'SCRIPT'
#!/bin/bash
# Rebuild a single 3440x1440 (21:9) virtual display via BetterDisplay at login.
B=/opt/homebrew/bin/betterdisplaycli
LOG="$HOME/ensure-ultrawide.log"; exec >>"$LOG" 2>&1
echo "=== $(date '+%Y-%m-%d %H:%M:%S') ensure-ultrawide (air) ==="
for i in $(seq 1 30); do pgrep -x BetterDisplay >/dev/null && break; open -a BetterDisplay; sleep 2; done
sleep 5
"$B" discard -type=VirtualScreen; sleep 3
"$B" create -type=VirtualScreen -virtualScreenName="Ultrawide" \
  -aspectWidth=43 -aspectHeight=18 \
  -useResolutionList=on -resolutionList="3440x1440,2752x1152" -virtualScreenHiDPI=off
sleep 3
"$B" set -name=Ultrawide -connected=on;        sleep 4
"$B" set -name=Ultrawide -resolution=3440x1440; sleep 2
"$B" set -name=Ultrawide -main=on;             sleep 2
echo "result: $("$B" get -name=Ultrawide -resolution 2>/dev/null)"
SCRIPT
"${SSH[@]}" "chmod +x ~/ensure-ultrawide.sh; mkdir -p ~/Library/LaunchAgents"

echo "Installing login agent on the Air..."
"${SSH[@]}" "cat > ~/Library/LaunchAgents/com.ultrawide.air.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
 <key>Label</key><string>com.ultrawide.air</string>
 <key>ProgramArguments</key><array><string>/bin/bash</string><string>/Users/$REMOTE_USER/ensure-ultrawide.sh</string></array>
 <key>RunAtLoad</key><true/>
 <key>ProcessType</key><string>Interactive</string>
</dict></plist>
PLIST

echo "Done — the Air will now rebuild its 3440x1440 display automatically on every login."
