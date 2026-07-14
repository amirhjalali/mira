#!/bin/bash
# Legacy entry point. Prefer:
#   remote/setup-target-ultrawide.sh <remote-user> <remote-host>
set -e
REMOTE_USER="EDIT_ME_REMOTE_USER"
REMOTE_HOST="EDIT_ME_REMOTE_HOST.local"
if [ "$REMOTE_USER" = "EDIT_ME_REMOTE_USER" ] || [ "$REMOTE_HOST" = "EDIT_ME_REMOTE_HOST.local" ]; then
  echo "Edit REMOTE_USER and REMOTE_HOST at the top of this script first." >&2
  exit 1
fi
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/setup-target-ultrawide.sh" \
  "$REMOTE_USER" "$REMOTE_HOST"
