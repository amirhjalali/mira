#!/bin/bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/mira-config.sh"
acquire_action_lock "Take Display Control" || exit $?

NO_SYNC="${1:-}"
lease_command="mkdir -p \"\$HOME/$REMOTE_CONTROL_DIR\" && printf '%s\\n' '$VIEWER_ID' > \"\$HOME/$REMOTE_CONTROL_DIR/display-owner\""

echo "claiming remote displays for $VIEWER_NAME ($VIEWER_ID)"
if ! target_ssh 1 "$lease_command" >/dev/null 2>&1; then
  echo "✗ Could not write the display-owner lease on ${TARGET_NAMES[1]}." >&2
  echo "  Display control remains unchanged." >&2
  exit 1
fi

printf 'on\n' > "$DISPLAY_SYNC_STATE"
printf '%s\n' "$VIEWER_ID" > "$DISPLAY_OWNER_CACHE"

# The lease is authoritative. Turning off the peer's local switch as well keeps
# its menu accurate and avoids unnecessary lease checks when it receives events.
# shellcheck disable=SC2016 # $HOME must expand on the peer Mac
peer_disable='mkdir -p "$HOME/Library/Application Support/MacRig" && printf "off\n" > "$HOME/Library/Application Support/MacRig/display-sync"'
if target_ssh 0 "$peer_disable" >/dev/null 2>&1; then
  echo "✓ ${TARGET_NAMES[0]} display control released"
else
  echo "- ${TARGET_NAMES[0]} unavailable; shared lease still prevents conflicts"
fi

echo "✓ This Mac now owns remote display control"
[ "$NO_SYNC" = "--no-sync" ] || "$MACRIG_DIR/bin/sync-display-now.sh"
