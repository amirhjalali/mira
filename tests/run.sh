#!/bin/bash
set -e

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

make_fixture() {
  local root="$1" style="$2"
  mkdir -p "$root/lib" "$root/home"
  cp "$REPO_ROOT/lib/mira-config.sh" "$root/lib/"

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
  source "$1/lib/mira-config.sh"
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
  target_ssh() { printf "%s\n" "$2" > "$HOME/target-command"; }
  target_display_matches 0 laptop 1728x1080
  grep -q -- "--check" "$HOME/target-command"
  grep -q -- "1728x1080" "$HOME/target-command"
' _ "$GENERIC"

LEGACY="$TMP_ROOT/legacy"
make_fixture "$LEGACY" legacy
HOME="$LEGACY/home" bash -c '
  set -e
  source "$1/lib/mira-config.sh"
  [ "$TARGET_1_NAME" = "MacBook Air" ]
  [ "$TARGET_2_NAME" = "Mac Mini" ]
  [ "$VSCREEN_ULTRAWIDE_NAME" = "Ultrawide" ]
  [ "$VSCREEN_LAPTOP_NAME" = "Laptop" ]
' _ "$LEGACY"

FAKE_BDCLI="$TMP_ROOT/fake-betterdisplaycli"
cat > "$FAKE_BDCLI" <<'FAKE'
#!/bin/bash
case "$*" in
  # A connected screen answers once per matching entity, like real BetterDisplay.
  "get -name=Laptop -connected") echo on,on ;;
  "get -name=Laptop -resolution") echo 1728x1080 ;;
  "get -name=Ultrawide -connected") echo off ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$FAKE_BDCLI"

MACRIG_BDCLI="$FAKE_BDCLI" bash "$REPO_ROOT/remote/mira-set-display.sh" \
  --check laptop 1728x1080 >/dev/null
if MACRIG_BDCLI="$FAKE_BDCLI" bash "$REPO_ROOT/remote/mira-set-display.sh" \
    --check laptop 1470x956 >/dev/null 2>&1; then
  echo "remote display drift test unexpectedly passed" >&2
  exit 1
fi

# console_is_active from ensure-ultrawide-generic.sh: a physically present
# user keeps display ownership; headless or remote-only targets do not.
CONSOLE_FN="$(sed -n '/^console_is_active()/,/^}/p' "$REPO_ROOT/remote/ensure-ultrawide-generic.sh")"
[ -n "$CONSOLE_FN" ]

SHIMS="$TMP_ROOT/shims"
mkdir -p "$SHIMS"
cat > "$SHIMS/stat" <<'SHIM'
#!/bin/bash
[ "$*" = "-f %Su /dev/console" ] && { echo "$FAKE_CONSOLE_USER"; exit 0; }
exec /usr/bin/stat "$@"
SHIM
cat > "$SHIMS/system_profiler" <<'SHIM'
#!/bin/bash
printf '%s\n' "$FAKE_DISPLAY_BLOCK"
SHIM
chmod +x "$SHIMS/stat" "$SHIMS/system_profiler"

PHYSICAL_BLOCK='Graphics/Displays:
      Displays:
        Color LCD:
          Main Display: Yes'
VIRTUAL_BLOCK='Graphics/Displays:
      Displays:
        Ultrawide:
          Main Display: Yes'

run_console_check() {
  PATH="$SHIMS:$PATH" FAKE_CONSOLE_USER="$1" FAKE_DISPLAY_BLOCK="$2" \
    bash -c "$CONSOLE_FN"$'\nconsole_is_active'
}

run_console_check someuser "$PHYSICAL_BLOCK"      # user present at a real screen
! run_console_check loginwindow "$PHYSICAL_BLOCK" # nobody logged in
! run_console_check root "$PHYSICAL_BLOCK"        # system session only
! run_console_check someuser "$VIRTUAL_BLOCK"     # only virtual screens attached
! run_console_check someuser ""                   # no displays at all

echo "MIRA tests: OK"
