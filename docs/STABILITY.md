# MIRA Stability Doctrine

*2026-07-22, written after a false walk-up handback kicked a live work session.
This document governs every future change.*

## The prime directive

**A person working through MIRA must never be interrupted by MIRA.**
An interruption (session kicked, display flipped, resolution changed,
audio yanked) is a sev-1 regardless of how clever the feature that caused
it is. The rig is production; Amir's workday is the uptime metric.

## Failure-bias rule

Every automatic behavior must fail toward *doing nothing*:

- A missed handback costs one manual click ("Stop Driving"). A false handback
  costs a broken work session. Handback triggers therefore require proof of
  human presence, not absence of counter-evidence.
- A missed quality adaptation costs some bandwidth. A mid-session display-mode
  flip costs an interruption. Tiers shape **future** rides only; a live ride's
  mode is sticky until the ride ends (implemented in driveTick).
- When a guard's assumption is unverified, the feature ships **default-off**
  behind a setting, not default-on behind the guard.

## Change discipline

1. **Selftest-provable logic** (pure functions) may ship after `tests/run.sh`.
2. **Behavioral changes that can interrupt** (handback triggers, display/audio
   convergence, ride placement) require the live-fire protocol before they
   ship enabled:
   - Deploy to the **mini only** (canary — headless, no work happens there).
   - Drive the mini and exercise the trigger deliberately (inject input,
     simulate the condition over SSH) while watching its daemon log.
   - Soak ≥ 1 day of normal use with the feature enabled on the canary.
   - Only then enable fleet-wide.
3. **During Amir's work hours, no fleet deploys of behavior changes.** Bug
   fixes that *remove* interruptions are exempt (they restore the directive).
4. Every incident gets a line in this file's log below — the doctrine grows
   from scars, not theory.

## Known-fragile assumptions (verify before relying)

- HIDIdleTime IS reset by remote-injected input (proven 2026-07-22).
- Fluid sessions are UDP: lsof shows no connected peers (proven 2026-07-22).
- JumpConnect encoder CPU ≥5% during interaction: plausible, NOT yet proven
  under the live-fire protocol — presence detection stays default-off.
- Clamshell sleep overrides power assertions (proven 2026-07-22, Air).
- The mini has FileVault on and no auto-login: ANY reboot (power cut, forced
  update, remote command) strands it at the unlock screen, unreachable until
  someone physically unlocks it. Never reboot the mini remotely. Decide
  deliberately: keep FileVault (secure, fragile fleet) or disable it / enable
  auto-login on the headless canary (available fleet, weaker at-rest story).
- `caffeinate -u` does NOT reset HIDIdleTime (measured 2026-07-28) — it is not
  a synthetic-presence vector and not a usable exercise for the presence guard.
- ~~macOS updates strip Jump Connect TCC grants~~ DISPROVEN 2026-07-28: the
  grants were intact in TCC.db the whole time. `JumpConnect --dumpmacperm`
  reports every permission false when run from an SSH session, and true from
  the gui/<uid> domain (measured both ways on the Air). Any TCC probe must run
  inside the target's GUI session — the daemon's health.json does; never trust
  dumpmacperm over SSH.

## Incident log

- 2026-08-18: the Air (passenger, panel + virtual) blinked once a minute all
  morning. Cause: mirroring the panel onto the virtual WITHOUT an explicit
  mode made CG negotiate a mode all members share — panel and virtual share
  none, so the virtual was left modeless (CGDisplayCopyDisplayMode == nil,
  bounds still 3440x1440 so the invariant passed) and WindowServer reclaimed
  it ~30 s later; the reconciler rebuilt it every tick-after-death. Headless
  mini (no mirror) was immune. Fix: the virtual's mode now rides in the same
  display transaction as the mirror; invariant gained a "virtual has no mode"
  check; every reconverge logs WHICH invariant check broke. Diagnosed by
  sampling CGGetOnlineDisplayList every 2 s (px=0 on the virtual, then gone).
- 2026-08-17: the Pro's first day as a closed-lid passenger flapped through
  Clamshell Sleep / DarkWake every few seconds all evening (display off/on;
  session stutter). Assertions can't beat clamshell sleep (proven 07-22).
  The Air rode clamshell fine because it already had `pmset disablesleep 1`;
  the Pro never got it — it had always been the driver. Fix: disablesleep=1
  on the Pro. Convention: EVERY laptop that can be driven gets
  `sudo pmset -a disablesleep 1` at onboarding (candidate for add-machine.sh).
- 2026-07-19: v1 login agent stole displays at physical login (invisible-apps).
  Root cause: unconditional display mutation. Led to v2 reconciler design.
- 2026-07-22 AM: macOS 26.5.2 stripped TCC on both passengers; no signal
  anywhere pointed at the cause. Fix: doctor probes dumpmacperm.
  [CORRECTED 2026-07-28: no strip ever happened — the probe itself lies over
  SSH. See known-fragile assumptions.]
