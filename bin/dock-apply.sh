#!/bin/bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/mira-config.sh"
acquire_action_lock "Apply Dock Mode" || exit $?

# dock-apply.sh <ultrawide|laptop>
# Fired by the dock-watch agent on display connect/disconnect. Does BOTH:
#   1) remote Mac resolution  (via mac-resolution-toggle.sh)
#   2) local MacBook WiFi:  OFF when docked (once wired ethernet is actually up),
#                           ON  when undocked
#
# "ultrawide" = docked (external display present); "laptop" = undocked.
MODE="${1:-}"
LOG="$LOG_DIR/dock-watch.log"

# Detect this Mac's WiFi device (don't hardcode en0).
WIFI_DEV="$(networksetup -listallhardwareports 2>/dev/null \
             | awk '/Wi-Fi|AirPort/{getline; print $2; exit}')"
[ -z "$WIFI_DEV" ] && WIFI_DEV="en0"

echo "=== $(date '+%F %T')  dock-apply $MODE  (wifi=$WIFI_DEV) ===" >>"$LOG"

# True if some wired (non-WiFi, non-virtual) interface is carrying an IPv4 —
# i.e. the dock's ethernet is really up, so it's safe to drop WiFi.
wired_up() {
  local dev
  for dev in $(ifconfig -l); do
    case "$dev" in
      "$WIFI_DEV"|lo*|utun*|awdl*|llw*|bridge*|gif*|stf*|ap1|anpi*) continue ;;
    esac
    ipconfig getifaddr "$dev" >/dev/null 2>&1 && return 0
  done
  return 1
}

RESULT=0
RESOLUTION_MODE="$MODE"
if [ "$(cat "$PROFILE_STATE" 2>/dev/null)" = "low" ]; then
  RESOLUTION_MODE="laptop"
fi

# Restore WiFi before any SSH work when undocking. This keeps the local viewer
# online even when a remote target is slow or unavailable.
if [ "$MODE" = "laptop" ]; then
  networksetup -setairportpower "$WIFI_DEV" on \
    && echo "  wifi ON" >>"$LOG" \
    || RESULT=1
fi

RESOLUTION_PID=""
if display_control_owned; then
  bash "$MACRIG_DIR/bin/mac-resolution-toggle.sh" "$RESOLUTION_MODE" &
  RESOLUTION_PID=$!
else
  if display_sync_enabled; then
    printf 'off\n' > "$DISPLAY_SYNC_STATE"
    echo "  remote display lease belongs elsewhere; local control reconciled OFF" >>"$LOG"
  else
    echo "  remote display sync OFF on this viewer" >>"$LOG"
  fi
fi

case "$MODE" in
  ultrawide)   # docked → drop WiFi, but only once wired ethernet has an IP
    for _ in 1 2 3 4 5 6; do
      if wired_up; then
        networksetup -setairportpower "$WIFI_DEV" off \
          && echo "  wifi OFF (wired ethernet up)" >>"$LOG" \
          || RESULT=1
        break
      fi
      sleep 2
    done
    if ! wired_up; then
      echo "  no wired ethernet came up — leaving WiFi ON" >>"$LOG"
    fi
    ;;
  laptop) ;;
  *) echo "invalid dock mode: $MODE" >>"$LOG"; RESULT=2 ;;
esac

if [ -n "$RESOLUTION_PID" ] && ! wait "$RESOLUTION_PID"; then
  RESULT=1
fi

exit "$RESULT"
