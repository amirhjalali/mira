# Standalone hardening — boot resume, honest doctor, fleet hygiene

Date: 2026-07-28. Trigger: after a Pro reboot, MIRA reported healthy while no
passenger desktops were open; recovery attempts chased a phantom TCC re-grant.

## Root causes (measured, not guessed)

1. **Reboot forgets the session windows.** The `driving` flag survives a
   reboot, the daemon re-places rides, `mira status` says `driving: true` —
   but Jump session windows only open inside the menu app's Drive action.
   Nothing re-opens them at boot, and the menu app is not even a login item.
2. **Doctor's TCC probe lies over SSH.** `JumpConnect --dumpmacperm` executed
   from an SSH session reports every permission `false` regardless of the real
   grants (verified: system TCC.db shows `auth_value=2` while the SSH probe
   says `false`; the identical probe bootstrapped into `gui/$UID` reports
   `true`). The 2026-07-22 "26.5.2 stripped TCC" incident record was this
   artifact, not a real strip.

## Changes

### App (`app/MIRA.swift`)

- **Boot-resume**: menu app records the boot epoch (`kern.boottime`) in
  `sessions-opened` whenever it opens session windows. On launch, if
  `driving && viewer && marker != current boot`, it re-opens the windows after
  a short settle delay. Pure gate: `shouldResumeSessions()` (selftested).
- **Login item**: menu app registers itself via `SMAppService.mainApp` so it
  is present after every login — scroll reversal and boot-resume included.
- **Honest health probe**: every daemon (gui domain — truthful context) runs
  `dumpmacperm` locally every 5 minutes and writes
  `health.json` (`accessibility`, `screenRecording`, `ts`). Doctor reads that
  file instead of running `dumpmacperm` over SSH. Fresh-and-false → failure;
  missing/stale → advisory line, not a failure. Parser is pure + selftested.
- **Shared window opener**: `openSessionWindows()` free function used by menu
  Drive, boot-resume, a new "Reopen Session Windows" menu item, and CLI
  `mira drive` (best effort from a terminal; falls back with a hint).
- **Log location**: `repo/logs/` only when the repo checkout exists (dev
  machine); otherwise `~/Library/Logs/MIRA/` — passengers stop depending on a
  repo checkout entirely.

### Deploy (`deploy.sh`)

- **Deploys to the Pro too** (`local` target, included in the no-arg run):
  build → bundle → sign with the stable identity → install to
  `/Applications/MIRA.app` → restart daemon + menu app. Ends the stale-binary
  gap (the Pro was running a Jul 22 build while the repo moved on).
- Bundle name `MIRA`, version 2.1.
- Remote cleanup list gains the mini's v1 `com.gabooja.ultrawide.plist`.

### Fleet hygiene (one-time, done during rollout)

- Air: stale v1-era `~/mira` checkout moved aside (nothing references it once
  logs move to `~/Library/Logs/MIRA`).
- Mini: v1 `com.gabooja.ultrawide.plist` booted out and removed.

### Docs

- `STABILITY.md`: correct the 2026-07-22 record (probe artifact, not a TCC
  strip) and add today's incident + fixes.

## Non-goals

- No transport change (Jump Fluid stays; TCC grants were never actually lost).
- No MDM, no PPPC profiles.
- Walk-up/presence behavior untouched.
