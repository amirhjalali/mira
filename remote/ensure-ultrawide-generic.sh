#!/bin/bash
# ensure-ultrawide-generic.sh — make this Mac present a single 3440x1440 (21:9)
# display matching the ultrawide monitor, via a BetterDisplay virtual screen.
# Works on any Mac with BetterDisplay (uses the CLI if installed, else the app
# binary). Safe to run at login (LaunchAgent) or by hand to repair the display.

B=""
for c in /opt/homebrew/bin/betterdisplaycli /usr/local/bin/betterdisplaycli \
         "/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay" \
         "$HOME/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay"; do
  [ -x "$c" ] && B="$c" && break
done
LOG="$HOME/ensure-ultrawide.log"; exec >>"$LOG" 2>&1
echo "=== $(date '+%Y-%m-%d %H:%M:%S') ensure-ultrawide (binary: ${B:-NONE}) ==="
[ -z "$B" ] && { echo "BetterDisplay not found — install it first."; exit 1; }

# 1. BetterDisplay must be running.
for i in $(seq 1 30); do pgrep -x BetterDisplay >/dev/null && break; open -a BetterDisplay; sleep 2; done
sleep 4

# 2. Ensure one "Ultrawide" virtual screen exists (create only if missing).
if ! "$B" get -identifiers 2>/dev/null | grep -q '"Ultrawide"'; then
  "$B" create -type=VirtualScreen -virtualScreenName="Ultrawide" \
    -aspectWidth=43 -aspectHeight=18 \
    -useResolutionList=on -resolutionList="3440x1440,2752x1152,1720x720" \
    -virtualScreenHiDPI=off
  sleep 3
fi

# 3. Connect, lock to 3440x1440, make main.
"$B" set -name=Ultrawide -connected=on;        sleep 4
"$B" set -name=Ultrawide -resolution=3440x1440; sleep 2
"$B" set -name=Ultrawide -main=on;             sleep 2

# 4. Fold any other (non-main) display in as a mirror -> remote viewer sees one screen.
if [ "$(system_profiler SPDisplaysDataType 2>/dev/null | grep -c 'Online: Yes')" -ge 2 ]; then
  OID="$("$B" get -displayWithNonMainStatus -identifier=displayID 2>/dev/null | head -1)"
  [ -n "$OID" ] && "$B" set -name=Ultrawide -mirror=on -targetDisplayID="$OID"
fi
echo "result: resolution=$("$B" get -name=Ultrawide -resolution 2>/dev/null) main=$("$B" get -name=Ultrawide -main 2>/dev/null)"
