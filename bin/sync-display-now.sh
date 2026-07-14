#!/bin/bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/macrig-config.sh"
acquire_action_lock "Sync Remote Displays" || exit $?

if ! display_sync_enabled; then
  echo "remote display sync is off on this viewer"
  exit 0
fi

if ! display_control_owned; then
  echo "This viewer does not own the shared display lease."
  exit 1
fi

if system_profiler SPDisplaysDataType 2>/dev/null | grep -q "$DOCK_MARKER"; then
  mode="ultrawide"
else
  mode="laptop"
fi

echo "syncing both targets to this viewer's $mode shape"
"$MACRIG_DIR/bin/mac-resolution-toggle.sh" "$mode"
