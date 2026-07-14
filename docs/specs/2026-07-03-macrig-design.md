# MacRig Design

## Goal

MacRig turns the loose dual-Mac remote-desktop scripts into a small repo with one visible controller: a menu bar app that opens both Jump Desktop sessions, applies network-appropriate quality, and keeps remote resolutions aligned with the MacBook Pro's docked or undocked display shape.

## Why Accessibility Automation

Jump Desktop build 9.1.22 no longer accepts the previous `jump://` deep links for these saved sessions. In this build, the URL path is treated like an ad-hoc RDP hostname, so it fails before reaching the saved Fluid connection. The reliable path is the same one used manually: File > Open Recent for opening sessions and the Remote menu for bandwidth, framerate, and quality caps. Those menus require macOS Accessibility permission.

## Repo Layout

- `config.example.sh`: public, viewer-local template for two target names, users, hostnames, Tailscale IPs, BetterDisplay path, and target resolutions.
- `config.sh`: private gitignored config copied from `config.example.sh`.
- `lib/macrig-config.sh`: compatibility loader that exposes neutral target arrays and accepts both current `TARGET_1_*`/`TARGET_2_*` fields and legacy `MINI_*`/`AIR_*` fields.
- `bin/`: local scripts that open sessions, switch remote resolution, apply Jump quality, and react to dock state.
- `menubar/`: `MacRig.swift` and its LSUIElement app plist.
- `watchers/`: display-change watcher kept as a separate LaunchAgent.
- `agents/`: LaunchAgent templates rendered by `install.sh`.
- `remote/`: verbatim helper scripts that run on the other Macs.
- `state/`: runtime profile and mode files.
- `logs/`: app and watcher logs.

## Profiles

| Profile | Resolution behavior | Bandwidth | FPS | Quality | Auto selection |
| --- | --- | --- | --- | --- | --- |
| High | Dock-aware full shape | Auto | 60 fps | Highest | Home LAN average RTT under 8 ms |
| Medium | Dock-aware full shape | 10 mbps | 30 fps | High | Average RTT under 60 ms and jitter under 30 ms |
| Low | Laptop shape | 4 mbps | 15 fps | Low | Anything worse, including poor cellular or hotel WiFi |

`jump-quality.sh auto --if-changed` exits without touching Jump menus when the detected profile is already recorded in `state/profile`.

## MacRig App Behavior

MacRig is an AppKit LSUIElement app with no windows and no Dock icon. Its status item reads `state/profile`: `●H` is green, `●M` is orange, `●L` is red, and `○` is gray when no profile exists. If a script exits non-zero, the icon becomes `●!` in red until a later script action succeeds.

The menu is rebuilt on open. It shows the current profile and mode, then checks Jump session presence with a short System Events AppleScript using both configured target names. If MacRig does not have Accessibility permission, that line becomes an enabled item that opens the Accessibility privacy pane.

Auto/manual mode is pinned through `state/mode`. Auto writes `auto` and runs `jump-quality.sh auto`. High, Medium, and Low write `manual` and run the matching profile. `Start Workspace` runs Doctor preflight, claims display ownership, opens targets in order, and applies auto quality. While any script is running, the status item shows `◐` and menu actions are disabled.

The old `net-watch.swift` logic now lives in `MacRig.swift`. `NWPathMonitor` keys changes by sorted interface names and path status. Repeated keys are ignored. A satisfied real change schedules a 12-second debounce, cancels any pending older debounce, then runs `jump-quality.sh auto --if-changed` only if mode is auto or missing. Manual mode skips the network tune and logs the reason.

## What Stays Outside

`dock-watch` remains a separate compiled LaunchAgent because display reconfiguration is independent of Jump's Accessibility-driven menus. It listens to CoreGraphics display events and calls `bin/dock-apply.sh`, which performs the resolution switch and local WiFi on/off behavior. It records a display mode only after the script succeeds and retries failures at 5, 15, and 30 seconds. All mutating scripts share an atomic action lock under `~/Library/Application Support/MacRig`.

Sleep can hide a dock transition from CoreGraphics, so dock-watch also forces a fresh reconciliation after system wake. Network recovery provides a second safety net: an automatic quality check always reconciles the remote display shape even when the bandwidth/quality profile itself has not changed. A lightweight five-minute check verifies the desired screen, exact resolution, and disconnected counterpart on both targets, correcting only when state has drifted. The remote setter repeats that same verification after its changes settle, and Doctor reports active-state drift instead of merely checking that the display recipe exists.

## Interchangeable Viewers

The target pair belongs to the local viewer's private config, rather than being fixed to mini and Air. The peer laptop is always target 1 and the Mac mini is target 2, producing the intended Spaces order: local desktop, remote laptop, then Mac mini. Jump quality is local to each viewer, but BetterDisplay resolution is global state on each target.

Display handoff uses two layers. A local switch under `~/Library/Application Support/MacRig` lets an inactive viewer opt out cheaply. The authoritative `display-owner` lease lives on target 2, the shared Mac mini. Every resolution action verifies the lease; taking control overwrites it and also disables the peer's local switch best-effort. New viewers default to released.

`macrig-doctor.sh` verifies the viewer and both targets without changing their display state. Laptop shape is viewer-specific: the 16-inch Pro uses a 1728x1080 clean 16:10 canvas and the 15-inch Air uses 1440x900. BetterDisplay filters custom modes by virtual-screen aspect ratio, so each target holds a 21:9 `Ultrawide` screen and a 16:10 `Laptop` screen. Runtime switching connects and verifies the desired screen before disconnecting the other; ownership can move without rebuilding displays.

MacRig and dock-watch obtain the checkout root from the `MACRIG_DIR` LaunchAgent environment variable. `install.sh` renders the current absolute checkout path into each agent, removing the earlier `~/home/macrig` deployment assumption.

## Install And Cutover

`install.sh` builds `MacRig.app`, builds `dock-watch`, copies the app into `/Applications`, renders both LaunchAgent templates with the current checkout path into `~/Library/LaunchAgents`, then cleanly reloads the two labels. The MacRig LaunchAgent starts the app; the bundle also prohibits duplicate instances.

After first launch, macOS may ask for Accessibility permission. Grant it to MacRig so it can drive Jump's File, Window, and Remote menus. Any older ad-hoc scripts outside this repo become legacy after cutover and can be removed once the repo-based install is confirmed.

## Open-Source Later

The repo can be made public because user-specific values are isolated in gitignored `config.sh`; the tracked `config.example.sh` documents placeholders for new adopters. The remaining portability caveat is that the Accessibility menu strings are specific to Jump Desktop 9.1.22 in English; a different build or language may need adjusted menu item names.
