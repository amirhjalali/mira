# MIRA — Driver / Passenger Fleet Proposal

*2026-07-19. Extends DESIGN-2.md with the full use-case set: mixed Mac/Windows
fleet, any-laptop-as-driver, dock-aware and network-aware resolution, live
add/remove, passenger hygiene, upgrade safety.*

## The mental model (the whole app in three sentences)

Every machine is either the **driver** (the Mac in front of you), a
**passenger** (a machine you drive, one desktop Space each), or **parked**
(in the fleet, not in the session). You grab a laptop and press **Drive from
here** — everything else follows automatically: passengers reshape their
screens to fit the driver's current display, quality adapts to the network,
and machines return to normal the moment they stop being passengers. One menu,
one config file, one binary.

## Fleet registry

`config/machines.json` describes every machine once:

- Macs: `type: mac`, transport **Jump Fluid** (account-paired Connect).
- Windows boxes: `type: windows`, transport **RDP — through Jump Desktop**,
  not the Microsoft Windows App. Jump is already the Mac client and does RDP
  natively with dynamic resolution; one client means one automation surface,
  one place quality lives, one Space-per-machine pattern. (The Windows App
  stays installed as a fallback; nothing depends on it.)
- Future machines (M1 Air, new Windows boxes) are one JSON entry + one
  installer run. Nothing else to deploy anywhere.

## Driver detection: suggested automatically, confirmed explicitly

The daemon on each Mac knows if a human is present (console user + physical
display + recent HID input). A present human makes that Mac *eligible*; it
becomes the driver on one click (menu: **Drive from here**) or a `mira drive`
command. Switching drivers is the same click on the other laptop — it claims
the fleet, and the old driver gracefully releases (its own claim heartbeats
stop). Fully automatic driver switching is deliberately rejected: today showed
what happens when machines guess (dock-watch yanking displays mid-session).
One explicit click is the simplicity contract.

## Screens: the driver's canvas propagates

- Driver canvas = what's in front of you *right now*: 34" ultrawide when
  docked (3440x1440), the laptop panel when not (16:10 canvas per model —
  Pro 1728x1080, Air-15 1470x956, future Air-13 1440x900). Dock/undock is a
  canvas change the daemon debounces (~10s) and rolls out as one coordinated
  transition — never a mid-session yank.
- Mac passengers: one BetterDisplay virtual screen shaped to the canvas,
  physical displays mirrored onto it (works unlicensed — capture-then-restore
  arrangement via displayplacer), HiDPI when the quality tier allows.
- Windows passengers: RDP dynamic resolution already follows the client
  window; MIRA just sizes the Space. No agent needed on Windows.

## Network-adaptive quality (fast, hysteretic, simple)

Tiers, evaluated from ping avg/jitter to passengers (thresholds proven in v1:
demote at ≥70ms avg or ≥35 jitter, recover at <50/<22, 15×0.2s samples,
debounced):

| Tier | When | Mac passengers | Windows passengers |
|---|---|---|---|
| **Full** | home LAN, docked | canvas res, HiDPI | full res |
| **Standard** | home LAN, undocked | canvas res, HiDPI | full res |
| **Travel** | away, decent | canvas res, 1x | full res, 30fps |
| **Lifeline** | away, poor | reduced res (e.g. 1280x800), 1x | reduced |

Tier changes touch only what must change (HiDPI flips are display-mode
switches, not rebuilds, and every transition re-asserts the mirror set —
today's HiDPI-broke-the-mirror bug is structurally prevented).

## Passenger hygiene (the stability ask)

Entering passenger mode applies a hygiene profile; leaving restores it. All
reversible, all recorded in the passenger's state file:

- **Static wallpaper** (animated/video wallpapers murder the codec — this is
  a real bandwidth win), screensaver off, display-sleep off / system awake.
- **Focus: "Passenger"** — notifications muted so banners don't wake the
  encoder or leak into your session.
- Reduce Motion on; passenger's own Jump viewer quit (feedback-loop
  prevention, learned today).
- Nothing destructive: every setting is captured before change and restored
  on release.

## Upgrade safety (the BetterDisplay/Jump/Scroll-Reverser reality)

A `knownGood` block in the config pins the tool versions the rig trusts
(BetterDisplay 4.3.5, Jump Desktop 10.15.6 direct-download — never the 9.1.9
cask, displayplacer, Scroll Reverser). The doctor compares installed vs
known-good on every machine and flags drift *before* it bites; upgrades are a
deliberate per-machine act (upgrade one passenger, doctor, then roll on). All
tool quirks live behind one adapter layer in the binary (the per-entity
answer parsing, wake-before-connect, etc.), so a tool update breaks one file,
not five scripts.

## Live session add / remove

The menu lists every fleet machine with a checkbox-style toggle:
- **Add**: places a claim + opens its Space (Fluid or RDP through Jump).
- **Remove**: releases the claim — the passenger restores itself; its Space
  closes. Both work mid-session; claims are independent per machine.

## Simplicity contract

- One menu: status line, Drive from here / Stop driving, the machine list,
  Doctor, Quit. Nothing else.
- One config file, one binary, one LaunchAgent per Mac. No deployed scripts,
  no per-machine config, no lease server.
- `mira` CLI mirrors the menu 1:1 for scripting and for me (Claude) to
  operate headlessly.
- Status is always one glance: `◈ driving 4 · ultrawide · Standard`.

## What stays from today's v2 core (already built and selftested)

Claim files with TTL + heartbeat, the reconciler invariant loop, console
evidence, arrangement capture/restore, per-entity answer handling, parallel
multiplexed doctor. Rename in code: claim→ride, target→passenger, so the
code speaks the same language as the menu.

## Build order (each step usable on its own)

1. **Core cutover (Macs only):** driver/passenger rename, fix doctor SSH
   multiplexing (socket path), dock-aware canvas, tier engine with hysteresis.
   Prove on Pro+mini from the Air.
2. **Passenger hygiene** profile + restore.
3. **Windows passengers** via Jump RDP entries + Space management.
4. **Live add/remove UI** + fleet registry polish (M1 Air becomes a 5-minute
   add).
5. **Known-good version doctor** + upgrade runbook.

## Open questions

1. Windows depth: is opening each Windows box as a Jump RDP Space enough, or
   do you want per-tier resolution forcing there too (possible, slightly
   clunkier — RDP reconnect on tier change)?
2. Should the mini ever be drivable? (Proposal assumes no — targets-only.)
3. Hygiene: OK for MIRA to switch passengers to a static wallpaper and a
   "Passenger" Focus automatically? (Both restored on release.)
