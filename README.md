# MIRA

**Multi-Instance Rig Activation** — a menu-bar app that turns a fleet of Macs
into one workspace. The Mac in front of you is the **driver**; every other
machine is a **passenger** you drive through Jump Desktop, each on its own
native virtual display shaped to your current screen.

One Swift binary per machine. No BetterDisplay, no displayplacer, no Scroll
Reverser — displays, audio routing, and scroll reversal are native engines
inside the app.

## What it does

- **Drive from Here** (menu or `mira drive`): claims every passenger, shapes
  each one's screen to your canvas (34" ultrawide when docked, your laptop
  panel when not, Retina/HiDPI when the network allows), routes their audio
  into the session, and opens the Jump windows.
- **Self-healing by construction**: passengers hold a ride with a TTL,
  heartbeated by the driver. Driver dies → passengers restore themselves
  (displays, audio, arrangement, mirror topology) within 90 s. A reconciler
  re-asserts the whole invariant every 15 s, so hot-plugs and half-applied
  transitions converge instead of stranding.
- **Walk-up handback**: open a driven laptop's lid (or type on it) and it
  hands itself back to you — console restored, driver notified.
- **Network-adaptive**: ping-based tiers with hysteresis pick quality and
  HiDPI; dock/undock is a debounced canvas change, never a yank.
- **Settings menu**: reverse mouse scrolling (wheel only — trackpad stays
  natural), walk-up handback, Retina passengers, per-machine session toggles.

## Layout

```
app/MIRA.swift        the entire app (menu bar + daemon + CLI) + shim.h (CGVirtualDisplay)
config/machines.json  the whole fleet: machines, canvases, tiers, TTLs
deploy.sh             build, sign, push to every machine, restart daemons
add-machine.sh        one-command onboarding for a new Mac
tests/run.sh          build + pure-logic selftest gate
docs/                 design, fleet proposal, roadmap, test reports
```

## Install

Existing fleet: `bash deploy.sh` from any repo checkout (normally the Pro) —
builds, selftests, signs, ships to every machine, restarts daemons.

New machine:

```bash
bash add-machine.sh <id> <ssh-user> <host> "<Jump name>" [--viewer [canvas]]
```

That registers it in `machines.json`, authorizes SSH, and deploys. The only
human steps left are the ones that need a human: Jump Desktop Connect pairing
(`JumpConnect --connectcode <code>`), Tailscale sign-in, and — for a machine
that will drive — the Accessibility grant.

## CLI

`mira status | drive | stop | handback | console | doctor | report | selftest`
(binary at `MIRA.app/Contents/MacOS/MIRA`). `doctor` checks the fleet in
parallel; `report` summarizes daemon health from the logs.

## Requirements

macOS 14+ (Apple silicon tested), Jump Desktop + Jump Desktop Connect
(Fluid, account-paired), Tailscale recommended. The virtual-display engine
uses the private CGVirtualDisplay API — validate before macOS major upgrades
(`mira doctor` after updating on one machine first).

## History

v1 was a shell-script stack driving BetterDisplay over SSH (see git history
before 2026-07-20). v2 is the current native rewrite; the transitional
"MIRA2" identity is retired.
