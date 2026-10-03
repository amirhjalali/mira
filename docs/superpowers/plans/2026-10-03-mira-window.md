# MIRA Window Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give MIRA a native window that shows every Mac and Windows PC in the rig: role, live sessions with stale ones flagged, audio route, screen layout and health. From the window you can connect to any machine and fix the faults it shows.

**Architecture:** Facts that only the logged-in GUI session can see (screens, open Jump viewer windows, audio devices, Windows App TCP sessions) are written every 5 s by the menu-bar app to `local-status.json`. A new short-lived CLI verb, `MIRA inspect-machine`, merges that file with `runtime.json`, `health.json` and fresh `ps` data into one `MachineStatus` JSON. The window runs the verb locally or over the existing SSH `peerRun`, and polls every Mac every 5 s while it is visible. Windows PCs are probed on the polling Mac with `tailscale status --json` and the `lsof` output already gathered.

**Tech Stack:** Swift 5 (single concatenated compile via `swiftc`), AppKit menu app, SwiftUI view in an `NSHostingController`, CoreGraphics, CoreAudio, SSH via `peerRun`.

**Spec:** `docs/superpowers/specs/2026-10-03-mira-window-design.md`

## Global Constraints

- Product name is **MIRA**; there is no "Fleet" in user-visible strings. The menu item is `Open MIRA…` and the window title is `MIRA`.
- Windows PCs live in a new optional top-level `windowsPCs` array, **not** in `machines`. Several loops send SSH control messages to every entry in `machines` (`Reliability.swift:171`, `MIRA.swift:2498`). Old binaries `fatalError` on a `machines` entry that is missing a Mac-only field, while an unknown top-level key is ignored by `JSONDecoder`.
- The daemon has no run loop and must never be the source of display facts (2026-09-16). An SSH process sees **no** screens (verified 2026-10-03: `inspect-screens` over SSH printed `{"widths":[]}`). Screen data comes only from the menu app.
- Display verdicts may be `ok`, `wrong` or `unknown`. Unreadable or stale means `unknown`, never `wrong` (392d86a).
- Killing a stale Jump session is done on the Mac that holds the **viewer**. A host-side kill reconnects within 1 s (2026-10-01 Agent log, 08:42:49).
- New control kinds must be inert under `MIRA_STATE_DIR` so tests never touch real sessions, audio or displays.
- New top-level globals use computed `var x: URL { … }`, never `let`. The sources are concatenated, and a `let` placed before `MIRA.swift` would initialise before `stateDir` exists.
- `miraBuild` (app/Reliability.swift) and `BUILD` (scripts/release.py) are bumped together. release.py refuses to build otherwise.
- Machine ids: `rig3090` (3090 Desktop, 100.78.167.19:1337, desktop-iki1670), `amelie` (Amelie's Desktop, 100.64.135.60:1338, desktop-aeefjre), `ace` (Ace Mini PC, 100.101.253.21, win-slk2vhu7sbe, RDP port 3389).
- Only the Pro sets `mirrorDocked: true`. Only a Mac with that flag is judged on "external is main and the built-in mirrors it".

## Review Focus

1. **The menu app is not running on a Mac** (crashed, not logged in): `local-status.json` goes stale, so the card must say "MIRA menu app not reporting" with display `unknown`. It must not show stale screens as current. → Task 4 test `machineStatus: stale local status gives unknown display`.
2. **A Mac is unreachable mid-poll** (asleep, off Tailscale): the card greys out, keeps the last snapshot and shows when it was last seen. The window does not hang, because each poll is bounded and at most one is in flight per Mac. → Task 6 (model) plus the live check in Task 7.
3. **The current driver's own sessions are never "stale"**, so there is no Kill button on the Pro's sessions while it drives. → Task 3 test `stale: the driver's own viewer is not stale`.
4. **`tailscale` is missing or its JSON changes shape**: Windows cards show `unknown` rather than crashing or claiming offline. → Task 3 test `tailscale: garbage gives no verdicts`.
5. **A Jump window title that is not a machine** ("Computers", "Minimize", "Zoom"): it is never shown as a session. → Task 3 test `outbound: menu noise is ignored`.

---

### Task 1: Config — Windows PCs and per-Mac layout preference; build wiring

**Files:**
- Modify: `app/MIRA.swift:83-111` (Machine, Config)
- Modify: `config/machines.json`
- Create: `app/Status.swift` (header only in this task)
- Modify: `tests/run.sh:7` (source list)
- Modify: `scripts/release.py` (`build()` inputs and manifest source lists)
- Test: `app/MIRA.swift` selftest

**Interfaces:**
- Produces: `struct WindowsPC: Codable { let id: String; let name: String; let tailscale: String; let tailscaleName: String; let rdpPort: Int? }`, `Config.windowsPCs: [WindowsPC]?`, `Machine.mirrorDocked: Bool?`, `func rdpEndpoint(_ pc: WindowsPC) -> String`

- [ ] **Step 1: Write the failing test** (selftest, after the scroll-owner checks)

```swift
    // MIRA window: Windows PCs are a separate list so no SSH loop over
    // `machines` can ever reach them.
    let winJSON = #"{"id":"x","name":"X","tailscale":"100.1.2.3","tailscaleName":"x","rdpPort":1337}"#
    let pc = try! JSONDecoder().decode(WindowsPC.self, from: Data(winJSON.utf8))
    expect(rdpEndpoint(pc) == "100.1.2.3:1337", "windows: endpoint uses the configured port")
    let pc2 = WindowsPC(id: "y", name: "Y", tailscale: "100.1.2.4", tailscaleName: "y", rdpPort: nil)
    expect(rdpEndpoint(pc2) == "100.1.2.4:3389", "windows: endpoint defaults to 3389")
    expect(!(cfg.windowsPCs ?? []).contains { pc in cfg.machines.contains { $0.id == pc.id } },
           "windows: no PC id collides with a Mac")
```

- [ ] **Step 2: Run to verify failure.** Run `bash tests/run.sh`. Expected: compile error `cannot find 'WindowsPC' in scope`.

- [ ] **Step 3: Implement**

In `app/MIRA.swift`, add the following to `Machine`, after `jumpAliases`:
```swift
    let mirrorDocked: Bool?       // docked: external main, built-in mirrors it (pro)
```
Add the following to `Config`, after `homeGatewayMAC`:
```swift
    // Watched and launched only: never in `machines`, so no SSH loop reaches them.
    let windowsPCs: [WindowsPC]?
```
Create `app/Status.swift`:
```swift
// MIRA window data: what each machine reports, and the pure rules that judge it.
// Compiled together with Reliability.swift and MIRA.swift by tests/run.sh.
import AppKit
import CoreAudio
import Foundation

struct WindowsPC: Codable {
    let id: String
    let name: String
    let tailscale: String
    let tailscaleName: String
    let rdpPort: Int?
}

func rdpEndpoint(_ pc: WindowsPC) -> String { "\(pc.tailscale):\(pc.rdpPort ?? 3389)" }
```
In `tests/run.sh`, change the concatenation line to:
```bash
cat "$REPO_ROOT/app/Reliability.swift" "$REPO_ROOT/app/Status.swift" "$REPO_ROOT/app/Window.swift" "$REPO_ROOT/app/MIRA.swift" > "$OUT.sources.swift"
```
Also create `app/Window.swift` with just `// MIRA window UI. Compiled with the other sources by tests/run.sh.\nimport SwiftUI\n`, so the build list is final.

In `scripts/release.py`, both `inputs=[…]` in `build()` and the `manifest` sources list become:
```python
[ROOT/'app/MIRA.swift',ROOT/'app/Reliability.swift',ROOT/'app/Status.swift',ROOT/'app/Window.swift',ROOT/'app/shim.h',ROOT/'config/machines.json']
```
In `config/machines.json`, add `"mirrorDocked": true` to the `pro` entry, and a top-level key after `machines`:
```json
  "windowsPCs": [
    {"id": "rig3090", "name": "3090 Desktop", "tailscale": "100.78.167.19", "tailscaleName": "desktop-iki1670", "rdpPort": 1337},
    {"id": "amelie", "name": "Amelie's Desktop", "tailscale": "100.64.135.60", "tailscaleName": "desktop-aeefjre", "rdpPort": 1338},
    {"id": "ace", "name": "Ace Mini PC", "tailscale": "100.101.253.21", "tailscaleName": "win-slk2vhu7sbe"}
  ]
```

- [ ] **Step 4: Run to verify pass.** Run `bash tests/run.sh`. Expected: `MIRA selftest: OK`, `Control integration: OK`, exit 0.

- [ ] **Step 5: Commit** — `git add app config tests scripts && git commit -m "Windows PCs join the config as watch-only; Status/Window sources in the build"`

---

### Task 2: Local status — what the menu app sees, written every 5 s

**Files:**
- Modify: `app/Status.swift`
- Modify: `app/MIRA.swift` (MenuApp: a 5 s timer in `applicationDidFinishLaunching`)
- Test: selftest

**Interfaces:**
- Produces:
  - `struct ScreenInfo: Codable, Equatable { let w: Int; let h: Int; let main: Bool; let builtIn: Bool; let mirrorsMain: Bool }`
  - `struct LocalStatus: Codable { let ts: Double; let screens: [ScreenInfo]; let output: String?; let input: String?; let jumpWindows: [String]?; let rdpEndpoints: [String] }`
  - `var localStatusFile: URL`
  - `func parseLsofEndpoints(_ out: String) -> [String]`
  - `func captureLocalStatus(includeJumpWindows: Bool) -> LocalStatus`

- [ ] **Step 1: Write the failing test**

```swift
    let lsof = """
    COMMAND  PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
    Windows 1102 amir   28u  IPv4 0x36   0t0  TCP 100.91.23.16:60895->100.78.167.19:1337 (ESTABLISHED)
    Windows 1102 amir   29u  IPv4 0x37   0t0  TCP 192.168.1.5:50000->20.26.121.2:3389 (ESTABLISHED)
    """
    expect(parseLsofEndpoints(lsof) == ["100.78.167.19:1337", "20.26.121.2:3389"],
           "lsof: remote endpoints of established Windows App connections")
    expect(parseLsofEndpoints("") == [], "lsof: nothing open is an empty list")
```

- [ ] **Step 2: Run to verify failure.** `bash tests/run.sh`, expected compile error `cannot find 'parseLsofEndpoints'`.

- [ ] **Step 3: Implement** (append to `app/Status.swift`)

```swift
// Written by the menu app every 5 s. It is the ONLY process that can see the
// screens: the daemon has no run loop (stale display list, 2026-09-16) and an
// SSH process sees none at all (2026-10-03).
struct ScreenInfo: Codable, Equatable {
    let w: Int; let h: Int; let main: Bool; let builtIn: Bool; let mirrorsMain: Bool
}
struct LocalStatus: Codable {
    let ts: Double
    let screens: [ScreenInfo]
    let output: String?
    let input: String?
    let jumpWindows: [String]?   // nil = Jump's Window menu was unreadable
    let rdpEndpoints: [String]   // Windows App connections, "ip:port"
}
var localStatusFile: URL { stateDir.appendingPathComponent("local-status.json") }

// Pure, selftested.
func parseLsofEndpoints(_ out: String) -> [String] {
    out.components(separatedBy: "\n").compactMap { line in
        guard line.contains("(ESTABLISHED)"), let arrow = line.range(of: "->") else { return nil }
        let rest = line[arrow.upperBound...]
        return rest.split(separator: " ").first.map(String.init)
    }
}

func currentDefaultInputName() -> String? {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var dev: AudioDeviceID = 0
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                     &addr, 0, nil, &size, &dev) == noErr, dev != 0 else { return nil }
    return listAudioDevices().first { $0.id == dev }?.name
}

func captureLocalStatus(includeJumpWindows: Bool) -> LocalStatus {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var n: UInt32 = 0
    CGGetOnlineDisplayList(16, &ids, &n)
    let physical = ids.prefix(Int(n)).filter { CGDisplayVendorNumber($0) != miraVendorID }
    let main = CGMainDisplayID()
    let screens = physical.map { d -> ScreenInfo in
        let mode = CGDisplayCopyDisplayMode(d)
        return ScreenInfo(w: mode?.width ?? Int(CGDisplayBounds(d).width),
                          h: mode?.height ?? Int(CGDisplayBounds(d).height),
                          main: d == main, builtIn: CGDisplayIsBuiltin(d) != 0,
                          mirrorsMain: CGDisplayMirrorsDisplay(d) == main)
    }
    let lsof = sh("lsof -nP -iTCP -sTCP:ESTABLISHED -c Windows 2>/dev/null", timeout: 5).out
    return LocalStatus(ts: Date().timeIntervalSince1970, screens: screens,
                       output: currentDefaultOutputName(), input: currentDefaultInputName(),
                       jumpWindows: includeJumpWindows ? openJumpWindowTitles() : nil,
                       rdpEndpoints: parseLsofEndpoints(lsof))
}
```

In `MenuApp.applicationDidFinishLaunching`, after the 3 s timer:
```swift
        // What only this GUI session can see, for `mira inspect-machine` over SSH.
        // Jump's Window menu is AppleScript: read it every third beat (15 s).
        var beat = 0
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            beat += 1
            let withWindows = beat % 3 == 1
            DispatchQueue.global(qos: .utility).async {
                var s = captureLocalStatus(includeJumpWindows: withWindows)
                if !withWindows, let prev = readJSON(LocalStatus.self, localStatusFile) {
                    s = LocalStatus(ts: s.ts, screens: s.screens, output: s.output, input: s.input,
                                    jumpWindows: prev.jumpWindows, rdpEndpoints: s.rdpEndpoints)
                }
                try? atomicJSON(s, to: localStatusFile)
            }
        }
```

- [ ] **Step 4: Run to verify pass.** `bash tests/run.sh`, exit 0.
- [ ] **Step 5: Commit** — `git commit -am "Menu app publishes what only the GUI session can see"`

---

### Task 3: The pure rules — sessions, staleness, audio, display, Tailscale, process age

**Files:**
- Modify: `app/Status.swift`
- Test: selftest

**Interfaces:**
- Produces:
  - `func outboundMachines(titles: [String], cfg: Config, me: String) -> [String]`
  - `func sessionIsStale(holder: String, driver: String?) -> Bool`
  - `func audioWarning(role: String, output: String?, input: String?) -> String?`
  - `func displayVerdict(role: String, runtimeState: String, runtimeDetail: String, screens: [ScreenInfo]?, mirrorDocked: Bool, snapshotPending: Bool) -> (verdict: String, detail: String)`
  - `func parseTailscale(_ json: String) -> [String: (online: Bool, lastSeen: String?)]` (keyed by Tailscale IP)
  - `func parseEtime(_ s: String) -> Double?`

- [ ] **Step 1: Write the failing tests** (selftest)

```swift
    // outbound sessions come from Jump's Window menu titles
    let titles = ["Computers", "Minimize", "Zoom", "Mac Mini", "MacBook Air", "Bring All to Front"]
    let out = outboundMachines(titles: titles, cfg: cfg, me: "pro")
    expect(out.contains("mini"), "outbound: alias title maps to the machine")
    expect(!out.contains { ["Computers", "Minimize", "Zoom"].contains($0) }, "outbound: menu noise is ignored")
    expect(!out.contains("pro"), "outbound: never this Mac itself")
    // staleness: 2026-10-01, air13 kept a session into the pro the pro was driving from
    expect(sessionIsStale(holder: "air13", driver: "pro"), "stale: a non-driver's viewer is stale")
    expect(!sessionIsStale(holder: "pro", driver: "pro"), "stale: the driver's own viewer is not stale")
    expect(sessionIsStale(holder: "air13", driver: nil), "stale: nobody driving means any viewer is stale")
    // audio
    expect(audioWarning(role: "local", output: "Jump Desktop Audio", input: "MacBook Pro Microphone") != nil,
           "audio: Jump output on a Mac nobody drives is flagged")
    expect(audioWarning(role: "driver", output: "AirPods", input: "Jump Desktop Microphone") != nil,
           "audio: Jump mic on the driver is flagged")
    expect(audioWarning(role: "passenger", output: "Jump Desktop Audio", input: "Jump Desktop Microphone") == nil,
           "audio: passenger routed through Jump is fine")
    expect(audioWarning(role: "passenger", output: "AirPods", input: nil) != nil,
           "audio: passenger not routed through Jump is flagged")
    expect(audioWarning(role: "local", output: "AirPods", input: "AirPods") == nil, "audio: normal local use is fine")
    // display
    let benq = ScreenInfo(w: 3440, h: 1440, main: true, builtIn: false, mirrorsMain: false)
    let panelMirror = ScreenInfo(w: 3440, h: 1440, main: false, builtIn: true, mirrorsMain: true)
    let panelExtend = ScreenInfo(w: 1728, h: 1117, main: false, builtIn: true, mirrorsMain: false)
    expect(displayVerdict(role: "driver", runtimeState: "driving", runtimeDetail: "", screens: [benq, panelMirror],
                          mirrorDocked: true, snapshotPending: false).verdict == "ok", "display: docked pro mirrored is ok")
    expect(displayVerdict(role: "driver", runtimeState: "driving", runtimeDetail: "", screens: [benq, panelExtend],
                          mirrorDocked: true, snapshotPending: false).verdict == "wrong", "display: docked pro extended is wrong")
    expect(displayVerdict(role: "local", runtimeState: "local", runtimeDetail: "", screens: [benq, panelExtend],
                          mirrorDocked: false, snapshotPending: false).verdict == "ok", "display: extended is fine where not preferred")
    expect(displayVerdict(role: "local", runtimeState: "local", runtimeDetail: "", screens: [benq, panelMirror],
                          mirrorDocked: true, snapshotPending: true).verdict == "wrong", "display: retained snapshot is wrong")
    expect(displayVerdict(role: "local", runtimeState: "local", runtimeDetail: "", screens: nil,
                          mirrorDocked: true, snapshotPending: false).verdict == "unknown", "display: no fresh screens is unknown")
    expect(displayVerdict(role: "passenger", runtimeState: "needs-attention", runtimeDetail: "Virtual display is not main",
                          screens: [], mirrorDocked: false, snapshotPending: false) == ("wrong", "Virtual display is not main"),
           "display: passenger takes the daemon's verdict")
    // tailscale
    let ts = #"{"Peer":{"k1":{"TailscaleIPs":["100.78.167.19","fd7a::1"],"Online":true,"LastSeen":"2026-10-03T10:00:00Z"},"k2":{"TailscaleIPs":["100.101.253.21"],"Online":false,"LastSeen":"2026-08-09T10:00:00Z"}}}"#
    let parsed = parseTailscale(ts)
    expect(parsed["100.78.167.19"]?.online == true, "tailscale: online peer")
    expect(parsed["100.101.253.21"]?.online == false && parsed["100.101.253.21"]?.lastSeen == "2026-08-09T10:00:00Z",
           "tailscale: offline peer keeps last seen")
    expect(parseTailscale("not json").isEmpty, "tailscale: garbage gives no verdicts")
    // ps etime
    expect(parseEtime("02-05:03:35") == 2 * 86400 + 5 * 3600 + 3 * 60 + 35, "etime: days")
    expect(parseEtime("13:17:36") == 13 * 3600 + 17 * 60 + 36, "etime: hours")
    expect(parseEtime("05:09") == 309, "etime: minutes")
    expect(parseEtime("x") == nil, "etime: garbage")
```

- [ ] **Step 2: Run to verify failure.** Compile errors for each new function.

- [ ] **Step 3: Implement** (append to `app/Status.swift`)

```swift
// MARK: - Pure rules (selftested)

// Jump's Window menu lists every viewer window by title; only titles that name
// a Mac in the config are sessions (the rest is menu furniture).
func outboundMachines(titles: [String], cfg: Config, me: String) -> [String] {
    var out: [String] = []
    for m in cfg.machines where m.id != me {
        let names = [m.jumpName] + (m.jumpAliases ?? [])
        if titles.contains(where: { names.contains($0) }), !out.contains(m.id) { out.append(m.id) }
    }
    return out
}

// 2026-10-01: a session held by any Mac other than the current driver is a leftover.
func sessionIsStale(holder: String, driver: String?) -> Bool { holder != driver }

func audioWarning(role: String, output: String?, input: String?) -> String? {
    let jumpOut = output?.hasPrefix("Jump Desktop") == true
    let jumpIn = input?.hasPrefix("Jump Desktop") == true
    if role == "passenger" { return jumpOut ? nil : "Sound is not going through Jump" }
    if jumpIn { return "Jump microphone selected — remote audio can loop back" }
    if jumpOut { return "Sound is going to Jump, not this Mac" }
    return nil
}

func displayVerdict(role: String, runtimeState: String, runtimeDetail: String, screens: [ScreenInfo]?,
                    mirrorDocked: Bool, snapshotPending: Bool) -> (verdict: String, detail: String) {
    if role == "passenger" {
        switch runtimeState {
        case "ready": return ("ok", "Matches the driver")
        case "needs-attention": return ("wrong", runtimeDetail)
        default: return ("unknown", runtimeDetail)
        }
    }
    if snapshotPending { return ("wrong", "A display layout restore is pending") }
    guard let screens = screens, !screens.isEmpty else { return ("unknown", "No fresh screen report") }
    let external = screens.filter { !$0.builtIn }
    guard mirrorDocked, !external.isEmpty else { return ("ok", summary(screens)) }
    let widest = external.max { $0.w * $0.h < $1.w * $1.h }!
    if !widest.main { return ("wrong", "The external screen is not main") }
    if screens.contains(where: { !$0.main && !$0.mirrorsMain }) { return ("wrong", "Screens are extended, not mirrored") }
    return ("ok", summary(screens))
}

private func summary(_ screens: [ScreenInfo]) -> String {
    let main = screens.first { $0.main }.map { "\($0.w)×\($0.h) main" } ?? "no main"
    let mirrored = screens.filter { $0.mirrorsMain }.count
    return mirrored > 0 ? "\(main), \(mirrored) mirrored" : "\(main), \(screens.count) screen(s)"
}

func parseTailscale(_ json: String) -> [String: (online: Bool, lastSeen: String?)] {
    guard let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
          let peers = root["Peer"] as? [String: Any] else { return [:] }
    var out: [String: (online: Bool, lastSeen: String?)] = [:]
    for case let p as [String: Any] in peers.values {
        let online = p["Online"] as? Bool ?? false
        for case let ip as String in (p["TailscaleIPs"] as? [Any] ?? []) {
            out[ip] = (online, p["LastSeen"] as? String)
        }
    }
    return out
}

// `ps -o etime`: [[dd-]hh:]mm:ss
func parseEtime(_ s: String) -> Double? {
    let t = s.trimmingCharacters(in: .whitespaces)
    var days = 0.0, clock = Substring(t)
    if let dash = t.firstIndex(of: "-") {
        guard let d = Double(t[..<dash]) else { return nil }
        days = d; clock = t[t.index(after: dash)...]
    }
    let parts = clock.split(separator: ":").map { Double($0) }
    guard (2...3).contains(parts.count), !parts.contains(where: { $0 == nil }) else { return nil }
    let v = parts.map { $0! }
    let secs = v.count == 3 ? v[0] * 3600 + v[1] * 60 + v[2] : v[0] * 60 + v[1]
    return days * 86400 + secs
}
```

- [ ] **Step 4: Run to verify pass.** `bash tests/run.sh`, exit 0.
- [ ] **Step 5: Commit** — `git commit -am "The rules MIRA's window judges machines by, pure and selftested"`

---

### Task 4: `mira inspect-machine` — one MachineStatus per Mac, readable over SSH

**Files:**
- Modify: `app/Status.swift`
- Modify: `app/MIRA.swift` (CLI `switch`: new `case "inspect-machine"`)
- Modify: `app/Reliability.swift:115-125` (`remoteControl` uses the shared exec command)
- Test: selftest

**Interfaces:**
- Consumes: Task 2 `LocalStatus`, `localStatusFile`; Task 3 rules.
- Produces:
  - `struct SessionLink: Codable, Equatable { let peer: String; let stale: Bool }`
  - `struct MachineStatus: Codable { let machine, build: String; let ts: Double; let role: String; let driver: String?; let outbound: [SessionLink]?; let inboundCount: Int; let inboundOldestSeconds: Double?; let output, input, audioWarning: String?; let display: String; let displayDetail: String; let screens: [ScreenInfo]?; let rdpEndpoints: [String]; let warnings: [String] }`
  - `func buildMachineStatus(cfg: Config, me: Machine, runtime: RuntimeSnapshot?, local: LocalStatus?, health: Health?, inboundAges: [Double], driver: String?, snapshotPending: Bool, now: Double) -> MachineStatus` (pure)
  - `func miraExec(_ args: String) -> String` (the remote shell command)

- [ ] **Step 1: Write the failing tests**

```swift
    let me13 = cfg.machines.first { $0.id == "air13" }!
    let rt = RuntimeSnapshot(machine: "air13", build: miraBuild, pid: 1, ts: 1000, role: "local", session: nil,
                             state: "local", detail: "", width: nil, height: nil, pixelWidth: nil, pixelHeight: nil, fdCount: 5)
    let fresh = LocalStatus(ts: 1000, screens: [], output: "MacBook Air Speakers", input: "MacBook Air Microphone",
                            jumpWindows: ["Amir’s MacBook Pro"], rdpEndpoints: [])
    let st = buildMachineStatus(cfg: cfg, me: me13, runtime: rt, local: fresh, health: nil, inboundAges: [],
                                driver: "pro", snapshotPending: false, now: 1005)
    expect(st.outbound == [SessionLink(peer: "pro", stale: true)], "machineStatus: air13's session into the driving pro is stale")
    let old = LocalStatus(ts: 900, screens: [], output: nil, input: nil, jumpWindows: nil, rdpEndpoints: [])
    let st2 = buildMachineStatus(cfg: cfg, me: me13, runtime: rt, local: old, health: nil, inboundAges: [],
                                 driver: "pro", snapshotPending: false, now: 1005)
    expect(st2.display == "unknown" && st2.warnings.contains("MIRA menu app not reporting"),
           "machineStatus: stale local status gives unknown display")
    let st3 = buildMachineStatus(cfg: cfg, me: me13, runtime: nil, local: fresh, health: Health(accessibility: false, screenRecording: true, ts: 1000),
                                 inboundAges: [100, 50_000], driver: "pro", snapshotPending: false, now: 1005)
    expect(st3.warnings.contains("MIRA daemon not reporting") && st3.warnings.contains("Jump Connect lost Accessibility"),
           "machineStatus: daemon and permission warnings")
    expect(st3.inboundCount == 2 && st3.inboundOldestSeconds == 50_000, "machineStatus: inbound sessions counted with oldest age")
    let rt0 = try! JSONEncoder().encode(st)
    expect((try? JSONDecoder().decode(MachineStatus.self, from: rt0)) != nil, "machineStatus: JSON round-trip")
```

(If config has no `air13` `jumpName` "Amir’s MacBook Pro" alias for pro, the pro's `jumpName` is matched. The config's pro `jumpName` is `Amir’s MacBook Pro`.)

- [ ] **Step 2: Run to verify failure.** Compile errors for `MachineStatus`, `buildMachineStatus`.

- [ ] **Step 3: Implement** (append to `app/Status.swift`)

```swift
// MARK: - MachineStatus

struct SessionLink: Codable, Equatable { let peer: String; let stale: Bool }
struct MachineStatus: Codable {
    let machine: String
    let build: String
    let ts: Double
    let role: String                  // driver | passenger | local | unknown
    let driver: String?
    let outbound: [SessionLink]?      // nil = this Mac's viewer windows unknown
    let inboundCount: Int
    let inboundOldestSeconds: Double?
    let output: String?
    let input: String?
    let audioWarning: String?
    let display: String               // ok | wrong | unknown
    let displayDetail: String
    let screens: [ScreenInfo]?
    let rdpEndpoints: [String]
    let warnings: [String]
}

// Pure: everything already read, judged here.
func buildMachineStatus(cfg: Config, me: Machine, runtime: RuntimeSnapshot?, local: LocalStatus?, health: Health?,
                        inboundAges: [Double], driver: String?, snapshotPending: Bool, now: Double) -> MachineStatus {
    var warnings: [String] = []
    let rt = runtime.flatMap { now - $0.ts < 30 ? $0 : nil }
    if rt == nil { warnings.append("MIRA daemon not reporting") }
    let loc = local.flatMap { now - $0.ts < 30 ? $0 : nil }
    if loc == nil { warnings.append("MIRA menu app not reporting") }
    if let h = health {
        if !h.accessibility { warnings.append("Jump Connect lost Accessibility") }
        if !h.screenRecording { warnings.append("Jump Connect lost Screen Recording") }
    }
    let role = rt?.role ?? "unknown"
    let outbound = loc?.jumpWindows.map { titles in
        outboundMachines(titles: titles, cfg: cfg, me: me.id)
            .map { SessionLink(peer: $0, stale: sessionIsStale(holder: me.id, driver: driver)) }
    }
    let verdict = loc == nil
        ? (verdict: "unknown", detail: "No fresh screen report")
        : displayVerdict(role: role, runtimeState: rt?.state ?? "unknown", runtimeDetail: rt?.detail ?? "",
                         screens: loc?.screens, mirrorDocked: me.mirrorDocked == true, snapshotPending: snapshotPending)
    return MachineStatus(machine: me.id, build: rt?.build ?? runtime?.build ?? "?", ts: now, role: role, driver: driver,
                         outbound: outbound, inboundCount: inboundAges.count, inboundOldestSeconds: inboundAges.max(),
                         output: loc?.output, input: loc?.input,
                         audioWarning: loc == nil ? nil : audioWarning(role: role, output: loc?.output, input: loc?.input),
                         display: verdict.verdict, displayDetail: verdict.detail, screens: loc?.screens,
                         rdpEndpoints: loc?.rdpEndpoints ?? [], warnings: warnings)
}

// Inbound Jump sessions: one `JumpConnect --desktopproxy` per live session.
func inboundSessionAges() -> [Double] {
    sh("ps -Ao etime=,command= | grep 'JumpConnect --desktopproxy' | grep -v grep", timeout: 5).out
        .components(separatedBy: "\n")
        .compactMap { $0.trimmingCharacters(in: .whitespaces).split(separator: " ").first.flatMap { parseEtime(String($0)) } }
}

// The shell command that runs this binary's CLI on any Mac, wherever it is installed.
func miraExec(_ args: String) -> String {
    "if [ -x \"$HOME/Applications/MIRA.app/Contents/MacOS/MIRA\" ]; then "
      + "exec \"$HOME/Applications/MIRA.app/Contents/MacOS/MIRA\" \(args); "
      + "else exec /Applications/MIRA.app/Contents/MacOS/MIRA \(args); fi"
}
```

In `app/Reliability.swift` `remoteControl`, replace the `let command = …` lines with:
```swift
    let command = miraExec("control \(payload)")
```

In `app/MIRA.swift`'s CLI switch, before `case "ipc-selftest":`:
```swift
case "inspect-machine":
    // Runs over SSH: reads what the menu app and daemon published, plus `ps`.
    let cfg = loadConfig(), me = selfMachine(cfg), now = Date().timeIntervalSince1970
    let runtime = readJSON(RuntimeSnapshot.self, snapshotFile)
    let driver = runtime?.role == "driver" ? me.id
        : (readRide()?.driver ?? readWheel().flatMap { now - $0.ts < cfg.rideTTLSeconds ? $0.driver : nil })
    let status = buildMachineStatus(cfg: cfg, me: me, runtime: runtime,
        local: readJSON(LocalStatus.self, localStatusFile), health: readJSON(Health.self, healthFile),
        inboundAges: inboundSessionAges(), driver: driver,
        snapshotPending: FileManager.default.fileExists(atPath: arrangementFile.path), now: now)
    if let data = try? JSONEncoder().encode(status) { print(String(decoding: data, as: UTF8.self)) }
    exit(0)
```

- [ ] **Step 4: Run to verify pass.** `bash tests/run.sh`, exit 0. Also run `./build.noindex/mira inspect-machine | python3 -m json.tool` (prints a MachineStatus; the warnings list the menu app as not reporting, because the dev binary has no local status yet).
- [ ] **Step 5: Commit** — `git commit -am "mira inspect-machine: one judged status per Mac, readable over SSH"`

---

### Task 5: Fix and kill actions — three new control kinds

**Files:**
- Modify: `app/Reliability.swift` (`handleControl` cases, integration tests)

**Interfaces:**
- Consumes: `relinquishWheel`'s counter `viewerCloseRequests`, `killJumpViewer()`, `routeAudio(passenger:)`, `Reconciler.lastMode`, `consoleRestoreAttempts`, `breaker`.
- Produces: control kinds `close-viewer`, `fix-audio`, `fix-display`; `var fixRequests: [String]` (test observability).

- [ ] **Step 1: Write the failing integration tests** (in `controlIntegrationTests`, before the final print)

```swift
    let closes = viewerCloseRequests
    check(handleControl(ControlRequest(kind: "close-viewer"), rec: rec).ok && viewerCloseRequests == closes + 1,
          "close-viewer is accepted and counted, inert under MIRA_STATE_DIR")
    check(handleControl(ControlRequest(kind: "fix-audio"), rec: rec).ok && fixRequests.last == "audio",
          "fix-audio is accepted, inert under MIRA_STATE_DIR")
    try? atomicJSON([SavedDisplay](), to: stateDir.appendingPathComponent("last-console-arrangement.json"))
    removeState(rideFile)
    check(handleControl(ControlRequest(kind: "fix-display"), rec: rec).ok
          && FileManager.default.fileExists(atPath: arrangementFile.path) && rec.lastMode == nil,
          "fix-display at console re-arms the last verified layout")
    removeState(arrangementFile)
```

- [ ] **Step 2: Run to verify failure.** `fixRequests` not found; the kinds would fall to the default reply.

- [ ] **Step 3: Implement.** Add near `viewerCloseRequests` in `app/MIRA.swift`:
```swift
var fixRequests: [String] = []
```
In `handleControl`, add the following cases before `case "release":`
```swift
        case "close-viewer":
            // A stale session is closed where its viewer lives (host-side kills reconnect).
            viewerCloseRequests += 1
            log("asked to close this Mac's viewer")
            if ProcessInfo.processInfo.environment["MIRA_STATE_DIR"] == nil {
                DispatchQueue.global(qos: .utility).async { killJumpViewer() }
            }
            return answer(true, "Closing this Mac's Jump sessions")
        case "fix-audio":
            fixRequests.append("audio")
            let passenger = readRide() != nil
            if ProcessInfo.processInfo.environment["MIRA_STATE_DIR"] == nil { routeAudio(passenger: passenger) }
            return answer(true, passenger ? "Sound routed through Jump" : "Sound returned to this Mac")
        case "fix-display":
            fixRequests.append("display")
            rec.breaker.reset(); rec.consoleRestoreAttempts = 0
            if readRide() == nil {
                // Re-arm the last layout MIRA itself verified; the next tick restores and re-verifies it.
                let good = stateDir.appendingPathComponent("last-console-arrangement.json")
                guard let data = try? Data(contentsOf: good) else { return answer(false, "No verified layout to restore") }
                try data.write(to: arrangementFile, options: .atomic)
            }
            rec.lastMode = nil
            return answer(true, "Display will be re-applied on the next beat")
```

- [ ] **Step 4: Run to verify pass.** `bash tests/run.sh`, exit 0.
- [ ] **Step 5: Commit** — `git commit -am "close-viewer, fix-audio, fix-display: the window's repair verbs"`

---

### Task 6: The window — model, polling, actions

**Files:**
- Modify: `app/Window.swift`
- Modify: `app/MIRA.swift` (`rebuild()`: an "Open MIRA…" item; MenuApp keeps the window controller)

**Interfaces:**
- Consumes: `MachineStatus`, `WindowsPC`, `rdpEndpoint`, `parseTailscale`, `miraExec`, `peerRun`, `remoteControl`, `requestDaemon`, `openSessionWindows`, `currentSession`, `readJSON(LocalStatus…)`.
- Produces: `final class MiraModel: ObservableObject`, `struct MiraView: View`, `final class MiraWindowController`, `func openWindowsPC(_ pc: WindowsPC, sessionOpen: Bool)`.

- [ ] **Step 1: Write the failing test** (selftest: the only pure piece, the `.rdp` text)

```swift
    let rdp = rdpFileText(WindowsPC(id: "rig3090", name: "3090", tailscale: "100.78.167.19", tailscaleName: "d", rdpPort: 1337))
    expect(rdp.contains("full address:s:100.78.167.19:1337"), "rdp: file targets the PC's endpoint")
```

- [ ] **Step 2: Run to verify failure.** `rdpFileText` not found.

- [ ] **Step 3: Implement `app/Window.swift`**

```swift
// MIRA window UI. Compiled with the other sources by tests/run.sh.
import SwiftUI

struct WindowsStatus { let pc: WindowsPC; let online: Bool?; let lastSeen: String?; let sessionOpen: Bool }

func rdpFileText(_ pc: WindowsPC) -> String {
    "full address:s:\(rdpEndpoint(pc))\nprompt for credentials on client:i:0\nscreen mode id:i:2\n"
}

// Windows App owns the session; MIRA only brings it forward or starts it.
func openWindowsPC(_ pc: WindowsPC, sessionOpen: Bool) {
    if sessionOpen { sh("open -a 'Windows App'"); return }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(pc.id).rdp")
    try? rdpFileText(pc).write(to: url, atomically: true, encoding: .utf8)
    sh("open -a 'Windows App' \(shellQuote(url.path))")
}

final class MiraModel: ObservableObject {
    let cfg: Config, me: Machine
    @Published var statuses: [String: MachineStatus] = [:]
    @Published var lastSeen: [String: Date] = [:]
    @Published var unreachable: Set<String> = []
    @Published var pcs: [WindowsStatus] = []
    @Published var notes: [String: String] = [:]
    @Published var refreshed: Date?
    private var timer: Timer?
    private var inFlight = Set<String>()
    private let lock = NSLock()

    init(cfg: Config, me: Machine) { self.cfg = cfg; self.me = me }
    var macs: [Machine] { cfg.machines.filter { ($0.type ?? "mac") == "mac" } }
    var driver: String? { statuses.values.compactMap { $0.driver }.first }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
    }
    func stop() { timer?.invalidate(); timer = nil }

    func refresh() {
        macs.forEach(poll)
        DispatchQueue.global(qos: .utility).async { [self] in
            let ts = parseTailscale(sh("tailscale status --json 2>/dev/null || /Applications/Tailscale.app/Contents/MacOS/Tailscale status --json 2>/dev/null", timeout: 8).out)
            let open = Set(readJSON(LocalStatus.self, localStatusFile)?.rdpEndpoints ?? [])
            let list = (cfg.windowsPCs ?? []).map { pc in
                WindowsStatus(pc: pc, online: ts.isEmpty ? nil : (ts[pc.tailscale]?.online ?? false),
                              lastSeen: ts[pc.tailscale]?.lastSeen, sessionOpen: open.contains(rdpEndpoint(pc)))
            }
            DispatchQueue.main.async { self.pcs = list; self.refreshed = Date() }
        }
    }

    private func poll(_ m: Machine) {
        lock.lock(); guard !inFlight.contains(m.id) else { lock.unlock(); return }
        inFlight.insert(m.id); lock.unlock()
        DispatchQueue.global(qos: .utility).async { [self] in
            let r = m.id == me.id
                ? sh("\(shellQuote(Bundle.main.executablePath ?? CommandLine.arguments[0])) inspect-machine", timeout: 10)
                : peerRun(m, miraExec("inspect-machine"), timeout: 12, force: true)
            let s = try? JSONDecoder().decode(MachineStatus.self, from: Data(r.out.utf8))
            lock.lock(); inFlight.remove(m.id); lock.unlock()
            DispatchQueue.main.async {
                if let s = s { self.statuses[m.id] = s; self.lastSeen[m.id] = Date(); self.unreachable.remove(m.id) }
                else { self.unreachable.insert(m.id) }
            }
        }
    }

    func act(_ kind: String, on m: Machine) {
        notes[m.id] = "…"
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var r = ControlRequest(kind: kind)
            if kind == "stop" { r.session = currentSession(me) }
            let reply = m.id == me.id ? requestDaemon(r) : remoteControl(m, r)
            DispatchQueue.main.async { self.notes[m.id] = reply.message; self.poll(m) }
        }
    }
    func connect(_ m: Machine) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let r = openSessionWindows(cfg: cfg, me: me, targets: [m])
            DispatchQueue.main.async { self.notes[m.id] = sessionWindowSummary(opened: r.opened, kept: r.kept) }
        }
    }
}

struct MiraView: View {
    @ObservedObject var model: MiraModel
    let columns = [GridItem(.adaptive(minimum: 280), spacing: 12)]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(model.driver.map { "\(name($0)) is driving" } ?? "Nobody is driving").font(.headline)
                    Spacer()
                    if let t = model.refreshed { Text("Updated \(t.formatted(date: .omitted, time: .standard))").foregroundStyle(.secondary).font(.caption) }
                    Button("Refresh") { model.refresh() }
                }
                Text("Macs").font(.title3.bold())
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    ForEach(model.macs, id: \.id) { m in MacCard(model: model, machine: m) }
                }
                if !model.pcs.isEmpty {
                    Text("Windows").font(.title3.bold())
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(model.pcs, id: \.pc.id) { s in PCCard(status: s) }
                    }
                }
            }.padding(16)
        }.frame(minWidth: 620, minHeight: 460)
    }
    func name(_ id: String) -> String { model.cfg.machines.first { $0.id == id }?.jumpName ?? id }
}

struct Dot: View {
    let color: Color
    var body: some View { Circle().fill(color).frame(width: 9, height: 9) }
}

struct MacCard: View {
    @ObservedObject var model: MiraModel
    let machine: Machine
    @State private var confirmKill = false
    var body: some View {
        let s = model.statuses[machine.id]
        let down = model.unreachable.contains(machine.id)
        let stale = s?.outbound?.contains { $0.stale } == true
        let warn = s.map { $0.audioWarning != nil || $0.display == "wrong" || !$0.warnings.isEmpty } ?? false
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Dot(color: down || s == nil ? .gray : stale ? .red : warn ? .orange : .green)
                Text(machine.jumpName).font(.headline)
                Spacer()
                Text(down ? "unreachable" : (s?.role ?? "…")).font(.caption).padding(.horizontal, 6)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }
            if down, let seen = model.lastSeen[machine.id] {
                Text("Last seen \(seen.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
            }
            if let s = s {
                Group {
                    if let out = s.outbound, !out.isEmpty {
                        HStack {
                            Text("Viewing: " + out.map { l in name(l.peer) + (l.stale ? " (stale)" : "") }.joined(separator: ", "))
                                .foregroundStyle(stale ? .red : .primary)
                            if stale { Button("Kill") { confirmKill = true } }
                        }
                    }
                    if s.inboundCount > 0 {
                        Text("Being viewed: \(s.inboundCount) session(s), oldest \(age(s.inboundOldestSeconds))")
                    }
                    HStack {
                        Text("Audio: \(s.output ?? "?") / \(s.input ?? "?")")
                        if s.audioWarning != nil { Button("Fix") { model.act("fix-audio", on: machine) } }
                    }
                    if let w = s.audioWarning { Text(w).foregroundStyle(.orange) }
                    HStack {
                        Text("Display: \(s.displayDetail)").foregroundStyle(s.display == "wrong" ? .orange : .primary)
                        if s.display == "wrong" { Button("Fix") { model.act("fix-display", on: machine) } }
                    }
                    ForEach(s.warnings, id: \.self) { Text($0).foregroundStyle(.orange) }
                    Text("Build \(s.build)").foregroundStyle(.secondary)
                }.font(.caption).opacity(down ? 0.5 : 1)
            }
            HStack {
                if machine.id == model.me.id {
                    if s?.role == "driver" { Button("Stop Driving") { model.act("stop", on: machine) } }
                    else if mayDrive(roles: machine.roles) { Button("Drive from Here") { model.act("drive", on: machine) } }
                    if s?.role == "passenger" { Button("Use Locally") { model.act("local", on: machine) } }
                } else if machine.roles.contains("target") {
                    Button("Connect") { model.connect(machine) }
                }
                if let note = model.notes[machine.id] { Text(note).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .confirmationDialog("Close every Jump session \(machine.jumpName) is holding?", isPresented: $confirmKill) {
            Button("Close Sessions", role: .destructive) { model.act("close-viewer", on: machine) }
        }
    }
    func name(_ id: String) -> String { model.cfg.machines.first { $0.id == id }?.jumpName ?? id }
    func age(_ s: Double?) -> String {
        guard let s = s else { return "?" }
        return s >= 3600 ? "\(Int(s / 3600))h" : "\(Int(s / 60))m"
    }
}

struct PCCard: View {
    let status: WindowsStatus
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Dot(color: status.online == true ? .green : status.online == false ? .gray : .yellow)
                Text(status.pc.name).font(.headline)
                Spacer()
                Text(status.online == true ? "online" : status.online == false ? "offline" : "unknown").font(.caption)
            }
            Text(status.pc.tailscaleName + " · " + rdpEndpoint(status.pc)).font(.caption).foregroundStyle(.secondary)
            if status.online == false, let seen = status.lastSeen { Text("Last seen \(seen.prefix(10))").font(.caption) }
            if status.sessionOpen { Text("Session open from this Mac").font(.caption).foregroundStyle(.green) }
            Button(status.sessionOpen ? "Show" : "Connect") { openWindowsPC(status.pc, sessionOpen: status.sessionOpen) }
                .disabled(status.online == false)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

final class MiraWindowController: NSObject, NSWindowDelegate {
    let model: MiraModel
    let window: NSWindow
    init(cfg: Config, me: Machine) {
        model = MiraModel(cfg: cfg, me: me)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "MIRA"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: MiraView(model: model))
        window.delegate = self
        window.center()
    }
    func show() {
        model.start()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) { model.stop() }
}
```

In `app/MIRA.swift` `MenuApp`, add the stored property `var miraWindow: MiraWindowController?`. In `rebuild()`, add the following right after the header item:
```swift
        m.addItem(withTitle: "Open MIRA…", action: #selector(openMiraWindow), keyEquivalent: "m").target = self
```
and in the `extension MenuApp`:
```swift
    @objc func openMiraWindow() {
        if miraWindow == nil { miraWindow = MiraWindowController(cfg: cfg, me: me) }
        miraWindow?.show()
    }
```

- [ ] **Step 4: Run to verify pass.** `bash tests/run.sh`, exit 0 (the whole thing compiles, including the SwiftUI).
- [ ] **Step 5: Commit** — `git commit -am "MIRA's window: every Mac and Windows PC, live, with connect and repair"`

---

### Task 7: Release and live verification

**Files:**
- Modify: `app/Reliability.swift:7` and `scripts/release.py:5` (build `20261003.1`)
- Modify: `docs/superpowers/specs/2026-10-03-mira-window-design.md` (record the departures: `windowsPCs` list, menu-app-sourced screen data, Connect mechanism)

- [ ] **Step 1:** Bump both build strings to `20261003.1`, run `bash tests/run.sh` (exit 0) and commit.
- [ ] **Step 2:** `python3 scripts/release.py` (mini canary first). Expected: `Canary acceptance recorded`, then `installed` for air15, pro and air13.
- [ ] **Step 3:** Live checks. Each Mac's `inspect-machine` over SSH returns JSON with no "menu app not reporting" warning:
  `for h in amirjalali@100.118.137.45 gabooja@100.105.19.90 amirhjalali@100.112.227.24; do ssh $h '…/MIRA inspect-machine'; done`, run with the `miraExec` path.
- [ ] **Step 4:** On the Pro, open the window from the menu ("Open MIRA…"). Check that:
  - the Pro shows as driver with display `ok` (mirrored)
  - the 3090 shows online with "Session open"
  - the Ace shows offline with a last-seen date
- [ ] **Step 5:** Update the spec's departures, then commit and push only if the user asks.
