#!/bin/bash
set -e
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "1) Building MacRig.app..."
mkdir -p build/MacRig.app/Contents/MacOS
swiftc -O menubar/MacRig.swift -o build/MacRig.app/Contents/MacOS/MacRig
cp menubar/Info.plist build/MacRig.app/Contents/
chmod +x build/MacRig.app/Contents/MacOS/MacRig

echo "2) Building dock-watch..."
swiftc -O watchers/dock-watch.swift -o build/dock-watch
chmod +x build/dock-watch

echo "3) Installing MacRig.app into /Applications..."
rm -rf /Applications/MacRig.app
cp -R build/MacRig.app /Applications/

echo "4) Installing LaunchAgents..."
mkdir -p "$HOME/Library/LaunchAgents"
sed "s|__HOME__|$HOME|g" agents/com.amir.dockwatch.plist.tpl > "$HOME/Library/LaunchAgents/com.amir.dockwatch.plist"
sed "s|__HOME__|$HOME|g" agents/com.amir.macrig.plist.tpl > "$HOME/Library/LaunchAgents/com.amir.macrig.plist"

echo "5) (Re)loading LaunchAgents..."
launchctl unload "$HOME/Library/LaunchAgents/com.amir.dockwatch.plist" 2>/dev/null || true
launchctl unload "$HOME/Library/LaunchAgents/com.amir.macrig.plist" 2>/dev/null || true
launchctl load "$HOME/Library/LaunchAgents/com.amir.dockwatch.plist"
launchctl load "$HOME/Library/LaunchAgents/com.amir.macrig.plist"

echo "6) Starting MacRig..."
open /Applications/MacRig.app

echo
echo "Done — dock-watch now uses the macrig build path under ~/home/macrig/build."
echo "MacRig appears in the menu bar as ○ until a profile is applied, then ●H, ●M, or ●L."
echo "macOS will prompt for Accessibility on first use; approve MacRig in System Settings."
echo "The old loose scripts in ~/home/ are now legacy. Do not delete them yet; decide later."
