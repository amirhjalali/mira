# MIRA

## What It Is

MIRA (Multi-Instance Rig Activation, formerly MacRig) is a macOS menu-bar controller for driving two remote Macs through Jump Desktop. Either laptop can be the viewer: for example, the MacBook Pro can target the MacBook Air and Mac mini, while the Air can target the Pro and mini. It provides one-click open-all for saved Jump sessions, network-adaptive quality profiles (`high`, `medium`, `low`, `auto`), dock-aware remote resolution switching through BetterDisplay, and automatic re-tuning when the viewer Mac's network changes.

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

After first launch, approve the macOS Accessibility prompt for MIRA. MIRA needs Accessibility permission because it drives Jump Desktop's menus. Run `MIRA Doctor` from the menu to verify the complete installation.

The installer records the checkout's absolute path in both LaunchAgents, so the repository does not need to live in a particular directory.
It also disables Mission Control's automatic Space rearranging when `PRESERVE_SPACE_ORDER="on"`, keeping the peer laptop second and Mac mini third after they are opened in that order.

## Install On Both Laptops

Each viewer has its own untracked `config.sh`. Configure the target pair from that viewer's perspective:

| Viewer | Target 1 | Target 2 |
| --- | --- | --- |
| MacBook Pro | MacBook Air | Mac mini |
| MacBook Air | MacBook Pro | Mac mini |

This order is intentional and required: target 1 is the peer laptop, while target 2 is the Mac mini that coordinates display ownership. The local desktop remains first, the peer laptop opens second, and the mini opens third. On the Air, Jump Desktop must have saved connections for the Pro and mini, and the names in `TARGET_1_NAME` and `TARGET_2_NAME` must match Jump's File > Open Recent menu. The Air also needs SSH key access to both targets. Because the Pro is now a target, it needs Jump Desktop Connect and the same BetterDisplay virtual-screen setup as the other remote Macs.

Prepare or upgrade each target's virtual screen with:

```bash
bash remote/setup-target-ultrawide.sh <remote-user> <remote-host>
```

The setup installs two fixed-aspect virtual screens: `Ultrawide` for 3440×1440 and `Laptop` for both 16:10 laptop canvases. MIRA connects only the screen appropriate to the active viewer.

`RES_LAPTOP` belongs to the viewer, not the target. Use `1728x1080` on the 16-inch MacBook Pro and `1440x900` on the 15-inch MacBook Air. These are clean 16:10 remote canvases rather than the panels' physical native resolutions. The remote recipe installs both so either viewer can take control without rebuilding displays.

The tracked configuration uses neutral `TARGET_1_*` and `TARGET_2_*` fields. Existing configs using `MINI_*` and `AIR_*` continue to work on the Pro.

## Menu Bar Cheat-Sheet

- `○`: no profile has been recorded yet.
- `●H`: high profile is active.
- `●M`: medium profile is active.
- `●L`: low profile is active.
- `●!`: the last script action failed; a later successful action clears it.

`Start Workspace` is the primary action. It runs preflight diagnostics, takes remote display control, opens the peer laptop before the Mac mini, and applies the network-appropriate profile.

`Auto` lets MIRA re-tune quality after network changes. `High`, `Medium`, and `Low` pin a manual profile until `Auto` is selected again.

`Take Display Control Here` writes a shared owner lease on the Mac mini and releases the peer viewer. `Release Display Control` stops this viewer from changing target resolutions. New installations start released, so two viewers cannot silently become owners just because they launched.

`Run MIRA Doctor` checks Accessibility, Jump connection names, LaunchAgents, SSH, BetterDisplay, the two-screen recipe, and display ownership. Its report is appended to the normal MIRA log.

## How It Works

The menu-bar app shells out to the scripts in `bin/`. It uses macOS Accessibility automation to drive Jump Desktop's File, Window, and Remote menus because `jump://` URLs are unreliable for saved Fluid connections in the tested Jump Desktop build. Network changes are monitored with `NWPathMonitor` and applied after a 12-second debounce. App, network, and dock actions share an atomic lock, while dock failures retry with bounded backoff.

## Caveats And Limitations

- Accessibility menu strings assume Jump Desktop 9.1.22 with the English UI.
- The current app model is exactly two configurable target machines per viewer.
- Target 2 must be the shared Mac mini because it stores the display-owner lease.
- The app is unsigned; on first launch, use right-click > Open if macOS blocks it.
- macOS Accessibility permission is required.
- BetterDisplay virtual-display recipes are opinionated and may need tuning for your displays.

## Uninstall

```bash
launchctl unload "$HOME/Library/LaunchAgents/com.amir.mira.plist" 2>/dev/null || true
launchctl unload "$HOME/Library/LaunchAgents/com.amir.dockwatch.plist" 2>/dev/null || true
rm -rf /Applications/MIRA.app
rm -f "$HOME/Library/LaunchAgents/com.amir.mira.plist"
rm -f "$HOME/Library/LaunchAgents/com.amir.dockwatch.plist"
```
