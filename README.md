# MIRA

Mira turns four Macs into one workspace, with one menu-bar icon.

**Drive from Here** chooses the Mac in front of you. Each included passenger gets a desktop sized for that screen. **Use This Mac Locally** returns just that passenger to local use; it does not take over the fleet.

Mira 2.2 uses one daemon to own session and display state. The menu and CLI request changes; passengers acknowledge them and report their actual display geometry. Session generations prevent delayed handoffs or stops from changing a newer session. Lost contact preserves the current picture while reconnecting.

The display backend remains native CoreGraphics. Jump Desktop provides Fluid streaming. The newer Jump-owned display path is not enabled: the active Air 13 viewer is still on Jump 9.1.9 and does not meet the 10.12+ trial prerequisite. See [release notes](docs/RELEASE-2.2.md).

## Everyday use

- **Drive from Here:** explicitly take over the included machines.
- **Machine checkboxes:** include or release one passenger.
- **Use This Mac Locally:** return this passenger to local use until explicitly included or a new driver takes over.
- **Stop Driving:** release only the session owned by this Mac.
- **Reopen Session Windows:** reopen saved Jump sessions whose window is missing. Drive and Reopen both consult Jump's Window menu first, so a window that is already up (on any Space, or mid-reconnect after a sleep) is kept rather than opened a second time.
- **Settings:** local mouse direction, optional local handback, and Retina rendering.

Mouse wheels are reversed only at the input-owning machine. A passenger passes the incoming events unchanged. Trackpad gesture phases remain untouched. Optional lid/keyboard handback is default-off; when enabled it only returns that machine to local use.

Passenger rows show Ready only after a fresh report verifies logical width/height, backing pixels and display topology. Reconnecting and uncertain states are displayed honestly.

## Layout

```
app/MIRA.swift          native displays, menu, CLI entry point, legacy regressions
app/Reliability.swift   daemon control protocol, session fencing, transport, runtime state
app/shim.h             CGVirtualDisplay interface
config/machines.json   fleet membership and initial canvases
tests/run.sh           build, pure/event/process tests, isolated control sequences
scripts/release.py     signed, checksummed rolling deployment
scripts/rollback.sh    restore a retained previous app on one Mac
scripts/verify-live-switch.py  live canary acceptance before fleet deployment
docs/                  architecture, incidents and release evidence
```

## Build and deploy

```sh
bash tests/run.sh
bash deploy.sh --build
bash deploy.sh --skip-build mini
bash deploy.sh --verify-switch mini
bash deploy.sh --skip-build air15 pro air13
```

A no-argument deploy builds and deploys in that same order, running the live Mini check before continuing. The Mini must be an active, ready passenger. The check briefly switches between laptop Retina and ultrawide canvases and restores its original canvas; it requires the same daemon PID throughout. Fleet deployment requires a passing receipt from the last 24 hours for the exact installed binary. The signing identity must be available before any installation changes. Each target retains its previous app and configuration under `~/Library/Application Support/MIRA/releases/<build>-before/`. Machine identity is pinned in `~/.config/mira/machine-id` instead of guessed from a shared login name. Neither deployment nor rollback reboots a Mac.

Deployment restarts each passenger's display owner, so its virtual display is briefly recreated. All four machines must run the new release for receiver-side ownership checks to cover the entire fleet.

## CLI and diagnostics

`mira status [--json] | drive | stop | console | handback | wheel | doctor | report | perf | version | selftest | inspect-screens`

`inspect-screens` prints the displays physically attached to this Mac. The daemon runs it as a subprocess to decide the driver's canvas: its own display list is not refreshed while it has no run loop, so it cannot be trusted about hardware it does not own.

`console` and `handback` request local use from the running daemon. They do not instantiate a second display owner. `help` and invalid arguments return promptly instead of launching another menu app.

Runtime diagnostics live in `~/Library/Application Support/MIRA/`: `runtime.json` contains the observed role, geometry, build, PID and descriptor count; `fleet.json` contains per-peer acknowledgements. `mira doctor` reads fresh runtime reports across all four machines. The legacy event and text logs remain available.

## Jump connections

Saved connection documents live in `~/Library/Application Support/MIRA/aliases/<machine-id>.jump`. They are local data and are not committed or replaced by deployment. Mira's display backend should be the only owner of remote geometry: Jump's host resolution matching/dynamic resizing settings must be disabled for these sessions. Viewer fullscreen and Retina preferences must match the user's screen and desired rendering.

## Requirements

macOS 14+, Apple silicon, Jump Desktop/Jump Desktop Connect paired for Fluid, existing SSH access, and Accessibility for the viewer's mouse handling. The private CGVirtualDisplay API still requires checking before major macOS upgrades. Long-duration stability and physical dock/lid/input behavior require live observation in addition to automated tests.
