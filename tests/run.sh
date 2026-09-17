#!/bin/bash
# MIRA 2 test harness: compile the binary and run its pure-logic selftest.
set -e
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$REPO_ROOT/build.noindex/mira}"
mkdir -p "$(dirname "$OUT")"
cat "$REPO_ROOT/app/Reliability.swift" "$REPO_ROOT/app/MIRA.swift" > "$OUT.sources.swift"
swiftc -O -import-objc-header "$REPO_ROOT/app/shim.h" "$OUT.sources.swift" -o "$OUT"
MACRIG_DIR="$REPO_ROOT" "$OUT" selftest

TEST_STATE=$(mktemp -d /tmp/mira-control-test.XXXXXX)
trap 'rm -rf "$TEST_STATE"' EXIT
MIRA_STATE_DIR="$TEST_STATE" MACRIG_DIR="$REPO_ROOT" "$OUT" ipc-selftest
"$OUT" help >/dev/null
# The driver's canvas now depends on this subprocess answering. A silent
# regression here degrades to "whatever this process last believed", which is
# exactly the 2026-09-16 failure, so assert the contract itself.
if ! "$OUT" inspect-screens | grep -qE '^\{"widths":\[[0-9,]*\]\}$'; then
  echo "FAIL: inspect-screens did not report a widths array" >&2
  exit 1
fi
if "$OUT" --not-a-mira-command >/dev/null 2>&1; then
  echo "FAIL: unknown CLI command was accepted" >&2
  exit 1
fi
