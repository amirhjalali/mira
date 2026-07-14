#!/bin/bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/macrig-config.sh"

FAILURES=0
WARNINGS=0

pass() { echo "✓ $*"; }
warn() { echo "! $*"; WARNINGS=$((WARNINGS + 1)); }
fail() { echo "✗ $*"; FAILURES=$((FAILURES + 1)); }

echo "MacRig Doctor"
echo "Viewer: $VIEWER_NAME ($VIEWER_ID)"
echo "Root: $MACRIG_DIR"
echo

if [ -d "/Applications/Jump Desktop.app" ]; then pass "Jump Desktop installed"; else fail "Jump Desktop is not installed in /Applications"; fi

AX_ENABLED=$(/usr/bin/osascript -e 'tell application "System Events" to get UI elements enabled' 2>/dev/null || echo false)
if [ "$AX_ENABLED" = "true" ]; then pass "Accessibility automation enabled"; else fail "Accessibility automation is not enabled"; fi

if launchctl print "gui/$(id -u)/com.amir.macrig" >/dev/null 2>&1; then
  pass "MacRig LaunchAgent running"
else
  fail "MacRig LaunchAgent is not running"
fi

if launchctl print "gui/$(id -u)/com.amir.dockwatch" >/dev/null 2>&1; then
  pass "dock-watch LaunchAgent running"
else
  fail "dock-watch LaunchAgent is not running"
fi

MRU_SPACES=$(defaults read com.apple.dock mru-spaces 2>/dev/null || echo 1)
if [ "$PRESERVE_SPACE_ORDER" != "on" ] || [ "$MRU_SPACES" = "0" ]; then
  pass "Mission Control Space ordering is stable"
else
  warn "Mission Control may rearrange Spaces; rerun install.sh to enforce target order"
fi

if pgrep -qf "Jump Desktop.app/Contents/MacOS"; then
  for name in "${TARGET_NAMES[@]}"; do
    result=$(/usr/bin/osascript - "$name" <<'APPLESCRIPT' 2>/dev/null
on run argv
  set machineName to item 1 of argv
  tell application "System Events"
    tell process "Jump Desktop"
      if exists window machineName then return "present"
      if exists menu item machineName of menu 1 of menu item "Open Recent" of menu 1 of menu bar item "File" of menu bar 1 then return "present"
      return "missing"
    end tell
  end tell
end run
APPLESCRIPT
    )
    if [ "$result" = "present" ]; then pass "Jump connection found: $name"; else fail "Jump connection missing or renamed: $name"; fi
  done
else
  warn "Jump Desktop is not running; saved connection names were not checked"
fi

echo
for i in 0 1; do
  name="${TARGET_NAMES[$i]}"
  command="test -x '$BDCLI' && '$BDCLI' get -identifiers"
  if identifiers=$(target_ssh "$i" "$command" 2>/dev/null) && [ -n "$identifiers" ]; then
    pass "$name reachable; BetterDisplay responds"
  else
    fail "$name unreachable or BetterDisplay unavailable"
    continue
  fi

  if printf '%s\n' "$identifiers" | grep -q "\"name\" : \"$VSCREEN_ULTRAWIDE_NAME\"" \
      && printf '%s\n' "$identifiers" | grep -q "\"name\" : \"$VSCREEN_LAPTOP_NAME\""; then
    pass "$name has separate ultrawide and laptop screens"
  else
    fail "$name is missing a MacRig virtual screen; rerun remote/setup-target-ultrawide.sh"
    continue
  fi

  # shellcheck disable=SC2016 # command substitution must run on the target Mac
  if target_ssh "$i" 'launchctl print "gui/$(id -u)/com.amir.macrig-display" >/dev/null 2>&1' >/dev/null 2>&1; then
    pass "$name display login agent running"
  else
    warn "$name display login agent is not running; rerun remote/setup-target-ultrawide.sh"
  fi

  # shellcheck disable=SC2016 # $HOME must expand on the target Mac
  if target_ssh "$i" 'test -f "$HOME/.macrig-display-v3" && test -x "$HOME/macrig-set-display.sh"' >/dev/null 2>&1; then
    pass "$name display recipe supports 3440x1440, 1728x1080, and 1440x900"
  else
    warn "$name display recipe is stale; rerun remote/setup-target-ultrawide.sh"
  fi
done

echo
owner="$(display_owner)"
if [ -z "$owner" ]; then
  warn "No viewer currently owns remote display control"
elif [ "$owner" = "$VIEWER_ID" ]; then
  if display_sync_enabled; then
    pass "This viewer owns remote display control"
  else
    warn "The shared lease names this viewer, but local display control is released"
  fi
else
  if display_sync_enabled; then
    warn "Local display control is on, but the shared lease belongs to $owner"
  else
    pass "Remote display control belongs to $owner"
  fi
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "Doctor result: ready ($WARNINGS warning(s))"
  exit 0
fi

echo "Doctor result: $FAILURES failure(s), $WARNINGS warning(s)"
exit 1
