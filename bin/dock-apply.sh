#!/bin/bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/config.sh"

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

# 1) Remote-Mac resolution (has its own logging/retries).
bash "$MACRIG_DIR/bin/mac-resolution-toggle.sh" "$MODE"

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

case "$MODE" in
  ultrawide)   # docked → drop WiFi, but only once wired ethernet has an IP
    for i in 1 2 3 4 5 6; do
      if wired_up; then
        networksetup -setairportpower "$WIFI_DEV" off \
          && echo "  wifi OFF (wired ethernet up)" >>"$LOG"
        exit 0
      fi
      sleep 2
    done
    echo "  no wired ethernet came up — leaving WiFi ON" >>"$LOG"
    ;;
  laptop)      # undocked → make sure WiFi is back on
    networksetup -setairportpower "$WIFI_DEV" on \
      && echo "  wifi ON" >>"$LOG"
    ;;
esac
