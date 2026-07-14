#!/bin/bash
set -e

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

make_fixture() {
  local root="$1" style="$2"
  mkdir -p "$root/lib" "$root/home"
  cp "$REPO_ROOT/lib/macrig-config.sh" "$root/lib/"

  if [ "$style" = "generic" ]; then
    cat > "$root/config.sh" <<'CONFIG'
VIEWER_NAME="MacBook Pro"
VIEWER_ID="pro"
TARGET_1_NAME="MacBook Air"; TARGET_1_TS="100.0.0.1"; TARGET_1_LAN="air.local"; TARGET_1_USER="air"
TARGET_2_NAME="Mac Mini"; TARGET_2_TS="100.0.0.2"; TARGET_2_LAN="mini.local"; TARGET_2_USER="mini"
REMOTE_DISPLAY_SYNC_DEFAULT="off"
BDCLI="/opt/homebrew/bin/betterdisplaycli"
RES_ULTRAWIDE="3440x1440"
RES_LAPTOP="1728x1080"
CONFIG
  else
    cat > "$root/config.sh" <<'CONFIG'
AIR_NAME="MacBook Air"; AIR_TS="100.0.0.1"; AIR_LAN="air.local"; AIR_USER="air"
MINI_NAME="Mac Mini"; MINI_TS="100.0.0.2"; MINI_LAN="mini.local"; MINI_USER="mini"
BDCLI="/opt/homebrew/bin/betterdisplaycli"
RES_ULTRAWIDE="3440x1440"
RES_LAPTOP="1728x1080"
CONFIG
  fi
}

GENERIC="$TMP_ROOT/generic"
make_fixture "$GENERIC" generic
HOME="$GENERIC/home" bash -c '
  set -e
  source "$1/lib/macrig-config.sh"
  [ "$TARGET_1_NAME" = "MacBook Air" ]
  [ "$TARGET_2_NAME" = "Mac Mini" ]
  [ "$VSCREEN_ULTRAWIDE_NAME" = "Ultrawide" ]
  [ "$VSCREEN_LAPTOP_NAME" = "Laptop" ]
  ! display_sync_enabled
  acquire_action_lock "test action"
  [ -d "$ACTION_LOCK_DIR" ]
  target_ssh() { printf "%s\n" "$VIEWER_ID"; }
  printf "on\n" > "$DISPLAY_SYNC_STATE"
  display_control_owned
  release_action_lock
  [ ! -d "$ACTION_LOCK_DIR" ]
' _ "$GENERIC"

LEGACY="$TMP_ROOT/legacy"
make_fixture "$LEGACY" legacy
HOME="$LEGACY/home" bash -c '
  set -e
  source "$1/lib/macrig-config.sh"
  [ "$TARGET_1_NAME" = "MacBook Air" ]
  [ "$TARGET_2_NAME" = "Mac Mini" ]
  [ "$VSCREEN_ULTRAWIDE_NAME" = "Ultrawide" ]
  [ "$VSCREEN_LAPTOP_NAME" = "Laptop" ]
' _ "$LEGACY"

echo "MacRig tests: OK"
