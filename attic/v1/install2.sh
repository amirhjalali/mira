#!/bin/bash
# MIRA 2 installer. Builds, selftests, signs (when the "MIRA Signing" identity
# exists), and stages the daemon LaunchAgent WITHOUT loading it.
# Activation is an explicit second step:  bash install2.sh --activate
set -e
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACRIG_DIR="$PWD"

echo "1) Build + selftest…"
bash tests/run2.sh build.noindex/mira2

echo "2) Bundle MIRA2.app…"
APP=build.noindex/MIRA2.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp build.noindex/mira2 "$APP/Contents/MacOS/MIRA2"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.amir.mira2</string>
  <key>CFBundleName</key><string>MIRA 2</string>
  <key>CFBundleExecutable</key><string>MIRA2</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleShortVersionString</key><string>2.0</string>
</dict></plist>
PLIST
if security find-identity -p codesigning 2>/dev/null | grep -q "MIRA Signing"; then
  echo "   signing with MIRA Signing identity"
  codesign --force --sign "MIRA Signing" "$APP"
else
  codesign --force --sign - "$APP"
fi
rm -rf /Applications/MIRA2.app
cp -R "$APP" /Applications/

echo "3) Staging daemon LaunchAgent (NOT loaded)…"
SED_DIR=$(printf '%s' "$MACRIG_DIR" | sed 's/[&|\\]/\\&/g')
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$HOME/Library/LaunchAgents/com.amir.mira2.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.amir.mira2</string>
  <key>ProgramArguments</key>
  <array><string>/Applications/MIRA2.app/Contents/MacOS/MIRA2</string><string>--daemon</string></array>
  <key>EnvironmentVariables</key>
  <dict><key>MACRIG_DIR</key><string>$MACRIG_DIR</string></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
</dict></plist>
PLIST

if [ "${1:-}" = "--activate" ]; then
  echo "4) ACTIVATING: stopping v1 agents, starting the v2 daemon…"
  launchctl unload "$HOME/Library/LaunchAgents/com.amir.dockwatch.plist" 2>/dev/null || true
  launchctl unload "$HOME/Library/LaunchAgents/com.amir.mira-display.plist" 2>/dev/null || true
  launchctl unload "$HOME/Library/LaunchAgents/com.amir.mira2.plist" 2>/dev/null || true
  launchctl load "$HOME/Library/LaunchAgents/com.amir.mira2.plist"
  echo "   v2 daemon active. v1 menu app (com.amir.mira) left running for its UI."
else
  echo
  echo "Staged only. When ready to cut this machine over:  bash install2.sh --activate"
fi
echo "Done."
