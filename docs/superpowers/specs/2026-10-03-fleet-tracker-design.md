# Fleet Tracker — design

Date: 2026-10-03 · Status: draft for review

## Intent

MIRA becomes a fleet tracker. A native MIRA window, opened from the menu bar, shows every machine the
owner uses (the four Macs and three Windows PCs) at a glance. From the same window the owner can connect
to any machine and fix the faults it shows. Success looks like this:

- this morning's failure (air13's 13-hour session into the Pro echoing a meeting) shows up as a red
  "stale session" with a one-click kill
- connecting to any machine, Mac or Windows, is one click

**What the owner said:**
- see + launch
- a native window from the menu bar
- Windows: status + launch only, nothing installed on the PCs
- cards show:
  - role + connections
  - audio route
  - display layout
  - health/build
- actions:
  - Drive/Stop/Local
  - kill stale session
  - fix audio/display

**Assumptions** (correct me if any are wrong):
- the window refreshes only while it is visible
- Windows PCs are reached only over Tailscale
- the window is the same on every viewer Mac

## Fleet additions

`config/machines.json` gains three `type: "windows"` machines (the schema field already exists, app/MIRA.swift:89):

| id | name | Tailscale | RDP endpoint | notes |
|---|---|---|---|---|
| `rig3090` | 3090 Desktop | 100.78.167.19 (desktop-iki1670) | 100.78.167.19:1337 | primary |
| `amelie` | Amelie's Desktop | 100.64.135.60 (desktop-aeefjre) | 100.64.135.60:1338 | |
| `ace` | Ace Mini PC | 100.101.253.21 (win-slk2vhu7sbe) | none yet | no Windows App bookmark; offline 55 days |

New optional fields: `rdpHost`, `rdpPort`, `tailscaleName`.

- Windows machines have no `roles`, so every existing loop that filters on `viewer`/`target` already skips them.
- `release.py` already filters the fleet to `type == mac`.
- Out of scope: the `amir-lab` Linux bookmark and the public `20.26.121.2` bookmark.

## Architecture (approach A: each Mac reports itself, any window polls all)

```
FleetWindow (menu app, any Mac)
  ├─ every 5 s while visible, in parallel:
  │    Mac peers ──SSH── `MIRA control {kind:"status"}` → MachineStatus
  │    this Mac  ──────── buildMachineStatus() locally
  │    Windows   ──────── `tailscale status --json` + lsof on this Mac
  └─ actions ───SSH──── existing control kinds + three new ones
```

**Units:**
- `app/Fleet.swift`: the data model, status builders, pure classifiers and the Windows probes. No UI.
- `app/FleetWindow.swift`: an AppKit `NSWindow` hosting a SwiftUI view, plus a "Fleet…" menu item.
- `app/MIRA.swift` stays as it is apart from the menu item and the new control kinds.
- `tests/run.sh` and `scripts/release.py` gain the two new source files (their concatenation list and source hashes).

## MachineStatus (one per Mac, built on that Mac)

```
machine, build, ts, role (driving|passenger|local), driver
connections: [{direction: in|out, peer (machine id or IP), app (jump|windows-app), ageSeconds, stale}]
audio:   {output, input, warning?}
display: {screens: [{name, w, h, main, mirrorOf}], expected (yes|no|unknown), detail}
health:  {daemonAge, jumpPermissions (ok|stripped|unknown), warnings: [String]}
```

**Fresh-data rule (from the 2026-09-16 incident):** the daemon has no run loop, so its CoreGraphics
display list goes stale. Display and audio facts are therefore gathered by a short-lived subprocess,
the same way `mira inspect-screens` works today. They are never read from the daemon's cached state.

## Classifiers (pure, selftested)

- **Stale session.** A Jump session counts as stale if either:
  - it goes *into* a Mac from a peer that is not the current driver
  - it goes *out* from a Mac that is not the current driver

  Session age comes from the `JumpConnect --desktopproxy` process age (inbound) and from the Jump
  viewer's Window menu (outbound, existing code).
- **Audio warning.** A Jump Desktop device is selected on a Mac that is not a passenger, or a passenger is
  not routed through Jump.
- **Display expectation:**
  - passenger: `passengerInvariantFailure == nil`
  - console: no retained `arrangement.json`, and the main screen is the widest physical screen (the owner
    wants the external main and the built-in mirrored)
  - anything else is `unknown`, never "broken" (from the 392d86a rule)

## Windows probes (run on the Mac doing the polling)

- **Online / last seen:** `tailscale status --json`, matched by Tailscale IP.
- **Session open from this Mac:** `lsof -nP -iTCP -sTCP:ESTABLISHED` shows a Windows App connection to `rdpHost:rdpPort`.
  Verified 2026-10-03: `100.91.23.16:60895->100.78.167.19:1337`.
- **Connect:** opens the saved bookmark, credentials included. The mechanism is unproven. Plan task 1 is a
  spike over three options, and only a mechanism that uses the saved credentials is accepted:
  - the `ms-rd:` URL scheme
  - a generated `.rdp` file
  - selecting the bookmark through Windows App's UI

## Actions

| Button | Where it runs | Mechanism |
|---|---|---|
| Drive / Stop / Local | this Mac | existing control kinds `drive`, `stop`, `local` |
| Kill stale session | the Mac that holds the *viewer* | new kind `close-viewer` → `killJumpViewer()`. Host-side kills are useless because the viewer reconnects within 1 s. |
| Fix audio | the target Mac | new kind `fix-audio` → `routeAudio(passenger:)` for its current mode |
| Fix display | the target Mac | new kind `fix-display`: a passenger resets the breaker and reconverges; a console Mac applies `last-console-arrangement.json` (its last *verified* layout) |
| Connect (Mac) | this Mac | existing `openSessionWindows(targets:)` |
| Connect (Windows) | this Mac | the mechanism chosen in the spike |

Every destructive action asks for confirmation in the window. The new control kinds are no-ops under
`MIRA_STATE_DIR`, so tests never touch real sessions.

## Window layout

- Header: who is driving, the time of the last refresh, and a manual refresh button.
- Two rows of cards: **Macs** (pro, air15, mini, air13), then **Windows** (3090, Amelie, Ace).
- Mac card: status dot, name, role badge, the connections list with stale ones in red and a Kill button,
  an audio line (warning plus a Fix button), a display line (plus a Fix button), a build/health line, and
  Drive/Stop/Local where they apply.
- Windows card: status dot, name, Tailscale state and last seen, "session open" when connected, and Connect.
- An unreachable Mac shows grey with its last-seen time and keeps its last snapshot greyed out.

## Error handling

- Each peer poll is bounded by the existing 16 s `peerRun` timeout, and at most one poll per peer is in
  flight, matching `SessionTransport`.
- If `tailscale` is missing, Windows cards show `unknown`.
- A failed action shows its `ControlReply.message` on the card.

## Testing

- **Selftest:**
  - the stale-session classifier (incl. the 2026-10-01 scenario)
  - the audio rule
  - the display rule (incl. the retained-snapshot case)
  - Tailscale JSON parsing
  - the lsof line parsing
  - MachineStatus JSON round-trip
- **ipc-selftest:** `status` returns a snapshot, and the new action kinds are inert under `MIRA_STATE_DIR`.
- **Live:** release via the mini canary, then open the window on the Pro and check every card against reality.

## Out of scope

- A Windows agent
- Wake-on-LAN
- A web dashboard
- Doctor reusing MachineStatus (a natural follow-up)
- Fixing why the 2026-09-30 arrangement capture lost `mirrorOf` (tracked separately)
