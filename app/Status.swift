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

// MARK: - Local status (menu app)

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
        return line[arrow.upperBound...].split(separator: " ").first.map(String.init)
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
    guard mirrorDocked, let widest = external.max(by: { $0.w * $0.h < $1.w * $1.h }) else {
        return ("ok", screenSummary(screens))
    }
    if !widest.main { return ("wrong", "The external screen is not main") }
    if screens.contains(where: { !$0.main && !$0.mirrorsMain }) { return ("wrong", "Screens are extended, not mirrored") }
    return ("ok", screenSummary(screens))
}

private func screenSummary(_ screens: [ScreenInfo]) -> String {
    let main = screens.first { $0.main }.map { "\($0.w)×\($0.h) main" } ?? "no main screen"
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

// MARK: - MachineStatus (what `mira inspect-machine` prints)

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
    return MachineStatus(machine: me.id, build: runtime?.build ?? "?", ts: now, role: role, driver: driver,
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

// MARK: - Tests (called from selftest)

func windowTests(_ expect: (Bool, String) -> Void, _ cfg: Config) {
    // Windows PCs are a separate list so no SSH loop over `machines` can ever reach them.
    let winJSON = #"{"id":"x","name":"X","tailscale":"100.1.2.3","tailscaleName":"x","rdpPort":1337}"#
    let pc = try! JSONDecoder().decode(WindowsPC.self, from: Data(winJSON.utf8))
    expect(rdpEndpoint(pc) == "100.1.2.3:1337", "windows: endpoint uses the configured port")
    let pc2 = WindowsPC(id: "y", name: "Y", tailscale: "100.1.2.4", tailscaleName: "y", rdpPort: nil)
    expect(rdpEndpoint(pc2) == "100.1.2.4:3389", "windows: endpoint defaults to 3389")
    expect((cfg.windowsPCs ?? []).count == 3, "windows: three PCs configured")
    expect(!(cfg.windowsPCs ?? []).contains { pc in cfg.machines.contains { $0.id == pc.id } },
           "windows: no PC id collides with a Mac")
    expect(cfg.machines.first { $0.id == "pro" }?.mirrorDocked == true, "config: the pro prefers mirrored when docked")
    let lsof = """
    COMMAND  PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
    Windows 1102 amir   28u  IPv4 0x36   0t0  TCP 100.91.23.16:60895->100.78.167.19:1337 (ESTABLISHED)
    Windows 1102 amir   29u  IPv4 0x37   0t0  TCP 192.168.1.5:50000->20.26.121.2:3389 (ESTABLISHED)
    """
    expect(parseLsofEndpoints(lsof) == ["100.78.167.19:1337", "20.26.121.2:3389"],
           "lsof: remote endpoints of established Windows App connections")
    expect(parseLsofEndpoints("") == [], "lsof: nothing open is an empty list")
    // outbound sessions come from Jump's Window menu titles
    let titles = ["Computers", "Minimize", "Zoom", "Mac Mini", "MacBook Air", "Bring All to Front"]
    let out = outboundMachines(titles: titles, cfg: cfg, me: "pro")
    expect(out.contains("mini"), "outbound: alias title maps to the machine")
    expect(!out.contains { ["Computers", "Minimize", "Zoom"].contains($0) }, "outbound: menu noise is ignored")
    expect(!outboundMachines(titles: ["MacBook Pro"], cfg: cfg, me: "pro").contains("pro"), "outbound: never this Mac itself")
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
    let pv = displayVerdict(role: "passenger", runtimeState: "needs-attention", runtimeDetail: "Virtual display is not main",
                            screens: [], mirrorDocked: false, snapshotPending: false)
    expect(pv.verdict == "wrong" && pv.detail == "Virtual display is not main", "display: passenger takes the daemon's verdict")
    // tailscale
    let ts = #"{"Peer":{"k1":{"TailscaleIPs":["100.78.167.19","fd7a::1"],"Online":true,"LastSeen":"2026-10-03T10:00:00Z"},"k2":{"TailscaleIPs":["100.101.253.21"],"Online":false,"LastSeen":"2026-08-09T10:00:00Z"}}}"#
    let parsed = parseTailscale(ts)
    expect(parsed["100.78.167.19"]?.online == true, "tailscale: online peer")
    expect(parsed["100.101.253.21"]?.online == false && parsed["100.101.253.21"]?.lastSeen == "2026-08-09T10:00:00Z",
           "tailscale: offline peer keeps last seen")
    expect(parseTailscale("not json").isEmpty, "tailscale: garbage gives no verdicts")
    // ps etime
    expect(parseEtime("02-05:03:35") == 191_015.0, "etime: days")
    expect(parseEtime("13:17:36") == 47_856.0, "etime: hours")
    expect(parseEtime("05:09") == 309, "etime: minutes")
    expect(parseEtime("x") == nil, "etime: garbage")
    // MachineStatus: the 2026-10-01 incident, seen from air13
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
    let st3 = buildMachineStatus(cfg: cfg, me: me13, runtime: nil, local: fresh,
                                 health: Health(accessibility: false, screenRecording: true, ts: 1000),
                                 inboundAges: [100, 50_000], driver: "pro", snapshotPending: false, now: 1005)
    expect(st3.warnings.contains("MIRA daemon not reporting") && st3.warnings.contains("Jump Connect lost Accessibility"),
           "machineStatus: daemon and permission warnings")
    expect(st3.inboundCount == 2 && st3.inboundOldestSeconds == 50_000, "machineStatus: inbound sessions counted with oldest age")
    let encoded = try! JSONEncoder().encode(st)
    expect((try? JSONDecoder().decode(MachineStatus.self, from: encoded)) != nil, "machineStatus: JSON round-trip")
}
