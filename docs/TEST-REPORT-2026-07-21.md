# MIRA 2 — Automated Test Matrix Report

**Date:** 2026-07-21
**Operator:** automated matrix run (Pro `amirhjalali`, driving)
**Binaries:** Pro `/Applications/MIRA2.app/Contents/MacOS/MIRA2` (signed, "MIRA Signing"); air + mini `~/Applications/MIRA2.app/Contents/MacOS/MIRA2`
**Build health:** `bash tests/run2.sh` → `MIRA2 selftest: OK` (4 pure-function checks pass).

## Fleet at start
| machine | user | mode | driving |
|---|---|---|---|
| pro | amirhjalali | console | true (prior session) |
| air | amirjalali | passenger(ultrawide) | false |
| mini | gabooja | passenger(ultrawide) | false |

## Results

| T-id | Test | Status | Evidence |
|---|---|---|---|
| T9a | doctor positive | **PASS** | `doctor` → "Doctor: ready", exit 0. `✓ air/mini reachable`, `✓ air/mini daemon running`, `✓ no VNC session detected`. |
| T9b | doctor negative | **PASS** | `ssh mini launchctl unload …com.amir.mira2.plist` (daemon-gone) → Pro `doctor` = "✗ mini daemon not running", "Doctor: 1 failure(s)", exit 1. Reload (`launchctl load`, daemon-up) → `doctor` "Doctor: ready", exit 0. |
| T3 | stop | **PASS (1 caveat)** | Pro `stop` → "stopped — passengers return to console". Within 45s: air status=console, mini status=console (both `driving:false`). Pro `pgrep -x "Jump Desktop"` → JUMP-EMPTY. Pro console arrangement preserved: `BenQ EX3501R … Main Display: Yes, Mirror On (Master Mirror)`; `Color LCD … Mirror On (Hardware Mirror)` — Pro untouched (never a passenger). Audio: air Default Output = **MacBook Air Speakers** (built-in, restored by air's own daemon). **Caveat:** mini Default Output lingered on **Jump Desktop Audio** after stop — a side effect of the T9b daemon reload (see Findings #2); a normal console converge (`mini console` verb) correctly re-routed to **Mac mini Speakers**. |
| T1 | drive | **PASS (after transient)** | Pro `drive` → both "riding (ultrawide)", Pro `driving:true`. Jump sessions opened via the `openJumpSession` File▸Open Recent osascript pattern (real recent-entry names — see Findings #1). Within ~60s: air + mini status=`passenger(canvas: "ultrawide", hidpi: true)`; both report a `MIRA` display `3440 x 1440`, `Main Display: Yes`; audio on both = **Jump Desktop Audio**; Jump viewer window present on Pro ("MacBook Air" / "Mac Mini"). **Transient:** first `drive` returned `air: RIDE FAILED` because air's Tailscale peer path (100.118.137.45) was momentarily un-hole-punched (air awake & reachable on LAN throughout); it recovered ("active; direct 192.168.1.31") and the retry succeeded. |
| T10 | audio routing | **PASS (mini caveat)** | Passenger (T1): air + mini Default Output = **Jump Desktop Audio** ✓. Console (T3): air = **MacBook Air Speakers** ✓ (built-in transport, restored automatically by daemon). Mini console audio = **Mac mini Speakers** ✓ only after an explicit console converge; the daemon's fresh-start guard left it on Jump audio after the T9b reload (Findings #2). Passenger input route (Jump Desktop Microphone) selected per `pickAudioNames` selftest. |
| T5 | crash drill | **PASS** | Removed **only** the Pro `driving` flag (no `stop`; heartbeats simply cease). Within TTL+45s (135s): both passengers self-restored — air status=console (physical `1920 x 1080` main, **no MIRA display**), mini status=console (`800 x 600` placeholder main, **no MIRA display**). Virtual display destroyed on both. Re-ran the T1 drive sequence to end DRIVING — see Final State. |
| T8 | scroll reversal (menu app) | **FAIL (automatable) / manual feel-test pending** | Relaunched Pro menu app (`open -a /Applications/MIRA2.app`). `logs/mira2.log` shows `scroll tap creation failed (grant Accessibility)` at relaunch; **zero** occurrences of "scroll tap active". The CGEventTap needs Accessibility, which is not effective for the current app binary (grant lost after re-sign/redeploy — see Findings #3). Note: osascript Automation (File▸Open Recent) works — that is AppleEvents permission, distinct from Accessibility. Feel-test remains manual. |

## Final state (end of run)
**DRIVING.** Pro `status` = `machine: pro  mode: console  driving: true` (BenQ-main + built-in-mirror preserved). `drive` → both "riding (ultrawide)"; both Jump sessions re-opened ("ok"); Jump Desktop running on Pro. Both passengers converged to `passenger(ultrawide)` with `MIRA` `3440 x 1440` main and Jump Desktop Audio.

## Findings (real defects surfaced by the matrix)

1. **Jump recent-name mismatch breaks auto-open (production impact).** `MenuApp.drive()` calls `openJumpSession(t.jumpName)` with the config `jumpName` values `"Amir's Mac mini"` / `"Amir's MacBook Air"` (typographic U+2019). Jump Desktop's actual File▸Open Recent entries are **`"Mac Mini"`** and **`"MacBook Air"`**. The osascript therefore finds no matching menu item and returns `"missing"` (double-Escape, no session opened) — for **both** targets, on every drive. The automation itself is healthy (verified by enumerating the submenu and opening by the real names, which returned "ok" and produced live viewer windows). Fix: reconcile `machines[].jumpName` in `config/machines.json` with the actual Jump connection display names (or add a `jumpRecentName` field).

2. **Console-converge fresh-start guard can leave stale Jump audio.** `Reconciler.convergeConsole()` (app/MIRA2.swift ~645-648) returns early — skipping `routeAudio(false)` — when a daemon starts fresh into console (`lastMode == nil`, `virtualID == 0`, no arrangement file). If the machine's audio was left on "Jump Desktop Audio" by a prior passenger session (e.g. the daemon was restarted while a passenger, as in T9b), a fresh daemon that comes up in console never restores built-in output. Observed on mini after the T9b unload/reload; forcing `console` fixed it. Consider routing audio to built-in on the fresh-start path too (idempotent).

3. **Scroll-reversal Accessibility grant not effective for the deployed app.** The Pro menu app logs `scroll tap creation failed (grant Accessibility)` on launch and relaunch; no "scroll tap active" is ever emitted. TCC Accessibility is signature-bound and was not re-granted after the latest re-sign/redeploy of `/Applications/MIRA2.app`. Scroll reversal is currently inert until Accessibility is re-granted to the current binary.

4. **Tailscale peer path is a single point of drive failure (environmental).** `peerRun`/`placeRide` use the Tailscale IP only. When air's direct path was briefly un-established, `drive` reported `RIDE FAILED` even though air was awake and reachable on the LAN (`MacBook-Air-3.local`). It self-healed within the session. Not a code bug, but a resilience gap: a LAN/`.host` fallback would harden drive placement.

## MANUAL-REMAINING (not automatable — require physical presence / travel)

- **T2 undock:** unplug the Pro from the BenQ ultrawide and confirm the driver canvas falls back from `ultrawide` (docked) to `laptop-pro`, and passengers re-converge at the laptop canvas.
- **T4 walk-up lid test:** physically open a passenger laptop's lid (or generate a real input burst) and confirm the walk-up handback fires (`writeHandback` → immediate console converge), returning local control. Requires Input Monitoring granted (`walk-up input watch unavailable` currently logged).
- **T6 drive-from-Air travel drill:** drive the rig from the Air (as viewer) away from the home subnet; confirm tier hysteresis and remote ride placement over Tailscale from a non-Pro driver.
- **T7 laptop reboots:** reboot air and mini and confirm the LaunchAgent restarts the daemon, state dir is intact, and they re-accept rides without manual intervention.
- **T8 feel check:** with Accessibility re-granted, physically confirm wheel-mouse scroll direction is reversed and trackpad/Magic-Mouse continuous gestures are untouched.
