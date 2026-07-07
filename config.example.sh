#!/bin/bash
# macrig config - copy this file to config.sh and edit it for your Macs.
# config.sh is gitignored and should be the only file with private machine values.

# Jump Desktop connection names.
# These must EXACTLY match the saved connection names in Jump Desktop's
# File > Open Recent menu and the resulting session window titles.
MINI_NAME="Mac Mini"
AIR_NAME="MacBook Air"

# Reachability and SSH users.
# Tailscale IPs are preferred because they work from anywhere. The .local names
# are the home-LAN fallback when mDNS is available.
# Find Tailscale IPs with `tailscale ip -4` on each remote Mac or in the
# Tailscale admin console. Find .local hostnames in System Settings > General >
# Sharing > Local hostname. Use the short macOS account name for *_USER.
MINI_TS="100.x.y.z";  MINI_LAN="mini-hostname.local";  MINI_USER="miniuser"
AIR_TS="100.x.y.z";   AIR_LAN="air-hostname.local";   AIR_USER="airuser"

# Home LAN IPv4 prefix used by auto quality detection to recognize your local
# network. Keep the trailing dot. For example, 192.168.1. matches 192.168.1.23.
HOME_SUBNET_PREFIX="192.168.1."

# Remote virtual display (BetterDisplay) - both Macs hold one virtual screen.
# BDCLI is the BetterDisplay CLI path on each remote Mac. The default is the
# Homebrew-on-Apple-Silicon path; adjust it if you installed BetterDisplay
# elsewhere. VSCREEN_NAME must match the virtual display name managed there.
BDCLI="/opt/homebrew/bin/betterdisplaycli"
VSCREEN_NAME="Ultrawide"
RES_ULTRAWIDE="3440x1440"   # when the MacBook Pro is docked (external ultrawide present)
RES_LAPTOP="1728x1080"      # when undocked (true 16:10, exact 2x on the 16" panel)
DOCK_MARKER="3440"          # substring in system_profiler output that means "docked"

# Derived paths (do not edit)
MACRIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="$MACRIG_DIR/state"
LOG_DIR="$MACRIG_DIR/logs"
PROFILE_STATE="$STATE_DIR/profile"    # last applied profile: high|medium|low
MODE_STATE="$STATE_DIR/mode"          # auto|manual (written by MacRig app)
mkdir -p "$STATE_DIR" "$LOG_DIR"
