#!/bin/bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/mira-config.sh"
acquire_action_lock "Start Workspace" || exit $?

echo "1/3 Running preflight checks…"
"$MACRIG_DIR/bin/mira-doctor.sh"

echo "2/3 Taking display control on this viewer…"
"$MACRIG_DIR/bin/claim-display-control.sh" --no-sync

echo "3/3 Opening targets in workspace order…"
"$MACRIG_DIR/bin/open-both-macs.sh"
