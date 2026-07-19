#!/bin/bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/mira-config.sh"
acquire_action_lock "Sync Remote Displays" || exit $?

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
# hold separate 21:9 and 16:10 BetterDisplay virtual screens. The remote helper
# connects the desired screen and verifies its exact mode before disconnecting
# the other one.

MODE="${1:-}"
case "$MODE" in
  ultrawide) RES="$RES_ULTRAWIDE" ;;
  laptop)    RES="$RES_LAPTOP" ;;
  *) echo "usage: $(basename "$0") <ultrawide|laptop>"; exit 2 ;;
esac

LOG="$LOG_DIR/dock-watch.log"
echo "=== $(date '+%F %T')  ->  $MODE ($RES) ===" >>"$LOG"

if ! display_control_owned; then
  echo "  display sync skipped: $VIEWER_ID does not own the shared lease" >>"$LOG"
  echo "This viewer does not own remote display control. Use Take Display Control Here first." >&2
  exit 1
fi

# Set one Mac. Tries Tailscale IP first, then .local. Retries a few rounds —
# a dock/undock often coincides with the network handing off, so the first
# attempt can briefly fail.
set_mac() {
  local name="$1" user="$2" ts="$3" lan="$4" remote_command out rc
  printf -v remote_command '%q %q %q %q %q' \
    "/Users/$user/mira-set-display.sh" "$MODE" "$RES" \
    "$VSCREEN_ULTRAWIDE_NAME" "$VSCREEN_LAPTOP_NAME"
  for try in 1 2 3 4; do
    for host in "$ts" "$lan"; do
      out=$(ssh -o ConnectTimeout=4 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
              "$user@$host" "$remote_command" 2>&1)
      rc=$?
      if [ "$rc" -eq 0 ]; then
        [ -n "$out" ] && printf '%s\n' "$out" >>"$LOG"
        echo "  $name: ok via $host (try $try)" >>"$LOG"
        return 0
      fi
      # ssh returns 255 only for its own connect failures; any other nonzero
      # code means the remote helper ran and rejected the request (e.g. an
      # unsupported mode). Retrying other hosts/rounds can't fix that, so
      # surface the real message and stop instead of blaming the network.
      if [ "$rc" -ne 255 ]; then
        printf '%s\n' "$out" >>"$LOG"
        echo "  $name: FAILED (remote error, exit $rc): ${out:-no output}" >>"$LOG"
        return 1
      fi
      echo "  $name: connect failed via $host (try $try): ${out:-ssh exit 255}" >>"$LOG"
    done
    sleep 3
  done
  echo "  $name: FAILED after 4 rounds (unreachable?)" >>"$LOG"
  return 1
}

# Both in parallel so the whole switch finishes in a few seconds.
pids=()
for i in 0 1; do
  set_mac "${TARGET_NAMES[$i]}" "${TARGET_USERS[$i]}" \
          "${TARGET_TS_HOSTS[$i]}" "${TARGET_LAN_HOSTS[$i]}" &
  pids+=("$!")
done

result=0
for pid in "${pids[@]}"; do
  wait "$pid" || result=1
done
echo "  done." >>"$LOG"
exit "$result"
