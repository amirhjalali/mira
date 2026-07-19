#!/bin/bash
# mira config - copy this file to config.sh and edit it for your Macs.
# config.sh is gitignored and should be the only file with private machine values.

# This file is local to the viewer Mac. Target order is also the order in which
# Jump sessions open: put the peer laptop first and the Mac mini second.
VIEWER_NAME="MacBook Pro"
VIEWER_ID="macbook-pro"  # stable, unique ID used for the shared display-owner lease
PRESERVE_SPACE_ORDER="on" # disable Mission Control's automatic Space rearranging at install

# Jump Desktop connection names. These must EXACTLY match File > Open Recent
# and the resulting session window titles on this viewer.
TARGET_1_NAME="MacBook Air"
TARGET_2_NAME="Mac Mini"

# Reachability and SSH users.
# Tailscale IPs are preferred because they work from anywhere. The .local names
# are the home-LAN fallback when mDNS is available.
# Find Tailscale IPs with `tailscale ip -4` on each remote Mac or in the
# Tailscale admin console. Find .local hostnames in System Settings > General >
# Sharing > Local hostname. Use the short macOS account name for *_USER.
TARGET_1_TS="100.x.y.z"; TARGET_1_LAN="air-hostname.local";  TARGET_1_USER="airuser"
TARGET_2_TS="100.x.y.z"; TARGET_2_LAN="mini-hostname.local"; TARGET_2_USER="miniuser"

# Home LAN IPv4 prefix used by auto quality detection to recognize your local
# network. Keep the trailing dot. For example, 192.168.1. matches 192.168.1.23.
HOME_SUBNET_PREFIX="192.168.1."

# Remote virtual displays (BetterDisplay) - both targets hold one 21:9 screen
# and one 16:10 screen because BetterDisplay filters modes by aspect ratio.
# BDCLI is the BetterDisplay CLI path on each remote Mac. The default is the
# Homebrew-on-Apple-Silicon path; adjust it if you installed BetterDisplay
# elsewhere. The names must match the screens installed by remote/setup-target-ultrawide.sh.
BDCLI="/opt/homebrew/bin/betterdisplaycli"
VSCREEN_ULTRAWIDE_NAME="Ultrawide"
VSCREEN_LAPTOP_NAME="Laptop"
RES_ULTRAWIDE="3440x1440"   # when the MacBook Pro is docked (external ultrawide present)
# Viewer-specific clean 16:10 remote canvas:
#   16-inch MacBook Pro: 1728x1080
#   15-inch MacBook Air: 1440x900
RES_LAPTOP="1728x1080"
DOCK_MARKER="3440"          # substring in system_profiler output that means "docked"

# New viewers start released. "Take Display Control Here" claims a shared lease
# on target 2 (the Mac mini) and safely hands control away from the peer viewer.
REMOTE_DISPLAY_SYNC_DEFAULT="off"

# Derived paths (do not edit)
MACRIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="$MACRIG_DIR/state"
LOG_DIR="$MACRIG_DIR/logs"
PROFILE_STATE="$STATE_DIR/profile"    # last applied profile: high|medium|low
MODE_STATE="$STATE_DIR/mode"          # auto|manual (written by MacRig app)
mkdir -p "$STATE_DIR" "$LOG_DIR"
