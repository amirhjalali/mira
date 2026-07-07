# MacRig

## What It Is

MacRig is a macOS menu-bar controller for driving two remote Macs through Jump Desktop. It provides one-click open-all for saved Jump sessions, network-adaptive quality profiles (`high`, `medium`, `low`, `auto`), dock-aware remote resolution switching through BetterDisplay, and automatic re-tuning when the viewer Mac's network changes.

## Requirements

- macOS 13 or later.
- On the viewer Mac: Jump Desktop, tested with 9.1.22, with saved connections for both remote Macs.
- On each remote Mac: Jump Desktop Connect, BetterDisplay with its CLI, and SSH key authentication from the viewer Mac.
- Optional: Tailscale, recommended for away-from-home access.

## Install

```bash
cp config.example.sh config.sh
$EDITOR config.sh
bash install.sh
```

After first launch, approve the macOS Accessibility prompt for MacRig. MacRig needs Accessibility permission because it drives Jump Desktop's menus.

## Menu Bar Cheat-Sheet

- `○`: no profile has been recorded yet.
- `●H`: high profile is active.
- `●M`: medium profile is active.
- `●L`: low profile is active.
- `●!`: the last script action failed; a later successful action clears it.

`Auto` lets MacRig re-tune quality after network changes. `High`, `Medium`, and `Low` pin a manual profile until `Auto` is selected again.

## How It Works

The menu-bar app shells out to the scripts in `bin/`. It uses macOS Accessibility automation to drive Jump Desktop's File, Window, and Remote menus because `jump://` URLs are unreliable for saved Fluid connections in the tested Jump Desktop build. Network changes are monitored with `NWPathMonitor` and applied after a 12-second debounce.

## Caveats And Limitations

- Accessibility menu strings assume Jump Desktop 9.1.22 with the English UI.
- The current app model is exactly two machines, named mini and air in `config.sh`.
- The app is unsigned; on first launch, use right-click > Open if macOS blocks it.
- macOS Accessibility permission is required.
- BetterDisplay virtual-display recipes are opinionated and may need tuning for your displays.

## Uninstall

```bash
launchctl unload "$HOME/Library/LaunchAgents/com.amir.macrig.plist" 2>/dev/null || true
launchctl unload "$HOME/Library/LaunchAgents/com.amir.dockwatch.plist" 2>/dev/null || true
rm -rf /Applications/MacRig.app
rm -f "$HOME/Library/LaunchAgents/com.amir.macrig.plist"
rm -f "$HOME/Library/LaunchAgents/com.amir.dockwatch.plist"
```
