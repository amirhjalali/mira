#!/bin/bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/mira-config.sh"
acquire_action_lock "Sync Remote Displays" || exit $?

CHECK_ONLY="${1:-}"

if ! display_sync_enabled; then
  echo "remote display sync is off on this viewer"
  exit 0
fi

if ! display_control_owned; then
  echo "This viewer does not own the shared display lease."
  exit 1
fi

if [ "$(cat "$PROFILE_STATE" 2>/dev/null)" = "low" ]; then
  mode="laptop"
elif system_profiler SPDisplaysDataType 2>/dev/null | grep -q "$DOCK_MARKER"; then
  mode="ultrawide"
else
  mode="laptop"
fi

echo "syncing both targets to this viewer's $mode shape"
if [ "$CHECK_ONLY" = "--check" ]; then
  case "$mode" in
    ultrawide) expected_resolution="$RES_ULTRAWIDE" ;;
    laptop) expected_resolution="$RES_LAPTOP" ;;
  esac
  drift=0
  for i in 0 1; do
    if ! target_display_matches "$i" "$mode" "$expected_resolution" >/dev/null 2>&1; then
      echo "${TARGET_NAMES[$i]} display drift detected"
      drift=1
    fi
  done
  if [ "$drift" -eq 0 ]; then
    echo "remote display shape already correct"
    exit 0
  fi
fi

"$MACRIG_DIR/bin/mac-resolution-toggle.sh" "$mode"
