# Display architecture: who owns the size of the picture

Written 2026-08-18, after an evening of adjusting numbers one at a time and
getting nowhere. The point of this document is that nobody should ever have to
do that again.

## The one-sentence model

**A canvas is not a preference. It is the size of the hole the picture is poured
into** — the Jump viewer's content rect on the driver's panel, in points. Config
*seeds* it; measurement *owns* it.

## Why it kept going wrong

The old design had a static `canvas` in `config/machines.json` that had to equal
a quantity nothing measured, and that depends on:

- the viewer's panel pixels
- its current scaled mode
- its notch inset (fullscreen content is laid out **below** the camera)
- Jump's own window chrome

Four moving inputs, one hand-typed constant. It went stale every single time any
of them moved, and it was invisible when it did:

| Date | What happened |
|---|---|
| 2026-08-12 | `laptop-air` was `1470x956` (the Air's *default scaled* size). Blurry and letterboxed. Corrected to `1440x932` = panel ÷ 2. |
| `45f0502` | "Pixel-exact canvases" commits that correct value. |
| `7df68eb` | An **unrelated** commit silently reverts it to the 16:10 legacy `1710x1068`. Nothing catches it. |
| 2026-08-18 | Rediagnosed by eye. Then found that panel ÷ 2 is *itself* wrong on a notched Mac: the panel is `1440x932` but the viewer only gets `1440x903`. |

Three separate rounds, same class of bug. The rule was never wrong because
someone was careless — it was wrong because **a constant cannot track a
measurement.**

## What made it invisible

Two blind spots, both now closed:

1. **The control loop asked the wrong question.** `passengerInvariantFailure`
   checked "does my virtual display match the canvas I was handed?" — perfect
   self-consistency, `converged=true` all night, while the picture was wrong.
   Nothing asked "does the canvas match the hole it is poured into?"
2. **`doctor` had never looked at a screen.** Daemons, reachability, TCC, VNC —
   all green while every display in the fleet was wrong.

## Two more controllers exist

MIRA is not alone in writing display state:

- **Jump renegotiates modes on both ends of a session.** Not just the machine
  being viewed: air15's own panel was replaced with `1920x1200 @1x` twice in 40
  minutes while it was the *driver*, silently undoing each fix.
- **A stale viewer holds sessions open indefinitely.** One had been up
  **14h24m** on the pro — a *passenger* — streaming into two other machines.
  The anti-stream guard that exists to prevent exactly this had been "fixed"
  twice (`c11d7ed` is literally titled "Fix the passenger anti-stream guard,
  which had never worked") and still did nothing, because the pattern always
  matched and `pkill`'s **SIGTERM was simply ignored by an AppKit app**.

## The design now

1. **Measure, don't configure.** The driver measures the Jump viewer's content
   rect every tick (`observedViewerContent`) and ships it in `ride.json` as
   `canvasW`/`canvasH`. Passengers render that. Config is the seed used only
   until there is a window to measure.
2. **The measurement is sticky.** `observedViewerContent()` returns nil whenever
   the window is not on screen — a Space switch, a reconnect — and letting that
   fall back to the seed rebuilt the passenger's display twice per flap. That
   was the visible "resolution bounces from here to there". `adoptMeasurement`
   keeps the last good value and applies a 2-point deadband.
3. **The console panel is defended.** The driver baselines its own panel (only
   ever from a *sane* mode: HiDPI at native aspect) and restores it whenever it
   is changed to something objectively worse — 1x where we had HiDPI, or an
   aspect the panel does not have. A deliberate, sane resolution change by the
   user is left alone. Cause-agnostic on purpose: it does not matter who moved
   it.
4. **The anti-stream guard verifies and escalates.** Signal, check, SIGKILL,
   check again, and log loudly if something survives. Proven live at 20:54:32:
   `viewer ignored SIGTERM — escalating to SIGKILL`.
5. **Attribution, not a kill list.** `screenTakers()` names what is on the screen
   (VNC on :5900, screensharingd, Sidecar, inbound Jump sessions with their age)
   so a defense says who to go quit. Killing them was considered and rejected:
   `screensharingd` is launchd-managed and respawns, and it is also the way back
   into a machine that is not in front of you.
6. **The selftest holds the invariant.** `tests/run.sh` runs under `set -e` and
   `deploy.sh` gates on it, so the `7df68eb` regression cannot ship again.
   Every pure decision above is tested headless.

## If it looks wrong again

Run `mira doctor` — it now reports console panel geometry, the measured viewer
content area, screen-taking agents, and the age of inbound sessions. Do **not**
start editing numbers. Symptom map:

| What you see | What it means |
|---|---|
| Bars at the edges | Canvas aspect ≠ the hole's aspect |
| Small **and** soft | The panel fell into a 1x mode (`_spdisplays_pixels` == points) |
| Soft, full screen | Backing pixels ≠ panel pixels: a non-integer downscale |
| Bouncing | Two controllers fighting, or a measurement flapping |

## Known-open

- `laptop-air13` is `1280x800`, **unverified**: correct for an M1 Air
  (2560x1600), wrong for M2/M3/M4 (2560x1664 → `1280x832`). Left out of the
  selftest table rather than guessed at.
- `laptop-pro` is in the table as panel ÷ 2 (`1728x1117`) but has never been
  *measured as a viewer*; the notch inset almost certainly applies there too
  when the pro drives. Measure it the first time the pro drives again.
- The doctor VNC check (`screensharingd` >5% CPU) produced one failure that did
  not reproduce seconds later, with no process and no ESTABLISHED :5900. Likely
  a transient; if it recurs, it is a false positive worth tightening.

## A display symptom that is not a display problem

2026-08-18, after rebooting air15: "the mac mini resolution looks a little
funny". Nothing was wrong with any canvas. The mini had a **driving claim**
stamped at 21:27:38 — newer than air15's — so it rejected every incoming ride as
stale, destroyed its virtual display and fell back to its own 1920x1080 console.
The size was correct for what it had become: a driver with no passengers.

The mini is `roles: ["target"]`. It must never drive. But `claimDriver()` asked
nobody, "Drive from Here" sat in its menu, and `mira drive` worked on its command
line. One stray claim on a passenger-only machine strands the fleet, and the
symptom points at the display.

Now: `mayDrive(roles:)` gates the claim, the daemon clears such a flag at start
so it cannot survive a reboot, and the menu offers "Passenger only — cannot
drive" instead of the wheel. All selftested.

**Read the mode before the pixels.** `mira status` on the machine that looks
wrong answers this in one line: a passenger that says `driving: false` and names
a canvas is being driven; anything else is an arbitration problem, not a
geometry one.
