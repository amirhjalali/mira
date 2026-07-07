# MacRig Design

## Goal

MacRig turns the loose dual-Mac remote-desktop scripts into a small repo with one visible controller: a menu bar app that opens both Jump Desktop sessions, applies network-appropriate quality, and keeps remote resolutions aligned with the MacBook Pro's docked or undocked display shape.

## Why Accessibility Automation

Jump Desktop build 9.1.22 no longer accepts the previous `jump://` deep links for these saved sessions. In this build, the URL path is treated like an ad-hoc RDP hostname, so it fails before reaching the saved Fluid connection. The reliable path is the same one used manually: File > Open Recent for opening sessions and the Remote menu for bandwidth, framerate, and quality caps. Those menus require macOS Accessibility permission.

## Repo Layout

- `config.example.sh`: public template for machine names, users, hostnames, Tailscale IPs, BetterDisplay path, and target resolutions.
- `config.sh`: private gitignored config copied from `config.example.sh`.
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

The menu is rebuilt on open. It shows the current profile and mode, then checks Jump session presence with a short System Events AppleScript using connection names read from `config.sh`. If MacRig does not have Accessibility permission, that line becomes an enabled item that opens the Accessibility privacy pane.

Auto/manual mode is pinned through `state/mode`. Auto writes `auto` and runs `jump-quality.sh auto`. High, Medium, and Low write `manual` and run the matching profile. While any script is running, menu actions are disabled and watcher-triggered runs are logged as skipped.

The old `net-watch.swift` logic now lives in `MacRig.swift`. `NWPathMonitor` keys changes by sorted interface names and path status. Repeated keys are ignored. A satisfied real change schedules a 12-second debounce, cancels any pending older debounce, then runs `jump-quality.sh auto --if-changed` only if mode is auto or missing. Manual mode skips the network tune and logs the reason.

## What Stays Outside

`dock-watch` remains a separate compiled LaunchAgent because display reconfiguration is independent of Jump's Accessibility-driven menus. It listens to CoreGraphics display events and calls `bin/dock-apply.sh`, which performs the resolution switch and local WiFi on/off behavior.

## Install And Cutover

`install.sh` builds `MacRig.app`, builds `dock-watch`, copies the app into `/Applications`, renders both LaunchAgent templates into `~/Library/LaunchAgents`, unloads and reloads the two labels, then opens MacRig. The dock-watch label stays the same while its binary path moves from the previous ad-hoc script location into this repo's `build/` directory.

After first launch, macOS may ask for Accessibility permission. Grant it to MacRig so it can drive Jump's File, Window, and Remote menus. Any older ad-hoc scripts outside this repo become legacy after cutover and can be removed once the repo-based install is confirmed.

## Open-Source Later

The repo can be made public because user-specific values are isolated in gitignored `config.sh`; the tracked `config.example.sh` documents placeholders for new adopters. The remaining portability caveat is that the Accessibility menu strings are specific to Jump Desktop 9.1.22 in English; a different build or language may need adjusted menu item names.
