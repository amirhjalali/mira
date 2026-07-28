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
- ~~macOS updates strip Jump Connect TCC grants~~ DISPROVEN 2026-07-28: the
  grants were intact in TCC.db the whole time. `JumpConnect --dumpmacperm`
  reports every permission false when run from an SSH session, and true from
  the gui/<uid> domain (measured both ways on the Air). Any TCC probe must run
  inside the target's GUI session — the daemon's health.json does; never trust
  dumpmacperm over SSH.

## Incident log

- 2026-07-19: v1 login agent stole displays at physical login (invisible-apps).
  Root cause: unconditional display mutation. Led to v2 reconciler design.
- 2026-07-22 AM: macOS 26.5.2 stripped TCC on both passengers; no signal
  anywhere pointed at the cause. Fix: doctor probes dumpmacperm.
  [CORRECTED 2026-07-28: no strip ever happened — the probe itself lies over
  SSH. See known-fragile assumptions.]
- 2026-07-22 AM: presence-based handback false-fired on injected input mid-
  session (guard blind to UDP). Fix: encoder-CPU guard + lid gate + feature
  now default-off pending live-fire proof. Process fix: this document.
- 2026-07-28: after a Pro reboot, MIRA reported driving with zero session
  windows — the driving flag survives reboot and rides re-place, but only the
  menu app's Drive action opened windows, and the menu app wasn't even a login
  item. Doctor simultaneously cried TCC-strip (the SSH probe artifact above),
  sending recovery down a re-granting goose chase. Fixes: menu app registers
  as a login item and boot-resumes session windows once per boot
  (kern.boottime marker); doctor now reads each daemon's gui-domain
  health.json instead of probing dumpmacperm over SSH; deploy.sh installs on
  the driver too so the Pro never runs a stale build.
