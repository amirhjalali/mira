#!/bin/bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/mira-config.sh"
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
  # Not home -> measure the Tailscale path (15 samples at 0.2s: ~3s wall time,
  # a materially stabler stddev than 5 samples at the default 1s spacing).
  if [ "$PROFILE" = "auto" ]; then
    stats=""
    for ts in "${TARGET_TS_HOSTS[@]}"; do
      # macOS summary: round-trip min/avg/max/stddev = a/b/c/d ms
      # -> $5 is avg (clean), $7 is stddev with a trailing " ms" unit; strip it
      # so avg and jitter come out as single bare numbers.
      stats=$(ping -c 15 -i 0.2 -q "$ts" 2>/dev/null | awk -F/ '/round-trip/{gsub(/[^0-9.]/,"",$7); print $5, $7}')
      [ -n "$stats" ] && break
    done
    if [ -z "$stats" ]; then
      # 69 = EX_UNAVAILABLE. MIRA treats this as "network not up yet" (log +
      # reschedule), unlike a real action failure — keep it distinct from 1.
      echo "✗ Can't reach either Mac (Tailscale down?). No changes made." >&2
      exit 69
    fi
    avg=${stats% *}; sdev=${stats#* }
    # Hysteresis around the medium/low boundary: a link hovering near the
    # cutoffs (e.g. jitter ~27-33ms) must not flip profiles — and remote
    # resolutions — on every auto tune. Demoting from medium and returning
    # from low each need to clear the boundary by a margin; any other prior
    # state (high, empty, unreadable) uses the plain thresholds.
    prev=$(cat "$STATE" 2>/dev/null)
    case "$prev" in
      medium) if awk "BEGIN{exit !($avg < 70 && $sdev < 35)}"; then PROFILE="medium"; else PROFILE="low"; fi ;;
      low)    if awk "BEGIN{exit !($avg < 50 && $sdev < 22)}"; then PROFILE="medium"; else PROFILE="low"; fi ;;
      *)      if awk "BEGIN{exit !($avg < 60 && $sdev < 30)}"; then PROFILE="medium"; else PROFILE="low"; fi ;;
    esac
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
    # --check: two cheap read-only SSH probes first; sync-display-now falls
    # through to the full switch (>=8s of fixed sleeps per target) only when
    # real drift is detected.
    "$MACRIG_DIR/bin/sync-display-now.sh" --check
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
# Disabled by default: driving Jump's menus at runtime steals focus, can strand
# a menu open (blocking all input), and doesn't persist anyway — quality and
# High Bandwidth Mode are per-connection settings that reassert on reconnect.
# Set them once in the saved connection instead. Resolution (section 1) is the
# real bandwidth lever and syncs over SSH without touching the screen.
# Set MACRIG_JUMP_MENUS=on to re-enable the legacy menu automation.
ACTION_FAILED=0
if [ "${MACRIG_JUMP_MENUS:-off}" != "on" ]; then
  echo "- Jump menu automation off (quality lives in the saved connections)"
  MACHINES=()
fi
for name in "${MACHINES[@]}"; do
  result=$(/usr/bin/osascript <<EOF 2>&1
on joinNames(theList)
  set outText to ""
  repeat with anItem in theList
    set nm to (contents of anItem)
    if nm is missing value then set nm to "(separator)"
    if outText is "" then
      set outText to nm
    else
      set outText to outText & ", " & nm
    end if
  end repeat
  return outText
end joinNames

-- Apply one Remote-menu setting. Jump 10.15.6 populates submenus lazily, so the
-- parent item must be physically clicked open before its target item exists;
-- deep one-shot clicks fail with -1728. Escape (consumed by the open menu, not
-- forwarded to the remote session) closes the menu on any failure.
on applySetting(parentName, targetName)
  tell application "System Events" to tell process "Jump Desktop"
    try
      click menu bar item "Remote" of menu bar 1
      delay 0.35
      set parentItem to menu item parentName of menu 1 of menu bar item "Remote" of menu bar 1
      -- Disabled parent: on VNC sessions Maximum Bandwidth and Framerate are
      -- never available (Fluid-only); Quality is available whenever the
      -- session is actually connected. The caller decides what disabled means.
      if not (enabled of parentItem) then
        key code 53 -- Escape: close the Remote menu
        return "disabled"
      end if
      click parentItem -- open the submenu so its lazy items populate
      delay 0.35
      if not (exists menu item targetName of menu 1 of parentItem) then
        set avail to my joinNames(name of every menu item of menu 1 of parentItem)
        key code 53 -- close submenu
        key code 53 -- close Remote menu
        return "no '" & targetName & "' under " & parentName & " (have: " & avail & ")"
      end if
      click menu item targetName of menu 1 of parentItem
      return "ok"
    on error errMsg number errNum
      -- Close only menus that are actually open: the menu bar item stays
      -- selected while its menu tree is open, and each Escape closes one
      -- level. A blind Escape with no menu open would be forwarded to the
      -- remote session instead.
      try
        repeat 2 times
          if not (selected of menu bar item "Remote" of menu bar 1) then exit repeat
          key code 53
          delay 0.15
        end repeat
      end try
      return "AppleScript error " & errNum & " on " & parentName & ": " & errMsg
    end try
  end tell
end applySetting

tell application "System Events"
  tell process "Jump Desktop"
    -- Prefix match: viewing a single remote display retitles the window
    -- (e.g. "Amir's MacBook Pro - Display 1"), so exact names go stale.
    if not (exists (first menu item of menu 1 of menu bar item "Window" of menu bar 1 whose name begins with "$name")) then return "no-session"
    set frontmost to true
    click (first menu item of menu 1 of menu bar item "Window" of menu bar 1 whose name begins with "$name")
    delay 1.5 -- allow Space switch to the session
  end tell
end tell
-- VNC (Screen Sharing, port 5900) sessions expose only Quality; Maximum
-- Bandwidth and Framerate exist for Fluid sessions. Skip what the protocol
-- lacks, but treat a disabled Quality menu as a dead session.
set skipped to {}
set r to applySetting("Maximum Bandwidth", "$BW")
if r is "disabled" then
  set end of skipped to "bandwidth"
else if r is not "ok" then
  return r
end if
set r to applySetting("Framerate", "$FPS")
if r is "disabled" then
  set end of skipped to "framerate"
else if r is not "ok" then
  return r
end if
set r to applySetting("Quality", "$QUAL")
if r is "disabled" then return "not-connected"
if r is not "ok" then return r
if (count of skipped) is 0 then return "applied"
return "applied (" & my joinNames(skipped) & " unavailable on this protocol)"
EOF
  )
  case "$result" in
    applied*)      echo "✓ $name — caps applied${result#applied}" ;;
    no-session)    echo "- $name — no open session, skipped" ;;
    not-connected) echo "✗ $name — session window open but not connected; caps need a live connection" >&2; ACTION_FAILED=1 ;;
    *)             echo "✗ $name — $result" >&2; ACTION_FAILED=1 ;;
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
