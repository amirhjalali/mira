#!/bin/bash
# Shared config loader. New installs use TARGET_1_*/TARGET_2_*; the legacy
# MINI_*/AIR_* names remain supported so existing private configs keep working.

MACRIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ ! -f "$MACRIG_DIR/config.sh" ]; then
  echo "MacRig config missing: $MACRIG_DIR/config.sh" >&2
  return 1
fi

# shellcheck disable=SC1091 # private config exists only in installed checkouts
source "$MACRIG_DIR/config.sh"

# BetterDisplay uses separate fixed-aspect virtual screens. Keep VSCREEN_NAME
# as a compatibility alias for configs created before the split.
VSCREEN_ULTRAWIDE_NAME="${VSCREEN_ULTRAWIDE_NAME:-${VSCREEN_NAME:-Ultrawide}}"
VSCREEN_LAPTOP_NAME="${VSCREEN_LAPTOP_NAME:-Laptop}"

VIEWER_NAME="${VIEWER_NAME:-$(scutil --get ComputerName 2>/dev/null || hostname -s)}"
VIEWER_ID="${VIEWER_ID:-$(scutil --get LocalHostName 2>/dev/null || hostname -s)}"
VIEWER_ID="$(printf '%s' "$VIEWER_ID" | tr -cs 'A-Za-z0-9._-' '-')"

# Target order is also Jump/Spaces order: peer laptop first, Mac mini second.
# On legacy Pro configs AIR_* is therefore target 1 and MINI_* is target 2.
TARGET_1_NAME="${TARGET_1_NAME:-${AIR_NAME:-}}"
TARGET_1_TS="${TARGET_1_TS:-${AIR_TS:-}}"
TARGET_1_LAN="${TARGET_1_LAN:-${AIR_LAN:-}}"
TARGET_1_USER="${TARGET_1_USER:-${AIR_USER:-}}"

TARGET_2_NAME="${TARGET_2_NAME:-${MINI_NAME:-}}"
TARGET_2_TS="${TARGET_2_TS:-${MINI_TS:-}}"
TARGET_2_LAN="${TARGET_2_LAN:-${MINI_LAN:-}}"
TARGET_2_USER="${TARGET_2_USER:-${MINI_USER:-}}"

# These arrays are consumed by the scripts that source this file.
# shellcheck disable=SC2034
TARGET_NAMES=("$TARGET_1_NAME" "$TARGET_2_NAME")
# shellcheck disable=SC2034
TARGET_TS_HOSTS=("$TARGET_1_TS" "$TARGET_2_TS")
# shellcheck disable=SC2034
TARGET_LAN_HOSTS=("$TARGET_1_LAN" "$TARGET_2_LAN")
# shellcheck disable=SC2034
TARGET_USERS=("$TARGET_1_USER" "$TARGET_2_USER")

for required in TARGET_1_NAME TARGET_1_TS TARGET_1_LAN TARGET_1_USER \
                TARGET_2_NAME TARGET_2_TS TARGET_2_LAN TARGET_2_USER; do
  if [ -z "${!required}" ]; then
    echo "MacRig config value missing: $required" >&2
    return 1
  fi
done

for required in BDCLI RES_ULTRAWIDE RES_LAPTOP; do
  if [ -z "${!required}" ]; then
    echo "MacRig config value missing: $required" >&2
    return 1
  fi
done

STATE_DIR="${STATE_DIR:-$MACRIG_DIR/state}"
LOG_DIR="${LOG_DIR:-$MACRIG_DIR/logs}"
PROFILE_STATE="${PROFILE_STATE:-$STATE_DIR/profile}"
MODE_STATE="${MODE_STATE:-$STATE_DIR/mode}"
CONTROL_DIR="${CONTROL_DIR:-$HOME/Library/Application Support/MacRig}"
LEGACY_DISPLAY_SYNC_STATE="${DISPLAY_SYNC_STATE:-$STATE_DIR/display-sync}"
DISPLAY_SYNC_STATE="$CONTROL_DIR/display-sync"
DISPLAY_OWNER_CACHE="${DISPLAY_OWNER_CACHE:-$CONTROL_DIR/display-owner}"
ACTION_LOCK_DIR="${ACTION_LOCK_DIR:-$CONTROL_DIR/action.lock}"
REMOTE_DISPLAY_SYNC_DEFAULT="${REMOTE_DISPLAY_SYNC_DEFAULT:-off}"
PRESERVE_SPACE_ORDER="${PRESERVE_SPACE_ORDER:-on}"
# shellcheck disable=SC2034 # consumed by claim/release scripts after sourcing
REMOTE_CONTROL_DIR='Library/Application Support/MacRig'
mkdir -p "$STATE_DIR" "$LOG_DIR" "$CONTROL_DIR"

