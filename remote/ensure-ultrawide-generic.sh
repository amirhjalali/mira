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
# Bump the marker version whenever the recipe below changes (resolution lists,
# aspect ratios, HiDPI): a marker-less target rebuilds its screens on the next
# run, so already-provisioned machines pick up the new recipe automatically.
MARKER="$HOME/.mira-display-v1"
echo "=== $(date '+%Y-%m-%d %H:%M:%S') ensure MacRig displays (binary: ${B:-NONE}) ==="

# A user at a physical screen owns the display arrangement; only steal main
# for the virtual screen when the machine is headless or remote-only.
# system_profiler lists connected displays as 8-space-indented "Name:" lines,
# and a connected virtual screen appears there under its own name.
console_is_active() {
  local u names
  u=$(stat -f %Su /dev/console 2>/dev/null)
  case "$u" in ""|root|loginwindow|_mbsetupuser) return 1 ;; esac
  names=$(system_profiler SPDisplaysDataType 2>/dev/null \
    | grep -E '^ {8}[^ ].*:$' | sed -e 's/^ *//' -e 's/:$//')
  [ -n "$names" ] || return 1
  printf '%s\n' "$names" | grep -qvE '^(Ultrawide|Laptop)$'
}

if [ -f "$MARKER" ] && console_is_active; then
  echo "result: console session active — displays untouched"
  exit 0
fi

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

  # HiDPI stays OFF on both screens: these are driven over Screen Sharing/VNC,
  # which encodes the raw framebuffer — HiDPI would 4x the pixels (Laptop
  # 1.4M -> 5.6M, Ultrawide 5.0M -> 19.8M) with no bandwidth or framerate cap
  # available on VNC sessions to absorb it. A future Retina-sharp mode must be
  # an explicit opt-in rebuild, never a runtime quality-tier switch.
  "$B" create -type=VirtualScreen -virtualScreenName="Ultrawide" \
    -aspectWidth=43 -aspectHeight=18 \
    -useResolutionList=on -resolutionList="3440x1440,2752x1152,1720x720" \
    -virtualScreenHiDPI=off || { echo "Could not create Ultrawide."; exit 1; }
  sleep 2

  "$B" create -type=VirtualScreen -virtualScreenName="Laptop" \
    -aspectWidth=16 -aspectHeight=10 \
    -useResolutionList=on -resolutionList="1728x1080,1470x956,1440x900" \
    -virtualScreenHiDPI=off || { echo "Could not create Laptop."; exit 1; }
  sleep 3
fi

# Validate the 16:10 recipe while connected; BetterDisplay does not return a
# mode list for a disconnected virtual screen.
"$B" set -name=Laptop -connected=on >/dev/null 2>&1 || true
sleep 3
laptop_modes=$("$B" get -name=Laptop -displayModeList 2>/dev/null || true)
if ! printf '%s\n' "$laptop_modes" | grep -q '1728x1080' \
    || ! printf '%s\n' "$laptop_modes" | grep -q '1470x956'; then
  echo "Laptop is missing a required 16:10 canvas."
  exit 1
fi
"$B" set -name=Laptop -connected=off >/dev/null 2>&1 || true

# First run with a user at the console: the recipe is built and validated, so
# record that and stop before rearranging their screens.
if console_is_active; then
  touch "$MARKER"
  echo "result: console session active — recipe verified, displays untouched"
  exit 0
fi

# Leave login in the safe/default docked state. Runtime switching is handled by
# mira-set-display.sh, which selects an exact mode before disconnecting this.
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
