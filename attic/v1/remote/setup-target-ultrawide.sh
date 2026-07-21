#!/bin/bash
# setup-target-ultrawide.sh <remote-username> <remote-host>
#
# Remote helper: the display setup installed by this script runs ON the remote
# Mac, not the viewer machine. Run this from a shell that can SSH to that Mac.
#
# Run ONCE to install 21:9 ultrawide and 16:10 laptop virtual screens and keep
# the recipe available through a login agent. Remote Login must already be on.
#
#   ./setup-air-ultrawide.sh <remote-username> <remote-host-or-ip>
#
# It asks for the remote Mac's password one time (for the SSH key), then
# everything is automatic. BetterDisplay must already be installed there.
#
# At runtime MacRig connects exactly one of the two virtual screens. This avoids
# forcing a 16:10 Air canvas into a 21:9 screen recipe.

set -e
U="$1"; HOST="$2"
if [ -z "$U" ] || [ -z "$HOST" ]; then
  echo "usage: $0 <remote-username> <remote-host-or-ip>"
  exit 1
fi
KEY="$HOME/.ssh/id_ed25519.pub"
SSH=(ssh -o AddressFamily=inet -o ConnectTimeout=10 "$U@$HOST")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "1/3  Authorizing this Mac's SSH key on the remote Mac (enter its password once)…"
ssh-copy-id -o AddressFamily=inet -i "$KEY" "$U@$HOST" || true

echo "2/3  Installing the display script + login agent on the remote Mac…"
scp -o AddressFamily=inet \
  "$SCRIPT_DIR/ensure-ultrawide-generic.sh" \
  "$SCRIPT_DIR/mira-set-display.sh" \
  "$U@$HOST:/Users/$U/"
"${SSH[@]}" 'mv ~/ensure-ultrawide-generic.sh ~/ensure-ultrawide.sh; chmod +x ~/ensure-ultrawide.sh ~/mira-set-display.sh'
"${SSH[@]}" "mkdir -p ~/Library/LaunchAgents"
"${SSH[@]}" "cat > ~/Library/LaunchAgents/com.amir.mira-display.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
 <key>Label</key><string>com.amir.mira-display</string>
 <key>ProgramArguments</key><array><string>/bin/bash</string><string>/Users/$U/ensure-ultrawide.sh</string></array>
 <key>RunAtLoad</key><true/>
 <key>ProcessType</key><string>Interactive</string>
</dict></plist>
PLIST

echo "3/3  Installing both virtual screens and applying 3440x1440 now…"
"${SSH[@]}" 'launchctl unload ~/Library/LaunchAgents/com.ultrawide.air.plist 2>/dev/null; rm -f ~/Library/LaunchAgents/com.ultrawide.air.plist; launchctl unload ~/Library/LaunchAgents/com.amir.macrig-display.plist 2>/dev/null; rm -f ~/Library/LaunchAgents/com.amir.macrig-display.plist; launchctl unload ~/Library/LaunchAgents/com.amir.mira-display.plist 2>/dev/null; if ! bash ~/ensure-ultrawide.sh --ensure-recipe; then tail -12 ~/ensure-ultrawide.log; exit 1; fi; launchctl load -w ~/Library/LaunchAgents/com.amir.mira-display.plist; sleep 2; grep "^result:" ~/ensure-ultrawide.log | tail -1; echo "login agent loaded: com.amir.mira-display"'
echo
echo "Done — the remote Mac should now show 3440x1440 in Jump. Use 'Start Workspace' in MacRig."