- 2026-07-22 AM: presence-based handback false-fired on injected input mid-
  session (guard blind to UDP). Fix: encoder-CPU guard + lid gate + feature
  now default-off pending live-fire proof. Process fix: this document.
- 2026-07-28 PM live-fire (endpoint death): killed the mini's user-session
  JumpConnect mid-drive. launchd respawned it and the Fluid session
  auto-reconnected in ~12 s; the viewer window survived untouched. Transient
  Connect crashes on a passenger are self-healing — no MIRA action needed.
- 2026-07-28 PM: session opening moved off UI scripting. Exported .jump
  connection documents (machine-local, `aliases/<id>.jump` in the MIRA state
  dir) open saved sessions via plain `open` from any context — cold start
  proven, no Accessibility, no Open Recent dependency. Menu scripting remains
  only as fallback for a machine without an alias file.
- 2026-07-28 PM: presence-based walk-up entered the live-fire protocol —
  enabled on the mini canary only. Failure signature: an unwanted mini
  handback while its session streams (watch `walk-up: sustained` in its
  daemon log). Soak ≥1 day of normal use before any fleet enable.
- 2026-08-13: morning fleet check from the Pro found both peers unreachable
  over SSH. Cause: Tailscale was stopped on the Pro; `tailscale up` restored
  it. Rides were unaffected — Jump's path is independent — but doctor,
  deploy, and permission reports all ride the tailnet. Compounding: the
  peers were still on Jul 28 builds and the Pro on the Aug 12 midday build,
  so none of the 08-12 fixes were live (the Air's 21:21 ride still phantom
  handed back). Fix: full-fleet `deploy.sh`. During it the Air agent
  bootstrapped but launchd never spawned the daemon (state = not running,
  never exited) until an explicit kickstart — deploy.sh now kickstarts after
  bootstrap. Lesson: a fix isn't live until deployed; check binary mtimes
  against source when behavior contradicts the code.
- 2026-08-12: Mac rides on the Air looked fuzzy while the Windows RDP session
  was crisp. Cause: both Air-side session aliases had `UseHIDPIResolution:
  false` — the viewer streamed the 1470x956 canvas at 1x and upscaled 2x onto
  the Retina panel. The Pro alias was also a fresh export under Jump's default
  filename, not `pro.jump`, so MIRA's alias-open path never used it. Fix:
  `plutil -replace UseHIDPIResolution -bool true` on both aliases + copied the
  export to `pro.jump`. Alias export checklist is now THREE flags:
  `StartInFullscreen: true`, `UseHIDPIResolution: true`, correct `<id>.jump`
  filename. Sessions must be closed and reopened from the alias to pick this
  up. Note: HiDPI quadruples streamed pixels — on thin links the codec may
  soften motion, but static text renders 1:1.
- 2026-08-12: the day's first remote ride was handed back 3 s after converge
  ("walk-up detected"). Cause: the walk-up burst latch is only consumed while
  a passenger, so a burst of real local input from the console period (owner
  using the Pro hours earlier) survived until the ride's first tick and fired
  as a phantom walk-up. The handback hold then blocked re-rides for 10 min
  (drive-from-Air degraded to a console-canvas session). Fix: converge now
  discards anything latched before/while it ran — only input that arrives
  during an established ride can hand back. A real walk-up still fires: a
  person present keeps typing and re-latches within the next 15 s tick.
- 2026-08-02: all rides rendered scaled/soft, never 1:1. Two stacked causes:
  the 07-28 alias export captured `StartInFullscreen: false` (sessions reopen
  windowed), and the global `AppleMenuBarVisibleInFullscreen = 1` capped even
  fullscreen viewers at 3440x1410 vs the 3440x1440 canvas. Fix: `plutil
  -replace StartInFullscreen -bool true` on both aliases + reverted the menu
  bar default. Re-exported aliases must keep StartInFullscreen true.
- 2026-08-02: walk-up presence canary FAILED live-fire on the mini: a viewer
  restart (Jump reconnect) reset HIDIdleTime and fired "walk-up: sustained
  local input" twice in a row — the relay/reconnect window bypasses the
  inboundSessionActive() gate exactly as the known-fragile note predicted.
  walkupPresence disabled on the canary; do not fleet-enable. Any future
  presence trigger must survive a viewer restart without firing.
- 2026-07-28: after a Pro reboot, MIRA reported driving with zero session
  windows — the driving flag survives reboot and rides re-place, but only the
  menu app's Drive action opened windows, and the menu app wasn't even a login
  item. Doctor simultaneously cried TCC-strip (the SSH probe artifact above),
  sending recovery down a re-granting goose chase. Fixes: menu app registers
  as a login item and boot-resumes session windows once per boot
  (kern.boottime marker); doctor now reads each daemon's gui-domain
  health.json instead of probing dumpmacperm over SSH; deploy.sh installs on
  the driver too so the Pro never runs a stale build.
