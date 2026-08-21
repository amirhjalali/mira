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

- 2026-08-20: air15 rebuilt its virtual display **717 times in one day**, one
  every ~46 s, and the mini spent the day on Jump Desktop's own 1920x1080
  headless virtual instead of MIRA's canvas — which is what "both letterboxed"
  actually was. Two causes, one of them two days old and one of them original.
  **`desc.queue = DispatchQueue.main`.** CGVirtualDisplay delivers every
  callback it has on that queue, and `runDaemon` is a bare `while true` blocked
  in `DispatchSemaphore.wait` — it never runs the main run loop, so nothing
  dispatched to main is ever delivered, in the one process whose whole job is
  owning virtual displays. That single line accounts for all three symptoms
  chased across 08-19/20: modes never became visible in-process while an
  external probe read all 18 off the same display id (publication callback never
  delivered); the framework reclaimed a client that never serviced its queue;
  and `terminationHandler` logged ZERO times across 717 teardowns, which is what
  made the teardown invisible and sent two days of fixes at symptoms instead of
  the cause. Now a private serial queue, serviced by libdispatch's own threads,
  needing no run loop.
  **rideTTLSeconds 90 -> 300.** With the teardowns no longer silent the residue
  was visible: leases arrived FRESH (age 0.04 s) but in 82-95 s gaps against a
  90 s TTL, because beats cost 9-14 s. Every expiry dropped the passenger to
  console, and a console fall destroys and rebuilds the virtual display — the
  bounce. The TTL only has to fire when a driver DISAPPEARS; a deliberate Stop
  deletes ride.json outright. Ten beats of slack for a safety net costs nothing.
  Result: 7 minutes with 1 virtual created, 0 destroyed, 0 console falls on both
  machines, both showing MIRA's canvas — against 745 converges/day before.
  Lesson: three separate fixes went at "the display keeps failing" while the
  event that would have named the cause was queued to a thread that never ran.
  A callback you never receive is indistinguishable from an event that never
  happens; if a lifecycle handler has never fired once, that is the bug, not
  evidence of health.
  **Still unfixed:** modes remain unreadable in-process even on the new queue,
  so the mirror is still applied without an explicit mode and CG could yet
  renegotiate the set (the 08-18 bug). It has not, but nothing prevents it.

- 2026-08-19 (evening): no passenger could converge at all. Every ride ended
  `apply topology: no 3440x1440 mode published on the virtual` →
  `converged=false — topology transaction failed`, on repeat until the breaker
  tripped, then again on the next lease. Cause: **this process cannot read the
  display state of a virtual display it owns.** An external probe read all 18
  modes off virtual display id 8 — including the exact `3440x1440 px=6880x2880`
  wanted — while the owning daemon read none off the same id, and
  `CGDisplayCopyDisplayMode(virtualID)` returned nil indefinitely. Turning the
  run loop and re-asking does not clear it (tried, deployed, measured: no
  change). The daemon had received no `CGDisplayRegisterReconfigurationCallback`
  since start.
  What made an unreadable snapshot fatal was the morning's strobe fix, in two
  places: the mode lookup became `guard ... else { return false }` where it had
  been "no match, mirror anyway", and the 08-18 `CGDisplayCopyDisplayMode`
  invariant clause was kept and merely wrapped in a settle.
  Fixes: (1) a missing mode DEGRADES the transaction instead of aborting it —
  mode selection only stops CG renegotiating the mirror set, the mirror itself
  is the point. (2) the unreadable clause may no longer fail the invariant; the
  clauses that ARE readable in-process (bounds, main-ness, mirror membership)
  judge the topology, and they agreed with the external probe throughout.
  Result: `converged=true` on air15 and the mini, topology externally verified
  (virtual main at 3440x1440, physical mirroring it), and zero reconverges in
  75 s where it had been flapping every 3–6 s.
  Lesson, and it is the same one twice in a day: an invariant that cannot tell
  "broken" from "unreadable" must never report "broken". Two fixes in a row
  tried to make the unreadable read (settle, re-ask); both failed, because the
  read is not late, it is unavailable. **Unfixed:** why a process cannot read
  its own virtual display. Everything above works around that, it does not
  solve it — and without an explicit mode CG can still renegotiate the set,
  which is the 08-18 bug waiting to return.

