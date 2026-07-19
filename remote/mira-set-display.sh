#!/bin/bash
# mira-set-display.sh [--check] <ultrawide|laptop> <resolution>
# Switch atomically between MacRig's 21:9 and 16:10 virtual screens, or verify
# that the requested state is already active without changing anything.

set -u
ACTION="set"
if [ "${1:-}" = "--check" ]; then
  ACTION="check"
  shift
fi
MODE="${1:-}"
RESOLUTION="${2:-}"
ULTRAWIDE_NAME="${3:-Ultrawide}"
LAPTOP_NAME="${4:-Laptop}"

case "$MODE" in
  ultrawide) DESIRED="$ULTRAWIDE_NAME"; OTHER="$LAPTOP_NAME" ;;
  laptop) DESIRED="$LAPTOP_NAME"; OTHER="$ULTRAWIDE_NAME" ;;
  *) echo "usage: $0 <ultrawide|laptop> <resolution>" >&2; exit 2 ;;
esac

B="${MACRIG_BDCLI:-}"
if [ -z "$B" ]; then
  for candidate in /opt/homebrew/bin/betterdisplaycli /usr/local/bin/betterdisplaycli \
      "/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay" \
      "$HOME/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay"; do
    [ -x "$candidate" ] && B="$candidate" && break
  done
fi
[ -n "$B" ] || { echo "BetterDisplay CLI not found." >&2; exit 1; }

# BetterDisplay answers a name query once per matching entity: a connected
# virtual screen reports both itself and its live display ("on,on"), while a
# disconnected one reports a single "off". Accept any count as long as every
# reported value is the expected one.
all_values_are() {
  local expected="$1" actual="$2"
  [ -n "$actual" ] || return 1
  ! printf '%s\n' "$actual" | tr ',' '\n' | grep -qv "^${expected}\$"
}

display_matches() {
  local desired_connected desired_resolution other_connected
  desired_connected=$("$B" get -name="$DESIRED" -connected 2>/dev/null || true)
  desired_resolution=$("$B" get -name="$DESIRED" -resolution 2>/dev/null || true)
  other_connected=$("$B" get -name="$OTHER" -connected 2>/dev/null || true)
  all_values_are on "$desired_connected" \
    && all_values_are "$RESOLUTION" "$desired_resolution" \
    && all_values_are off "$other_connected"
}

if [ "$ACTION" = "check" ]; then
  if display_matches; then
    echo "$DESIRED=$RESOLUTION; $OTHER=off"
    exit 0
  fi
  echo "display drift: expected $DESIRED=$RESOLUTION and $OTHER=off" >&2
  exit 1
fi

"$B" set -name="$DESIRED" -connected=on >/dev/null 2>&1 || true
sleep 3
modes=$("$B" get -name="$DESIRED" -displayModeList 2>/dev/null || true)
mode_number=$(printf '%s\n' "$modes" | awk -v resolution="$RESOLUTION" '$3 == resolution { print $1; exit }')
if [ -z "$mode_number" ]; then
  echo "$DESIRED does not support $RESOLUTION." >&2
  exit 1
fi

"$B" set -name="$DESIRED" -displayModeNumber="$mode_number" >/dev/null 2>&1 || true
sleep 2
if ! all_values_are "$RESOLUTION" "$("$B" get -name="$DESIRED" -resolution 2>/dev/null)"; then
  echo "$DESIRED did not reach $RESOLUTION." >&2
  exit 1
fi

"$B" set -name="$DESIRED" -main=on >/dev/null 2>&1 || true
sleep 1
"$B" set -name="$OTHER" -connected=off >/dev/null 2>&1 || true
sleep 2
if ! display_matches; then
  echo "display did not remain at $DESIRED=$RESOLUTION with $OTHER disconnected." >&2
  exit 1
fi
echo "$DESIRED=$RESOLUTION"
