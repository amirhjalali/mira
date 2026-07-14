#!/bin/bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/macrig-config.sh"
acquire_action_lock "Open Both Macs" || exit $?

# open-both-macs.sh — ONE CLICK: open BOTH Macs at once via Jump Desktop.
#
# Both Macs are wired and set to never sleep, so this is reliable. Jump (unlike
# native Screen Sharing) can hold two sessions at once — that's why we use it
# for the both-at-once view.
#
# HOW IT WORKS (2026-07-01 rewrite): the old `open jump://<GUID>` deep-links
# stopped working — this Jump build treats anything after jump:// as an ad-hoc
# RDP hostname ("Can not resolve the computer name"). The only reliable
# programmatic path is the same one a manual click uses: Jump's
# File > Open Recent menu, driven via Accessibility. Verified: opens the real
# Connect/Fluid tunnel and connects in <1s.
#
# FIRST RUN: macOS may ask to grant Accessibility to the caller. Approve once
# in System Settings > Privacy & Security > Accessibility.
#
# TIP: once a window is up, press  Ctrl+Cmd+F  to send it to its own full-screen
# desktop, then two-finger swipe between the sessions.
#
# If Jump ever misbehaves, the fallback is native Screen Sharing to one Mac at a
# time on LAN using the hostnames in config.sh.

# Connection names EXACTLY as they appear in Jump's File > Open Recent menu
# (= the saved computer names; session windows get the same title).
MACHINES=("${TARGET_NAMES[@]}")

# 1. Make sure Jump Desktop is running (and give a fresh launch time to sign
#    in to Jump Connect before we ask it to open sessions).
if ! pgrep -qf "Jump Desktop.app/Contents/MacOS"; then
  open -a "Jump Desktop"
  for _ in $(seq 1 20); do
    pgrep -qf "Jump Desktop.app/Contents/MacOS" && break
    sleep 0.5
  done
  sleep 4
fi

# 2. Open each machine via File > Open Recent — skipping ones that already
#    have a session window. Retry a couple of times (fresh launches can be
#    slow to populate the menu bar).
OPEN_FAILED=0
for name in "${MACHINES[@]}"; do
  ok=""
  for _ in 1 2 3; do
    result=$(/usr/bin/osascript <<EOF 2>&1
tell application "System Events"
  tell process "Jump Desktop"
    set frontmost to true
    if (exists window "$name") then return "already-open"
    click menu item "$name" of menu 1 of menu item "Open Recent" of menu 1 of menu bar item "File" of menu bar 1
    return "opened"
  end tell
end tell
EOF
    )
    case "$result" in
      already-open) echo "✓ $name — session already open"; ok=1; break ;;
      opened)       echo "✓ $name — opening…";             ok=1; break ;;
      *)            sleep 2 ;;
    esac
  done
  if [ -z "$ok" ]; then
    OPEN_FAILED=1
    echo "✗ $name — could not open via Jump's Open Recent menu." >&2
    echo "  Last error: $result" >&2
    echo "  (Did the connection get renamed? Check File > Open Recent in Jump.)" >&2
  fi
  sleep 2   # stagger the two sessions
done

# 3. Auto-tune quality to the network we're on (high at home, medium/low away).
sleep 4   # let sessions finish connecting first
QUALITY_STATUS=0
"$MACRIG_DIR/bin/jump-quality.sh" auto || QUALITY_STATUS=$?
[ "$OPEN_FAILED" -ne 0 ] && exit 1
exit "$QUALITY_STATUS"
