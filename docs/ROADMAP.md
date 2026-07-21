# MIRA Roadmap

*2026-07-21. Where MIRA goes after the v2 consolidation.*

## Now shipped (v2, consolidated as plain MIRA)
One signed binary per Mac (menu app + reconciler daemon + CLI), native display
and audio engines, driver/passenger rides with TTL self-healing, walk-up
handback, dock-aware canvases, tier engine, per-machine session toggles,
Settings menu (scroll reversal, walk-up, HiDPI), fleet deploy.sh.

## Near term
- Passenger hygiene v2: static wallpaper + "Passenger" Focus while driven,
  restored on release.
- Windows fleet entries: generated .rdp files opened in the native Windows
  App, Space placement, live add/remove alongside Mac passengers.
- Settings depth: canvas overrides, tier thresholds, per-machine hygiene
  opt-outs — all in the Settings submenu, stored in ~/.config/mira/.
- LAN fallback for peer SSH (Tailscale is currently a single point of failure).
- Menu polish: per-passenger status glyphs (riding / walked-up / unreachable),
  live tier indicator.

## Experiment: MIRA transport (complement Jump, not replace it)
Decision 2026-07-21: Jump/Fluid stays the transport backbone indefinitely —
its input feel (client-side cursor, gestures, keyboard long-tail) and
lossy-network resilience represent years of tuning we should not re-fight,
and it covers RDP + iOS clients besides. MIRA transport is a curiosity spike
targeting the one niche we could win: Mac-to-Mac on the home LAN/tailnet,
exact-canvas capture + hardware HEVC at 2x HiDPI. Per-machine
`transport: "jump" | "mira"` keeps Jump as permanent fallback.

Architecture sketch:
- Capture: ScreenCaptureKit on the passenger's MIRA virtual display
  (we already own the display — capture is the easy half).
- Encode: VideoToolbox hardware HEVC/H.264, 10-60fps adaptive; tier engine
  already provides the bitrate/framerate policy.
- Transport: Network.framework over the existing tailnet (QUIC-style
  datagrams); input events (keyboard/mouse/scroll) on a reliable stream,
  video on unreliable datagrams; audio via the existing CoreAudio taps.
- Viewer: one NSWindow per passenger rendering the stream (Metal layer),
  input capture reusing the scroll-tap machinery.
- Migration: per-machine `transport: "jump" | "mira"` in machines.json —
  passengers can move one at a time; Jump remains the fallback until parity.

Milestone 0 for the protocol: a read-only viewer (no input) of the mini's
virtual display at 30fps over the tailnet — proves capture+encode+transport
in one spike before input handling.

## Deferred / parked
- MIRA2 transitional identity: retired 2026-07-21.
- BetterDisplay / displayplacer / Scroll Reverser: absorbed and uninstalled.
- v1 shell stack: attic/v1/ (reference only).
