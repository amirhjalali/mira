#!/bin/bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/macrig-config.sh"
acquire_action_lock "Release Display Control" || exit $?

printf 'off\n' > "$DISPLAY_SYNC_STATE"
rm -f "$DISPLAY_OWNER_CACHE"

release_command="owner=\$(cat \"\$HOME/$REMOTE_CONTROL_DIR/display-owner\" 2>/dev/null || true); if [ \"\$owner\" = '$VIEWER_ID' ]; then rm -f \"\$HOME/$REMOTE_CONTROL_DIR/display-owner\"; fi"
if target_ssh 1 "$release_command" >/dev/null 2>&1; then
  echo "✓ Remote display control released"
else
  echo "- Local control released; ${TARGET_NAMES[1]} was unavailable to clear the lease" >&2
fi
