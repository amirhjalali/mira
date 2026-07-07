#!/bin/bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/config.sh"

# mac-resolution-toggle.sh <ultrawide|laptop>
#
# Pushes the matching screen shape to BOTH remote Macs:
#   ultrawide -> configured ultrawide resolution
#   laptop    -> configured laptop-panel resolution
#
# Called automatically by the dock-watch agent the instant a display is
# connected/disconnected. Safe to run by hand too:  mac-resolution-toggle.sh laptop
#
# Reaches the Macs over TAILSCALE first (works from anywhere — home or a phone
# hotspot), then falls back to .local (home LAN) if Tailscale is down. Both Macs
# hold a single BetterDisplay virtual screen whose resolution list contains both
# shapes, so this is a fast, gentle per-name set (no recreate).

MODE="${1:-}"
case "$MODE" in
  ultrawide) RES="$RES_ULTRAWIDE" ;;
  laptop)    RES="$RES_LAPTOP" ;;
  *) echo "usage: $(basename "$0") <ultrawide|laptop>"; exit 2 ;;
esac

B="$BDCLI"
LOG="$LOG_DIR/dock-watch.log"
echo "=== $(date '+%F %T')  ->  $MODE ($RES) ===" >>"$LOG"

# Set one Mac. Tries Tailscale IP first, then .local. Retries a few rounds —
# a dock/undock often coincides with the network handing off, so the first
# attempt can briefly fail.
set_mac() {
  local name="$1" user="$2" ts="$3" lan="$4"
  for try in 1 2 3 4; do
    for host in "$ts" "$lan"; do
      if ssh -o ConnectTimeout=4 -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$user@$host" \
           "$B set -name=$VSCREEN_NAME -resolution=$RES; $B set -name=$VSCREEN_NAME -main=on" \
           >>"$LOG" 2>&1; then
        echo "  $name: ok via $host (try $try)" >>"$LOG"
        return 0
      fi
    done
    sleep 3
  done
  echo "  $name: FAILED after 4 rounds (unreachable?)" >>"$LOG"
  return 1
}

# Both in parallel so the whole switch finishes in a few seconds.
set_mac "mini" "$MINI_USER" "$MINI_TS" "$MINI_LAN" &
set_mac "air"  "$AIR_USER"  "$AIR_TS"  "$AIR_LAN"  &
wait
echo "  done." >>"$LOG"
