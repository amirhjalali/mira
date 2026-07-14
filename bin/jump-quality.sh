#!/bin/bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/macrig-config.sh"
acquire_action_lock "Apply Jump Quality" || exit $?

# jump-quality.sh [high|medium|low|auto]     (default: auto)
#
# One command to match the remote-desktop experience to the network you're on.
# Applies BOTH levers:
#   1. Remote Mac resolution (BetterDisplay via mac-resolution-toggle.sh)
#   2. Jump Desktop per-session caps (Remote menu via Accessibility):
#      Maximum Bandwidth / Framerate / Quality
#
#   PROFILE   RESOLUTION                BANDWIDTH  FPS  QUALITY   WHEN
#   high      full (dock-aware shape)   Auto       60   Highest   home LAN (pristine)
#   medium    full (dock-aware shape)   10 mbps    30   High      decent remote (hotel wifi)
#   low       viewer laptop canvas      4 mbps     15   Low       bad internet / cellular
#
# auto measures RTT+jitter to the Macs and picks:
#   on home LAN (<8ms)            -> high
#   avg<60ms and jitter<30ms      -> medium
#   worse                         -> low
#
# The bandwidth cap matters most on cellular: an uncapped Fluid stream fills the
# phone's queue (bufferbloat) and interactive packets wait behind it — measured
# 248ms avg / 565ms spikes uncapped on a hotspot whose idle RTT was ~45ms.
#
# Jump caps apply to OPEN sessions (focused via the Window menu, which also
# works across full-screen Spaces). Machines without an open session are
# skipped. Needs Accessibility (same grant as open-both-macs.sh).

MACHINES=("${TARGET_NAMES[@]}")
TOGGLE="$MACRIG_DIR/bin/mac-resolution-toggle.sh"
STATE="$PROFILE_STATE"   # last applied profile (for --if-changed)

# --if-changed: exit quietly if the (auto-detected) profile is already applied.
# Used by the net-watch agent so network flaps don't flip Spaces for nothing.
IFCHANGED=""
PROFILE="auto"
for a in "$@"; do
  case "$a" in
    --if-changed) IFCHANGED=1 ;;
    *) PROFILE="$a" ;;
  esac
done

# ---------- auto-detect ----------
if [ "$PROFILE" = "auto" ]; then
  # Home LAN? Any target resolving inside the configured subnet is a suitable probe.
  for lan_host in "${TARGET_LAN_HOSTS[@]}"; do
    lan_ip=$(dscacheutil -q host -a name "$lan_host" 2>/dev/null | awk -v prefix="$HOME_SUBNET_PREFIX" '/^ip_address: / { if (index($2, prefix) == 1) { print $2; exit } }')
    if [ -n "$lan_ip" ]; then
      lan_avg=$(ping -c 2 -q "$lan_ip" 2>/dev/null | awk -F/ '/round-trip/{print $5}')
      if [ -n "$lan_avg" ] && awk "BEGIN{exit !($lan_avg < 8)}"; then
        PROFILE="high"
        break
      fi
    fi
  done
  # Not home -> measure the Tailscale path (5 samples; avg + jitter).
  if [ "$PROFILE" = "auto" ]; then
    stats=""
    for ts in "${TARGET_TS_HOSTS[@]}"; do
      stats=$(ping -c 5 -q "$ts" 2>/dev/null | awk -F/ '/round-trip/{print $5, $7}')
      [ -n "$stats" ] && break
    done
    if [ -z "$stats" ]; then
      echo "✗ Can't reach either Mac (Tailscale down?). No changes made." >&2
      exit 1
    fi
    avg=${stats% *}; sdev=${stats#* }
    if awk "BEGIN{exit !($avg < 60 && $sdev < 30)}"; then PROFILE="medium"; else PROFILE="low"; fi
    echo "measured: avg=${avg}ms jitter=${sdev}ms -> $PROFILE"
  else
    echo "on home LAN (${lan_avg}ms) -> high"
  fi
fi

# ---------- skip if nothing changed (--if-changed) ----------
if [ -n "$IFCHANGED" ] && [ -f "$STATE" ] && [ "$(cat "$STATE" 2>/dev/null)" = "$PROFILE" ]; then
  echo "profile unchanged ($PROFILE) — Jump caps unchanged"
  # Network recovery often follows a sleep/dock transition. Even when the
  # quality profile is unchanged, reconcile the remote screen shape because
  # the display callback may have occurred while this Mac was asleep and Jump
  # can independently resize a remote virtual display.
  if display_control_owned; then
    echo "reconciling remote display shape"
    "$MACRIG_DIR/bin/sync-display-now.sh"
  fi
  exit 0
fi

# ---------- profile table ----------
case "$PROFILE" in
  high)   BW="Auto";    FPS="60 fps"; QUAL="Highest"; RESMODE="dock" ;;
  medium) BW="10 mbps"; FPS="30 fps"; QUAL="High";    RESMODE="dock" ;;
  low)    BW="4 mbps";  FPS="15 fps"; QUAL="Low";     RESMODE="laptop" ;;
  *) echo "usage: $(basename "$0") [high|medium|low|auto]"; exit 2 ;;
esac
echo "profile: $PROFILE   (bandwidth=$BW, framerate=$FPS, quality=$QUAL)"

# ---------- 1. remote resolution ----------
if [ "$RESMODE" = "laptop" ]; then
  shape="laptop"
else
  # dock-aware: external display present -> ultrawide, else laptop
  if system_profiler SPDisplaysDataType 2>/dev/null | grep -q "$DOCK_MARKER"; then
    shape="ultrawide"
  else
    shape="laptop"
  fi
fi
TOGGLE_PID=""
if display_control_owned; then
  echo "resolution -> $shape (both targets, via mac-resolution-toggle.sh)"
  "$TOGGLE" "$shape" >/dev/null 2>&1 &
  TOGGLE_PID=$!
else
  echo "resolution sync not owned by this viewer — remote displays unchanged"
fi

# ---------- 2. Jump per-session caps ----------
ACTION_FAILED=0
for name in "${MACHINES[@]}"; do
  result=$(/usr/bin/osascript <<EOF 2>&1
tell application "System Events"
  tell process "Jump Desktop"
    if not (exists menu item "$name" of menu 1 of menu bar item "Window" of menu bar 1) then return "no-session"
    set frontmost to true
    click menu item "$name" of menu 1 of menu bar item "Window" of menu bar 1
    delay 1.5 -- allow Space switch to the session
    click menu item "$BW" of menu 1 of menu item "Maximum Bandwidth" of menu 1 of menu bar item "Remote" of menu bar 1
    delay 0.4
    click menu item "$FPS" of menu 1 of menu item "Framerate" of menu 1 of menu bar item "Remote" of menu bar 1
    delay 0.4
    click menu item "$QUAL" of menu 1 of menu item "Quality" of menu 1 of menu bar item "Remote" of menu bar 1
    return "applied"
  end tell
end tell
EOF
  )
  case "$result" in
    applied)    echo "✓ $name — caps applied" ;;
    no-session) echo "- $name — no open session, skipped" ;;
    *)          echo "✗ $name — $result" >&2; ACTION_FAILED=1 ;;
  esac
done

if [ -n "$TOGGLE_PID" ] && ! wait "$TOGGLE_PID" 2>/dev/null; then
  echo "✗ Remote display sync failed for one or more targets; see logs/dock-watch.log." >&2
  ACTION_FAILED=1
fi

if [ "$ACTION_FAILED" -ne 0 ]; then
  echo "profile was not recorded because one or more actions failed" >&2
  exit 1
fi

echo "$PROFILE" > "$STATE"
echo "done."
