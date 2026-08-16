# MacBook Air 13" (M1) Fleet Onboarding Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Tasks 0–2 need a human at the new machine; run this plan when the Air is physically present.

**Goal:** Onboard a 13" MacBook Air M1 ("air13") into the MIRA fleet as a viewer+target that is a great grab-and-go laptop: fully usable standalone the moment it's picked up, drivable when docked at home, and self-healing on walk-up.

**Architecture:** Use the existing one-command onboarding (`add-machine.sh` → `deploy.sh --to`) which registers the machine in `config/machines.json`, authorizes SSH, and pushes the signed app + LaunchAgent. Then close the two gaps the scripts don't cover: the `deploy.sh` routine target table (hardcodes air/mini) and Jump aliases. Grab-and-go behavior comes free from MIRA's walk-up guard + handback hold; this plan verifies it end-to-end.

**Tech Stack:** bash (`add-machine.sh`, `deploy.sh`), Tailscale, Jump Desktop Connect, MIRA daemon.

## Global Constraints

- Machine id: `air13`. Jump name: `Amir's MacBook Air 13`. Canvas: `laptop-air13` (already in `config/machines.json` at 1440x900 hidpi — the M1 Air 13.3" default scaled resolution).
- **The unix username on air13 MUST be unique across the fleet** — `config/machines.json` says "A machine finds itself by unix user name." Taken: `amirhjalali` (pro), `amirjalali` (air), `gabooja` (mini). Recommended: `amir`. Wherever this plan says `$NEWUSER`, substitute the chosen name.
- Wherever this plan says `$TSIP`, substitute the Air's Tailscale IPv4 (known after Task 0).
- Roles: `viewer` + `target` (grab-and-go = usable as a standalone driver anywhere, drivable when docked).
- All fleet-side commands run from the Pro at `~/mira`.

---

### Task 0: Prepare the new Air (human, at the Air)

**Files:** none (machine setup only).

**Interfaces:**
- Produces: a unique unix username (`$NEWUSER`), a Tailscale IP (`$TSIP`), SSH reachability — consumed by Task 1.

- [ ] **Step 1: Clean install.** On the old install: System Settings → General → Transfer or Reset → **Erase All Content and Settings** (M1 supports this directly — no recovery-mode reinstall needed unless the OS itself is damaged; it wipes data while keeping the signed OS). If the machine was previously in Find My under another Apple ID, remove it there first so Activation Lock doesn't bite.
- [ ] **Step 2: macOS setup assistant.** Skip Migration Assistant (fresh machine, no baggage). Create the account with short name `$NEWUSER` (unique — see Global Constraints). Sign into iCloud. Run Software Update until current.
- [ ] **Step 3: Enable SSH.** System Settings → General → Sharing → Remote Login: on, for `$NEWUSER`.
- [ ] **Step 4: Install Tailscale** (App Store), sign in to the tailnet, then record the address:

```bash
/Applications/Tailscale.app/Contents/MacOS/Tailscale ip -4   # -> $TSIP
```

- [ ] **Step 5: Install Jump Desktop Connect** from <https://jumpdesktop.com/connect> (do not pair yet — Task 2 does that with a code).
- [ ] **Step 6: Grab-and-go basics** while you're there: FileVault on, Touch ID enrolled, Optimized Battery Charging on, Find My Mac on, and System Settings → Battery → Options → "Wake for network access" on (keeps it drivable while docked/asleep on power).
- [ ] **Step 7: Verify from the Pro** (password prompt expected — key comes in Task 1):

```bash
ping -c1 $TSIP && ssh -o PubkeyAuthentication=no $NEWUSER@$TSIP true
```

Expected: ping replies; ssh asks for the password and exits 0.

---

### Task 1: One-command onboarding from the Pro

**Files:**
- Modify: `config/machines.json` (script-driven append of the air13 entry)

**Interfaces:**
- Consumes: `$NEWUSER`, `$TSIP` from Task 0.
- Produces: air13 entry in `machines.json` with `roles: ["viewer","target"]`, `laptopCanvas: "laptop-air13"`; MIRA.app + LaunchAgent running on air13 — consumed by Tasks 2–5.

- [ ] **Step 1: Run the onboarder:**

```bash
cd ~/mira
bash add-machine.sh air13 $NEWUSER $TSIP "Amir's MacBook Air 13" --viewer laptop-air13
```

This ssh-copy-ids the key, appends the machines.json entry, and runs `deploy.sh --to air13 $NEWUSER $TSIP` (build + selftest gate, adhoc-signed bundle, LaunchAgent install, daemon start).

- [ ] **Step 2: Verify the daemon came up:**

```bash
ssh $NEWUSER@$TSIP 'pgrep -fl "MIRA --daemon" && tail -3 ~/mira-or-tmp 2>/dev/null; tail -3 /tmp/mira-daemon.log'
```

Expected: a `MIRA --daemon` pid and a fresh `mira daemon started on air13 (roles: ["viewer","target"])`-style line.

- [ ] **Step 3: Verify the config entry** (`python3 -c` or just look): `config/machines.json` now has the air13 block with the unique user. Do not commit yet — Task 3 adds aliases first.

---

### Task 2: Jump pairing + permission grants (human, at the Air)

**Files:** none (TCC + Jump state).

**Interfaces:**
- Consumes: Jump Desktop Connect installed (Task 0), daemon running (Task 1).
- Produces: air13 pairable/drivable over Jump; MIRA scroll tap working — consumed by Task 5.

- [ ] **Step 1: Pair Jump.** In the Pro's Jump Desktop app: + Add Computer → generate a connect code. On the Air:

```bash
"/Applications/Jump Desktop Connect.app/Contents/MacOS/JumpConnect" --connectcode <code>
```

- [ ] **Step 2: Grant Jump Connect its TCC prompts** (Screen Recording, Accessibility) when macOS asks.
- [ ] **Step 3: Grant Accessibility to MIRA.app** (System Settings → Privacy & Security → Accessibility) — required for the viewer-role scroll tap; the daemon logs `scroll tap creation failed (grant Accessibility)` until this is done, and `scroll tap active` after.
- [ ] **Step 4: Save passenger connections** in the Air's own Jump Desktop viewer: open + save connections to "Amir's MacBook Pro", "Amir's MacBook Air", "Amir's Mac mini" so it can drive the fleet.
- [ ] **Step 5: Verify:** from the Pro's Jump app, open "Amir's MacBook Air 13" — you should land on its desktop.

---

### Task 3: Jump aliases + config commit

**Files:**
- Modify: `config/machines.json` (air13 entry from Task 1)

**Interfaces:**
- Consumes: air13 entry (Task 1).
- Produces: committed fleet config with `jumpAliases` — consumed by alias-based session opening (`openJumpSession`) and Task 4's fleet deploy.

- [ ] **Step 1: Add aliases** to the air13 entry, matching the fleet convention (every other machine has `jumpAliases`; Jump sometimes registers the bare model name):

```json
"jumpAliases": ["MacBook Air 13", "Amir's MacBook Air 13"]
```

- [ ] **Step 2: Selftest gate** (config is validated by the selftest's config checks):

```bash
bash tests/run.sh build.noindex/mira
```

Expected: `MIRA selftest: OK`.

- [ ] **Step 3: Commit:**

```bash
git add config/machines.json
git commit -m "fleet: onboard air13 (M1 Air 13\") as viewer+target"
```

---

### Task 4: Add air13 to deploy.sh routine targets

**Files:**
- Modify: `deploy.sh:14-15` (target table), `deploy.sh:28` (no-arg TARGETS), `deploy.sh:32` (case pattern), `deploy.sh:263-265` (dispatch case)

**Interfaces:**
- Consumes: `$NEWUSER`, `$TSIP`.
- Produces: `bash deploy.sh` (no args) covers air13 forever after — without this, routine fleet deploys silently skip the new machine.

- [ ] **Step 1: Target table** — after the `mini_user` line add:

```bash
air13_user="$NEWUSER"; air13_host="$TSIP"
```

- [ ] **Step 2: No-arg fleet list** — change `TARGETS=(local air mini)` to:

```bash
  TARGETS=(local air mini air13)
```

- [ ] **Step 3: Named-target validation** — change the case pattern `local|air|mini)` to `local|air|mini|air13)` (both the validation case and the dispatch case at the bottom; give air13 an `adhoc` dispatch line like mini's):

```bash
    air13) deploy_one air13 "$air13_user" "$air13_host" adhoc || fail=1 ;;
```

- [ ] **Step 4: Verify single-target deploy:**

```bash
bash deploy.sh air13
```

Expected: ends `air13: OK`.

- [ ] **Step 5: Commit:**

```bash
git add deploy.sh
git commit -m "deploy: add air13 to routine fleet targets"
```

---

### Task 5: End-to-end ride + grab-and-go verification

**Files:** none (behavioral verification).

**Interfaces:**
- Consumes: everything above.
- Produces: a machine you can trust to grab and go.

- [ ] **Step 1: Fleet health:**

```bash
mira doctor
```

Expected: `air13 daemon running`, `air13 reachable`, no failures.

- [ ] **Step 2: Drive it.** From the Pro: `mira drive air13` (or open the Jump session). On convergence the Air's daemon log shows `passenger converged=true`; the session canvas is 1440x900 hidpi.
- [ ] **Step 3: Walk-up handback.** While driven, tap ~20 keys/trackpad events on the Air itself (`walkupInputEvents: 20`). Expected: session hands back, console restored — check that displays return to the pre-ride arrangement **at the captured resolution** (the SavedDisplay mode capture/restore fix from 2026-08-11 is in the deployed build), audio is off the Jump device, and the fleet respects the 10-minute `handbackHoldSeconds` before re-driving.
- [ ] **Step 4: Drive from it.** On the Air, open its saved Jump connection to the mini. Expected: scroll direction correct (scroll tap active), session opens by alias.
- [ ] **Step 5: Grab-and-go drill.** Unplug, close nothing, walk away, use it on another network for a few minutes; come home, dock/plug it. Expected: standalone use is untouched by MIRA (console mode), and once home + idle it's drivable again. Any misbehavior here is a bug — file it against `docs/STABILITY.md`.
- [ ] **Step 6: Push:**

```bash
git push
```

---

## Self-Review Notes

- Spec coverage: unique-username constraint (config discovery), canvas (pre-existing `laptop-air13`), onboarding script path, Jump pairing, TCC grants, aliases, deploy-table gap, ride + walk-up + grab-and-go verification — all have tasks.
- Deferred as YAGNI: no new canvas work (1440x900 already defined), no MIRA code changes needed, no doctor changes (it reads `machines.json`).
- Runtime inputs `$NEWUSER`/`$TSIP` are unknowable before Task 0 by design, not placeholders.
