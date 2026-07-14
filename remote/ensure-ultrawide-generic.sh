#!/bin/bash
# Install two BetterDisplay virtual screens on a target Mac:
#   Ultrawide — 21:9, used by a docked viewer at 3440x1440
#   Laptop   — 16:10, used by either laptop viewer at its own canvas size
#
# BetterDisplay filters custom resolutions by a virtual screen's aspect ratio,
# so 3440x1440 and 1440x900 cannot reliably live on one virtual screen.

B=""
for candidate in /opt/homebrew/bin/betterdisplaycli /usr/local/bin/betterdisplaycli \
    "/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay" \
    "$HOME/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay"; do
  [ -x "$candidate" ] && B="$candidate" && break
done

LOG="$HOME/ensure-ultrawide.log"
exec >>"$LOG" 2>&1
MARKER="$HOME/.macrig-display-v3"
echo "=== $(date '+%Y-%m-%d %H:%M:%S') ensure MacRig displays (binary: ${B:-NONE}) ==="
[ -n "$B" ] || { echo "BetterDisplay not found — install it first."; exit 1; }

for _ in $(seq 1 30); do
  pgrep -x BetterDisplay >/dev/null && break
  open -a BetterDisplay
  sleep 2
done
sleep 4

identifiers=$("$B" get -identifiers 2>/dev/null || true)
if [ "${1:-}" = "--rebuild" ] \
    || [ ! -f "$MARKER" ] \
    || ! printf '%s\n' "$identifiers" | grep -q '"name" : "Ultrawide"' \
    || ! printf '%s\n' "$identifiers" | grep -q '"name" : "Laptop"'; then
  "$B" discard -type=VirtualScreen >/dev/null 2>&1 || true
  sleep 3

  "$B" create -type=VirtualScreen -virtualScreenName="Ultrawide" \
    -aspectWidth=43 -aspectHeight=18 \
    -useResolutionList=on -resolutionList="3440x1440,2752x1152,1720x720" \
    -virtualScreenHiDPI=off || { echo "Could not create Ultrawide."; exit 1; }
  sleep 2

  "$B" create -type=VirtualScreen -virtualScreenName="Laptop" \
    -aspectWidth=16 -aspectHeight=10 \
    -useResolutionList=on -resolutionList="1728x1080,1440x900" \
    -virtualScreenHiDPI=off || { echo "Could not create Laptop."; exit 1; }
  sleep 3
fi

# Validate the 16:10 recipe while connected; BetterDisplay does not return a
# mode list for a disconnected virtual screen.
"$B" set -name=Laptop -connected=on >/dev/null 2>&1 || true
sleep 3
laptop_modes=$("$B" get -name=Laptop -displayModeList 2>/dev/null || true)
if ! printf '%s\n' "$laptop_modes" | grep -q '1728x1080' \
    || ! printf '%s\n' "$laptop_modes" | grep -q '1440x900'; then
  echo "Laptop is missing a required 16:10 canvas."
  exit 1
fi
"$B" set -name=Laptop -connected=off >/dev/null 2>&1 || true

# Leave login in the safe/default docked state. Runtime switching is handled by
# macrig-set-display.sh, which selects an exact mode before disconnecting this.
"$B" set -name=Ultrawide -connected=on >/dev/null 2>&1 || true
sleep 3
ultra_modes=$("$B" get -name=Ultrawide -displayModeList 2>/dev/null || true)
mode_number=$(printf '%s\n' "$ultra_modes" | awk '$3 == "3440x1440" { print $1; exit }')
[ -n "$mode_number" ] || { echo "Ultrawide is missing 3440x1440."; exit 1; }
"$B" set -name=Ultrawide -displayModeNumber="$mode_number" >/dev/null 2>&1 || true
sleep 2
"$B" get -name=Ultrawide -resolution 2>/dev/null | grep -q '3440x1440' \
  || { echo "Ultrawide did not reach 3440x1440."; exit 1; }
"$B" set -name=Ultrawide -main=on >/dev/null 2>&1 || true

touch "$MARKER"
echo "result: Ultrawide=$("$B" get -name=Ultrawide -resolution 2>/dev/null) Laptop=ready"
