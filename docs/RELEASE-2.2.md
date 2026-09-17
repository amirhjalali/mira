# Mira 2.2 — session reliability

Approved 2026-09-12: implement and deploy to Pro, Air 15, mini, and Air 13.

## Interaction

- **Drive from Here** is the explicit fleet takeover.
- **Use This Mac Locally** returns only this passenger to local use. The hold persists until explicit inclusion or a new driver session.
- Lid/keyboard handback, when enabled, has the same local-only effect. It remains default-off because the historical presence heuristics are unreliable.
- Passenger rows show observed readiness, connecting, local use or reconnecting. An excluded passenger is labelled Not included.
- Mouse reversal belongs to the physical-input machine. Passenger event taps pass input unchanged; duplicate app/daemon instances are refused.

## Architecture

The GUI and CLI send UUID-named atomic requests to one daemon. The daemon is the session-state and display owner. The fresh-process display helper performs mode, mirroring and main-origin changes as one transaction under that owner. CoreGraphics caches in the virtual-display-owning process proved unreliable for both modes and topology. Readiness likewise uses a fresh snapshot.

Each session is identified by driver + claim generation. Receivers persist the highest accepted generation and release tombstones. Delayed rides cannot revive a released session; delayed stops cannot release a newer one. Explicit re-inclusion is ordered against earlier release operations. Queued requests expire after 30 seconds. Authenticated peer transport uses existing SSH access.

Network operations run independently per peer with a single in-flight request per peer. Process groups have monotonic deadlines; stdout is drained while children run, bounded to 1 MiB. Children are reaped and descriptors closed. A sleeping peer cannot block the local display/control loop.

A heartbeat does not reset the display repair breaker. A different requested geometry or explicit recovery does. Lost driver contact preserves the picture; explicit stop/local use/new ownership still works. New virtual canvases retain the old object until success and roll back to it on failed resize. Console restoration retains its snapshot until geometry/mirror verification passes and stops automatic retries after three failures. New snapshots record persistent display identity as well as transient CG IDs.

The GUI measures the viewer in its proper context, requires two consistent observations, and ties them to the driving session and screen. Network quality does not repeatedly change desktop geometry. Fresh-process measurements verify both dimensions and backing pixel density before reporting readiness.

## Display backend decision

Air 13 currently has Jump Desktop **9.1.9**, while Pro and Air 15 have **10.15.16**. Jump's newer virtual-display controls require 10.12+. A Jump-owned trial therefore cannot establish compatibility with the active Air 13 driver as installed. This release retains the existing native backend and today's verified out-of-process mode-selection fix. Migration to Jump-owned displays remains conditional on a separate supported-version trial, including existing-window visibility and restoration; no unproven backend is enabled in production.

## Verification and deployment

`bash tests/run.sh` builds and runs legacy regressions, synthetic unposted scroll events, process timeout/output/descriptor tests, real control-handler sequences in isolated temporary state, and CLI parsing checks. No test input is posted into the live desktop.

`bash deploy.sh --build` creates a signed release and source/binary hash manifest. `bash deploy.sh --skip-build mini` stages and verifies it, preserves the prior app/config/agents, pins machine identity, restarts daemon and menu in the GUI launchd domain, and requires a fresh runtime report from this build. Run `bash deploy.sh --verify-switch mini` before repeating for air15, pro, air13. The latter deployments refuse to run without a passing, recent receipt bound to the exact canary binary.

Rollback: run `scripts/rollback.sh 20260914.7` on the affected Mac. Previous bundles are under `~/Library/Application Support/MIRA/releases/20260914.7-before/`. Existing rides are retained through deployment; expect a short virtual-display rebuild during each passenger restart. No Mac is rebooted.

The requested four-machine rollout overrides the old one-day canary delay for this release. It does not prove a full day of stability. Hardware dock/lid cycles, the user's actual mouse feel, and long-duration behavior require subsequent observation.

## September 14 driver-switch regression

The first rollout's startup and protocol checks missed a live canvas replacement failure. Switching from Air 13 to the Pro left Air 15 and Mini at the old resolution. Retaining the old virtual display exposed three assumptions: a replacement reused its serial identity, both canvases competed for the main origin, and the owner process could report stale bounds after the fresh helper successfully selected Retina mode.

The correction gives each virtual display a distinct identity, uses a fresh helper to move the retained display aside, select the requested mode, mirror the physical displays, and promote the replacement in one transaction. It verifies geometry and main/mirror topology with a fresh snapshot. Only explicitly retained live display objects participate; stale cached IDs cannot re-enter the transaction. Creation publishes the requested canvas once instead of rebuilding because the owner's mode cache is unreadable. Failed replacements retain the previous canvas and its observed density through restoration.

The repeatable live acceptance test switches Mini between 1280×800 at 2x and 3440×1440 at 1x, restores the original request, requires one unchanged daemon PID, and checks that stale rides/releases cannot displace the owner. A signed build that only starts successfully is insufficient for fleet deployment. This covers the failure observed here; real changes of driver, docking, sleep/wake, and Jump versions still belong in release observation.

## Final verification — build 20260914.7

All four machines were checked on this exact signed binary. The Mini passed four successive live canvas transitions without restarting (1280×800 at 2x, 3440×1440 at 1x, then both again); each converged in roughly two seconds. Stale ride and release requests preserved the Pro session. A later real handoff to Air 13 was also observed: Pro, Air 15 and Mini all reported 1280×800 points and 2560×1600 backing pixels while Air 13 drove.

The final fleet check verifies fresh daemon state, matching binary SHA256, exactly one menu process and one daemon per Mac, and Accessibility/scroll-tap health on viewer machines. See [machine-readable evidence](RELEASE-2.2-VERIFICATION.json). The deployment script also retries missing launchd registrations during bounded post-install verification; a launchd removal/bootstrap race occurred on Pro and Air 13 during this rollout and was recovered without resetting session state.
