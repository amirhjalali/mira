#!/bin/bash
# MIRA 2 test harness: compile the binary and run its pure-logic selftest.
set -e
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$REPO_ROOT/build.noindex/mira2}"
mkdir -p "$(dirname "$OUT")"
swiftc -O "$REPO_ROOT/app/MIRA2.swift" -o "$OUT"
MACRIG_DIR="$REPO_ROOT" "$OUT" selftest
