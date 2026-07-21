# MIRA — Finish, Install, Test, Assess

*2026-07-21. The plan that takes v2 from "driving" to "done", proves it on all
three machines, and sets up the cutover decision.*

## Phase 0 — Preflight (5 min)

- Confirm Accessibility is granted to MIRA2 on the Pro (blocks Drive-from-here).
- Verify all three daemons healthy, repos clean, everything pushed.
- Baseline note of current state for before/after comparison.

## Phase 1 — Finish the core (the must-haves)

1. **Driver mutual exclusion.** A machine that receives a live ride clears its
   own `driving` flag. Closes the two-drivers-at-once feedback scenario
   (Pro driving while Air starts driving = both heartbeating rides at each
   other). Found by walking the test matrix; must fix before T6.
2. **Walk-up handback (console reclaim).** While a ride is live, the passenger
   daemon watches local HID idle time; sustained physical input (lid open +
   typing/mouse, ~5s of activity) → passenger deletes its own ride, restores
   console, notifies the driver. Grabbing the Air off the desk "just works" —
   no Stop-driving dance. Tunable threshold so a brushed key doesn't yank it.
3. **Stop driving closes the session windows.** Quit the Jump viewer on the
   driver at Stop; parked means no dead windows.
4. **Real install story.** `deploy.sh`: builds once on the Pro, signs (per-
   machine identity where present, ad-hoc otherwise), ships the .app bundle +
   config to Air and mini over scp -O, installs/reloads the LaunchAgent
   remotely. One command upgrades the whole fleet; no more raw-binary scp.
5. **Built-in scroll reversal.** CGEventTap: mouse wheel reversed, trackpad
   natural, per-device. Feature-parity gate for uninstalling Scroll Reverser.
6. **Hygiene v1 (scoped).** While passenger: Universal Control off, display
   kept awake (power assertion instead of repeated caffeinate), viewer kill
   (already live). Wallpaper-static and Focus are hygiene v2 — deferred, they
   need fragile automation and aren't blocking stability.

## Phase 2 — Install on Air + mini (15 min)

- Run `deploy.sh` to put the finished, signed bundles on both machines.
- Air additionally gets the menu app registered (it's the travel driver);
  its Accessibility grant survives rebuilds via its imported signing identity.
- Verify: daemons running from bundles, `mira2 status` sane on all three.

## Phase 3 — Full test matrix (interactive, ~1 hour)

Each test has a hard pass criterion; failures get fixed and the affected tests
re-run. Physical steps (undock, lid-open) need Amir at the machines — best run
when not mid-work, since displays will visibly flip.

| # | Scenario | Pass when |
|---|---|---|
| T1 | Drive from Pro (docked), one click | Both sessions open themselves; both passengers at 3440x1440; audio follows |
| T2 | Undock the Pro mid-drive | Passengers re-shape to laptop canvas ≤45s, sessions survive |
| T3 | Stop driving | Passengers restore display+audio to their captured console state; viewer closed |
| T4 | Walk-up: open Air lid and type while driven | Air self-releases ≤10s, Pro notified, Air usable as laptop |
| T5 | Driver crash: kill Pro daemon mid-drive | Passengers self-restore within TTL (≤90s) |
| T6 | Drive from the Air (travel drill) | Pro becomes passenger (its driving flag cleared), both sessions open on Air |
| T7 | Reboot each machine | Daemons return; no stale rides; mini boots to console |
| T8 | Scroll reversal | Mouse reversed, trackpad natural, on driver and inside sessions |
| T9 | Doctor | Green on all three; deliberately-broken case (daemon stopped) is caught |
| T10 | Audio round-trip | Passenger audio audible in session; console audio restored after |

## Phase 4 — Assess + cutover decision

Report: what passed, what needed fixing, remaining rough edges. Then the
decision gate (Amir's call, after a day or two of daily driving if preferred):

- v1 → `attic/v1/` (repo) + v1 apps/agents removed on all machines
- MIRA2 → **MIRA** everywhere (bundle, app name, label; one re-grant of
  Accessibility on Pro+Air since the bundle id changes)
- Uninstall BetterDisplay (+ discard its leftover virtual screens) and
  Scroll Reverser on all three machines
- Delete legacy home-dir scripts (`ensure-ultrawide.sh`, `mira-set-display.sh`,
  `collapse/restore-displays.sh`)
- Menu bar: one icon

## Needs from Amir

- Accessibility grant for MIRA2 on the Pro (Settings → Privacy & Security →
  Accessibility) if not already done — Phase 0 checks.
- Presence for T2/T4/T6/T7 physical steps.
- Cutover go/no-go after Phase 4.

## Amir's console-state preferences (honor, never "fix")

- **Pro docked:** BenQ ultrawide is primary, built-in panel MIRRORS it (he
  doesn't use the laptop screen at the desk). The mouse-hop incident was this
  mirror being wrongly dismantled, not the mirror itself. v2's arrangement
  capture must snapshot mirror topology too, not just origins — add that to
  Phase 1 item 6 acceptance.

## Known risks, stated plainly

- CGVirtualDisplay is private API — already live on all three, re-validated
  before any macOS upgrade (doctor gains a version pin).
- Walk-up threshold may need tuning (too eager = sessions drop when something
  touches a key; too lazy = the old dance). Shipped conservative, adjustable
  in config.
- The Air's external monitor is capped at 1080p by its cable/adapter path —
  hardware, not MIRA; unaffected by this plan.
