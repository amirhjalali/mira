#!/bin/bash
# uninstall-remote-tools.sh
# Remote helper: the remote cleanup step runs ON the remote Mac, not the viewer
# machine. This legacy script also invokes the same payload locally before SSH.
#
# Cleanly removes NoMachine + Chrome Remote Desktop from this Mac and a remote
# Mac. Keeps Jump Desktop + Screen Sharing.
#
#   bash remote/uninstall-remote-tools.sh
#
# You'll be asked for your login password twice: once for this Mac, once for the
# remote Mac over SSH. Your password is never stored.
set -u
P="$HOME/home/.uninstall-payload.sh"
REMOTE_USER="EDIT_ME_REMOTE_USER"
REMOTE_HOST="100.x.y.z"
if [ "$REMOTE_USER" = "EDIT_ME_REMOTE_USER" ] || [ "$REMOTE_HOST" = "100.x.y.z" ]; then
  echo "Edit REMOTE_USER and REMOTE_HOST at the top of this script first." >&2
  exit 1
fi
REMOTE="$REMOTE_USER@$REMOTE_HOST"   # Tailscale IP or reachable hostname

echo "################ THIS MacBook Pro ################"
sudo bash "$P"

echo
echo "################ Remote Mac ################"
if scp -q -o StrictHostKeyChecking=accept-new "$P" "$REMOTE:/tmp/.up.sh"; then
  ssh -t -o StrictHostKeyChecking=accept-new "$REMOTE" "sudo bash /tmp/.up.sh; rm -f /tmp/.up.sh"
else
  echo "  ⚠ couldn't reach the remote Mac — re-run when it's online."
fi

echo
echo "✅ Done. NoMachine + Chrome Remote Desktop removed from this Mac and the remote Mac."
echo "   Jump + Screen Sharing untouched."
echo "   Any leftover menu-bar icon clears on next reboot (reboot not required)."