if [ ! -f "$DISPLAY_SYNC_STATE" ] && [ -f "$LEGACY_DISPLAY_SYNC_STATE" ]; then
  cp "$LEGACY_DISPLAY_SYNC_STATE" "$DISPLAY_SYNC_STATE"
fi

display_sync_enabled() {
  local value="$REMOTE_DISPLAY_SYNC_DEFAULT"
  [ -f "$DISPLAY_SYNC_STATE" ] && value="$(tr -d '[:space:]' < "$DISPLAY_SYNC_STATE")"
  [ "$value" != "off" ]
}

target_ssh() {
  local index="$1" command="$2" host
  for host in "${TARGET_TS_HOSTS[$index]}" "${TARGET_LAN_HOSTS[$index]}"; do
    ssh -o ConnectTimeout=4 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
      "${TARGET_USERS[$index]}@$host" "$command" && return 0
  done
  return 1
}

target_display_matches() {
  local index="$1" mode="$2" resolution="$3" command
  printf -v command '%q %q %q %q %q %q' \
    "/Users/${TARGET_USERS[$index]}/macrig-set-display.sh" --check \
    "$mode" "$resolution" "$VSCREEN_ULTRAWIDE_NAME" "$VSCREEN_LAPTOP_NAME"
  target_ssh "$index" "$command"
}

display_owner() {
  # shellcheck disable=SC2016 # $HOME must expand on the remote Mac
  target_ssh 1 'cat "$HOME/Library/Application Support/MacRig/display-owner" 2>/dev/null' 2>/dev/null \
    | tr -d '[:space:]'
}

display_control_owned() {
  display_sync_enabled || return 1
  [ "$(display_owner)" = "$VIEWER_ID" ]
}

release_action_lock() {
  [ "${MACRIG_LOCK_OWNER:-}" = "$$" ] || return 0
  rm -f "$ACTION_LOCK_DIR/pid" "$ACTION_LOCK_DIR/label"
  rmdir "$ACTION_LOCK_DIR" 2>/dev/null || true
}

acquire_action_lock() {
  local label="${1:-MacRig action}" owner="" modified=0 age=0
  [ "${MACRIG_LOCK_HELD:-}" = "1" ] && return 0

  if ! mkdir "$ACTION_LOCK_DIR" 2>/dev/null; then
    [ -f "$ACTION_LOCK_DIR/pid" ] && owner="$(cat "$ACTION_LOCK_DIR/pid" 2>/dev/null)"
    modified=$(stat -f %m "$ACTION_LOCK_DIR" 2>/dev/null || echo 0)
    age=$(( $(date +%s) - modified ))
    if [ -n "$owner" ] && [ "$age" -lt 600 ] && kill -0 "$owner" 2>/dev/null; then
      echo "MacRig is busy: $(cat "$ACTION_LOCK_DIR/label" 2>/dev/null || echo another action)" >&2
      return 75
    fi
    rm -f "$ACTION_LOCK_DIR/pid" "$ACTION_LOCK_DIR/label"
    rmdir "$ACTION_LOCK_DIR" 2>/dev/null || true
    mkdir "$ACTION_LOCK_DIR" 2>/dev/null || { echo "MacRig action lock is unavailable." >&2; return 75; }
  fi

  printf '%s\n' "$$" > "$ACTION_LOCK_DIR/pid"
  printf '%s\n' "$label" > "$ACTION_LOCK_DIR/label"
  export MACRIG_LOCK_HELD=1 MACRIG_LOCK_OWNER="$$"
  trap release_action_lock EXIT
  trap 'release_action_lock; exit 130' INT
  trap 'release_action_lock; exit 143' TERM
}
