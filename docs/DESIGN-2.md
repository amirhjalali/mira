# MIRA 2 — First-Principles Redesign

*2026-07-19, after a day of live failures. Supersedes specs/2026-07-03-macrig-design.md.*

## Why v1 keeps breaking

Every failure today traces to the same three root causes:

1. **Imperative mutation, no reconciliation.** Five actors (menu app, dock-watch,
   login agent, deployed helpers, humans) each fire one-shot display mutations.
   Any interruption or overlap strands the system between states — the broken
   mirror set after a HiDPI flip, the empty-desktop takeover at login, the
   dock-watch yank mid-session. Nothing ever looks at the whole state and
   converges it.
2. **Role confusion.** Every machine is both viewer and target, but v1 has no
   concept of a machine's *current* role. The Pro kept viewer sessions streaming
   the Air while the Air viewed the Pro (feedback loop); the Air's own target
   virtuals wandered in while it was being used as a viewer.
3. **Invisible transport and scattered state.** Nothing verified Fluid vs VNC.
   State lives in marker files, deployed script copies, LaunchAgent labels, a
   lease on the mini, and untracked per-machine config — drift is structural.

## v2 shape: one binary, one config, one reconciler

**`MIRA.app` is the only artifact.** One Swift binary, three modes:
- default launch → menu-bar app (viewer controls + status)
- `--daemon` → the reconciler (LaunchAgent, every machine, viewer or target)
- CLI verbs → `mira status | claim | release | console | doctor | selftest`

**One tracked config: `config/machines.json`.** The whole rig in one file —
every machine's names, users, addresses, canvases. A machine finds itself by
hostname. No more per-viewer gitignored config with mirrored perspectives and
wrong usernames.

**The reconciler owns all display state on its machine.** Nothing else touches
displays — no deployed helpers, no dock-watch, no login-agent display logic.

### The state model

Each machine is in exactly one mode, computed from two inputs:

```
claim file (written over SSH by a viewer): {viewer, canvas, hidpi, ts}
console evidence: console user + physical display + HID activity recency
```

- **CONSOLE** (default): physical displays in their captured arrangement,
  virtual screens disconnected, no mirror. A person at the machine always
  converges here when no live claim exists.
- **TARGET** (live claim): capture the physical arrangement first (displayplacer
  emits the exact restore command — store it), ensure the virtual screen for the
  claimed canvas (HiDPI per claim), mirror all physical displays onto it
  (mirroring works unlicensed; disconnect does not), virtual = main.
  A claim carries a TTL; the viewer's daemon heartbeats it. TTL expiry or an
  explicit release → CONSOLE, restored from the captured arrangement.
- Transitions are **atomic and re-asserted**: the reconciler re-checks the full
  invariant (connected + mode + mirror + main) every cycle, so a broken mirror
  or a display hot-plug self-heals within one cycle instead of stranding.

Claiming a target also ends the target's own outbound viewer sessions
(kills the feedback loop by construction: a machine in TARGET mode quits its
Jump viewer).

Dock/undock on the *viewer* is just a canvas change: the daemon debounces it and
rewrites its claims (laptop ↔ ultrawide canvas). Targets converge on the next
cycle — a coordinated transition, not a mid-session yank.

### Transport is verified, not assumed

Doctor and the daemon both check: Fluid session ⇢ JumpConnect serving;
`screensharingd` streaming = VNC ⇒ menu-bar alert + notification. Connect
pairing is done by CLI (`JumpConnect --connectcode`), never GUI.

### SSH: multiplexed and minimal

All peer traffic uses `ControlMaster auto` + `ControlPersist 120` with one
compound command per peer per operation. Doctor runs peers in parallel.
(v1's doctor: 15+ cold handshakes ≈ 20s. v2 target: <4s.)
`scp -O` everywhere (SFTP mode fails silently against these targets) — but v2
deploys nothing: the binary is installed per-machine by `install.sh`, which
also codesigns with the "MIRA Signing" identity when present so TCC grants
survive rebuilds.

### What v2 deliberately keeps

- BetterDisplay for virtual screens (create/connect/mode), displayplacer for
  mirroring and arrangement capture — both proven today.
- The v1 hardening knowledge: per-entity `-connected` answers, caffeinate
  display-wake during virtual connect, ping hysteresis thresholds
  (demote ≥70ms avg / ≥35 sdev, return <50 / <22), Window-menu prefix matching.
- Jump session opening via the hardened open-recent automation — the one
  remaining AppleScript, isolated, with the lazy-submenu and Escape fixes.
  Quality/bandwidth menu automation stays dead; quality lives in the saved
  connection.
- HiDPI on laptop-canvas virtuals (Fluid absorbs it), 1x on ultrawide.

### What v2 deletes

dock-watch (agent + binary), the mira-display login agent, deployed home
helpers (`ensure-ultrawide.sh`, `mira-set-display.sh`), the display-owner lease
on the mini, per-viewer `config.sh`, all of `bin/` and `lib/` and `remote/`.
One binary + one config + one LaunchAgent per machine.

## Migration

v2 installs alongside v1 (label `com.amir.mira2` during transition). Cutover
per machine: stop v1 agents, `mira claim/console` proves transitions, then v1
artifacts move to `attic/v1/`. The Air is the portability test: clone, run
`install.sh`, done — no target-side deploy step exists anymore.
