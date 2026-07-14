#!/bin/bash
# Backward-compatible name; new setup instructions use setup-target-ultrawide.sh.
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/setup-target-ultrawide.sh" "$@"
