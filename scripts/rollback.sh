#!/bin/bash
# Run on the affected Mac: bash rollback.sh <build> (default: this release).
set -euo pipefail
build=${1:-20260916.1}
case "$build" in *[!0-9.]*) echo 'Invalid build' >&2; exit 2;; esac
id=$(cat "$HOME/.config/mira/machine-id")
backup="$HOME/Library/Application Support/MIRA/releases/$build-before"
[ -x "$backup/MIRA.app/Contents/MacOS/MIRA" ] || { echo "No rollback bundle: $backup" >&2; exit 1; }
if [ "$id" = pro ]; then app=/Applications/MIRA.app; else app="$HOME/Applications/MIRA.app"; fi
uid=$(id -u)
launchctl bootout "gui/$uid/com.amir.mira" 2>/dev/null || true
launchctl bootout "gui/$uid/com.amir.mira.menu" 2>/dev/null || true
pkill -f '^.*MIRA.app/Contents/MacOS/MIRA$' 2>/dev/null || true
if [ -d "$app" ]; then mv "$app" "$backup/rejected-$(date +%s).app"; fi
cp -R "$backup/MIRA.app" "$app"
plist="$HOME/Library/LaunchAgents/com.amir.mira.plist"
if [ -f "$backup/daemon.plist" ]; then cp "$backup/daemon.plist" "$plist"; fi
launchctl bootstrap "gui/$uid" "$plist"
launchctl kickstart "gui/$uid/com.amir.mira"
# The menu LaunchAgent added in 2.2 also starts the previous app executable.
menu="$HOME/Library/LaunchAgents/com.amir.mira.menu.plist"
if [ -f "$menu" ]; then launchctl bootstrap "gui/$uid" "$menu"; fi
printf 'Rolled back %s to %s/MIRA.app\n' "$id" "$backup"
