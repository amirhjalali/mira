#!/bin/bash
# macrig-set-display.sh <ultrawide|laptop> <resolution>
# Switch atomically between MacRig's 21:9 and 16:10 virtual screens.

set -u
MODE="${1:-}"
RESOLUTION="${2:-}"
ULTRAWIDE_NAME="${3:-Ultrawide}"
LAPTOP_NAME="${4:-Laptop}"

case "$MODE" in
  ultrawide) DESIRED="$ULTRAWIDE_NAME"; OTHER="$LAPTOP_NAME" ;;
  laptop) DESIRED="$LAPTOP_NAME"; OTHER="$ULTRAWIDE_NAME" ;;
  *) echo "usage: $0 <ultrawide|laptop> <resolution>" >&2; exit 2 ;;
esac

B=""
for candidate in /opt/homebrew/bin/betterdisplaycli /usr/local/bin/betterdisplaycli \
    "/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay" \
    "$HOME/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay"; do
  [ -x "$candidate" ] && B="$candidate" && break
done
[ -n "$B" ] || { echo "BetterDisplay CLI not found." >&2; exit 1; }

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
if ! "$B" get -name="$DESIRED" -resolution 2>/dev/null | grep -q "^${RESOLUTION}$"; then
  echo "$DESIRED did not reach $RESOLUTION." >&2
  exit 1
fi

"$B" set -name="$DESIRED" -main=on >/dev/null 2>&1 || true
sleep 1
"$B" set -name="$OTHER" -connected=off >/dev/null 2>&1 || true
echo "$DESIRED=$RESOLUTION"
