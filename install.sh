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

source lib/mira-config.sh
if [ "$PRESERVE_SPACE_ORDER" = "on" ]; then
  # Only restart the Dock when the setting actually changes — a Dock restart
  # flashes every Space, which is hostile to a live remote session.
  if [ "$(defaults read com.apple.dock mru-spaces 2>/dev/null || echo 1)" != "0" ]; then
    defaults write com.apple.dock mru-spaces -bool false
    killall Dock 2>/dev/null || true
  fi
fi

rm -rf build   # pre-rename build dir; Spotlight indexed its app copy

echo "2) Building MIRA.app..."
mkdir -p build.noindex/MIRA.app/Contents/MacOS build.noindex/MIRA.app/Contents/Resources
swiftc -O menubar/MIRA.swift -o build.noindex/MIRA.app/Contents/MacOS/MIRA
cp menubar/Info.plist build.noindex/MIRA.app/Contents/
cp menubar/AppIcon.icns build.noindex/MIRA.app/Contents/Resources/
chmod +x build.noindex/MIRA.app/Contents/MacOS/MIRA

# TCC (Accessibility) identifies MIRA by its code signature. A bare swiftc
# binary is ad-hoc linker-signed, so every rebuild mints a new CDHash and
# macOS silently drops the Accessibility grant (-25211 storms). Signing with a
# stable "MIRA Signing" identity keeps the grant across rebuilds. One-time
# setup per machine: create a self-signed Code Signing certificate named
# "MIRA Signing" in Keychain Access (Certificate Assistant), trust it for
# code signing, and click "Always Allow" on the first signing prompt.
if security find-identity -v -p codesigning 2>/dev/null | grep -q '"MIRA Signing"'; then
  echo "   signing with the MIRA Signing identity (Accessibility grant survives rebuilds)"
  codesign --force --timestamp=none --sign "MIRA Signing" build.noindex/MIRA.app
else
  echo "   no trusted 'MIRA Signing' identity; sealing ad-hoc (re-approve Accessibility after each rebuild)"
  codesign --force --sign - build.noindex/MIRA.app
fi

echo "3) Building dock-watch..."
swiftc -O watchers/dock-watch.swift -o build.noindex/dock-watch
chmod +x build.noindex/dock-watch

echo "4) Installing MIRA.app into /Applications..."
rm -rf /Applications/MacRig.app /Applications/MIRA.app
cp -R build.noindex/MIRA.app /Applications/

echo "5) Installing LaunchAgents..."
mkdir -p "$HOME/Library/LaunchAgents"
SED_MACRIG_DIR=$(printf '%s' "$MACRIG_DIR" | sed 's/[&|\\]/\\&/g')
sed "s|__MACRIG_DIR__|$SED_MACRIG_DIR|g" agents/com.amir.dockwatch.plist.tpl > "$HOME/Library/LaunchAgents/com.amir.dockwatch.plist"
sed "s|__MACRIG_DIR__|$SED_MACRIG_DIR|g" agents/com.amir.mira.plist.tpl > "$HOME/Library/LaunchAgents/com.amir.mira.plist"

echo "6) (Re)loading LaunchAgents..."
launchctl unload "$HOME/Library/LaunchAgents/com.amir.macrig.plist" 2>/dev/null || true   # pre-rename label
rm -f "$HOME/Library/LaunchAgents/com.amir.macrig.plist"
launchctl unload "$HOME/Library/LaunchAgents/com.amir.dockwatch.plist" 2>/dev/null || true
launchctl unload "$HOME/Library/LaunchAgents/com.amir.mira.plist" 2>/dev/null || true
pkill -x MacRig 2>/dev/null || true; pkill -x MIRA 2>/dev/null || true
launchctl load "$HOME/Library/LaunchAgents/com.amir.dockwatch.plist"
launchctl load "$HOME/Library/LaunchAgents/com.amir.mira.plist"

echo
echo "Done — MIRA is linked to this checkout: $MACRIG_DIR"
echo "Mission Control automatic Space rearranging is disabled for stable target order."
echo "MIRA appears in the menu bar as ○ until a profile is applied, then ●H, ●M, or ●L."
echo "macOS will prompt for Accessibility on first use; approve MIRA in System Settings."
echo "NOTE: without a 'MIRA Signing' identity, every reinstall invalidates that grant —"
echo "      re-toggle MIRA in System Settings > Privacy & Security > Accessibility."
