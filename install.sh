#!/bin/bash
set -e
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACRIG_DIR="$PWD"

if [ ! -f config.sh ]; then
  echo "Missing config.sh. Copy config.example.sh and edit it first." >&2
  exit 1
fi

echo "1) Running tests..."
bash tests/run.sh

source lib/macrig-config.sh
if [ "$PRESERVE_SPACE_ORDER" = "on" ]; then
  defaults write com.apple.dock mru-spaces -bool false
  killall Dock 2>/dev/null || true
fi

echo "2) Building MacRig.app..."
mkdir -p build/MacRig.app/Contents/MacOS
swiftc -O menubar/MacRig.swift -o build/MacRig.app/Contents/MacOS/MacRig
cp menubar/Info.plist build/MacRig.app/Contents/
chmod +x build/MacRig.app/Contents/MacOS/MacRig

echo "3) Building dock-watch..."
swiftc -O watchers/dock-watch.swift -o build/dock-watch
chmod +x build/dock-watch

echo "4) Installing MacRig.app into /Applications..."
rm -rf /Applications/MacRig.app
cp -R build/MacRig.app /Applications/

echo "5) Installing LaunchAgents..."
mkdir -p "$HOME/Library/LaunchAgents"
SED_MACRIG_DIR=$(printf '%s' "$MACRIG_DIR" | sed 's/[&|\\]/\\&/g')
sed "s|__MACRIG_DIR__|$SED_MACRIG_DIR|g" agents/com.amir.dockwatch.plist.tpl > "$HOME/Library/LaunchAgents/com.amir.dockwatch.plist"
sed "s|__MACRIG_DIR__|$SED_MACRIG_DIR|g" agents/com.amir.macrig.plist.tpl > "$HOME/Library/LaunchAgents/com.amir.macrig.plist"

echo "6) (Re)loading LaunchAgents..."
launchctl unload "$HOME/Library/LaunchAgents/com.amir.dockwatch.plist" 2>/dev/null || true
launchctl unload "$HOME/Library/LaunchAgents/com.amir.macrig.plist" 2>/dev/null || true
pkill -x MacRig 2>/dev/null || true
launchctl load "$HOME/Library/LaunchAgents/com.amir.dockwatch.plist"
launchctl load "$HOME/Library/LaunchAgents/com.amir.macrig.plist"

echo
echo "Done — MacRig is linked to this checkout: $MACRIG_DIR"
echo "Mission Control automatic Space rearranging is disabled for stable target order."
echo "MacRig appears in the menu bar as ○ until a profile is applied, then ●H, ●M, or ●L."
echo "macOS will prompt for Accessibility on first use; approve MacRig in System Settings."