- 2026-08-19: the pro sat on extend for a day when the docked preference is
  duplicate. Cause: `restoreArrangement` called `unmirrorAll()` and `setMain()`
  BEFORE checking whether an arrangement had ever been saved, so the
  "nothing to restore" path was destructive and returned success. A console
  converge that runs twice is enough: the first restores the arrangement and
  deletes arrangement.json, the second finds no file and unmirrors what the
  first just rebuilt. Seen in the log as two `converge -> console` inside the
  same second (18:24:59), and reproduced deterministically afterwards — set
  duplicate, run `mira console` once, back to extend.
  Fix: the empty path now touches nothing at all; `unmirrorAll()` moved below
  the guard, `setMain()` deleted from it.
  Lesson: the reconciler converges to console constantly, so every line on that
  path runs thousands of times a day, including at the worst possible moment.
  Anything there that mutates displays *without having been asked to* is not a
  restore, it is a slow leak. "Nothing to give back" must mean touch nothing.

- 2026-08-19: two drivers. air15 took the wheel while air13 was asleep; the
  fleet ran with two claimants and passengers took rides from both.
  Three defects, all in the same act:
  (1) `stopOtherDrivers` pushed `rm -f driving` through `peerRun` WITHOUT
  `force:`, so the push was skipped by the unreachable-backoff and returned 125
  without attempting an SSH. peerRun's own comment already said force was for
  "doctor, an explicit drive" — doctor passed it, drive never did. The second
  click four seconds later never even tried.
  (2) The failure was silent: the result was discarded and the notification
  said "Driving: N/M sessions open". The only evidence was one log line,
  `could not reach air13 to stop its driving flag`.
  (3) The documented safety net — "the older claimant still yields on its own"
  — did not exist for air13. That yield lives in the `.passenger` branch of
  `tick()`, reached only when a RIDE lands, and rides go only to machines with
  the `target` role. air13 is `roles:["viewer"]`, so nothing was ever placed on
  it and it could not yield by any path. It slept holding a dead claim and woke
  up still driving.
  Fixes: a wheel beacon — the claim with no ride attached — pushed to every
  other machine that *may drive* (`otherViewers`, keyed on `mayDrive`, not on
  the target role), at claim time and again on every beat; a yield check at the
  TOP of `tick()` that any machine can reach; `force: true` on the claim; the
  peer's own claim read back each beat so a stale driver stands down even when
  it was *our* stop that missed; the unreachable list surfaced in the
  notification and the CLI; `mira wheel` and a doctor check that both name two
  drivers outright.
  Lesson: a rule enforced only along the path where it is usually violated is
  not enforced. "One driver at a time" was checked only where rides land, so
  the machine that received no rides was the one that could break it.

- 2026-08-19: the Air strobed its panel every 3.5 s for 89 minutes — 1,924 full
  display teardowns, sev-1 against the prime directive. Cause: the 08-18 fix
  added `guard let m = CGDisplayCopyDisplayMode(virtualID)` to the passenger
  invariant, promoting a check that previously ran only on hidpi rides into one
  that runs on every converge. The ultrawide canvas is hidpi=false, so that call
  had never executed before. It returns nil when asked immediately after
  CGCompleteDisplayConfiguration: CoreGraphics answers display queries from a
  per-process snapshot refreshed only when the process turns its run loop, and
  the converge queried on the next line. An external probe read the correct
  3440x1440 mode off the same display throughout. The cheap bounds queries
  (IsMain, PixelsWide) refresh eagerly and passed, which is what made it look
  like a genuinely modeless virtual and sent the first fix the wrong way.
  Collateral: captureArrangement snapshotted the panel mid-teardown and saved a
  1x 2560x1600 mode, so the console restore would have returned the Air's
  built-in non-retina.
  Fixes, all four architectural rather than another patch on the guard:
  (1) a ConvergeBreaker — N identical consecutive failures stop the loop, log
  once, and leave the display alone; the failure-bias rule applied to
  convergence itself. (2) One transaction: unmirror/setMode/mirror/setMain
  collapsed into a single CG configuration, because every seam between them was
  a window for CG to renegotiate the set down to a shared mode (the 1024x768
  trap and the modeless virtual are the same root). setVirtualMode and
  mirrorPhysicalsOntoVirtual are deleted so the old path cannot come back.
  (3) settledInvariantFailure turns the run loop and re-asks before believing a
  failure. (4) the apply's result is logged, never discarded.
  Lesson: a reconcile loop is only safe when reads are truthful, writes are
  cheap, and we own the resource. Display config is none of those — reads lag
  our own writes, each write costs a visible flash, and Jump Desktop mutates
  the same global state. Any future display invariant must assume its own reads
  can be wrong, and must be unable to act on that wrongness more than N times.

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
