// MIRA — one binary: menu-bar app, passenger daemon, CLI. Native display
// engine (CGVirtualDisplay + CoreGraphics config) — no BetterDisplay, no
// displayplacer. See docs/DESIGN-2.md and docs/PROPOSAL-fleet.md.
//
//   (no args)    menu-bar app (driver UI)
//   --daemon     reconciler daemon (every Mac; passengers converge here)
//   drive | stop | status | doctor | console | selftest
import AppKit
import CoreAudio
import Foundation
import IOKit
import IOKit.hid
import IOKit.pwr_mgt
import ServiceManagement

// MARK: - Shell (small residue: ssh, ping, osascript)

@discardableResult
func sh(_ cmd: String, timeout: TimeInterval = 30) -> (out: String, code: Int32) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = ["-c", cmd]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return ("", 127) }
    let deadline = Date().addingTimeInterval(timeout)
    while p.isRunning && Date() < deadline { usleep(50_000) }
    if p.isRunning {
        // Timed out. This path used to be terminate() + readDataToEndOfFile(),
        // and that made the timeout a lie: SIGTERM kills bash but *reparents*
        // its children rather than killing them, and an orphaned ssh still
        // holding the pipe's write end means the read to EOF never returns.
        // That is how a 20 s timeout became a multi-minute stall of the whole
        // daemon (2026-08-16). Kill hard and abandon the pipe — letting the
        // Pipe deallocate closes our read end, so any orphan writing into it
        // takes EPIPE and dies too.
        kill(p.processIdentifier, SIGKILL)
        return ("", 124)
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (String(data: data, encoding: .utf8) ?? "", p.terminationStatus)
}

// MARK: - Config

struct Canvas: Codable { let width: Int; let height: Int; let hidpi: Bool }
struct Machine: Codable {
    let id: String, jumpName: String, host: String, tailscale: String, user: String
    let roles: [String]
    let laptopCanvas: String?     // canvas key when this machine drives undocked
    let dockedCanvas: String?     // canvas key when this machine drives docked;
                                  // falls back to cfg.dockedCanvas when absent
    let type: String?             // "mac" (default) | "windows"
    let jumpAliases: [String]?    // other names this machine has in a viewer's Jump list
}
struct Config: Codable {
    let rideTTLSeconds: Double, heartbeatSeconds: Double, reconcileSeconds: Double
    let homeSubnetPrefix: String
    let dockedCanvas: String
    let canvases: [String: Canvas]
    let machines: [Machine]
    // Optional (decodeIfPresent via synthesized Codable — older configs stay valid).
    let handbackHoldSeconds: Double?
    let walkupInputEvents: Double?
    let reverseScroll: Bool?
    // How recent local input must be, on two consecutive ticks, to count as a
    // person at the console. Independent of reconcileSeconds on purpose — see
    // presenceThreshold().
    let presenceThresholdSeconds: Double?
    // Starlink's router also defaults to 192.168.1.0/24, so the home subnet alone
    // is not proof of being home. When set, the default gateway's MAC must match.
    let homeGatewayMAC: String?
}

func repoRoot() -> URL {
    for name in ["MIRA_DIR", "MACRIG_DIR"] {   // MACRIG_DIR: pre-rename agents
        if let env = ProcessInfo.processInfo.environment[name], !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
    }
    return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("mira", isDirectory: true)
}

func loadConfig() -> Config {
    let candidates = [
        repoRoot().appendingPathComponent("config/machines.json"),
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/mira/machines.json"),
    ]
    for url in candidates {
        if let data = try? Data(contentsOf: url),
           let cfg = try? JSONDecoder().decode(Config.self, from: data) { return cfg }
    }
    fatalError("cannot load machines.json from repo or ~/.config/mira/")
}

func selfMachine(_ cfg: Config) -> Machine {
    let me = NSUserName()
    let cands = cfg.machines.filter { $0.user == me }
    // A unix account is not an identity: two machines can share one (pro and
    // air13 are both "amirhjalali"), and first-match silently made air13
    // believe it was the pro. Disambiguate on ComputerName, which the fleet
    // naming convention keeps unique and equal to jumpName.
    if cands.count > 1 {
        let host = Host.current().localizedName ?? ""
        if let m = cands.first(where: { $0.jumpName == host }) { return m }
        if let m = cands.first(where: { ($0.jumpAliases ?? []).contains(host) }) { return m }
        FileHandle.standardError.write(
            "MIRA: \(cands.count) machines share user \(me); ComputerName \"\(host)\" matched none — using \(cands[0].id)\n"
                .data(using: .utf8)!)
    }
    if let m = cands.first { return m }
    fatalError("no machine in machines.json with user \(me)")
}

// MARK: - State

let stateDir = URL(fileURLWithPath: NSHomeDirectory())
    .appendingPathComponent("Library/Application Support/MIRA", isDirectory: true)
let rideFile = stateDir.appendingPathComponent("ride.json")
let drivingFlag = stateDir.appendingPathComponent("driving")
// Who holds the wheel fleet-wide, as last told to us by a driver. See "Wheel".
let wheelFile = stateDir.appendingPathComponent("wheel.json")

// The driving flag carries the moment we claimed the wheel, so a peer's ride can
// be compared against it. An empty flag (older build, or a file we failed to
// read) reads as nil, which driverYields() treats as "we never really claimed".
func readDriverClaim() -> Double? {
    guard let s = try? String(contentsOf: drivingFlag, encoding: .utf8) else { return nil }
    return Double(s.trimmingCharacters(in: .whitespacesAndNewlines))
}

// Only a viewer may take the wheel. The mini is roles:["target"] -- it has no
// business driving anything -- but "Drive from Here" was reachable in its menu
// and the drive verb on its command line, neither of which asked. One stray
// claim there (2026-08-18 21:27:38) outranked air15's, so the mini rejected
// every ride as stale, tore down its virtual display and dropped to its own
// 1920x1080 console: "the mac mini resolution looks a little funny". A
// passenger-only machine must be structurally incapable of this. Selftested.
func mayDrive(roles: [String]) -> Bool { roles.contains("viewer") }

// Claiming the wheel is one act: stamp the claim AND drop both of the things a
// previous driver left on us — its ride and its beacon. Without the ride half
// our own next tick reads that ride, concludes we are a passenger, and deletes
// the flag we just wrote; without the beacon half the same happens one layer
// up, via wheelYields.
func claimDriver(me: Machine) {
    guard mayDrive(roles: me.roles) else {
        log("refusing to drive: \(me.id) is roles=\(me.roles.joined(separator: ",")) — passenger-only")
        emit("drive_refused", [("id", .s(me.id))])
        try? FileManager.default.removeItem(at: drivingFlag)
        return
    }
    try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    let now = Date().timeIntervalSince1970
    try? String(now).write(to: drivingFlag, atomically: true, encoding: .utf8)
    emit("claim", [("at", .n(now))])
    try? FileManager.default.removeItem(at: rideFile)
    try? FileManager.default.removeItem(at: wheelFile)
}
let arrangementFile = stateDir.appendingPathComponent("arrangement.json")
let handbackFile = stateDir.appendingPathComponent("handback")
let hygieneFile = stateDir.appendingPathComponent("hygiene.json")
let excludedFile = stateDir.appendingPathComponent("excluded.json")
let healthFile = stateDir.appendingPathComponent("health.json")
let viewerHealthFile = stateDir.appendingPathComponent("viewer-health.json")
// Boot epoch at the time session windows were last opened; gates boot-resume.
let sessionMarkerFile = stateDir.appendingPathComponent("sessions-opened")
// Per-passenger Jump connection documents (File > Export in Jump Desktop,
// one <machine-id>.jump each). `open`ing one launches that saved session with
// no UI scripting and no Accessibility requirement. Machine-local state — the
// files carry MAC addresses and account ids, so they are never committed.
let aliasesDir = stateDir.appendingPathComponent("aliases", isDirectory: true)
func sessionAlias(for id: String) -> URL { aliasesDir.appendingPathComponent("\(id).jump") }

func loadExcluded() -> Set<String> {
    guard let d = try? Data(contentsOf: excludedFile),
          let a = try? JSONDecoder().decode([String].self, from: d) else { return [] }
    return Set(a)
}

func saveExcluded(_ e: Set<String>) {
    try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    if let d = try? JSONEncoder().encode(Array(e).sorted()) { try? d.write(to: excludedFile) }
}

let settingsFile = URL(fileURLWithPath: NSHomeDirectory())
    .appendingPathComponent(".config/mira/settings.json")

// Viewer-local settings, editable from the menu. Missing file = all defaults.
struct Settings: Codable {
    var reverseScroll: Bool = true
    var walkupHandback: Bool = true
    var hidpiRides: Bool = true
    // Idle-time presence detection false-fired on injected input 2026-07-22
    // and kicked a live session. OFF until proven under the live-fire
    // protocol (docs/STABILITY.md); lid-transition walk-up remains on.
    var walkupPresence: Bool = false
}

func loadSettings() -> Settings {
    guard let d = try? Data(contentsOf: settingsFile),
          let s = try? JSONDecoder().decode(Settings.self, from: d) else { return Settings() }
    return s
}

func saveSettings(_ s: Settings) {
    try? FileManager.default.createDirectory(
        at: settingsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let d = try? JSONEncoder().encode(s) { try? d.write(to: settingsFile) }
}
// Log beside the repo on a dev checkout; standalone installs (passengers, or a
// viewer without the repo) log to ~/Library/Logs/MIRA instead.
let logFile: URL = {
    var isDir: ObjCBool = false
    let dir: URL
    if FileManager.default.fileExists(atPath: repoRoot().path, isDirectory: &isDir), isDir.boolValue {
        dir = repoRoot().appendingPathComponent("logs", isDirectory: true)
    } else {
        dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/MIRA", isDirectory: true)
    }
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("mira.log")
}()

// Walk-up handback: a laptop that its owner physically returns to writes this
// file (unix ts) so the reconciler hands control back to the local console.
func writeHandback() {
    try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    try? String(Date().timeIntervalSince1970).write(to: handbackFile, atomically: true, encoding: .utf8)
}

func readHandbackTS() -> Double? {
    guard let s = try? String(contentsOf: handbackFile, encoding: .utf8) else { return nil }
    return Double(s.trimmingCharacters(in: .whitespacesAndNewlines))
}

// Serialised: the drive path fans out over passengers concurrently now, and
// seek-to-end + write from several threads interleaves half-written lines.
let logLock = NSLock()

func log(_ msg: String) {
    logLock.lock(); defer { logLock.unlock() }
    if let sz = try? FileManager.default.attributesOfItem(atPath: logFile.path)[.size] as? Int,
       sz > 1_000_000 {
        let old = logFile.deletingPathExtension().appendingPathExtension("old.log")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: logFile, to: old)
    }
    let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let line = "\(df.string(from: Date())) \(msg)\n"
    if let h = try? FileHandle(forWritingTo: logFile) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
    } else {
        try? line.write(to: logFile, atomically: true, encoding: .utf8)
    }
    FileHandle.standardOutput.write(line.data(using: .utf8)!)
}


// MARK: - Event log

// A structured, transition-only record of what the fleet actually did, kept
// beside the human log. The human log answers "what happened just now"; this
// answers "is it getting better or worse", which string-grepping a prose log
// cannot. Written ONLY on transitions — never sampled on a timer — so a healthy
// idle fleet writes essentially nothing and the file stays small on its own.
// Lives in Application Support (not /tmp) so it survives reboots.
let eventsFile = stateDir.appendingPathComponent("events.jsonl")
let eventsCapBytes = 256 * 1024        // rotate at 256 KB, keep one old file
let eventsLock = NSLock()

enum EV { case s(String), n(Double), b(Bool) }

func evJSON(_ v: EV) -> String {
    switch v {
    case .b(let x): return x ? "true" : "false"
    case .n(let x):
        if x == x.rounded() && abs(x) < 1e15 { return String(Int(x)) }
        // 2dp is plenty for ms and seconds; trailing zeros trimmed to keep
        // lines short (12.50 -> 12.5).
        var t = String(format: "%.2f", x)
        while t.hasSuffix("0") { t.removeLast() }
        return t
    case .s(let x):
        var out = "\""
        for c in x {
            switch c {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            default: out.append(c)
            }
        }
        return out + "\""
    }
}

// Field order is preserved so lines are stable and diffable, and so the
// selftest can assert on an exact string.
func eventLine(ts: Double, machine: String, event: String,
               fields: [(String, EV)]) -> String {
    var s = "{\"ts\":\(evJSON(.n(ts))),\"m\":\(evJSON(.s(machine))),\"e\":\(evJSON(.s(event)))"
    for (k, v) in fields { s += ",\(evJSON(.s(k))):\(evJSON(v))" }
    return s + "}"
}

// Nearest-rank percentile: no interpolation, so a p95 is always a value that
// really occurred. p of 0.5 on [1,2,3,4] is 3 by design.
func percentile(_ xs: [Double], _ p: Double) -> Double {
    guard !xs.isEmpty else { return 0 }
    let sorted = xs.sorted()
    let rank = Int((p * Double(sorted.count)).rounded(.up))
    return sorted[min(max(rank, 1), sorted.count) - 1]
}

// The machine id is resolved once; emit() is called from hot paths and must not
// re-read config on every event.
var eventMachineID = "?"

func emit(_ event: String, _ fields: [(String, EV)] = []) {
    eventsLock.lock(); defer { eventsLock.unlock() }
    if let sz = try? FileManager.default.attributesOfItem(atPath: eventsFile.path)[.size] as? Int,
       sz > eventsCapBytes {
        let old = stateDir.appendingPathComponent("events.1.jsonl")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: eventsFile, to: old)
    }
    let line = eventLine(ts: Date().timeIntervalSince1970, machine: eventMachineID,
                         event: event, fields: fields) + "\n"
    guard let d = line.data(using: .utf8) else { return }
    if let h = try? FileHandle(forWritingTo: eventsFile) {
        h.seekToEndOfFile(); h.write(d); try? h.close()
    } else {
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try? d.write(to: eventsFile)
    }
}

// The Jump *viewer* executable is ".../Jump Desktop.app/Contents/MacOS/Jump
// Desktop"; the *host service* is ".../Jump Desktop Connect.app/Contents/MacOS/
// JumpConnect". A passenger must kill the former (it streams outward, and a
// stale viewer session silently renegotiates the far end's display resolution)
// while never touching the latter, which is what serves inbound access.
// No trailing "$": the real argv carries args like -psn_0_1234.
let jumpViewerPattern = "/Jump Desktop\\.app/Contents/MacOS/Jump Desktop"

func matchesJumpViewer(_ argv: String) -> Bool {
    argv.range(of: jumpViewerPattern, options: .regularExpression) != nil
}

// MARK: - The measurement everything hangs off

// A canvas is not a preference. It is the size of the hole the picture is poured
// into: the Jump viewer's content rect on the driver's panel, in points. Every
// "the resolution is wrong / it doesn't fill the screen" round has been a
// hand-typed constant drifting away from that hole. panel/2 is itself wrong on
// any notched Mac -- macOS lays fullscreen content out BELOW the camera, so a
// 1440x932 panel gives a 1440x903 viewer (measured on air15, 2026-08-18) -- and
// the constant went stale again whenever a mode, a machine, or an unrelated
// commit moved (45f0502 set it right, 7df68eb silently reverted it).
//
// So the rule is: config SEEDS the canvas, measurement OWNS it.
struct ContentArea: Codable, Equatable { let w: Int; let h: Int }

// Jump puts up a connection bar and a toolbar strip beside the real session
// window (measured 1440x29 and 1440x32 against the true 1440x903 content).
// Treating either as the canvas would collapse every passenger to a sliver, so
// take the largest window that actually covers the screen. Pure and selftested.
func pickViewerContent(windows: [ContentArea], screen: ContentArea,
                       minCoverage: Double = 0.6) -> ContentArea? {
    let screenArea = Double(screen.w * screen.h)
    guard screenArea > 0 else { return nil }
    return windows
        .filter { Double($0.w * $0.h) / screenArea >= minCoverage }
        .max { ($0.w * $0.h) < ($1.w * $1.h) }
}

// A measured canvas only overrides the seed when it is plausibly a session:
// a garbage measurement must never be able to shrink a passenger to nothing.
func rideCanvas(base: Canvas, ride: Ride?) -> Canvas {
    guard let w = ride?.canvasW, let h = ride?.canvasH, w >= 600, h >= 400 else { return base }
    return Canvas(width: w, height: h, hidpi: base.hidpi)
}

// A measurement is STICKY. observedViewerContent() returns nil whenever the
// session window is not on screen right now -- a Space switch, a reconnect, a
// minimise -- and letting that nil fall back to the config seed makes the
// passenger rebuild its display twice per flap. That is the "resolution bounces
// from here to there" the user sees; the picture is only ever as stable as the
// least stable input. So: once measured, keep it until a DIFFERENT plausible
// measurement replaces it.
//
// The deadband stops the other thrash: a one-point window nudge is not worth
// tearing down and rebuilding a virtual display for. Pure and selftested.
func adoptMeasurement(previous: ContentArea?, observed: ContentArea?, slack: Int = 2) -> ContentArea? {
    guard let seen = observed else { return previous }
    guard let prev = previous else { return seen }
    let moved = abs(seen.w - prev.w) > slack || abs(seen.h - prev.h) > slack
    return moved ? seen : prev
}

func mainScreenPoints() -> ContentArea {
    let b = CGDisplayBounds(CGMainDisplayID())
    return ContentArea(w: Int(b.width), h: Int(b.height))
}

func observedViewerContent() -> ContentArea? {
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let info = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return nil }
    var wins: [ContentArea] = []
    for w in info {
        guard let owner = w[kCGWindowOwnerName as String] as? String,
              owner == "Jump Desktop",
              let b = w[kCGWindowBounds as String] as? [String: CGFloat],
              let width = b["Width"], let height = b["Height"] else { continue }
        wins.append(ContentArea(w: Int(width), h: Int(height)))
    }
    return pickViewerContent(windows: wins, screen: mainScreenPoints())
}

// MARK: - Defending the driver's own panel

// Jump renegotiates display modes on BOTH ends of a session, so the driver's own
// screen is not safe either: air15's panel was replaced with 1920x1200 @1x twice
// in 40 minutes while a session was live (2026-08-18), silently undoing the fix
// each time. Passengers get re-asserted every tick; the console panel had no
// defender at all.
struct PanelMode: Equatable { let w: Int; let h: Int; let px: Int; let py: Int; let hz: Double }

// Only fight back when the new mode is objectively WORSE -- 1x where we had
// HiDPI, or an aspect the panel does not have. A deliberate resolution change by
// the user is a legitimate choice and must be left alone. Pure and selftested.
func panelModeIsWorse(saved: PanelMode, now: PanelMode, nativeAspect: Double,
                      tolerance: Double = 0.01) -> Bool {
    if saved == now { return false }
    let lostHiDPI = saved.px >= saved.w * 2 && now.px < now.w * 2
    let nowAspect = now.h > 0 ? Double(now.w) / Double(now.h) : 0
    return lostHiDPI || abs(nowAspect - nativeAspect) > tolerance
}

// BSD ps prints elapsed time as [[dd-]hh:]mm:ss. Pure and selftested.
func parseETime(_ s: String) -> Double? {
    var days = 0.0
    var rest = s
    if let dash = rest.firstIndex(of: "-") {
        guard let d = Double(rest[rest.startIndex..<dash]) else { return nil }
        days = d
        rest = String(rest[rest.index(after: dash)...])
    }
    let parts = rest.split(separator: ":").map { Double($0) ?? -1 }
    guard !parts.contains(-1), parts.count == 2 || parts.count == 3 else { return nil }
    let secs = parts.count == 3 ? parts[0] * 3600 + parts[1] * 60 + parts[2]
                                : parts[0] * 60 + parts[1]
    return days * 86400 + secs
}

func currentPanelMode(_ d: CGDirectDisplayID) -> PanelMode? {
    guard let m = CGDisplayCopyDisplayMode(d) else { return nil }
    return PanelMode(w: m.width, h: m.height, px: m.pixelWidth, py: m.pixelHeight, hz: m.refreshRate)
}

// Native aspect = the aspect of the densest mode the panel offers.
func nativePanelAspect(_ d: CGDirectDisplayID) -> Double? {
    let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
    guard let modes = CGDisplayCopyAllDisplayModes(d, opts) as? [CGDisplayMode],
          let biggest = modes.max(by: { $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight }),
          biggest.pixelHeight > 0 else { return nil }
    return Double(biggest.pixelWidth) / Double(biggest.pixelHeight)
}

// Anything that can take the screen away from us, NAMED, so a defense is
// attributable instead of mysterious. Deliberately not a kill list: screensharingd
// is launchd-managed and simply respawns (the same reason `pkill -f JumpConnect`
// was recorded as futile), and it is also the way back into a machine that is not
// in front of you. The defender does not care who moved the mode -- it restores it
// either way -- so what is actually missing here is a name to go quit.
func screenTakers() -> [String] {
    var found: [String] = []
    if !sh("netstat -an 2>/dev/null | grep -E '\\.5900[ ].*ESTABLISHED' | head -1").out
        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        found.append("VNC session on :5900")
    }
    if sh("pgrep -x screensharingd >/dev/null").code == 0 { found.append("screensharingd") }
    if sh("pgrep -x sidecar-relay >/dev/null").code == 0 { found.append("Sidecar") }
    let proxies = sh("ps -Ao etime,command | grep '[d]esktopproxy'").out
        .split(separator: "\n").compactMap { line -> String? in
            let f = line.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init)
            guard let secs = f.flatMap(parseETime) else { return nil }
            return String(format: "inbound Jump session (%.1fh)", secs / 3600)
        }
    found.append(contentsOf: proxies)
    return found
}

var defendedPanel: PanelMode?
var lastRefusedBaseline: PanelMode?
var lastMeasuredContent: ContentArea?

// Only ever baseline a SANE mode. Taking the wheel while the panel is already
// wrong (1x, or an aspect the panel does not have) would otherwise enshrine the
// damage as the thing we defend, and the defender would sit quiet forever.
func panelModeIsSane(_ m: PanelMode, nativeAspect: Double, tolerance: Double = 0.01) -> Bool {
    let isHiDPI = m.px >= m.w * 2
    let aspect = m.h > 0 ? Double(m.w) / Double(m.h) : 0
    return isHiDPI && abs(aspect - nativeAspect) <= tolerance
}

func captureConsolePanel() {
    let d = CGMainDisplayID()
    guard let now = currentPanelMode(d), let native = nativePanelAspect(d) else { return }
    guard panelModeIsSane(now, nativeAspect: native) else {
        if lastRefusedBaseline != now {
            lastRefusedBaseline = now
            log("console panel is \(now.w)x\(now.h) px=\(now.px)x\(now.py) — not a sane baseline,"
              + " waiting for a HiDPI native-aspect mode before defending it")
        }
        return
    }
    defendedPanel = now
    log("console panel baseline \(now.w)x\(now.h) px=\(now.px)x\(now.py)")
}

func defendConsolePanel() {
    guard FileManager.default.fileExists(atPath: drivingFlag.path) else { defendedPanel = nil; return }
    let d = CGMainDisplayID()
    guard let saved = defendedPanel, let now = currentPanelMode(d),
          let aspect = nativePanelAspect(d),
          panelModeIsWorse(saved: saved, now: now, nativeAspect: aspect) else { return }
    guard let mode = matchMode(display: d, w: saved.w, h: saved.h, hz: saved.hz, px: saved.px) else {
        log("console panel changed to \(now.w)x\(now.h) px=\(now.px) — cannot restore \(saved.w)x\(saved.h)")
        return
    }
    var cfgRef: CGDisplayConfigRef?
    CGBeginDisplayConfiguration(&cfgRef)
    CGConfigureDisplayWithDisplayMode(cfgRef, d, mode, nil)
    let ok = CGCompleteDisplayConfiguration(cfgRef, .permanently) == .success
    let takers = screenTakers()
    log("console panel changed under us to \(now.w)x\(now.h) px=\(now.px)x\(now.py)"
      + " — restored \(saved.w)x\(saved.h) ok=\(ok)"
      + (takers.isEmpty ? " (no screen-taking agent found — suspect the live Jump session)"
                        : " — on screen right now: \(takers.joined(separator: ", "))"))
    emit("panel_defended", [("was", .s("\(now.w)x\(now.h)@\(now.px)")), ("restored", .b(ok))])
}

// MARK: - Anti-stream guard

// pkill sends SIGTERM, and an AppKit app can simply never act on it: a stale
// viewer survived 14h24m of a passenger firing this guard every 15 s
// (2026-08-18) while holding sessions into two other machines and renegotiating
// their resolutions. That is why "the guard never worked" twice over -- the
// pattern always matched, the signal was just ignored. Signal, VERIFY, escalate.
@discardableResult
func killJumpViewer() -> Bool {
    func alive() -> Bool { sh("pgrep -f '\(jumpViewerPattern)' >/dev/null").code == 0 }
    guard alive() else { return true }
    sh("pkill -f '\(jumpViewerPattern)' 2>/dev/null")
    usleep(1_200_000)
    guard alive() else { return true }
    log("viewer ignored SIGTERM — escalating to SIGKILL")
    sh("pkill -9 -f '\(jumpViewerPattern)' 2>/dev/null")
    usleep(500_000)
    let stillAlive = alive()
    if stillAlive { log("viewer SURVIVED SIGKILL — this passenger is still streaming outward") }
    emit("stream_guard", [("escalated", .b(true)), ("killed", .b(!stillAlive))])
    return !stillAlive
}

// MARK: - Ride (a driver's claim on this passenger)

struct Ride: Codable {
    let driver: String
    let canvas: String
    let hidpi: Bool
    let ts: Double
    // When the driver claimed the wheel (not when this ride was written). Lets a
    // receiver decide whether this ride outranks its own claim. Optional so a
    // ride from an older build still decodes — it simply never unseats anyone.
    let claimedAt: Double?
    // The driver's MEASURED viewer content area, in points. Optional so an older
    // build still decodes (it simply falls back to the config seed).
    var canvasW: Int? = nil
    var canvasH: Int? = nil
    func isLive(ttl: Double, now: Double = Date().timeIntervalSince1970) -> Bool {
        now - ts < ttl
    }
}

func readRide() -> Ride? {
    guard let d = try? Data(contentsOf: rideFile) else { return nil }
    return try? JSONDecoder().decode(Ride.self, from: d)
}

// MARK: - Wheel (the claim, fleet-wide)

// A ride says "become a passenger", and rides only ever go to machines with the
// "target" role. air13 is roles:["viewer"], so nothing was ever placed on it —
// which meant the "an older claimant still yields on its own" safety net
// described at driverYields did not cover the one machine that needed it. The
// beacon is a claim with no ride attached, pushed to every OTHER machine that
// may drive, at claim time and again on every beat. A machine that was asleep
// when the wheel changed hands learns it lost the wheel the moment it can be
// reached again.
struct Wheel: Codable {
    let driver: String
    let claimedAt: Double
    // When this beacon was written. Freshness for the menu bar ONLY — see below.
    let ts: Double
}

func readWheel() -> Wheel? {
    guard let d = try? Data(contentsOf: wheelFile) else { return nil }
    return try? JSONDecoder().decode(Wheel.self, from: d)
}

// A beacon can only ever TAKE the wheel away, never hand it back, so it needs
// no TTL: once we have yielded we are parked, and the only route back to
// driving is a fresh claim, which by construction outranks the beacon that
// unseated us. Expiring this would let a stale beacon lapse and restore a
// second driver — precisely the bug it exists to kill.
func wheelYields(me: String, myClaim: Double?, wheel: Wheel?) -> Bool {
    guard let w = wheel, w.driver != me else { return false }
    return driverYields(myClaim: myClaim, theirClaim: w.claimedAt)
}

// Menu bar only: who is driving the fleet, as far as this machine has been
// told. Display DOES expire — a driver that stopped talking should stop
// claiming the menu bar — which is exactly why it is not wheelYields.
func wheelHolder(wheel: Wheel?, me: String, ttl: Double,
                 now: Double = Date().timeIntervalSince1970) -> String? {
    guard let w = wheel, w.driver != me, now - w.ts < ttl else { return nil }
    return w.driver
}

// MARK: - Mode (pure, selftested)

enum Mode: Equatable { case console; case passenger(canvas: String, hidpi: Bool) }

func computeMode(ride: Ride?, ttl: Double, now: Double) -> Mode {
    if let r = ride, r.isLive(ttl: ttl, now: now) {
        return .passenger(canvas: r.canvas, hidpi: r.hidpi)
    }
    return .console
}

// System-wide seconds since the last HID event (IORegistry, no TCC). Injected
// events from an active remote session MAY also reset it, so presence detection
// is gated on no fleet peer actively streaming (inboundSessionActive).
func hidIdleSeconds() -> Double? {
    let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IOService:/IOResources/IOHIDSystem")
    guard entry != 0 else { return nil }
    defer { IOObjectRelease(entry) }
    guard let raw = IORegistryEntryCreateCFProperty(entry, "HIDIdleTime" as CFString,
                                                    kCFAllocatorDefault, 0)?.takeRetainedValue(),
          let ns = (raw as? NSNumber)?.doubleValue else { return nil }
    return ns / 1_000_000_000
}

// True when Jump Connect is actively encoding a session. Fluid rides UDP, so
// lsof shows no connected peers (learned 2026-07-22 the hard way: a false
// walk-up kicked a live session). Streaming provably burns encoder CPU, and
// interaction — the only source of injected input — always streams. Lid-closed
// machines also can't have a walk-up human at all.
func inboundSessionActive() -> Bool {
    let out = sh("ps -Aco pcpu,comm | awk '/JumpConnect/ {s+=$1} END {print s+0}'").out
    return (Double(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) >= 5.0
}

// MARK: - Handback (pure, selftested)

// Fresh handback: within the hold window. Used both to force console locally
// and to make a driver skip a walked-up target.
func handbackIsFresh(ts: Double, hold: Double, now: Double = Date().timeIntervalSince1970) -> Bool {
    now - ts < hold
}

// Clamshell convention: true = lid closed. A closed->open transition, a burst
// of real local input, or sustained console presence (system idle repeatedly
// under threshold across ticks) hands back while a converged passenger.
func shouldHandback(prevClamshell: Bool, nowClamshell: Bool,
                    inputBurst: Bool, passengerConverged: Bool) -> Bool {
    guard passengerConverged else { return false }
    let lidOpened = prevClamshell && !nowClamshell
    return lidOpened || inputBurst
}

// Presence via idle-time: two consecutive ticks with fresh local input.
// One tick can be a brushed key; two ticks of activity is a person.
func consolePresent(idleNow: Double?, idlePrev: Double?, threshold: Double) -> Bool {
    guard let a = idleNow, let b = idlePrev else { return false }
    return a < threshold && b < threshold
}

// Who drives, when two machines both think they do. Clicking Drive is the most
// explicit statement of intent in the system, so a ride must never silently
// override a newer one — that is what let a stale lease delete a driving flag
// the user had just created. Deciding by claim age rather than by "a ride
// exists" also makes handoff self-healing: stopOtherDrivers is a best-effort
// push, and when it fails to land the older claimant still yields on its own.
func driverYields(myClaim: Double?, theirClaim: Double?) -> Bool {
    guard let theirs = theirClaim else { return false }   // no claim can't unseat one
    guard let mine = myClaim else { return true }         // we never claimed; they did
    return theirs > mine
}

// Presence means "input seen on two consecutive ticks", which only implies a
// person actually sitting there if the threshold spans more than one tick.
// This used to be `reconcileSeconds + 5`, so re-tuning the tick rate silently
// re-tuned handback sensitivity: at a 2 s tick that window became 7 s and a
// single touch would hand the fleet back. It is its own knob now, floored at
// the value the 15 s tick produced so a faster loop can never be twitchier.
func presenceThreshold(configured: Double?, reconcile: Double) -> Double {
    max(configured ?? 20, reconcile + 5)
}

// MARK: - Boot-resume gate (pure, selftested)

// Seconds since epoch at boot; 0 when unreadable (never matches a marker, so
// an unreadable boot time fails open toward resuming).
func bootEpoch() -> Int {
    var tv = timeval()
    var size = MemoryLayout<timeval>.stride
    guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 else { return 0 }
    return tv.tv_sec
}

// Re-open session windows only when this login follows a reboot that happened
// after the last time windows were opened: driving flag set, viewer role, and
// the recorded marker is from a different boot (or absent).
func shouldResumeSessions(driving: Bool, viewer: Bool, markerBoot: Int?, currentBoot: Int) -> Bool {
    driving && viewer && markerBoot != currentBoot
}

func readSessionMarker() -> Int? {
    guard let s = try? String(contentsOf: sessionMarkerFile, encoding: .utf8) else { return nil }
    return Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
}

func writeSessionMarker() {
    try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    try? String(bootEpoch()).write(to: sessionMarkerFile, atomically: true, encoding: .utf8)
}

// MARK: - Jump permission health (probe truthful only in the gui domain)

// `JumpConnect --dumpmacperm` reports every permission false when run from an
// SSH session regardless of the real grants (the 2026-07-22 "stripped TCC"
// incident was this artifact). Each daemon therefore probes locally — its
// LaunchAgent lives in gui/<uid>, where the probe is truthful — and publishes
// health.json for doctor to read over SSH.
struct Health: Codable { let accessibility: Bool; let screenRecording: Bool; let ts: Double }

// The menu app's own vitals: without its Accessibility grant the scroll tap
// and the menu-scripting fallback die silently; without the menu app running
// at all, boot-resume never fires. Written by the menu app, read by doctor.
struct ViewerHealth: Codable { let axTrusted: Bool; let scrollTap: Bool; let ts: Double }

// Tolerates the QApplication warning line and the vendor's "hasAccessiblity"
// typo. Pure, selftested.
func parsePermReport(_ out: String) -> (accessibility: Bool, screenRecording: Bool)? {
    guard let a = out.firstIndex(of: "{"), let b = out.lastIndex(of: "}"), a < b,
          let obj = try? JSONSerialization.jsonObject(with: Data(out[a...b].utf8)) as? [String: Any],
          let ax = obj["hasAccessiblity"] as? Bool,
          let sr = obj["hasScreenRecording"] as? Bool else { return nil }
    return (ax, sr)
}

// Spawn a binary disclaimed — as its own TCC "responsible process" (the same
// long-stable private attribute sshd and Terminal use). A child spawned the
// normal way inherits OUR responsibility, so TCC answers for com.amir.mira
// instead of the probed app and the report is false for every permission
// (measured 2026-07-28: identical probe true as a launchd job, false as our
// child). Returns captured stdout+stderr, or nil on spawn failure/timeout.
func runDisclaimed(_ path: String, _ args: [String], timeout: TimeInterval = 10) -> String? {
    typealias SetDisclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>?, Int32) -> Int32
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2) /* RTLD_DEFAULT */,
                          "responsibility_spawnattrs_setdisclaim") else { return nil }
    let setDisclaim = unsafeBitCast(sym, to: SetDisclaim.self)
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    defer { posix_spawnattr_destroy(&attr) }
    _ = setDisclaim(&attr, 1)
    var fds: [Int32] = [0, 0]
    guard pipe(&fds) == 0 else { return nil }
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_adddup2(&actions, fds[1], 1)
    posix_spawn_file_actions_adddup2(&actions, fds[1], 2)
    posix_spawn_file_actions_addclose(&actions, fds[0])
    var pid: pid_t = 0
    var argv: [UnsafeMutablePointer<CChar>?] = ([path] + args).map { strdup($0) }
    argv.append(nil)
    defer { argv.forEach { if let p = $0 { free(p) } } }
    let rc = posix_spawn(&pid, path, &actions, &attr, argv, environ)
    close(fds[1])
    guard rc == 0 else { close(fds[0]); return nil }
    var status: Int32 = 0
    let deadline = Date().addingTimeInterval(timeout)
    while waitpid(pid, &status, WNOHANG) == 0 {
        if Date() >= deadline { kill(pid, SIGKILL); _ = waitpid(pid, &status, 0); break }
        usleep(50_000)
    }
    // Output is tiny (a few lines of JSON), far below the pipe buffer, so
    // reading after exit cannot deadlock.
    let data = FileHandle(fileDescriptor: fds[0], closeOnDealloc: true).readDataToEndOfFile()
    return String(data: data, encoding: .utf8)
}

func writeHealth() {
    guard let out = runDisclaimed("/Applications/Jump Desktop Connect.app/Contents/MacOS/JumpConnect",
                                  ["--dumpmacperm"]),
          let p = parsePermReport(out) else { return }
    let h = Health(accessibility: p.accessibility, screenRecording: p.screenRecording,
                   ts: Date().timeIntervalSince1970)
    try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    if let d = try? JSONEncoder().encode(h) { try? d.write(to: healthFile) }
}

// MARK: - Tier engine (pure, selftested)

enum Tier: String { case full, standard, travel, lifeline }

// Hysteresis thresholds proven in v1: demote at avg>=70 || jitter>=35;
// recover only when avg<50 && jitter<22.
func computeTier(previous: Tier, avgMs: Double, jitterMs: Double,
                 home: Bool, docked: Bool) -> Tier {
    if home { return docked ? .full : .standard }
    let bad = avgMs >= 70 || jitterMs >= 35
    let good = avgMs < 50 && jitterMs < 22
    switch previous {
    case .travel: return bad ? .lifeline : .travel
    case .lifeline: return good ? .travel : .lifeline
    default: return bad ? .lifeline : .travel
    }
}

func tierWantsHiDPI(_ t: Tier) -> Bool { t == .full || t == .standard }

// MARK: - Canvas pick (pure, selftested)

// Docked means any physical display at least 3000px wide is attached.
func pickCanvas(physicalWidths: [Int], dockedCanvas: String, laptopCanvas: String) -> String {
    physicalWidths.contains { $0 >= 3000 } ? dockedCanvas : laptopCanvas
}

// MARK: - Native audio engine (CoreAudio, public API)

struct AudioDev { let id: AudioDeviceID; let name: String; let builtIn: Bool
                  let hasOutput: Bool; let hasInput: Bool }

func listAudioDevices() -> [AudioDev] {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                     &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids.map { id in
        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var cfName: CFString = "" as CFString
        var nSize = UInt32(MemoryLayout<CFString>.size)
        withUnsafeMutablePointer(to: &cfName) { p in
            _ = AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nSize, p)
        }
        var tAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var tSize = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectGetPropertyData(id, &tAddr, 0, nil, &tSize, &transport)
        func streams(_ scope: AudioObjectPropertyScope) -> Bool {
            var sAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams, mScope: scope,
                mElement: kAudioObjectPropertyElementMain)
            var sSize: UInt32 = 0
            AudioObjectGetPropertyDataSize(id, &sAddr, 0, nil, &sSize)
            return sSize > 0
        }
        return AudioDev(id: id, name: cfName as String,
                        builtIn: transport == kAudioDeviceTransportTypeBuiltIn,
                        hasOutput: streams(kAudioObjectPropertyScopeOutput),
                        hasInput: streams(kAudioObjectPropertyScopeInput))
    }
}

func setDefaultAudio(_ id: AudioDeviceID, selector: AudioObjectPropertySelector) {
    var addr = AudioObjectPropertyAddress(
        mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var dev = id
    AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                               &addr, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &dev)
}

// Pure: choose the output/input device names for a mode.
func pickAudioNames(passenger: Bool, deviceNames: [String]) -> (output: String?, input: String?) {
    if passenger {
        return (deviceNames.first { $0 == "Jump Desktop Audio" },
                deviceNames.first { $0 == "Jump Desktop Microphone" })
    }
    return (nil, nil)  // console: caller falls back to built-in transport
}

func currentDefaultOutputName() -> String? {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var dev: AudioDeviceID = 0
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                     &addr, 0, nil, &size, &dev) == noErr, dev != 0 else { return nil }
    return listAudioDevices().first { $0.id == dev }?.name
}

func currentDefaultOutputIsJump() -> Bool {
    currentDefaultOutputName()?.hasPrefix("Jump Desktop") == true
}

func routeAudio(passenger: Bool) {
    let devs = listAudioDevices()
    let picked = pickAudioNames(passenger: passenger, deviceNames: devs.map { $0.name })
    if passenger {
        if let o = devs.first(where: { $0.name == picked.output }) {
            setDefaultAudio(o.id, selector: kAudioHardwarePropertyDefaultOutputDevice)
            setDefaultAudio(o.id, selector: kAudioHardwarePropertyDefaultSystemOutputDevice)
        }
        if let i = devs.first(where: { $0.name == picked.input }) {
            setDefaultAudio(i.id, selector: kAudioHardwarePropertyDefaultInputDevice)
        }
    } else {
        if let o = devs.first(where: { $0.builtIn && $0.hasOutput }) {
            setDefaultAudio(o.id, selector: kAudioHardwarePropertyDefaultOutputDevice)
            setDefaultAudio(o.id, selector: kAudioHardwarePropertyDefaultSystemOutputDevice)
        }
        if let i = devs.first(where: { $0.builtIn && $0.hasInput }) {
            setDefaultAudio(i.id, selector: kAudioHardwarePropertyDefaultInputDevice)
        }
    }
}

// MARK: - Native display engine

let miraVendorID: UInt32 = 0x4D49_5241 & 0xFFFF  // "RA" tail of 'MIRA'

final class DisplayEngine {
    private var virtualDisplay: CGVirtualDisplay?
    private(set) var virtualID: CGDirectDisplayID = 0
    private var builtCanvas: Canvas?     // dims the current virtual was created for

    func onlineDisplays() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    func physicalDisplays() -> [CGDirectDisplayID] {
        onlineDisplays().filter { $0 != virtualID && CGDisplayVendorNumber($0) != miraVendorID }
    }

    func physicalWidths() -> [Int] {
        physicalDisplays().map { Int(CGDisplayPixelsWide($0)) }
    }

    // Create (or reuse) the virtual display for a canvas. hiDPI is a
    // create-time property: publish both 2x and 1x modes under hiDPI so tier
    // changes are mode switches, not recreations.
    func ensureVirtual(canvas: Canvas) -> Bool {
        if virtualDisplay != nil {
            // Reuse only if built for the same canvas; a live ride whose canvas
            // changed (driver undocks: ultrawide->laptop) must rebuild, else
            // the topology apply can never match and the passenger reconverges forever.
            if let b = builtCanvas, b.width == canvas.width, b.height == canvas.height { return true }
            log("virtual canvas changed \(builtCanvas.map { "\($0.width)x\($0.height)" } ?? "?") -> \(canvas.width)x\(canvas.height); rebuilding")
            destroyVirtual()
        }
        let desc = CGVirtualDisplayDescriptor()
        desc.name = "MIRA"
        desc.maxPixelsWide = 6880
        desc.maxPixelsHigh = 3824
        desc.sizeInMillimeters = CGSize(width: 800, height: 335)
        desc.serialNum = 1
        desc.productID = 0x4D32
        desc.vendorID = miraVendorID
        desc.queue = DispatchQueue.main
        desc.terminationHandler = { _, _ in log("virtual display terminated by system") }
        guard let display = CGVirtualDisplay(descriptor: desc) else { return false }
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        var modes: [CGVirtualDisplayMode] = []
        for c in [canvas] {
            modes.append(CGVirtualDisplayMode(width: UInt32(c.width * 2),
                                              height: UInt32(c.height * 2), refreshRate: 60))
            modes.append(CGVirtualDisplayMode(width: UInt32(c.width),
                                              height: UInt32(c.height), refreshRate: 60))
        }
        settings.modes = modes
        guard display.apply(settings) else { return false }
        virtualDisplay = display
        virtualID = display.displayID
        builtCanvas = canvas
        log("virtual display created id=\(virtualID) for \(canvas.width)x\(canvas.height)")
        return true
    }

    func destroyVirtual() {
        if virtualDisplay != nil { log("virtual display destroyed") }
        virtualDisplay = nil
        virtualID = 0
        builtCanvas = nil
    }

    // Shared mode pick, so the mode chosen for the transaction and the mode the
    // invariant later expects can never drift apart.
    func virtualMode(canvas: Canvas, hidpi: Bool) -> CGDisplayMode? {
        guard virtualID != 0 else { return nil }
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let modes = (CGDisplayCopyAllDisplayModes(virtualID, opts) as? [CGDisplayMode]) ?? []
        let uiMatches = modes.filter { $0.width == canvas.width && $0.height == canvas.height }
        let exact = uiMatches.first {
            hidpi ? $0.pixelWidth == canvas.width * 2 : $0.pixelWidth == canvas.width
        }
        if exact == nil, let f = uiMatches.first {
            log("mode fallback: UI \(canvas.width)x\(canvas.height) with backing \(f.pixelWidth)px")
        }
        return exact ?? uiMatches.first
    }

    // The whole passenger topology in ONE transaction: the virtual holds the
    // canvas mode, every physical mirrors the virtual, the virtual is main.
    //
    // It used to be four transactions (unmirror, set mode, mirror, set main).
    // Every seam between them was a moment when CG renegotiated the mode for the
    // whole set, and CG picks the highest mode all members share EXACTLY --
    // 1024x768 on the BenQ/built-in pair, and a modeless virtual on the laptop
    // panel pair. Both traps, and the mid-converge flash the owner actually
    // sees, are one root cause: a topology that is briefly neither the old one
    // nor the new one. There is no such moment now.
    func applyPassengerTopology(canvas: Canvas, hidpi: Bool) -> Bool {
        guard virtualID != 0 else { log("apply topology: no virtual display"); return false }
        guard let mode = virtualMode(canvas: canvas, hidpi: hidpi) else {
            log("apply topology: no \(canvas.width)x\(canvas.height) mode published on the virtual")
            return false
        }
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success, let cfg = cfg else {
            log("apply topology: CGBeginDisplayConfiguration failed")
            return false
        }
        CGConfigureDisplayWithDisplayMode(cfg, virtualID, mode, nil)
        for p in physicalDisplays() { CGConfigureDisplayMirrorOfDisplay(cfg, p, virtualID) }
        CGConfigureDisplayOrigin(cfg, virtualID, 0, 0)          // origin 0,0 == main
        let r = CGCompleteDisplayConfiguration(cfg, .permanently)
        lastSelfDisplayWrite = Date()
        // Never discarded. A silent false here is how a converge used to fail
        // without leaving one line of evidence anywhere.
        if r != .success { log("apply topology: CGCompleteDisplayConfiguration error \(r.rawValue)") }
        return r == .success
    }

    func unmirrorAll() {
        var cfg: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&cfg)
        for d in onlineDisplays() where d != virtualID {
            CGConfigureDisplayMirrorOfDisplay(cfg, d, kCGNullDirectDisplay)
        }
        CGCompleteDisplayConfiguration(cfg, .permanently)
    }

    func setMain(_ id: CGDirectDisplayID) {
        var cfg: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&cfg)
        CGConfigureDisplayOrigin(cfg, id, 0, 0)
        CGCompleteDisplayConfiguration(cfg, .permanently)
    }

    // Invariant: virtual exists at canvas/hidpi, is main, every physical mirrors it.
    func passengerInvariantHolds(canvas: Canvas, hidpi: Bool) -> Bool {
        passengerInvariantFailure(canvas: canvas, hidpi: hidpi) == nil
    }

    // Which check failed, for the log. "converged=false" on its own says a ride
    // could not be satisfied but not why, and a passenger that can never satisfy
    // it reconverges on every tick — a hot loop of display reconfiguration
    // (observed on the pro, 2026-08-17). Naming the failing guard makes that
    // diagnosable instead of guesswork.
    func passengerInvariantFailure(canvas: Canvas, hidpi: Bool) -> String? {
        if virtualID == 0 { return "no virtual display" }
        if CGDisplayIsMain(virtualID) == 0 { return "virtual is not main" }
        let w = Int(CGDisplayPixelsWide(virtualID))
        if w != canvas.width { return "virtual width \(w) != canvas \(canvas.width)" }
        // A modeless virtual (post-mirror negotiation failure) looks converged
        // by bounds alone, but WindowServer reclaims it within a minute.
        guard let m = CGDisplayCopyDisplayMode(virtualID) else { return "virtual has no mode" }
        if hidpi, m.pixelWidth != canvas.width * 2 {
            return "hidpi mode pixelWidth \(m.pixelWidth) != \(canvas.width * 2)"
        }
        for p in physicalDisplays() where CGDisplayMirrorsDisplay(p) != virtualID {
            return "display \(p) (\(CGDisplayPixelsWide(p))x\(CGDisplayPixelsHigh(p))) not mirroring virtual"
        }
        return nil
    }

    // CoreGraphics answers display queries from a PER-PROCESS snapshot that is
    // refreshed when the process turns its run loop. Reading the invariant on
    // the line after CGCompleteDisplayConfiguration therefore interrogates a
    // cache that has not seen the write yet. On 2026-08-19 this daemon read
    // CGDisplayCopyDisplayMode as nil for 89 minutes while a separate probe
    // process read the correct 3440x1440 mode off the very same display. The
    // cheap bounds queries (IsMain, PixelsWide) refresh eagerly and passed
    // throughout, which is exactly what made it look like a real modeless
    // virtual and sent the fix in the wrong direction.
    //
    // So: give the run loop a turn and re-ask before believing a failure. A
    // clause still broken once the snapshot has caught up is a real one.
    func settledInvariantFailure(canvas: Canvas, hidpi: Bool, attempts: Int = 4) -> String? {
        var why = passengerInvariantFailure(canvas: canvas, hidpi: hidpi)
        var left = attempts
        while why != nil, left > 1 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.12))
            why = passengerInvariantFailure(canvas: canvas, hidpi: hidpi)
            left -= 1
        }
        return why
    }
}

// MARK: - Converge circuit breaker

// A converge that cannot succeed must stop trying. On 2026-08-19 a passenger
// reconverged 1,924 times in 89 minutes: every tick read one invariant clause as
// broken, tore the whole display topology down, rebuilt it, re-read the same
// clause as broken, and went round again -- each cycle a visible resolution
// flash on the owner's panel. Nothing counted the repeats, so the loop could not
// tell "the world drifted, re-assert" from "I cannot satisfy this, stop asking".
//
// Identical consecutive failures carry no new information. A DIFFERENT failure
// does -- it means the last attempt changed something -- so it restarts the
// count. Pure and selftested on purpose: this is the guard that has to work
// when everything else in the display stack is lying.
struct ConvergeBreaker {
    let limit: Int
    private(set) var reason: String?
    private(set) var streak = 0
    private(set) var tripped = false

    init(limit: Int = 5) { self.limit = limit }

    // nil failure == converged. Returns true only on the tick that trips the
    // breaker, so the caller logs the transition exactly once instead of once
    // per tick forever -- the log spam was its own half of the incident.
    @discardableResult
    mutating func record(_ failure: String?) -> Bool {
        guard let failure = failure else {
            reason = nil; streak = 0; tripped = false; return false
        }
        if failure == reason { streak += 1 } else { reason = failure; streak = 1 }
        let wasTripped = tripped
        tripped = streak >= limit
        return tripped && !wasTripped
    }

    var shouldAttempt: Bool { !tripped }

    // Anything that makes the previous verdict stale: a new lease, a mode
    // change, or the display topology actually moving underneath us.
    mutating func reset() { reason = nil; streak = 0; tripped = false }
}

// Set immediately after every display transaction WE issue. The reconfiguration
// callback fires for our own writes too, and a breaker that resets on those
// would never trip at all.
var lastSelfDisplayWrite = Date.distantPast
var displayReconfigured: ((CGDisplayChangeSummaryFlags) -> Void)?

// MARK: - Arrangement capture / restore (origins of physical displays)

// mirrorOf: nil = independent display; else the master display it mirrors.
// w/h/hz/px capture the display mode at capture time: re-establishing a mirror
// (or unmirroring) without an explicit mode lets CG pick the highest mode the
// panels share exactly — 1024x768 on the BenQ/built-in pair.
struct SavedDisplay: Codable {
    let id: UInt32; let x: Int; let y: Int; let main: Bool; let mirrorOf: UInt32?
    var w: Int? = nil       // UI width
    var h: Int? = nil       // UI height
    var hz: Double? = nil
    var px: Int? = nil      // backing pixel width (w*2 when hidpi)
}

// What restore must do to one display. Pure, selftested: the mode/mirror
// decision is the part that regressed twice, so it is testable headless.
struct RestoreStep: Equatable {
    let id: UInt32
    let setMode: Bool        // reapply the captured mode
    let mirrorOf: UInt32?    // nil = independent: set origin instead
}

// EVERY display gets its captured mode back — mirror members included. A
// member holds its own mode; the set runs at a mode all members hold, so a
// member left at 1024x768 by the torn-down virtual-display mirror drags the
// master down with it no matter what mode the master is asked for. Restoring
// only the master is the 1024x768 bug.
func restoreStep(_ s: SavedDisplay, online: Set<UInt32>) -> RestoreStep {
    RestoreStep(id: s.id,
                setMode: s.w != nil && s.h != nil,
                mirrorOf: s.mirrorOf.flatMap { online.contains($0) ? $0 : nil })
}

// Best available mode for UI w×h: prefer the saved backing-pixel width
// (hidpi vs 1x), then the closest refresh rate.
func matchMode(display: CGDirectDisplayID, w: Int, h: Int, hz: Double?, px: Int?) -> CGDisplayMode? {
    let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
    guard let modes = CGDisplayCopyAllDisplayModes(display, opts) as? [CGDisplayMode] else { return nil }
    let ui = modes.filter { $0.width == w && $0.height == h }
    var pool = ui
    if let px = px { let exact = ui.filter { $0.pixelWidth == px }; if !exact.isEmpty { pool = exact } }
    guard let hz = hz else { return pool.first }
    return pool.min { abs($0.refreshRate - hz) < abs($1.refreshRate - hz) }
}

func captureArrangement(engine: DisplayEngine) {
    guard !FileManager.default.fileExists(atPath: arrangementFile.path) else { return }
    let saved = engine.physicalDisplays().map { d -> SavedDisplay in
        let b = CGDisplayBounds(d)
        let master = CGDisplayMirrorsDisplay(d)
        let m = CGDisplayCopyDisplayMode(d)
        return SavedDisplay(id: d, x: Int(b.origin.x), y: Int(b.origin.y),
                            main: CGDisplayIsMain(d) != 0,
                            mirrorOf: master == kCGNullDirectDisplay ? nil : master,
                            w: m.map { $0.width }, h: m.map { $0.height },
                            hz: m.map { $0.refreshRate }, px: m.map { $0.pixelWidth })
    }
    try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    if let d = try? JSONEncoder().encode(saved) { try? d.write(to: arrangementFile) }
}

// Returns true when the arrangement is restored (or there is nothing to
// restore). Returns false on a transient CG config failure so the caller can
// retry next tick — arrangement.json is deleted only on success, never losing
// the user's docked BenQ-master/built-in-mirror preference.
@discardableResult
func restoreArrangement(engine: DisplayEngine) -> Bool {
    guard let data = try? Data(contentsOf: arrangementFile),
          let saved = try? JSONDecoder().decode([SavedDisplay].self, from: data) else {
        // No saved arrangement means we never took the displays away, so there
        // is nothing to give back — and "nothing to give back" must mean TOUCH
        // NOTHING. unmirrorAll() and setMain() used to run BEFORE this check,
        // which made an empty restore a destructive act: it tore the docked
        // BenQ-master/built-in-mirror pair into extend and returned success.
        // A console converge that runs twice is enough to trigger it — the
        // first restores and deletes arrangement.json, the second finds no file
        // and unmirrors what the first just rebuilt. Reproduced on the pro
        // 2026-08-19: set duplicate, one `mira console`, back to extend.
        // The reconciler converges to console constantly; anything on that path
        // that mutates displays without being asked will eventually be run at
        // the worst possible moment.
        return true   // nothing captured -> nothing to do, and nothing to retry
    }
    engine.unmirrorAll()   // break the virtual's mirror before rebuilding the real one
    let online = Set(engine.onlineDisplays())
    var cfg: CGDisplayConfigRef?
    CGBeginDisplayConfiguration(&cfg)
    for s in saved where online.contains(s.id) {
        let step = restoreStep(s, online: online)
        if step.setMode, let w = s.w, let h = s.h,
           let mode = matchMode(display: s.id, w: w, h: h, hz: s.hz, px: s.px) {
            CGConfigureDisplayWithDisplayMode(cfg, s.id, mode, nil)
        }
        if let master = step.mirrorOf {
            CGConfigureDisplayMirrorOfDisplay(cfg, s.id, master)   // restore mirror topology
        } else {
            CGConfigureDisplayOrigin(cfg, s.id, Int32(s.x), Int32(s.y))
        }
    }
    guard CGCompleteDisplayConfiguration(cfg, .permanently) == .success else {
        log("restoreArrangement config failed — leaving arrangement.json for retry")
        return false
    }
    if let main = saved.first(where: { $0.main }), online.contains(main.id) {
        engine.setMain(main.id)
    } else if let first = engine.physicalDisplays().first {
        engine.setMain(first)
    }
    try? FileManager.default.removeItem(at: arrangementFile)
    return true
}

// MARK: - Hygiene (Universal Control off while passenger)

struct Hygiene: Codable { let ucDisable: String?; let ucDisableMagicEdges: String? }

private func readDefault(_ domain: String, _ key: String) -> String? {
    let r = sh("defaults read \(domain) \(key) 2>/dev/null")
    if r.code != 0 { return nil }
    let v = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
    return v.isEmpty ? nil : v
}

// Save originals once, then force Universal Control off so a walk-up on another
// Mac's edge doesn't steal the cursor from the passenger canvas.
func applyHygiene() {
    if !FileManager.default.fileExists(atPath: hygieneFile.path) {
        let h = Hygiene(ucDisable: readDefault("com.apple.universalcontrol", "Disable"),
                        ucDisableMagicEdges: readDefault("com.apple.universalcontrol", "DisableMagicEdges"))
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(h) { try? d.write(to: hygieneFile) }
    }
    sh("defaults write com.apple.universalcontrol Disable -bool true")
    sh("defaults write com.apple.universalcontrol DisableMagicEdges -bool true")
    sh("killall UniversalControl 2>/dev/null")
}

func restoreHygiene() {
    guard let data = try? Data(contentsOf: hygieneFile),
          let h = try? JSONDecoder().decode(Hygiene.self, from: data) else { return }
    func restore(_ key: String, _ val: String?) {
        if let v = val {
            sh("defaults write com.apple.universalcontrol \(key) -bool \(v == "0" ? "false" : "true")")
        } else {
            sh("defaults delete com.apple.universalcontrol \(key) 2>/dev/null")   // missing originally
        }
    }
    restore("Disable", h.ucDisable)
    restore("DisableMagicEdges", h.ucDisableMagicEdges)
    try? FileManager.default.removeItem(at: hygieneFile)
    sh("killall UniversalControl 2>/dev/null")
}

// MARK: - Clamshell (lid) state via IORegistry

// Returns true when the lid is closed (clamshell), false when open, nil if the
// property is absent (desktops, or reading failed).
func readClamshellState() -> Bool? {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }
    guard let prop = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString,
                                                     kCFAllocatorDefault, 0) else { return nil }
    let value = prop.takeRetainedValue()
    if CFGetTypeID(value) == CFBooleanGetTypeID() { return CFBooleanGetValue((value as! CFBoolean)) }
    if let n = value as? NSNumber { return n.boolValue }
    return nil
}

// MARK: - Walk-up input watch (internal keyboard/trackpad via IOHIDManager)

// A burst of real local HID input means the owner is physically back. Synthetic
// remote events (Jump Desktop) never reach the internal device — that's the point.
final class WalkupWatcher {
    private var manager: IOHIDManager?
    private var timestamps: [Double] = []
    private var burstLatched = false   // sticky: survives until the next poll
    private let lock = NSLock()
    private let threshold: Int
    private static var loggedUnavailable = false

    init(threshold: Int) { self.threshold = threshold }

    func start() {
        Thread.detachNewThread { [weak self] in
            guard let self = self else { return }
            let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
            let matches: [[String: Any]] = [
                [kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
                 kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Keyboard],
                [kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
                 kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Mouse],
                [kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
                 kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Pointer],
            ]
            IOHIDManagerSetDeviceMatchingMultiple(mgr, matches as CFArray)
            let ctx = Unmanaged.passUnretained(self).toOpaque()
            IOHIDManagerRegisterInputValueCallback(mgr, { context, _, _, _ in
                guard let context = context else { return }
                Unmanaged<WalkupWatcher>.fromOpaque(context).takeUnretainedValue().recordEvent()
            }, ctx)
            if IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone)) != kIOReturnSuccess {
                if !WalkupWatcher.loggedUnavailable {
                    WalkupWatcher.loggedUnavailable = true
                    log("walk-up input watch unavailable (grant Input Monitoring for full walk-up)")
                }
                return  // fall back to lid-only detection
            }
            self.manager = mgr
            IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            RunLoop.current.run()
        }
    }

    func recordEvent() {
        let now = Date().timeIntervalSince1970
        lock.lock(); defer { lock.unlock() }
        timestamps.append(now)
        timestamps.removeAll { now - $0 > 5 }   // keep a rolling 5 s window
        // Latch the moment the window crosses threshold; the poll interval
        // (reconcileSeconds) is longer than the 5 s window, so a brief burst
        // would otherwise be pruned before the next consumeBurst.
        if timestamps.count >= threshold { burstLatched = true }
    }

    // True if a >= threshold burst has landed since the last poll; read-and-clears
    // the latch (and the window).
    func consumeBurst() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard burstLatched else { return false }
        burstLatched = false
        timestamps.removeAll()
        return true
    }
}

// MARK: - Reconciler

final class Reconciler {
    let cfg: Config
    let me: Machine
    let engine = DisplayEngine()
    var lastMode: Mode?
    lazy var walkup = WalkupWatcher(threshold: Int(cfg.walkupInputEvents ?? 20))
    var prevClamshell: Bool?
    var displaySleepAssertion: IOPMAssertionID = 0
    var nextStreamGuard = Date.distantPast
    var loggedStaleRideFrom: String?
    var lastLeaseTS: Double?
    // Stops the 2026-08-19 reconverge storm. Reset by anything that makes an
    // earlier "cannot converge" verdict stale.
    var breaker = ConvergeBreaker(limit: 5)

    init(cfg: Config) { self.cfg = cfg; self.me = selfMachine(cfg) }

    var isLaptop: Bool { me.laptopCanvas != nil }
    var passengerConverged: Bool { if case .passenger = lastMode { return true }; return false }

    // Started by the daemon only (not one-shot CLI ticks).
    func startWatchers() { if isLaptop { walkup.start() } }

    func tick() {
        // The wheel comes first: a machine that has lost it must stop behaving
        // like a driver before it does anything else this tick. This is the
        // ONLY path by which a viewer with no "target" role can learn it was
        // replaced — nothing ever places a ride on it, so the yield further
        // down in the .passenger branch is unreachable for it. air13 sat here
        // holding a dead claim through a sleep and a wake on 2026-08-19.
        if FileManager.default.fileExists(atPath: drivingFlag.path),
           wheelYields(me: me.id, myClaim: readDriverClaim(), wheel: readWheel()) {
            try? FileManager.default.removeItem(at: drivingFlag)
            let holder = readWheel()?.driver ?? "?"
            log("yielding the wheel to \(holder) (newer claim, via beacon)")
            emit("yield", [("to", .s(holder)), ("via", .s("beacon"))])
        }
        // Walk-up handback: a fresh handback file forces console regardless of ride.
        if let hts = readHandbackTS() {
            let hold = cfg.handbackHoldSeconds ?? 600
            if handbackIsFresh(ts: hts, hold: hold) {
                try? FileManager.default.removeItem(at: rideFile)
                convergeConsole()
                return
            }
            try? FileManager.default.removeItem(at: handbackFile)   // stale
        }

        let ride = readRide()
        let mode = computeMode(ride: ride, ttl: cfg.rideTTLSeconds,
                               now: Date().timeIntervalSince1970)
        switch mode {
        case .passenger(let canvasKey, let hidpi):
            // Two drivers at once is a bug, but *which* one yields has to be
            // decided by claim age rather than by "a ride showed up" — a lease
            // still in flight from the previous driver must not unseat the
            // driver the user just picked (2026-08-17).
            if FileManager.default.fileExists(atPath: drivingFlag.path) {
                if driverYields(myClaim: readDriverClaim(), theirClaim: ride?.claimedAt) {
                    try? FileManager.default.removeItem(at: drivingFlag)
                    log("yielding the wheel to \(ride?.driver ?? "?") (newer claim)")
                    emit("yield", [("to", .s(ride?.driver ?? "?"))])
                } else {
                    // Our claim is the newer one, so this ride is stale. Drop it
                    // and stay a driver; the sender yields as soon as it sees
                    // our claim on the ride we place on it.
                    try? FileManager.default.removeItem(at: rideFile)
                    if loggedStaleRideFrom != ride?.driver {
                        loggedStaleRideFrom = ride?.driver
                        log("ignoring stale ride from \(ride?.driver ?? "?") — we hold the newer claim")
                    }
                    convergeConsole()
                    return
                }
            }
            loggedStaleRideFrom = nil
            if let r = ride, r.ts != lastLeaseTS {
                lastLeaseTS = r.ts
                breaker.reset()   // a new lease deserves a fresh attempt
                // Age on arrival: a lease that lands most-expired is the signal
                // that the driver stamped it before a slow network op.
                emit("lease_recv", [("drv", .s(r.driver)), ("canvas", .s(r.canvas)),
                                    ("age", .n(Date().timeIntervalSince1970 - r.ts))])
            }
            // Measurement owns the size; the config entry is only the seed used
            // until the driver has a viewer window to measure.
            guard let seed = cfg.canvases[canvasKey] else { return }
            let canvas = rideCanvas(base: seed, ride: ride)
            let wantHi = hidpi && canvas.hidpi
            // A passenger never streams outward — enforce repeatedly, not just
            // on transition (the viewer can be relaunched under us). Held at
            // its original ~15 s cadence rather than the tick rate: the tick is
            // fast now so rides converge instantly, and three process spawns a
            // second on a laptop is a battery cost with no benefit.
            if Date() >= nextStreamGuard {
                killJumpViewer()
                nextStreamGuard = Date().addingTimeInterval(15)
            }
            let broken = engine.passengerInvariantFailure(canvas: canvas, hidpi: wantHi)
            if broken == nil, lastMode == mode { breaker.record(nil); checkWalkupTriggers(); return }
            // Already proved we cannot satisfy this ride: keep the owner's
            // display STILL and stay quiet until something actually changes.
            // Re-asserting a topology that just failed is what turned one bad
            // read into 89 minutes of strobing.
            guard breaker.shouldAttempt else { checkWalkupTriggers(); return }
            let t0 = Date()
            log("converge -> passenger(\(canvasKey), hidpi=\(wantHi))"
              + (broken.map { " — invariant broken: \($0)" } ?? ""))
            captureArrangement(engine: engine)
            applyHygiene()
            holdDisplayAwake()                                 // wake+hold display stack
            killJumpViewer()                                   // never stream outward
            guard engine.ensureVirtual(canvas: canvas) else { log("virtual create FAILED"); return }
            let applied = engine.applyPassengerTopology(canvas: canvas, hidpi: wantHi)
            routeAudio(passenger: true)
            let why = applied ? engine.settledInvariantFailure(canvas: canvas, hidpi: wantHi)
                              : "topology transaction failed"
            let ok = why == nil
            log("passenger converged=\(ok) in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s"
              + (why.map { " — \($0)" } ?? ""))
            emit("converge", [("canvas", .s(canvasKey)), ("hidpi", .b(wantHi)),
                              ("ms", .n(Date().timeIntervalSince(t0) * 1000)),
                              ("ok", .b(ok))] + (why.map { [("why", EV.s($0))] } ?? []))
            if breaker.record(why) {
                log("converge breaker TRIPPED after \(breaker.streak) identical failures "
                  + "(\(why ?? "?")) — holding the display still until something changes")
                emit("breaker_trip", [("why", .s(why ?? "?")), ("n", .n(Double(breaker.streak)))])
            }
            // The latch is only consumed while a passenger, so console-era
            // input (the owner using this machine hours ago) survives until
            // the first tick of the next ride and hands back a just-started
            // session (2026-08-12 incident). A ride start means the driver is
            // remote: discard anything latched before/while we converged.
            _ = walkup.consumeBurst()
            lastMode = mode
            checkWalkupTriggers()
        case .console:
            if let r = ride, lastLeaseTS == r.ts {   // the lease we were riding lapsed
                lastLeaseTS = nil
                emit("lease_expire", [("drv", .s(r.driver)),
                                      ("age", .n(Date().timeIntervalSince1970 - r.ts))])
            }
            convergeConsole()
        }
    }

    func convergeConsole() {
        breaker.reset()   // console is a clean slate for the next ride
        if lastMode == .console || (lastMode == nil && engine.virtualID == 0
            && !FileManager.default.fileExists(atPath: arrangementFile.path)) {
            // A fresh daemon can inherit a stale Jump audio route from a
            // predecessor that died mid-passenger: repair audio only, touch
            // nothing else (the user may have picked AirPods etc. at console).
            if lastMode == nil && currentDefaultOutputIsJump() { routeAudio(passenger: false) }
            lastMode = .console; return
        }
        log("converge -> console")
        engine.destroyVirtual()
        let restored = restoreArrangement(engine: engine)
        restoreHygiene()
        releaseDisplayAwake()
        routeAudio(passenger: false)
        // Re-baseline the lid so the first checkWalkupTriggers of the next
        // passenger session sees no phantom closed->open transition.
        prevClamshell = nil
        // On a failed arrangement restore, leave lastMode unset so the next
        // tick retries instead of permanently losing the saved arrangement.
        lastMode = restored ? .console : nil
    }

    // Laptops only, while converged: lid-open transition or a real-input burst
    // writes the handback file (acted on next tick).
    var prevIdle: Double?
    func checkWalkupTriggers() {
        guard loadSettings().walkupHandback else { return }
        // Presence detection works on any machine with local input (laptop
        // keyboard or a desktop's own mouse), needs no TCC, and keeps firing
        // while the person stays — so an expiring hold cannot re-claim them.
        let idle = hidIdleSeconds()
        defer { prevIdle = idle }
        if loadSettings().walkupPresence,
           consolePresent(idleNow: idle, idlePrev: prevIdle,
                          threshold: presenceThreshold(
                              configured: cfg.presenceThresholdSeconds,
                              reconcile: cfg.reconcileSeconds)),
           readClamshellState() != true,
           !inboundSessionActive() {
            log("walk-up: sustained local input (idle \(idle.map { String(format: "%.0f", $0) } ?? "?")s) — handing back")
            writeHandback()
            return
        }
        guard isLaptop else { return }
        let converged = passengerConverged
        let burst = walkup.consumeBurst()
        let nowClam = readClamshellState()
        let prev = prevClamshell ?? (nowClam ?? false)
        if shouldHandback(prevClamshell: prev, nowClamshell: nowClam ?? false,
                          inputBurst: burst, passengerConverged: converged) {
            writeHandback()
            log("walk-up detected -> handback")
        }
        if let nc = nowClam { prevClamshell = nc }
    }

    func holdDisplayAwake() {
        guard displaySleepAssertion == 0 else { return }
        var aid: IOPMAssertionID = 0
        if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                       IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                       "MIRA passenger" as CFString, &aid) == kIOReturnSuccess {
            displaySleepAssertion = aid
        }
    }

    func releaseDisplayAwake() {
        if displaySleepAssertion != 0 {
            IOPMAssertionRelease(displaySleepAssertion)
            displaySleepAssertion = 0
        }
    }
}

// MARK: - SSH to peers (multiplexed; sockets live in ~/.ssh — no spaces)

func sshArgs() -> String {
    // ServerAlive*: a peer that sleeps mid-session leaves its TCP connection
    // ESTABLISHED, and the ControlMaster parked on it then wedges every later
    // call — ConnectTimeout bounds the TCP connect, not the handoff to an
    // existing mux, so calls through it block forever. Measured 2026-08-16:
    // fresh connect to a sleeping air13 failed in 5.0 s, the same call through
    // its wedged mux was still blocked at 60 s, which stalled the driver's
    // heartbeat for minutes and dropped every passenger at its ride TTL.
    // Keepalives make the master notice in ~6 s and exit, so no wedge forms.
    "-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new " +
    "-o ServerAliveInterval=3 -o ServerAliveCountMax=2 " +
    "-o ControlMaster=auto -o ControlPath=~/.ssh/mira-%C -o ControlPersist=120"
}

// How long to leave a peer alone after consecutive failures. A machine that is
// simply asleep — the normal state of a grab-and-go laptop — must not cost the
// driver a connection attempt on every beat. Pure, so it is selftested.
func backoffSeconds(consecutiveFailures: Int) -> Double {
    guard consecutiveFailures > 0 else { return 0 }
    return min(60, 15 * pow(2, Double(consecutiveFailures - 1)))
}

// Per-peer reachability memory behind backoffSeconds().
final class PeerHealth {
    private let lock = NSLock()
    private var fails: [String: Int] = [:]
    private var nextTry: [String: Date] = [:]

    func shouldSkip(_ id: String, now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let t = nextTry[id] { return now < t }
        return false
    }

    func record(_ id: String, ok: Bool, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        if ok {
            if (fails[id] ?? 0) > 0 {
                log("peer \(id) reachable again"); emit("peer", [("id", .s(id)), ("up", .b(true))])
            }
            fails[id] = 0; nextTry[id] = nil
        } else {
            let n = (fails[id] ?? 0) + 1
            let wait = backoffSeconds(consecutiveFailures: n)
            fails[id] = n
            nextTry[id] = now.addingTimeInterval(wait)
            if n == 1 {
                log("peer \(id) unreachable — backing off \(Int(wait))s")
                emit("peer", [("id", .s(id)), ("up", .b(false))])
            }
        }
    }
}
let peerHealth = PeerHealth()

// `force` bypasses the backoff for on-demand commands (doctor, an explicit
// drive) where a truthful answer matters more than a fast one.
func peerRun(_ m: Machine, _ cmd: String, timeout: TimeInterval = 20,
             force: Bool = false) -> (out: String, code: Int32) {
    if !force && peerHealth.shouldSkip(m.id) { return ("", 125) }   // 125: skipped, not tried
    let q = cmd.replacingOccurrences(of: "'", with: "'\\''")
    let r = sh("ssh \(sshArgs()) \(m.user)@\(m.tailscale) '\(q)'", timeout: timeout)
    // 255 is ssh's own transport failure; 124 is our timeout kill. Anything the
    // remote command itself returns means the peer answered, so it is healthy.
    peerHealth.record(m.id, ok: r.code != 255 && r.code != 124)
    return r
}

// MARK: - Driver side

// Pure so it can be selftested. `expected` nil/empty => subnet alone decides.
// An empty observed MAC is inconclusive (transient arp miss) and must NOT demote
// a machine that really is at home — only a positively different MAC does.
func homeVerdict(onHomeSubnet: Bool, gatewayMAC: String, expected: String?) -> Bool {
    guard onHomeSubnet else { return false }
    guard let want = expected?.lowercased(), !want.isEmpty else { return true }
    let seen = gatewayMAC.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if seen.isEmpty { return true }
    return seen == want
}

func atHome(cfg: Config) -> Bool {
    let onSubnet = sh("ifconfig 2>/dev/null | awk '/inet /{print $2}'").out
        .contains(cfg.homeSubnetPrefix)
    let mac = sh("route -n get default 2>/dev/null | awk '/gateway/{print $2}'"
               + " | xargs -I{} arp -n {} 2>/dev/null | awk '{print $4}'").out
    return homeVerdict(onHomeSubnet: onSubnet, gatewayMAC: mac, expected: cfg.homeGatewayMAC)
}

func measureNet(to m: Machine) -> (avg: Double, jitter: Double)? {
    let out = sh("ping -c 15 -i 0.2 -q \(m.tailscale) 2>/dev/null | awk -F/ '/round-trip/{gsub(/[^0-9.]/,\"\",$7); print $5, $7}'", timeout: 15).out
    let parts = out.split(separator: " ").compactMap { Double($0) }
    guard parts.count == 2 else { return nil }
    return (parts[0], parts[1])
}

func driverCanvasKey(cfg: Config, me: Machine, engine: DisplayEngine) -> String {
    pickCanvas(physicalWidths: engine.physicalWidths(),
               dockedCanvas: me.dockedCanvas ?? cfg.dockedCanvas,
               laptopCanvas: me.laptopCanvas ?? "laptop-pro")
}

// MARK: - One driver at a time

// Two machines driving at once is not a tie — it oscillates. Each places a ride
// on the other; the reconciler clears its own driving flag when it sees a ride
// (see "driving flag cleared: now a passenger"), so both demote themselves and
// then re-claim on the next tick, fighting over the canvas every reconcileSeconds.
// Observed 2026-08-16: pro and air13 both driving left passengers at double the
// intended logical size and reconverging endlessly.
// Claiming is therefore explicit — stop every other viewer BEFORE placing rides.
let wheelDir = "$HOME/Library/Application Support/MIRA"

// One round trip that both takes the wheel away and leaves proof behind: drop
// the peer's flag AND install our beacon, so a peer we reached cannot be left
// holding the wheel, and a peer that later restarts still finds our claim.
// force: an explicit Drive is the most deliberate statement of intent in the
// system and must never be skipped by a cached "unreachable" verdict. That
// exact skip is how 2026-08-19 produced two drivers: air13 went into a 15 s
// backoff at 18:16:36, so the second click four seconds later never even
// attempted an SSH — it read 125 from the backoff and reported "could not
// reach". peerRun's own comment already said force was for "doctor, an
// explicit drive"; doctor passed it and drive did not.
func takeWheel(from m: Machine, driver: String, claimedAt: Double) -> Bool {
    let w = Wheel(driver: driver, claimedAt: claimedAt, ts: Date().timeIntervalSince1970)
    guard let d = try? JSONEncoder().encode(w), let json = String(data: d, encoding: .utf8)
    else { return false }
    return peerRun(m, "rm -f \"\(wheelDir)/driving\" && mkdir -p \"\(wheelDir)\" "
                    + "&& printf %s '\(json)' > \"\(wheelDir)/wheel.json.tmp\" "
                    + "&& mv -f \"\(wheelDir)/wheel.json.tmp\" \"\(wheelDir)/wheel.json\"",
                   timeout: 10, force: true).code == 0
}

// The heartbeat half of the same idea, and the reason handoff is now
// self-healing rather than best-effort: re-assert our beacon on every other
// viewer each beat, and read back whatever claim that peer holds. A machine
// that was asleep when the wheel changed hands gets our claim on its first
// reachable beat and yields itself. A peer holding a NEWER claim than ours
// means we are the stale driver, and we stand down.
// Not forced: this runs every beat, and a sleeping laptop must not cost a
// connection attempt every 30 s — that is what the backoff is for.
func syncWheel(with m: Machine, driver: String, claimedAt: Double) -> (reached: Bool, theirClaim: Double?) {
    let w = Wheel(driver: driver, claimedAt: claimedAt, ts: Date().timeIntervalSince1970)
    guard let d = try? JSONEncoder().encode(w), let json = String(data: d, encoding: .utf8)
    else { return (false, nil) }
    let r = peerRun(m, "mkdir -p \"\(wheelDir)\" "
                     + "&& printf %s '\(json)' > \"\(wheelDir)/wheel.json.tmp\" "
                     + "&& mv -f \"\(wheelDir)/wheel.json.tmp\" \"\(wheelDir)/wheel.json\"; "
                     + "echo \"CLAIM=$(cat \"\(wheelDir)/driving\" 2>/dev/null)\"", timeout: 10)
    guard r.code == 0 else { return (false, nil) }
    return (true, parseClaimReadback(r.out))
}

// The peer's own claim, out of syncWheel's read-back. Pure so the parse is
// selftested rather than trusted: getting this wrong in the lenient direction
// (junk read as a huge claim) would make a driver yield to nothing and leave
// the fleet with NO driver, which is worse than the bug being fixed. An absent
// flag prints "CLAIM=" and must read as "no claim", never as 0 — a peer with a
// real claim of 0 does not exist, but a peer with no claim is the normal case.
func parseClaimReadback(_ out: String) -> Double? {
    guard let line = out.components(separatedBy: .newlines)
            .first(where: { $0.hasPrefix("CLAIM=") }) else { return nil }
    let v = line.dropFirst("CLAIM=".count).trimmingCharacters(in: .whitespaces)
    guard !v.isEmpty, let d = Double(v), d > 0, d.isFinite else { return nil }
    return d
}

// Parking releases the wheel everywhere, so no peer's menu bar goes on naming a
// driver that stopped. Best-effort by nature: a beacon we fail to clear only
// expires a menu label (wheelHolder has a TTL), it can never strand anyone.
func clearWheel(on m: Machine) {
    _ = peerRun(m, "rm -f \"\(wheelDir)/wheel.json\"", timeout: 10, force: true)
}

// What an explicit claim actually achieved. `unreachable` is the honest half:
// those machines keep the wheel until they can be reached, and the beat-by-beat
// syncWheel above is what eventually takes it from them.
struct Handoff { let stopped: [String]; let unreachable: [String] }

@discardableResult
func stopOtherDrivers(cfg: Config, me: Machine) -> Handoff {
    let claim = readDriverClaim() ?? Date().timeIntervalSince1970
    let others = otherViewers(cfg: cfg, me: me)
    let results = forEachPeer(others) { takeWheel(from: $0, driver: me.id, claimedAt: claim) }
    // Report in config order, not completion order, so the output is stable.
    var stopped: [String] = [], unreachable: [String] = []
    for other in others {
        if results[other.id] == true {
            stopped.append(other.id)
            log("stopped driving on \(other.id) — taking over as driver")
        } else {
            unreachable.append(other.id)
            log("could not reach \(other.id) to stop its driving flag "
              + "— it yields on its first reachable beat")
        }
    }
    if !unreachable.isEmpty {
        emit("handoff_incomplete", [("unreachable", .s(unreachable.joined(separator: "+")))])
    }
    return Handoff(stopped: stopped, unreachable: unreachable)
}

func placeRide(on target: Machine, canvas: String, hidpi: Bool, driver: String,
               content: ContentArea? = nil) -> Bool {
    let ride = Ride(driver: driver, canvas: canvas, hidpi: hidpi,
                    ts: Date().timeIntervalSince1970, claimedAt: readDriverClaim(),
                    canvasW: content?.w, canvasH: content?.h)
    guard let d = try? JSONEncoder().encode(ride),
          let json = String(data: d, encoding: .utf8) else { return false }
    let dir = "$HOME/Library/Application Support/MIRA"
    // Write-then-rename, not `> ride.json`: an in-place rewrite can be read
    // half-written by a passenger that is now watching for changes rather than
    // polling on a slow timer, and a rename is the event its directory watcher
    // sees for both a new ride and a changed one.
    let r = peerRun(target, "mkdir -p \"\(dir)\" && printf %s '\(json)' > \"\(dir)/ride.json.tmp\" "
                          + "&& mv -f \"\(dir)/ride.json.tmp\" \"\(dir)/ride.json\"")
    // A ride that does not land is the whole ballgame: the passenger keeps its
    // old ride until the TTL, then drops to console and its physical display
    // comes back (the BenQ snapping to 3440x1440). This used to return a Bool
    // that every caller discarded, so six consecutive misses produced not one
    // line of evidence anywhere -- no backoff event, no fan-out timeout, just a
    // passenger mysteriously "back to widescreen" (2026-08-19).
    if r.code != 0 {
        let why = r.code == 125 ? " (skipped by backoff)"
                : r.code == 124 ? " (our timeout killed it)"
                : r.code == 255 ? " (ssh transport)" : ""
        log("ride NOT placed on \(target.id): code \(r.code)\(why)"
          + (r.out.isEmpty ? "" : " — \(r.out.prefix(160))"))
        emit("ride_failed", [("id", .s(target.id)), ("code", .n(Double(r.code)))])
    }
    return r.code == 0
}

func endRide(on target: Machine) {
    liveRideHiDPI.removeValue(forKey: target.id)
    _ = peerRun(target, "rm -f \"$HOME/Library/Application Support/MIRA/ride.json\"")
}

// An explicit Drive is a deliberate override: clear the target's own walk-up
// handback so its daemon stops forcing console, and forget any noticed state so
// the driver stops skipping it.
func clearRemoteHandback(on target: Machine) {
    _ = peerRun(target, "rm -f \"$HOME/Library/Application Support/MIRA/handback\"")
    handbackNoticedLock.lock(); handbackNoticed.remove(target.id); handbackNoticedLock.unlock()
}

func macPassengers(cfg: Config, me: Machine) -> [Machine] {
    cfg.machines.filter { $0.id != me.id && $0.roles.contains("target") && ($0.type ?? "mac") == "mac" }
}

// Every machine that could be holding the wheel right now. Deliberately NOT
// macPassengers: a viewer with no "target" role never receives a ride, so
// anything that fans out over passengers alone cannot reach every driver. It
// shares mayDrive with the claim path so the two can never drift apart.
func otherViewers(cfg: Config, me: Machine) -> [Machine] {
    cfg.machines.filter { $0.id != me.id && mayDrive(roles: $0.roles) }
}

// Fan out over machines concurrently, collecting results by machine id.
// doctor() has always probed its peers this way; the drive path had not, so
// every passenger paid its own serial SSH round trip (two of them) before the
// next one even started — N passengers cost N times one passenger.
// `deadline` is a hard cap on how long one peer can hold up the rest: a
// straggler's work continues in the background and its result is discarded.
// Without this the driver's heartbeat was only as fast as its slowest machine,
// so one sleeping laptop delayed every ride the fleet placed.
func forEachPeer<T>(_ ms: [Machine], deadline: TimeInterval = 8,
                    _ body: @escaping (Machine) -> T) -> [String: T] {
    if ms.isEmpty { return [:] }
    let group = DispatchGroup(), lock = NSLock()
    var out: [String: T] = [:]
    for m in ms {
        group.enter()
        DispatchQueue.global().async {
            let r = body(m)
            lock.lock(); out[m.id] = r; lock.unlock()
            group.leave()
        }
    }
    if group.wait(timeout: .now() + deadline) == .timedOut {
        lock.lock(); let answered = Set(out.keys); lock.unlock()
        let late = ms.map { $0.id }.filter { !answered.contains($0) }
        log("peer fan-out: \(late.joined(separator: ", ")) did not answer in \(Int(deadline))s — continuing without them")
    }
    lock.lock(); defer { lock.unlock() }
    return out
}

// Targets whose fresh handback we've already logged this walk-up (log once each).
// Guarded: the drive path now probes passengers concurrently.
var handbackNoticed: Set<String> = []
let handbackNoticedLock = NSLock()

// A target that has walked itself up (fresh handback) is left alone this beat.
func targetWalkedUp(_ t: Machine, cfg: Config) -> Bool {
    let hb = peerRun(t, "cat \"$HOME/Library/Application Support/MIRA/handback\" 2>/dev/null")
        .out.trimmingCharacters(in: .whitespacesAndNewlines)
    handbackNoticedLock.lock(); defer { handbackNoticedLock.unlock() }
    guard let hts = Double(hb),
          handbackIsFresh(ts: hts, hold: cfg.handbackHoldSeconds ?? 600) else {
        handbackNoticed.remove(t.id); return false
    }
    if !handbackNoticed.contains(t.id) {
        log("skipping \(t.id): walked up (fresh handback)")
        handbackNoticed.insert(t.id)
    }
    return true
}

var liveRideHiDPI: [String: Bool] = [:]

// Re-assert our claim on every other viewer and collect theirs. Returns the id
// of a peer whose claim outranks ours (having already dropped our own flag), or
// nil when we still hold the wheel. Both halves matter: the push is how a peer
// that was unreachable at claim time finds out it lost, and the pull is how we
// find out we are the stale one when OUR stop was the one that missed.
func syncWheelWithViewers(cfg: Config, me: Machine) -> String? {
    let myClaim = readDriverClaim()
    let peers = otherViewers(cfg: cfg, me: me)
    let results = forEachPeer(peers) { syncWheel(with: $0, driver: me.id,
                                                 claimedAt: myClaim ?? 0) }
    for p in peers {   // config order, so a tie resolves the same way everywhere
        guard let r = results[p.id], r.reached,
              driverYields(myClaim: myClaim, theirClaim: r.theirClaim) else { continue }
        try? FileManager.default.removeItem(at: drivingFlag)
        return p.id
    }
    return nil
}

func driveTick(cfg: Config, me: Machine, engine: DisplayEngine, previousTier: Tier) -> Tier {
    // Settle who holds the wheel BEFORE moving anyone's display. Two drivers
    // placing rides on the same passenger is the whole failure this beat
    // exists to prevent, so it is resolved first and rides are skipped
    // entirely on the beat we stand down.
    if let yieldedTo = syncWheelWithViewers(cfg: cfg, me: me) {
        log("yielding the wheel to \(yieldedTo) — it holds a newer claim")
        emit("yield", [("to", .s(yieldedTo)), ("via", .s("peer-claim"))])
        return previousTier
    }
    if defendedPanel == nil { captureConsolePanel() } else { defendConsolePanel() }
    let canvas = driverCanvasKey(cfg: cfg, me: me, engine: engine)
    let home = atHome(cfg: cfg)
    let docked = canvas == (me.dockedCanvas ?? cfg.dockedCanvas)
    var tier = previousTier
    if let net = macPassengers(cfg: cfg, me: me).lazy.compactMap({ measureNet(to: $0) }).first {
        tier = computeTier(previous: previousTier, avgMs: net.avg, jitterMs: net.jitter,
                           home: home, docked: docked)
        if tier != previousTier {
            log("tier \(previousTier.rawValue) -> \(tier.rawValue) (avg=\(String(format: "%.0f", net.avg))ms jitter=\(String(format: "%.0f", net.jitter))ms home=\(home) canvas=\(canvas))")
        }
    }
    let hidpi = tierWantsHiDPI(tier) && loadSettings().hidpiRides
    // Close the loop: what the passengers render is what this viewer actually
    // shows, re-measured every tick. A mode change, a notch, a window resize or
    // a new machine corrects itself here instead of waiting to be noticed by eye.
    let measured = adoptMeasurement(previous: lastMeasuredContent, observed: observedViewerContent())
    if let m = measured, m != lastMeasuredContent {
        lastMeasuredContent = m
        log("viewer content area measured \(m.w)x\(m.h) — canvas follows it")
        emit("content_measured", [("w", .n(Double(m.w))), ("h", .n(Double(m.h)))])
    }
    _ = forEachPeer(macPassengers(cfg: cfg, me: me)) { t in
        targetWalkedUp(t, cfg: cfg) ? false
            : placeRide(on: t, canvas: canvas, hidpi: hidpi, driver: me.id, content: measured)
    }
    return tier
}

// MARK: - Who holds the wheel, fleet-wide

// Ask every machine that COULD be driving whether it is. Answering this used to
// require SSHing to each Mac by hand and remembering where the flag lives; there
// was no fleet-wide view of driver state anywhere in the system, which is why
// two drivers could run for a day without anything noticing.
struct WheelSurvey {
    let claimants: [String]      // machines holding a driving flag, config order
    let unreachable: [String]    // machines that could not be asked
    let claims: [String: Double] // id -> claim stamp, where one was readable
}

// The flag's EXISTENCE is what makes a machine a driver; the stamp only decides
// who wins. An unstamped flag (older build, or a write that lost its contents)
// still drives, so the probe reports the two facts separately — "CLAIM=" alone
// cannot tell an empty flag from a missing one.
func parseWheelProbe(_ out: String) -> (flag: Bool, claim: Double?)? {
    guard let line = out.components(separatedBy: .newlines)
            .first(where: { $0.hasPrefix("FLAG=") }) else { return nil }
    return (line.dropFirst("FLAG=".count).trimmingCharacters(in: .whitespaces) == "yes",
            parseClaimReadback(out))
}

func surveyWheel(cfg: Config, me: Machine) -> WheelSurvey {
    let peers = otherViewers(cfg: cfg, me: me)
    let probe = "echo \"FLAG=$([ -f \"\(wheelDir)/driving\" ] && echo yes || echo no)\"; "
              + "echo \"CLAIM=$(cat \"\(wheelDir)/driving\" 2>/dev/null)\""
    let out = forEachPeer(peers, deadline: 15) { p in
        // force: a survey must probe, not report a cached "unreachable" verdict.
        let r = peerRun(p, probe, timeout: 10, force: true)
        return r.code == 0 ? parseWheelProbe(r.out) : nil
    }
    var claimants: [String] = [], unreachable: [String] = [], claims: [String: Double] = [:]
    if FileManager.default.fileExists(atPath: drivingFlag.path) {
        claimants.append(me.id)
        if let c = readDriverClaim() { claims[me.id] = c }
    }
    for p in peers {   // config order, so the report is stable run to run
        guard let answer = out[p.id], let a = answer else { unreachable.append(p.id); continue }
        if a.flag {
            claimants.append(p.id)
            if let c = a.claim { claims[p.id] = c }
        }
    }
    return WheelSurvey(claimants: claimants, unreachable: unreachable, claims: claims)
}

// MARK: - Doctor

func doctor(cfg: Config, me: Machine) -> (report: String, failures: Int) {
    var lines = ["MIRA Doctor — \(me.id)"], failures = 0
    let group = DispatchGroup(); let lock = NSLock(); var peerLines: [String] = []
    for t in macPassengers(cfg: cfg, me: me) {
        group.enter()
        DispatchQueue.global().async {
            var l: [String] = []
            // No dumpmacperm over SSH here — that probe reports false for every
            // permission outside the gui domain (2026-07-28 finding). The
            // passenger's own daemon publishes health.json from a truthful context.
            let probe = peerRun(t, """
            echo user=$(whoami); \
            pgrep -f 'MIRA.app/Contents/MacOS/MIRA --daemon' >/dev/null && echo daemon=ok || echo daemon=missing; \
            echo "HEALTH=$(cat "$HOME/Library/Application Support/MIRA/health.json" 2>/dev/null | tr -d ' \\n')"; \
            cat "$HOME/Library/Application Support/MIRA/ride.json" 2>/dev/null || echo no-ride
            """, timeout: 15, force: true)   // doctor must probe, not read a cached verdict
            if probe.code != 0 { l.append("✗ \(t.id) unreachable"); lock.lock(); failures += 1; lock.unlock() }
            else {
                let o = probe.out
                l.append("✓ \(t.id) reachable")
                if o.contains("daemon=missing") {
                    l.append("✗ \(t.id) daemon not running"); lock.lock(); failures += 1; lock.unlock()
                } else { l.append("✓ \(t.id) daemon running") }
                let health = o.components(separatedBy: "\n")
                    .first(where: { $0.hasPrefix("HEALTH=") })
                    .flatMap { try? JSONDecoder().decode(Health.self, from: Data($0.dropFirst(7).utf8)) }
                if let h = health, Date().timeIntervalSince1970 - h.ts < 900 {
                    if h.accessibility && h.screenRecording {
                        l.append("✓ \(t.id) Jump Connect permissions intact")
                    } else {
                        l.append("✗ \(t.id) Jump Connect lost \(h.accessibility ? "" : "Accessibility ")\(h.screenRecording ? "" : "Screen Recording")— re-grant on that machine")
                        lock.lock(); failures += 1; lock.unlock()
                    }
                } else {
                    l.append("! \(t.id) no fresh permission report (daemon old or probe failing) — not counted as failure")
                }
                l.append(o.contains("no-ride") ? "  \(t.id): parked" : "  \(t.id): being driven")
            }
            lock.lock(); peerLines.append(contentsOf: l); lock.unlock()
            group.leave()
        }
    }
    group.wait()
    lines.append(contentsOf: peerLines.sorted())
    // Viewer-side vitals: menu app alive with its Accessibility grant, and a
    // session alias per passenger so opening never depends on UI scripting.
    if me.roles.contains("viewer") {
        let vh = (try? Data(contentsOf: viewerHealthFile))
            .flatMap { try? JSONDecoder().decode(ViewerHealth.self, from: $0) }
        if let h = vh, Date().timeIntervalSince1970 - h.ts < 900 {
            if h.axTrusted { lines.append("✓ menu app running with Accessibility") }
            else {
                lines.append("✗ menu app lost Accessibility — scroll reversal and menu fallback dead (re-grant for MIRA)")
                failures += 1
            }
            if !h.scrollTap { lines.append("! scroll tap not installed (grant made after launch? toggle Reverse Mouse Scrolling)") }
        } else {
            lines.append("✗ menu app not running (no fresh viewer health) — boot-resume will not fire; open MIRA.app")
            failures += 1
        }
        for t in macPassengers(cfg: cfg, me: me)
        where !FileManager.default.fileExists(atPath: sessionAlias(for: t.id).path) {
            lines.append("! no session alias for \(t.id) — File > Export in Jump Desktop, put \(t.id).jump in \(aliasesDir.path)")
        }
    }
    // Geometry. Every round of "the resolution is wrong" happened while doctor
    // said ready, because doctor had never once looked at a screen.
    let mainD = CGMainDisplayID()
    if let now = currentPanelMode(mainD), let native = nativePanelAspect(mainD) {
        let isHiDPI = now.px >= now.w * 2
        let aspect = now.h > 0 ? Double(now.w) / Double(now.h) : 0
        let aspectOK = abs(aspect - native) <= 0.01
        if isHiDPI && aspectOK {
            lines.append("✓ console panel \(now.w)x\(now.h) HiDPI at native aspect")
        } else {
            lines.append("✗ console panel \(now.w)x\(now.h) px=\(now.px)x\(now.py)"
                + (isHiDPI ? "" : " is NOT HiDPI (1x renders small and soft)")
                + (aspectOK ? "" : String(format: " — aspect %.3f, panel is %.3f (bars at the edges)", aspect, native)))
            failures += 1
        }
    }
    if FileManager.default.fileExists(atPath: drivingFlag.path) {
        if let seen = observedViewerContent() {
            lines.append("✓ viewer content area \(seen.w)x\(seen.h) — canvas follows this measurement")
        } else {
            lines.append("! driving but no Jump viewer window found to measure — passengers are on the config seed")
        }
    }
    for taker in screenTakers() where !taker.hasPrefix("inbound Jump") {
        lines.append("! \(taker) can renegotiate this Mac's resolution")
    }
    // A long-lived inbound session is not cosmetic: it renegotiates this Mac's
    // resolution whenever it goes active. One at 14h24m is what spent an evening
    // undoing every fix (2026-08-18).
    for line in sh("ps -Ao etime,command | grep '[d]esktopproxy'").out.split(separator: "\n") {
        let field = line.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init)
        guard let secs = field.flatMap(parseETime) else { continue }
        if secs > 12 * 3600 {
            lines.append(String(format: "✗ inbound Jump session open %.1fh — it renegotiates this Mac's display; quit the viewer holding it", secs / 3600))
            failures += 1
        } else if secs > 4 * 3600 {
            lines.append(String(format: "! inbound Jump session open %.1fh", secs / 3600))
        }
    }
    let vnc = sh("ps -Aro pcpu,comm | awk '$2 ~ /screensharingd/ && $1+0 > 5'").out
    if !vnc.trimmingCharacters(in: .whitespaces).isEmpty {
        lines.append("✗ inbound session is VNC — use the Fluid entry"); failures += 1
    } else { lines.append("✓ no VNC session detected") }
    // Two drivers is the failure nothing ever detected: it was only ever visible
    // as passengers behaving oddly, and doctor only probed TARGETS, so a viewer
    // like air13 holding a second claim was outside everything it looked at.
    let wheelState = surveyWheel(cfg: cfg, me: me)
    if wheelState.claimants.count > 1 {
        lines.append("✗ TWO DRIVERS: \(wheelState.claimants.joined(separator: " and ")) both hold a claim"
                   + " — run Drive from Here on the one you want")
        failures += 1
    } else if let only = wheelState.claimants.first {
        lines.append("✓ one driver: \(only)")
    } else {
        lines.append("✓ nobody is driving")
    }
    for id in wheelState.unreachable {
        lines.append("! \(id) unreachable — cannot confirm whether it holds the wheel")
    }
    lines.append(failures == 0 ? "Doctor: ready" : "Doctor: \(failures) failure(s)")
    return (lines.joined(separator: "\n"), failures)
}

// MARK: - Wakeups

// Watches ride state and wakes the loop the moment it changes. Two sources are
// needed: placing a ride with `mv` changes the *directory*, while an in-place
// rewrite (`> ride.json`, which is what drivers older than this build do)
// changes only the *file*. Watching one alone misses half the transitions.
final class StateWatcher {
    private let wake: DispatchSemaphore
    private let queue = DispatchQueue(label: "com.amir.mira.statewatch")
    private var dirSource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?

    init(wake: DispatchSemaphore) { self.wake = wake }

    func start() {
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        queue.async { [self] in
            dirSource = makeSource(stateDir, mask: [.write])
            armFile()
        }
    }

    // Always called on `queue`. The ride file is created and deleted over and
    // over, and a source outlives its inode without delivering, so re-arm on
    // every event rather than trusting the first one.
    private func armFile() {
        fileSource?.cancel()
        fileSource = nil
        guard FileManager.default.fileExists(atPath: rideFile.path) else { return }
        fileSource = makeSource(rideFile, mask: [.write, .extend, .delete, .rename])
    }

    private func makeSource(_ url: URL, mask: DispatchSource.FileSystemEvent)
        -> DispatchSourceFileSystemObject? {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let s = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: mask, queue: queue)
        s.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.armFile()
            self.wake.signal()
        }
        s.setCancelHandler { close(fd) }
        s.resume()
        return s
    }
}

// MARK: - Daemon

func runDaemon(cfg: Config) -> Never {
    let rec = Reconciler(cfg: cfg)
    rec.startWatchers()
    eventMachineID = rec.me.id
    // A claim that should never have existed must not survive a reboot either.
    if !mayDrive(roles: rec.me.roles), FileManager.default.fileExists(atPath: drivingFlag.path) {
        try? FileManager.default.removeItem(at: drivingFlag)
        log("cleared a driving claim on \(rec.me.id): passenger-only machines never drive")
        emit("drive_claim_cleared", [("id", .s(rec.me.id))])
    }
    log("mira daemon started on \(rec.me.id) (driver+passenger roles: \(rec.me.roles))")
    emit("start", [("roles", .s(rec.me.roles.joined(separator: "+")))])
    var tier: Tier = .standard
    // Cuts a poll interval short. The daemon used to learn about a new ride
    // only on its next tick, so a ride landing just after one waited out the
    // whole of reconcileSeconds before any display moved — measured as the
    // single largest cost in "grab a laptop and drive" (avg ~7.5 s of ~15 s).
    let wake = DispatchSemaphore(value: 0)
    let stateWatcher = StateWatcher(wake: wake)   // held for the process lifetime
    stateWatcher.start()
    // Event-driven, so the daemon learns the topology moved the moment it moves
    // rather than up to reconcileSeconds later -- and so a change we did NOT
    // cause is recorded as evidence. Attributing display changes was the whole
    // difficulty on 2026-08-18/19: a stale Jump viewer renegotiates resolution
    // at unpredictable intervals and looked exactly like MIRA misbehaving.
    //
    // Our own writes fire this callback too. A breaker that reset on those
    // could never trip, so only external changes clear it.
    displayReconfigured = { flags in
        // The callback fires twice per change; the begin pass carries no state.
        if flags.contains(.beginConfigurationFlag) { return }
        let ours = Date().timeIntervalSince(lastSelfDisplayWrite) < 3
        log("display reconfigured — \(ours ? "ours" : "EXTERNAL (not MIRA)")")
        emit("display_reconfig", [("ours", .b(ours)), ("flags", .n(Double(flags.rawValue)))])
        if !ours { rec.breaker.reset() }
        wake.signal()
    }
    CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
        displayReconfigured?(flags)
    }, nil)
    // Wall-clock deadlines rather than per-iteration decrements: the loop is
    // woken early now, so counting iterations would fire the heartbeat far
    // more often than heartbeatSeconds. distantPast = due immediately, which
    // also fixes a latent stall — the old counter kept its value across a
    // stop/resume, so resuming a drive could wait two full intervals.
    var nextDrive = Date.distantPast
    var nextHealth = Date.distantPast
    // Undock/dock changes the driver's canvas. Waiting for the next heartbeat
    // to notice left passengers on the stale canvas for up to heartbeatSeconds;
    // driverCanvasKey is local CoreGraphics only, so it is cheap to check every
    // tick and re-assert the moment it moves.
    var lastCanvas: String?
    while true {
        rec.tick()
        if rec.me.roles.contains("viewer"),
           FileManager.default.fileExists(atPath: drivingFlag.path) {
            let canvas = driverCanvasKey(cfg: cfg, me: rec.me, engine: rec.engine)
            let canvasChanged = lastCanvas != nil && lastCanvas != canvas
            if canvasChanged { log("driver canvas \(lastCanvas!) -> \(canvas); re-asserting now") }
            lastCanvas = canvas
            if Date() >= nextDrive || canvasChanged {
                // Scheduled from the START of the beat, not the end. Measuring
                // from the end makes the real period heartbeat + however long
                // the beat took, which quietly ate the margin against
                // rideTTLSeconds — the thing that drops passengers to console.
                nextDrive = Date().addingTimeInterval(cfg.heartbeatSeconds)
                let beatT0 = Date()
                tier = driveTick(cfg: cfg, me: rec.me, engine: rec.engine, previousTier: tier)
                let spent = Date().timeIntervalSince(beatT0)
                emit("beat", [("ms", .n(spent * 1000))])
                // Loud when a beat eats enough of the TTL to threaten a drop.
                if spent > cfg.heartbeatSeconds {
                    log("drive beat took \(String(format: "%.1f", spent))s "
                      + "(> heartbeat \(Int(cfg.heartbeatSeconds))s, TTL \(Int(cfg.rideTTLSeconds))s)")
                }
            }
        } else {
            lastCanvas = nil   // not driving: re-baseline so resuming is not a "change"
        }
        if Date() >= nextHealth {
            writeHealth(); nextHealth = Date().addingTimeInterval(300)
        }
        // Sleep, but return the instant ride state changes on disk.
        _ = wake.wait(timeout: .now() + cfg.reconcileSeconds)
        while wake.wait(timeout: .now()) == .success {}   // collapse a burst
    }
}

// MARK: - Scroll reversal (MenuApp only — it holds Accessibility)

// Negate classic wheel-mouse deltas; leave continuous (trackpad/Magic Mouse)
// gestures untouched. Re-enables the tap if the system disables it.
var scrollReversalEnabled = loadSettings().reverseScroll

// Pure, selftested: reverse only phase-less scrolls (real wheels).
func shouldReverseScroll(phase: Int64, momentum: Int64) -> Bool {
    phase == 0 && momentum == 0
}

func scrollTapCallback(proxy: CGEventTapProxy, type: CGEventType,
                       event: CGEvent, userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let userInfo = userInfo,
           let tap = Unmanaged<MenuApp>.fromOpaque(userInfo).takeUnretainedValue().scrollTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passUnretained(event)
    }
    // A wheel — classic or hi-res "continuous" — never carries gesture phases;
    // trackpad and Magic Mouse scrolls always do (live phase or momentum).
    guard scrollReversalEnabled, type == .scrollWheel,
          shouldReverseScroll(
              phase: event.getIntegerValueField(.scrollWheelEventScrollPhase),
              momentum: event.getIntegerValueField(.scrollWheelEventMomentumPhase)) else {
        return Unmanaged.passUnretained(event)
    }
    // The delta fields are linked views onto shared storage: writing one can
    // update another, so a naive negate-in-sequence re-flips earlier writes
    // (observed: line delta reversed, point delta untouched). Read every
    // original first, then write all negations from the saved values.
    let d1 = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
    let d2 = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
    let p1 = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
    let p2 = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
    let f1 = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
    let f2 = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
    event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: -d1)
    event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: -d2)
    event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: -p1)
    event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: -p2)
    event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: -f1)
    event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: -f2)
    return Unmanaged.passUnretained(event)
}

// MARK: - Menu bar

final class MenuApp: NSObject, NSApplicationDelegate {
    var item: NSStatusItem!
    let cfg = loadConfig()
    lazy var me = selfMachine(cfg)
    var scrollTap: CFMachPort?

    func applicationDidFinishLaunching(_ n: Notification) {
        // Only the daemon used to set this, so every event the menu app emitted
        // — including "claim", the most important one to be able to attribute —
        // landed in the log as machine "?".
        eventMachineID = me.id
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        rebuild()
        installScrollTap()
        // Standalone app: present at every login (scroll reversal + boot-resume
        // depend on the menu app running, not on the user remembering to launch it).
        if SMAppService.mainApp.status != .enabled {
            do { try SMAppService.mainApp.register(); log("registered as login item") }
            catch { log("login item registration failed: \(error.localizedDescription)") }
        }
        writeViewerHealth()
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.writeViewerHealth()
        }
        maybeResumeSessions()
    }

    func writeViewerHealth() {
        let h = ViewerHealth(axTrusted: AXIsProcessTrusted(), scrollTap: scrollTap != nil,
                             ts: Date().timeIntervalSince1970)
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(h) { try? d.write(to: viewerHealthFile) }
    }

    func installScrollTap() {
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: scrollTapCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            log("scroll tap creation failed (grant Accessibility)")
            return
        }
        scrollTap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        log("scroll tap active")
    }
    var driving: Bool { FileManager.default.fileExists(atPath: drivingFlag.path) }
    func setIcon() {
        let name = driving ? "steeringwheel" : "display.2"
        if let img = NSImage(systemSymbolName: name, accessibilityDescription: "MIRA") {
            img.isTemplate = true
            item.button?.image = img
            item.button?.title = ""
        } else {
            item.button?.title = "◈"
        }
    }
    func rebuild() {
        setIcon()
        let m = NSMenu()
        let excluded = loadExcluded()
        let riding = macPassengers(cfg: cfg, me: me).filter { !excluded.contains($0.id) }.count
        // Every machine now knows who holds the wheel, not just whether it does
        // itself. Before this there was no fleet-wide driver state anywhere:
        // two menu bars could both show a steering wheel and neither could say so.
        let elsewhere = wheelHolder(wheel: readWheel(), me: me.id, ttl: cfg.rideTTLSeconds)
        let header = driving ? "Driving \(riding) passenger\(riding == 1 ? "" : "s")"
                             : (elsewhere.map { "Parked — \($0) is driving" } ?? "Parked")
        m.addItem(withTitle: header, action: nil, keyEquivalent: "")
        m.addItem(.separator())
        if driving {
            m.addItem(withTitle: "Stop Driving", action: #selector(stop), keyEquivalent: "d").target = self
            m.addItem(withTitle: "Reopen Session Windows", action: #selector(reopenWindows), keyEquivalent: "r").target = self
        } else if mayDrive(roles: me.roles) {
            m.addItem(withTitle: "Drive from Here", action: #selector(drive), keyEquivalent: "d").target = self
        } else {
            // Do not offer the wheel to a machine that must never take it: one
            // stray click on the mini was enough to strand the whole fleet.
            m.addItem(withTitle: "Passenger only — cannot drive", action: nil, keyEquivalent: "")
        }
        m.addItem(.separator())
        for t in macPassengers(cfg: cfg, me: me) {
            let mi = NSMenuItem(title: t.jumpName, action: #selector(toggleMachine(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = t.id
            mi.state = excluded.contains(t.id) ? .off : .on
            mi.isEnabled = true
            m.addItem(mi)
        }
        m.addItem(.separator())
        let settings = loadSettings()
        let sub = NSMenu()
        for (title, sel, on) in [
            ("Reverse Mouse Scrolling", #selector(toggleScroll), settings.reverseScroll),
            ("Walk-Up Handback", #selector(toggleWalkup), settings.walkupHandback),
            ("Retina Passengers (HiDPI)", #selector(toggleHiDPI), settings.hidpiRides),
        ] {
            let mi = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            mi.target = self
            mi.state = on ? .on : .off
            sub.addItem(mi)
        }
        let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        m.addItem(settingsItem)
        m.setSubmenu(sub, for: settingsItem)
        m.addItem(withTitle: "Run Doctor", action: #selector(runDoc), keyEquivalent: "").target = self
        m.addItem(withTitle: "View Log", action: #selector(viewLog), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "Quit MIRA", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = m
    }

    @objc func toggleMachine(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let t = cfg.machines.first(where: { $0.id == id }) else { return }
        var excluded = loadExcluded()
        if excluded.contains(id) {
            excluded.remove(id)
            saveExcluded(excluded)
            if driving {
                let engine = DisplayEngine()
                let canvas = driverCanvasKey(cfg: cfg, me: me, engine: engine)
                DispatchQueue.global().async { [self] in
                    clearRemoteHandback(on: t)
                    _ = placeRide(on: t, canvas: canvas, hidpi: loadSettings().hidpiRides, driver: me.id)
                    let names = (t.jumpAliases ?? []) + [t.jumpName]   // recents use the short alias names
                    _ = names.contains(where: { openJumpSession($0) })
                }
            }
        } else {
            excluded.insert(id)
            saveExcluded(excluded)
            if driving { DispatchQueue.global().async { endRide(on: t) } }
        }
        rebuild()
    }

    @objc func toggleScroll() {
        var s = loadSettings(); s.reverseScroll.toggle(); saveSettings(s)
        scrollReversalEnabled = s.reverseScroll
        // A grant made after launch: retry the tap on demand.
        if s.reverseScroll && scrollTap == nil { installScrollTap() }
        rebuild()
    }
    @objc func toggleWalkup() {
        var s = loadSettings(); s.walkupHandback.toggle(); saveSettings(s); rebuild()
    }
    @objc func toggleHiDPI() {
        var s = loadSettings(); s.hidpiRides.toggle(); saveSettings(s); rebuild()
    }
    @objc func viewLog() { sh("open -a Console '\(logFile.path)'") }
}

// MARK: - Session windows (Jump viewer UI scripting)

// Jump populates submenus lazily: the parent must be clicked open and given
// time before its items exist; Escape (consumed by the open menu) cleans up.
func openJumpSession(_ name: String) -> Bool {
        let esc = name.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Jump Desktop" to activate
        delay 0.7
        tell application "System Events" to tell process "Jump Desktop"
          try
            click menu bar item "File" of menu bar 1
            delay 0.4
            click menu item "Open Recent" of menu 1 of menu bar item "File" of menu bar 1
            delay 0.6
            set recentMenu to menu 1 of menu item "Open Recent" of menu 1 of menu bar item "File" of menu bar 1
            if not (exists menu item "\(esc)" of recentMenu) then
              delay 0.8
            end if
            if exists menu item "\(esc)" of recentMenu then
              click menu item "\(esc)" of recentMenu
              return "ok"
            else
              key code 53
              key code 53
              return "missing"
            end if
          on error errMsg
            try
              key code 53
              key code 53
            end try
            return "error: " & errMsg
          end try
        end tell
        """
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("mira-open-\(UUID().uuidString).scpt")
    try? script.write(to: tmp, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let r = sh("osascript '\(tmp.path)'", timeout: 20)
    let ok = r.out.contains("ok")
    if !ok { log("openJumpSession(\(name)) -> \(r.out.trimmingCharacters(in: .whitespacesAndNewlines))") }
    return ok
}

// Open one passenger's session: the exported .jump connection document first
// (plain `open`, no UI scripting, no Accessibility), menu scripting of the
// viewer's Open Recent as fallback for a machine without an alias file.
func openJumpTarget(_ t: Machine) -> Bool {
    let alias = sessionAlias(for: t.id)
    if FileManager.default.fileExists(atPath: alias.path) {
        if sh("open '\(alias.path)'").code == 0 { return true }
        log("alias open failed for \(t.id) — falling back to menu scripting")
    }
    let names = (t.jumpAliases ?? []) + [t.jumpName]   // recents use the short alias names
    return names.contains(where: { openJumpSession($0) })
}

// Open a Jump window for every included, not-walked-up passenger. Records the
// boot marker when at least one opened, so boot-resume runs once per boot.
func openSessionWindows(cfg: Config, me: Machine, targets: [Machine]? = nil) -> Int {
    // A caller that just placed rides already knows who is rideable; re-probing
    // every passenger over SSH here doubled the round trips on the drive path.
    let list = targets ?? rideablePassengers(cfg: cfg, me: me)
    var opened = 0
    for t in list {
        // Sequential on purpose. The alias path is a cheap `open`, but the
        // menu-scripting fallback drives the viewer's UI, and two of those at
        // once fight over the front window.
        if openJumpTarget(t) || openJumpTarget(t) { opened += 1 }   // one retry
    }
    if opened > 0 { writeSessionMarker() }
    return opened
}

// Included passengers that are not currently walked up, probed in parallel.
func rideablePassengers(cfg: Config, me: Machine) -> [Machine] {
    let excluded = loadExcluded()
    let candidates = macPassengers(cfg: cfg, me: me).filter { !excluded.contains($0.id) }
    let walked = forEachPeer(candidates) { targetWalkedUp($0, cfg: cfg) }
    return candidates.filter { walked[$0.id] != true }
}

extension MenuApp {
    @objc func drive() {
        try? FileManager.default.removeItem(at: handbackFile)   // explicit drive overrides walk-up
        claimDriver(me: me)
        let engine = DisplayEngine()
        let canvas = driverCanvasKey(cfg: cfg, me: me, engine: engine)
        let cfg = self.cfg, me = self.me
        DispatchQueue.global().async { [self] in
            let handoff = stopOtherDrivers(cfg: cfg, me: me)
            let excluded = loadExcluded()
            let targets = macPassengers(cfg: cfg, me: me).filter { !excluded.contains($0.id) }
            // An explicit drive overrides any walk-up, so there is nothing to
            // probe: clear the handback and claim every passenger at once.
            _ = forEachPeer(targets) { t -> Bool in
                clearRemoteHandback(on: t)
                return placeRide(on: t, canvas: canvas, hidpi: true, driver: me.id)
            }
            let opened = openSessionWindows(cfg: cfg, me: me, targets: targets)
            DispatchQueue.main.async {
                // Say it when the handoff was not clean. Silence here is what
                // let "could not reach air13 to stop its driving flag" sit in
                // a log file while the fleet ran with two drivers.
                var msg = "Driving: \(opened)/\(targets.count) sessions open (\(canvas))"
                if !handoff.unreachable.isEmpty {
                    msg += "\n\(handoff.unreachable.joined(separator: ", ")) "
                         + "could not be stopped — will yield on waking"
                }
                self.notify(msg)
                self.rebuild()
            }
        }
    }
    // Re-open viewer windows without touching rides/handbacks — for a closed
    // window mid-session or a boot-resume triggered manually.
    @objc func reopenWindows() {
        DispatchQueue.global().async { [self] in
            let opened = openSessionWindows(cfg: cfg, me: me)
            DispatchQueue.main.async { self.notify("Reopened \(opened) session window\(opened == 1 ? "" : "s")") }
        }
    }
    @objc func stop() {
        try? FileManager.default.removeItem(at: drivingFlag)
        try? FileManager.default.removeItem(at: wheelFile)
        for t in macPassengers(cfg: cfg, me: me) { endRide(on: t) }
        // Release the wheel everywhere too, so no other menu bar goes on
        // naming a driver that has parked.
        let cfg = self.cfg, me = self.me
        DispatchQueue.global().async {
            _ = forEachPeer(otherViewers(cfg: cfg, me: me)) { clearWheel(on: $0) }
        }
        sh("pkill -f '\(jumpViewerPattern)' 2>/dev/null")   // close the viewer locally
        notify("Stopped driving — passengers return to console")
        rebuild()
    }
    @objc func runDoc() {
        DispatchQueue.global().async {
            let (report, _) = doctor(cfg: self.cfg, me: self.me)
            log(report)
            DispatchQueue.main.async { self.notify("Doctor finished — see log") }
        }
    }
    func notify(_ text: String) {
        let esc = text.replacingOccurrences(of: "\"", with: "\\\"")
        sh("osascript -e 'display notification \"\(esc)\" with title \"MIRA\"'")
    }

    // After a reboot the driving flag survives and the daemon re-places rides,
    // but only the menu app can re-open the viewer windows. Once per boot.
    func maybeResumeSessions() {
        guard shouldResumeSessions(driving: driving,
                                   viewer: me.roles.contains("viewer"),
                                   markerBoot: readSessionMarker(),
                                   currentBoot: bootEpoch()) else { return }
        log("boot resume: driving flag set and no windows opened this boot")
        // Settle delay: Tailscale, Jump Desktop, and the menu bar all come up
        // around login; UI scripting too early hits half-built menus.
        DispatchQueue.global().asyncAfter(deadline: .now() + 12) { [self] in
            let opened = openSessionWindows(cfg: cfg, me: me)
            log("boot resume: opened \(opened) session window(s)")
            DispatchQueue.main.async {
                self.notify("Resumed driving: \(opened) session window\(opened == 1 ? "" : "s") reopened")
            }
        }
    }
}

// MARK: - Selftest (pure logic)

func selftest() -> Never {
    var failures = 0
    func expect(_ cond: Bool, _ name: String) {
        print("\(cond ? "ok" : "FAIL") - \(name)"); if !cond { failures += 1 }
    }
    let now = 1_000_000.0
    // ride TTL
    let live = Ride(driver: "air", canvas: "laptop-air", hidpi: true, ts: now - 10, claimedAt: nil)
    let stale = Ride(driver: "air", canvas: "laptop-air", hidpi: true, ts: now - 120, claimedAt: nil)
    expect(computeMode(ride: live, ttl: 90, now: now) == .passenger(canvas: "laptop-air", hidpi: true),
           "live ride -> passenger")
    expect(computeMode(ride: stale, ttl: 90, now: now) == .console, "stale ride -> console")
    expect(computeMode(ride: nil, ttl: 90, now: now) == .console, "no ride -> console")
    // tier engine
    expect(computeTier(previous: .travel, avgMs: 5, jitterMs: 2, home: true, docked: true) == .full,
           "home docked -> full")
    expect(computeTier(previous: .full, avgMs: 5, jitterMs: 2, home: true, docked: false) == .standard,
           "home undocked -> standard")
    expect(computeTier(previous: .standard, avgMs: 40, jitterMs: 10, home: false, docked: false) == .travel,
           "away good -> travel")
    expect(computeTier(previous: .travel, avgMs: 80, jitterMs: 10, home: false, docked: false) == .lifeline,
           "away bad avg -> lifeline")
    expect(computeTier(previous: .travel, avgMs: 40, jitterMs: 40, home: false, docked: false) == .lifeline,
           "away bad jitter -> lifeline")
    expect(computeTier(previous: .lifeline, avgMs: 60, jitterMs: 20, home: false, docked: false) == .lifeline,
           "hysteresis: 60ms stays lifeline")
    expect(computeTier(previous: .lifeline, avgMs: 40, jitterMs: 10, home: false, docked: false) == .travel,
           "hysteresis: clean recovery -> travel")
    expect(tierWantsHiDPI(.full) && tierWantsHiDPI(.standard), "home tiers hidpi on")
    expect(!tierWantsHiDPI(.travel) && !tierWantsHiDPI(.lifeline), "away tiers hidpi off")
    // canvas pick
    expect(pickCanvas(physicalWidths: [3456, 3440], dockedCanvas: "ultrawide",
                      laptopCanvas: "laptop-pro") == "ultrawide", "widescreen present -> ultrawide")
    expect(pickCanvas(physicalWidths: [2940], dockedCanvas: "ultrawide",
                      laptopCanvas: "laptop-air") == "laptop-air", "builtin only -> laptop canvas")
    expect(pickCanvas(physicalWidths: [], dockedCanvas: "ultrawide",
                      laptopCanvas: "laptop-air") == "laptop-air", "headless -> laptop canvas")
    // console presence via idle-time
    expect(consolePresent(idleNow: 2, idlePrev: 5, threshold: 20), "sustained input -> present")
    expect(!consolePresent(idleNow: 2, idlePrev: 300, threshold: 20), "single blip -> not present")
    expect(!consolePresent(idleNow: 300, idlePrev: 2, threshold: 20), "gone idle -> not present")
    expect(!consolePresent(idleNow: nil, idlePrev: 2, threshold: 20), "unreadable -> not present")
    // sh() must honour its timeout even when the child will not die on SIGTERM
    // and keeps the pipe open. This is the 2026-08-16 outage in miniature: an
    // ssh ControlMaster daemonises to PPID 1 and inherits stdout, so killing
    // the bash that spawned it freed nothing, readDataToEndOfFile() waited on
    // the master, and a 20 s timeout stalled the driver for minutes. Verified
    // to fail against the pre-fix implementation (8.1 s for a 1 s timeout).
    let shT0 = Date()
    let shR = sh("trap '' TERM; sleep 8", timeout: 1)
    let shElapsed = Date().timeIntervalSince(shT0)
    expect(shElapsed < 4, "sh() timeout is enforced despite an orphan holding the pipe "
                        + "(took \(String(format: "%.1f", shElapsed))s)")
    expect(shR.code == 124, "sh() reports 124 on timeout")
    // ---- converge circuit breaker ----
    // The 2026-08-19 incident in miniature: 1,924 identical failures, each one
    // tearing down the owner's display, because nothing counted them. The same
    // failure repeated is not new information and must stop the loop.
    var br = ConvergeBreaker(limit: 3)
    expect(br.shouldAttempt, "a fresh breaker attempts")
    br.record("virtual has no mode")
    br.record("virtual has no mode")
    expect(br.shouldAttempt, "under the limit it keeps trying")
    expect(br.record("virtual has no mode"), "the trip is reported on the tick it happens")
    expect(!br.shouldAttempt, "identical failure x3 stops the loop")
    expect(!br.record("virtual has no mode"), "staying tripped does not re-report (no log spam)")
    var br2 = ConvergeBreaker(limit: 3)
    br2.record("virtual has no mode")
    br2.record("virtual is not main")
    expect(br2.streak == 1 && br2.shouldAttempt,
           "a DIFFERENT failure is new information: the count restarts")
    var br3 = ConvergeBreaker(limit: 2)
    br3.record("x"); br3.record("x")
    expect(!br3.shouldAttempt, "tripped after the limit")
    br3.record(nil)
    expect(br3.shouldAttempt && br3.streak == 0, "a success clears the breaker")
    var br4 = ConvergeBreaker(limit: 2)
    br4.record("x"); br4.record("x")
    br4.reset()
    expect(br4.shouldAttempt, "reset clears it (new lease, or the topology moved under us)")

    // ---- event log (JSONL, transition-only, size-capped) ----
    // Every bug chased on 2026-08-16/17 was invisible in the human log: we could
    // see "converged=false" but not why, and nothing recorded that a lease
    // arrived 77 s into its 90 s life. These are the primitives for that.
    expect(evJSON(.n(2)) == "2", "whole numbers stay integers (no 2.000 noise)")
    expect(evJSON(.n(2.45)) == "2.45", "fractions keep 2dp")
    expect(evJSON(.b(true)) == "true", "bools are bare")
    expect(evJSON(.s("ok")) == "\"ok\"", "strings are quoted")
    expect(evJSON(.s("a\"b\\c")) == "\"a\\\"b\\\\c\"", "quotes and backslashes escaped")
    expect(eventLine(ts: 100, machine: "pro", event: "beat",
                     fields: [("ms", .n(12.5)), ("late", .s("air13"))])
           == "{\"ts\":100,\"m\":\"pro\",\"e\":\"beat\",\"ms\":12.5,\"late\":\"air13\"}",
           "event line is compact, ordered, parseable")
    expect(eventLine(ts: 1, machine: "m", event: "e", fields: [])
           == "{\"ts\":1,\"m\":\"m\",\"e\":\"e\"}", "no trailing comma with no fields")
    // percentiles drive the "is it getting better over time" question
    expect(percentile([1, 2, 3, 4, 5], 0.5) == 3, "p50 of odd sample")
    expect(percentile([1, 2, 3, 4], 0.5) == 2,
           "nearest-rank p50 on an even sample is a value that really occurred")
    expect(percentile([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 0.95) == 10, "p95 reaches the tail")
    expect(percentile([], 0.5) == 0, "empty sample is 0, not a crash")
    expect(percentile([5], 0.99) == 5, "single sample")
    // A passenger must never stream outward, but the guard that enforced it had
    // never actually worked: `pkill -x "Jump Desktop"` misses because macOS
    // reports comm as a truncated path, and `pkill -f "MacOS/Jump Desktop$"`
    // misses because the real argv carries trailing args. A viewer survived 15h
    // on a passenger and silently resized the driver's monitor (2026-08-18).
    expect(matchesJumpViewer("/Applications/Jump Desktop.app/Contents/MacOS/Jump Desktop"),
           "viewer argv matches")
    expect(matchesJumpViewer("/Applications/Jump Desktop.app/Contents/MacOS/Jump Desktop -psn_0_1234"),
           "viewer argv with trailing args still matches (the old $ anchor did not)")
    expect(!matchesJumpViewer("/Applications/Jump Desktop Connect.app/Contents/MacOS/JumpConnect --service"),
           "host service is NOT matched - killing it would cut inbound access")
    expect(!matchesJumpViewer("/Applications/Jump Desktop Connect.app/Contents/MacOS/JumpConnect --desktopproxy /var/run/x"),
           "host desktopproxy is NOT matched")
    // driver handoff: the newest explicit claim wins, and it must not depend on
    // the stop-push landing. 2026-08-17: clicking Drive on air15 while the pro's
    // ride was still live made air15 delete the driving flag it had just created,
    // leaving nobody driving and the pro reconverging every 2 s until the lease
    // expired.
    expect(driverYields(myClaim: 100, theirClaim: 200), "older claim yields to newer")
    expect(!driverYields(myClaim: 200, theirClaim: 100), "newer claim keeps driving")
    expect(!driverYields(myClaim: 200, theirClaim: 200), "equal claims: incumbent keeps driving")
    expect(!driverYields(myClaim: 100, theirClaim: nil),
           "a ride with no claim stamp (older build) never unseats a real claim")
    expect(driverYields(myClaim: nil, theirClaim: 100),
           "no claim of our own: any explicit claim wins")
    expect(!driverYields(myClaim: nil, theirClaim: nil), "no claims at all: nothing to yield to")
    // The wheel beacon. driverYields only ever ran in the .passenger branch of
    // tick(), which is reached only when a RIDE lands — and rides only go to
    // machines with the "target" role. air13 is roles:["viewer"], so no driver
    // ever placed anything on it and the "older claimant still yields on its
    // own" safety net documented above did not cover it at all. On 2026-08-19
    // air13 was asleep when air15 claimed ("could not reach air13 to stop its
    // driving flag"), so it kept the wheel, woke up still holding it, and drove
    // alongside air15. The beacon is the ride's equivalent for machines that
    // never ride: it carries a claim and nothing else.
    let beaconAir15 = Wheel(driver: "air15", claimedAt: 200, ts: now)
    expect(wheelYields(me: "air13", myClaim: 100, wheel: beaconAir15),
           "a viewer that never receives rides still yields to a newer claim")
    expect(!wheelYields(me: "air13", myClaim: 300, wheel: beaconAir15),
           "our newer claim survives an older beacon")
    expect(!wheelYields(me: "air15", myClaim: 200, wheel: beaconAir15),
           "our own beacon echoed back never unseats us")
    expect(!wheelYields(me: "air13", myClaim: 100, wheel: nil),
           "no beacon -> nothing to yield to")
    expect(wheelYields(me: "air13", myClaim: nil, wheel: beaconAir15),
           "an unstamped flag (older build, or a failed write) yields to any real claim")
    // Display only: a beacon whose driver stopped talking must stop claiming
    // the menu bar. It must NEVER expire the yield above — a stale beacon that
    // could hand the wheel back is how two drivers come back.
    expect(wheelHolder(wheel: beaconAir15, me: "air13", ttl: 90, now: now + 10) == "air15",
           "a fresh beacon names the driver")
    expect(wheelHolder(wheel: beaconAir15, me: "air13", ttl: 90, now: now + 120) == nil,
           "a beacon older than the TTL names nobody")
    expect(wheelHolder(wheel: beaconAir15, me: "air15", ttl: 90, now: now + 10) == nil,
           "our own beacon is not someone else driving")
    // The claim read-back. A false positive here makes a driver yield to a peer
    // that holds nothing, leaving NOBODY driving — so every unparseable form
    // must read as "no claim", not as a number.
    expect(parseClaimReadback("CLAIM=1787180657.5\n") == 1787180657.5, "a stamped claim reads back")
    expect(parseClaimReadback("CLAIM=\n") == nil, "an absent flag is no claim, not 0")
    expect(parseClaimReadback("CLAIM=   \n") == nil, "whitespace is no claim")
    expect(parseClaimReadback("") == nil, "no read-back line at all is no claim")
    expect(parseClaimReadback("mkdir: permission denied\n") == nil, "stderr noise is no claim")
    expect(parseClaimReadback("CLAIM=garbage\n") == nil, "an unstamped legacy flag is no claim")
    expect(parseClaimReadback("CLAIM=0\n") == nil, "zero is not a real claim")
    expect(parseClaimReadback("CLAIM=-5\n") == nil, "a negative claim is junk")
    expect(parseClaimReadback("CLAIM=nan\n") == nil, "NaN never outranks a real claim")
    expect(parseClaimReadback("CLAIM=inf\n") == nil, "infinity never outranks a real claim")
    expect(parseClaimReadback("some noise\nCLAIM=42\nmore noise\n") == 42,
           "the claim line is found among other output")
    // ...and the guard that matters: junk must not unseat a live driver.
    expect(!driverYields(myClaim: 100, theirClaim: parseClaimReadback("CLAIM=\n")),
           "a peer holding no claim never takes the wheel")
    // Flag existence, not the stamp, is what makes a machine a driver.
    expect(parseWheelProbe("FLAG=yes\nCLAIM=42\n")?.flag == true, "a stamped flag is a driver")
    expect(parseWheelProbe("FLAG=yes\nCLAIM=42\n")?.claim == 42, "and its stamp is read")
    expect(parseWheelProbe("FLAG=yes\nCLAIM=\n")?.flag == true,
           "an UNSTAMPED flag is still a driver — the survey must not miss it")
    expect(parseWheelProbe("FLAG=yes\nCLAIM=\n")?.claim == nil, "with no stamp to compare")
    expect(parseWheelProbe("FLAG=no\nCLAIM=\n")?.flag == false, "no flag is not a driver")
    expect(parseWheelProbe("ssh: connect refused\n") == nil,
           "an unanswered probe is unreachable, never 'not driving'")
    // peer backoff: a sleeping machine must not cost a connection attempt every beat
    expect(backoffSeconds(consecutiveFailures: 0) == 0, "healthy peer is never skipped")
    expect(backoffSeconds(consecutiveFailures: 1) == 15, "first failure backs off 15s")
    expect(backoffSeconds(consecutiveFailures: 2) == 30, "backoff doubles")
    expect(backoffSeconds(consecutiveFailures: 3) == 60, "backoff keeps doubling")
    expect(backoffSeconds(consecutiveFailures: 99) == 60,
           "backoff caps at 60s so a machine that wakes rejoins promptly")
    // presence threshold is its own knob, floored so a faster tick cannot make
    // walk-up handback more trigger-happy than the 15 s-tick default was
    expect(presenceThreshold(configured: nil, reconcile: 15) == 20,
           "presence threshold: legacy 15 s tick keeps 20 s")
    expect(presenceThreshold(configured: nil, reconcile: 2) == 20,
           "presence threshold: fast tick does not shrink the window")
    expect(presenceThreshold(configured: 45, reconcile: 2) == 45,
           "presence threshold: explicit config honoured")
    expect(presenceThreshold(configured: 5, reconcile: 15) == 20,
           "presence threshold: floor beats a too-small config")
    // scroll discrimination: wheels reversed, gesture devices untouched
    expect(shouldReverseScroll(phase: 0, momentum: 0), "classic wheel reversed")
    expect(!shouldReverseScroll(phase: 2, momentum: 0), "trackpad live gesture untouched")
    expect(!shouldReverseScroll(phase: 0, momentum: 1), "trackpad momentum untouched")
    // audio picks
    let names = ["MacBook Air Speakers", "Jump Desktop Audio", "Jump Desktop Microphone", "ZoomAudioDevice"]
    let pa = pickAudioNames(passenger: true, deviceNames: names)
    expect(pa.output == "Jump Desktop Audio" && pa.input == "Jump Desktop Microphone",
           "passenger audio -> jump devices")
    let ca = pickAudioNames(passenger: false, deviceNames: names)
    expect(ca.output == nil && ca.input == nil, "console audio -> builtin fallback")
    // handback logic
    let hnow = 2_000_000.0
    expect(handbackIsFresh(ts: hnow - 100, hold: 600, now: hnow), "handback fresh within hold")
    expect(!handbackIsFresh(ts: hnow - 700, hold: 600, now: hnow), "handback stale past hold")
    expect(shouldHandback(prevClamshell: true, nowClamshell: false, inputBurst: false,
                          passengerConverged: true), "lid open while passenger -> handback")
    expect(!shouldHandback(prevClamshell: true, nowClamshell: false, inputBurst: false,
                           passengerConverged: false), "lid open while console -> no handback")
    expect(shouldHandback(prevClamshell: false, nowClamshell: false, inputBurst: true,
                          passengerConverged: true), "input burst while passenger -> handback")
    expect(!shouldHandback(prevClamshell: false, nowClamshell: true, inputBurst: false,
                           passengerConverged: true), "lid closing -> no handback")
    expect(!shouldHandback(prevClamshell: true, nowClamshell: true, inputBurst: false,
                           passengerConverged: true), "lid still closed -> no handback")
    // SavedDisplay mirror-topology round-trip
    let enc = JSONEncoder(); let dec = JSONDecoder()
    let sdPlain = SavedDisplay(id: 7, x: 100, y: -20, main: true, mirrorOf: nil)
    let sdMirror = SavedDisplay(id: 8, x: 0, y: 0, main: false, mirrorOf: 7)
    if let r = try? dec.decode(SavedDisplay.self, from: (try? enc.encode(sdPlain)) ?? Data()) {
        expect(r.id == 7 && r.x == 100 && r.y == -20 && r.main && r.mirrorOf == nil,
               "SavedDisplay round-trip (no mirror)")
    } else { expect(false, "SavedDisplay round-trip (no mirror)") }
    if let r = try? dec.decode(SavedDisplay.self, from: (try? enc.encode(sdMirror)) ?? Data()) {
        expect(r.id == 8 && !r.main && r.mirrorOf == 7,
               "SavedDisplay round-trip (mirror)")
    } else { expect(false, "SavedDisplay round-trip (mirror)") }
    let sdMode = SavedDisplay(id: 9, x: 0, y: 0, main: true, mirrorOf: nil,
                              w: 3440, h: 1440, hz: 99, px: 3440)
    if let r = try? dec.decode(SavedDisplay.self, from: (try? enc.encode(sdMode)) ?? Data()) {
        expect(r.w == 3440 && r.h == 1440 && r.hz == 99 && r.px == 3440,
               "SavedDisplay round-trip (mode)")
    } else { expect(false, "SavedDisplay round-trip (mode)") }
    let legacy = #"[{"id":7,"x":0,"y":0,"main":true}]"#.data(using: .utf8)!
    if let r = try? dec.decode([SavedDisplay].self, from: legacy) {
        expect(r.count == 1 && r[0].w == nil && r[0].hz == nil,
               "SavedDisplay legacy decode (no mode fields)")
    } else { expect(false, "SavedDisplay legacy decode (no mode fields)") }
    // Restore plan: the docked pair — BenQ master + built-in mirroring it.
    // The member MUST get its mode reapplied or the set collapses to the
    // largest mode both happen to be sitting at (1024x768).
    let benq = SavedDisplay(id: 1, x: 0, y: 0, main: true, mirrorOf: nil,
                            w: 3440, h: 1440, hz: 99, px: 3440)
    let builtin = SavedDisplay(id: 2, x: 0, y: 0, main: false, mirrorOf: 1,
                               w: 3440, h: 1440, hz: 120, px: 3440)
    expect(restoreStep(benq, online: [1, 2]) == RestoreStep(id: 1, setMode: true, mirrorOf: nil),
           "restoreStep master reapplies mode")
    expect(restoreStep(builtin, online: [1, 2]) == RestoreStep(id: 2, setMode: true, mirrorOf: 1),
           "restoreStep mirror member reapplies mode (1024x768 regression)")
    // Master gone (undocked): member becomes independent, still gets its mode.
    expect(restoreStep(builtin, online: [2]) == RestoreStep(id: 2, setMode: true, mirrorOf: nil),
           "restoreStep offline master -> independent")
    // Legacy capture with no mode data: topology only, never a bogus mode.
    let old = SavedDisplay(id: 3, x: 0, y: 0, main: false, mirrorOf: 1)
    expect(restoreStep(old, online: [1, 3]) == RestoreStep(id: 3, setMode: false, mirrorOf: 1),
           "restoreStep legacy capture sets no mode")
    // boot-resume gate
    expect(shouldResumeSessions(driving: true, viewer: true, markerBoot: nil, currentBoot: 111),
           "no marker -> resume")
    expect(shouldResumeSessions(driving: true, viewer: true, markerBoot: 100, currentBoot: 111),
           "marker from previous boot -> resume")
    expect(!shouldResumeSessions(driving: true, viewer: true, markerBoot: 111, currentBoot: 111),
           "already opened this boot -> no resume")
    expect(!shouldResumeSessions(driving: false, viewer: true, markerBoot: nil, currentBoot: 111),
           "not driving -> no resume")
    expect(!shouldResumeSessions(driving: true, viewer: false, markerBoot: nil, currentBoot: 111),
           "not a viewer -> no resume")
    // dumpmacperm parse (vendor typo + warning noise tolerated)
    let permOut = """
    WARNING: QApplication was not created in the main() thread.
    {
       "hasAccessiblity" : true,
       "hasMicrophone" : false,
       "hasScreenRecording" : true
    }
    """
    if let p = parsePermReport(permOut) {
        expect(p.accessibility && p.screenRecording, "perm report parsed through noise")
    } else { expect(false, "perm report parsed through noise") }
    if let p = parsePermReport("{\"hasAccessiblity\":false,\"hasScreenRecording\":true}") {
        expect(!p.accessibility && p.screenRecording, "perm report false accessibility")
    } else { expect(false, "perm report false accessibility") }
    expect(parsePermReport("no json here") == nil, "garbage perm report -> nil")
    // health round-trip (what doctor decodes from the HEALTH= line)
    let hEnc = try? JSONEncoder().encode(Health(accessibility: true, screenRecording: false, ts: 5))
    if let d = hEnc, let h = try? JSONDecoder().decode(Health.self, from: d) {
        expect(h.accessibility && !h.screenRecording && h.ts == 5, "health round-trip")
    } else { expect(false, "health round-trip") }
    let vhEnc = try? JSONEncoder().encode(ViewerHealth(axTrusted: true, scrollTap: false, ts: 7))
    if let d = vhEnc, let h = try? JSONDecoder().decode(ViewerHealth.self, from: d) {
        expect(h.axTrusted && !h.scrollTap && h.ts == 7, "viewer health round-trip")
    } else { expect(false, "viewer health round-trip") }
    // session alias path shape
    expect(sessionAlias(for: "air").lastPathComponent == "air.jump", "session alias filename")
    // config sanity
    let cfg = loadConfig()
    expect(cfg.machines.count >= 3, "config has machines")
    expect(cfg.canvases[cfg.dockedCanvas] != nil, "docked canvas defined")
    // The structural gap itself, pinned: the set of machines that can hold the
    // wheel is NOT the set that receives rides. Anything that fans out only
    // over macPassengers cannot reach every machine that might be driving.
    let anyMe = cfg.machines.first(where: { $0.roles.contains("viewer") })!
    let viewerIDs = Set(otherViewers(cfg: cfg, me: anyMe).map { $0.id })
    let passengerIDs = Set(macPassengers(cfg: cfg, me: anyMe).map { $0.id })
    expect(!viewerIDs.subtracting(passengerIDs).isEmpty,
           "a machine can drive but never receives a ride — the beacon is why it exists")
    for m in cfg.machines where m.roles.contains("viewer") && m.id != anyMe.id {
        expect(viewerIDs.contains(m.id), "wheel push reaches viewer \(m.id)")
    }
    expect(!viewerIDs.contains(anyMe.id), "we never push the wheel to ourselves")
    for m in cfg.machines where !m.roles.contains("viewer") {
        expect(!viewerIDs.contains(m.id), "wheel push skips passenger-only \(m.id)")
    }

    // A laptop canvas IS the Jump viewer's FULLSCREEN CONTENT AREA in points.
    // Not the panel, and not panel/2: on a notched Mac, macOS lays fullscreen
    // content out BELOW the camera, so the content area is shorter than the
    // screen by safeAreaInsets.top. Measured on air15 2026-08-18 with the panel
    // in its native-aspect 1440x932 mode: NSScreen frame 1440x932, safeArea top
    // 28, Jump content window y=29 h=903. A canvas taller than that makes Jump
    // scale the image down to fit and pillarbox it -- "the screen isn't fully
    // used" -- while every log still reads converged=true.
    //
    // History: set to panel/2 (1440x932) in 45f0502, reverted to the 16:10
    // legacy 1710x1068 by the unrelated 7df68eb, corrected to the measured
    // content area here. Diagnosed by eye three times before this gate existed.
    // Re-measure with NSScreen.frame + safeAreaInsets + CGWindowListCopyWindowInfo
    // whenever a viewer's panel mode changes; a guess is what caused every round.
    // The measurement that now owns the canvas.
    let screen1440 = ContentArea(w: 1440, h: 932)
    expect(pickViewerContent(windows: [ContentArea(w: 1440, h: 29), ContentArea(w: 1440, h: 32),
                                       ContentArea(w: 1440, h: 903)], screen: screen1440)
           == ContentArea(w: 1440, h: 903), "viewer content is the session window, not the toolbars")
    expect(pickViewerContent(windows: [ContentArea(w: 1440, h: 29)], screen: screen1440) == nil,
           "a toolbar strip alone is never the canvas")
    expect(pickViewerContent(windows: [], screen: screen1440) == nil, "no viewer window -> no measurement")
    let seedCanvas = Canvas(width: 1440, height: 932, hidpi: true)
    let measuredRide = Ride(driver: "air15", canvas: "laptop-air", hidpi: true, ts: 1, claimedAt: nil,
                            canvasW: 1440, canvasH: 903)
    let junkRide = Ride(driver: "air15", canvas: "laptop-air", hidpi: true, ts: 1, claimedAt: nil,
                        canvasW: 1440, canvasH: 29)
    expect(rideCanvas(base: seedCanvas, ride: measuredRide).height == 903,
           "measured content beats the config seed")
    expect(rideCanvas(base: seedCanvas, ride: junkRide).height == 932,
           "an implausible measurement cannot shrink a passenger")
    expect(rideCanvas(base: seedCanvas, ride: nil).height == 932, "no measurement -> config seed")
    expect(rideCanvas(base: seedCanvas, ride: measuredRide).hidpi, "measurement never changes hidpi")
    // Only viewers drive. The mini claiming the wheel is what made its display
    // "look funny": rides rejected as stale, virtual display destroyed, console.
    expect(mayDrive(roles: ["viewer", "target"]), "a viewer may drive")
    expect(mayDrive(roles: ["viewer"]), "a viewer-only machine may drive")
    expect(!mayDrive(roles: ["target"]), "a target-only machine may never drive")
    expect(!mayDrive(roles: []), "no roles -> no driving")
    // Sticky measurement: the flap that bounced passengers between measured and seed.
    let measured903 = ContentArea(w: 1440, h: 903)
    expect(adoptMeasurement(previous: measured903, observed: nil) == measured903,
           "a momentarily missing viewer window keeps the last measurement")
    expect(adoptMeasurement(previous: nil, observed: measured903) == measured903,
           "first measurement is adopted")
    expect(adoptMeasurement(previous: measured903, observed: ContentArea(w: 1440, h: 904)) == measured903,
           "a one-point nudge does not rebuild a display")
    expect(adoptMeasurement(previous: measured903, observed: ContentArea(w: 1280, h: 800))
           == ContentArea(w: 1280, h: 800), "a real resize is adopted")
    expect(adoptMeasurement(previous: nil, observed: nil) == nil, "nothing measured yet stays nil")
    // Console panel defense.
    let airNative = 2880.0 / 1864.0
    let goodMode = PanelMode(w: 1440, h: 932, px: 2880, py: 1864, hz: 60)
    let jumpedMode = PanelMode(w: 1920, h: 1200, px: 1920, py: 1200, hz: 60)
    let deliberate = PanelMode(w: 1280, h: 828, px: 2560, py: 1656, hz: 60)
    expect(panelModeIsWorse(saved: goodMode, now: jumpedMode, nativeAspect: airNative),
           "1x wrong-aspect mode is worse -> re-assert")
    expect(!panelModeIsWorse(saved: goodMode, now: goodMode, nativeAspect: airNative),
           "unchanged panel is not worse")
    expect(!panelModeIsWorse(saved: goodMode, now: deliberate, nativeAspect: airNative),
           "a deliberate native-aspect HiDPI change is left alone")
    expect(panelModeIsSane(goodMode, nativeAspect: airNative), "native-aspect HiDPI is a sane baseline")
    expect(!panelModeIsSane(jumpedMode, nativeAspect: airNative),
           "a 1x wrong-aspect mode is never baselined as good")
    // ps etime parsing, used to spot the session that renegotiates resolutions.
    let hhmmss: Double = 51855      // 14:24:15, the session that undid every fix
    let mmss: Double = 1244         // 20:44
    let ddhhmmss: Double = 506_009  // 05-20:33:29
    expect(parseETime("14:24:15") == hhmmss, "etime hh:mm:ss")
    expect(parseETime("20:44") == mmss, "etime mm:ss")
    expect(parseETime("05-20:33:29") == ddhhmmss, "etime dd-hh:mm:ss")
    expect(parseETime("garbage") == nil, "etime rejects junk")
    let viewerContentPoints: [String: (w: Int, h: Int)] = [
        "laptop-air": (1440, 903),   // Air 15" M4, panel 2880x1864 @ 1440x932, notch inset 29
        "laptop-pro": (1728, 1117),  // Pro 16": panel/2, UNMEASURED as a viewer -- notch inset
                                     // likely applies here too when the pro drives
    ]
    for (key, want) in viewerContentPoints.sorted(by: { $0.key < $1.key }) {
        guard let c = cfg.canvases[key] else { expect(false, "canvas \(key) defined"); continue }
        expect(c.width == want.w && c.height == want.h,
               "canvas \(key) matches viewer content area: \(c.width)x\(c.height) == \(want.w)x\(want.h)")
    }

    // Starlink's LAN is 192.168.1.0/24 too — subnet alone must not mean "home"
    expect(homeVerdict(onHomeSubnet: true, gatewayMAC: "80:82:fe:34:40:dd",
                       expected: "80:82:FE:34:40:DD"), "home: subnet + right gateway")
    expect(!homeVerdict(onHomeSubnet: true, gatewayMAC: "aa:bb:cc:dd:ee:ff",
                        expected: "80:82:fe:34:40:dd"), "starlink LAN is not home")
    expect(homeVerdict(onHomeSubnet: true, gatewayMAC: "",
                       expected: "80:82:fe:34:40:dd"), "unknown gateway MAC stays home")
    expect(!homeVerdict(onHomeSubnet: false, gatewayMAC: "80:82:fe:34:40:dd",
                        expected: "80:82:fe:34:40:dd"), "off-subnet is never home")
    expect(homeVerdict(onHomeSubnet: true, gatewayMAC: "x", expected: nil),
           "no expected MAC => subnet decides")
    for m in cfg.machines where m.roles.contains("viewer") {
        expect(m.laptopCanvas != nil && cfg.canvases[m.laptopCanvas!] != nil,
               "viewer \(m.id) has laptop canvas")
        if let dc = m.dockedCanvas {
            expect(cfg.canvases[dc] != nil, "viewer \(m.id) docked canvas defined")
        }
    }
    expect(pickCanvas(physicalWidths: [3440], dockedCanvas: "per-machine",
                      laptopCanvas: "laptop-air13") == "per-machine",
           "docked pick honours per-machine canvas")
    // Loop cadence: the tick must stay well inside the heartbeat (it is what
    // subdivides it) and the ride TTL (a passenger that cannot re-check before
    // its ride expires drops to console mid-session).
    expect(cfg.reconcileSeconds > 0 && cfg.reconcileSeconds < cfg.heartbeatSeconds,
           "reconcile tick subdivides the heartbeat")
    expect(cfg.heartbeatSeconds < cfg.rideTTLSeconds,
           "heartbeat re-asserts before the ride TTL expires")
    expect(presenceThreshold(configured: cfg.presenceThresholdSeconds,
                             reconcile: cfg.reconcileSeconds) >= 20,
           "configured presence threshold is not trigger-happy")
    print(failures == 0 ? "MIRA selftest: OK" : "MIRA selftest: \(failures) FAILURES")
    exit(failures == 0 ? 0 : 1)
}

// MARK: - Main

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "selftest": selftest()
case "--daemon": runDaemon(cfg: loadConfig())
case "status":
    let cfg = loadConfig(); let me = selfMachine(cfg)
    let mode = computeMode(ride: readRide(), ttl: cfg.rideTTLSeconds,
                           now: Date().timeIntervalSince1970)
    let driving = FileManager.default.fileExists(atPath: drivingFlag.path)
    var line = "machine: \(me.id)  mode: \(mode)  driving: \(driving)"
    if let w = readWheel() {
        let age = Int(Date().timeIntervalSince1970 - w.ts)
        line += "  wheel: \(w.driver) (claim \(String(format: "%.0f", w.claimedAt)), beacon \(age)s old)"
    } else {
        line += "  wheel: no beacon"
    }
    if driving { line += "  ourClaim: \(readDriverClaim().map { String(format: "%.0f", $0) } ?? "UNSTAMPED")" }
    if driving {
        line += readSessionMarker() == bootEpoch()
            ? "  windows: opened this boot"
            : "  windows: NOT opened this boot (menu: Reopen Session Windows)"
    }
    print(line)
case "drive":
    let cfg = loadConfig(); let me = selfMachine(cfg)
    claimDriver(me: me)
    let handoff = stopOtherDrivers(cfg: cfg, me: me)
    for id in handoff.stopped { print("\(id): stopped driving") }
    for id in handoff.unreachable {
        print("\(id): UNREACHABLE — still holds its claim, yields on its first reachable beat")
    }
    let engine = DisplayEngine()
    let canvas = driverCanvasKey(cfg: cfg, me: me, engine: engine)
    let targets = macPassengers(cfg: cfg, me: me)
    let placed = forEachPeer(targets) { t -> Bool in
        clearRemoteHandback(on: t)   // explicit drive overrides target walk-up
        return placeRide(on: t, canvas: canvas, hidpi: true, driver: me.id)
    }
    for t in targets {   // report in config order, not completion order
        print("\(t.id): \(placed[t.id] == true ? "riding (\(canvas))" : "RIDE FAILED")")
    }
    // Alias documents open from any context; only the menu-scripting fallback
    // would need the terminal's Accessibility grant.
    let opened = openSessionWindows(cfg: cfg, me: me, targets: targets)
    print(opened > 0 ? "opened \(opened) session window(s)"
                     : "no windows opened — use the MIRA menu (Drive from Here / Reopen Session Windows)")
case "wheel":
    // "Who is driving?" — the question that took an evening of hand-SSH to
    // answer on 2026-08-19, and the fastest way to confirm a handoff landed.
    let cfg = loadConfig(); let me = selfMachine(cfg)
    let s = surveyWheel(cfg: cfg, me: me)
    func stamp(_ id: String) -> String {
        s.claims[id].map { "  claim \(String(format: "%.0f", $0))" } ?? "  claim UNSTAMPED"
    }
    switch s.claimants.count {
    case 0: print("nobody is driving")
    case 1: print("driver: \(s.claimants[0])\(stamp(s.claimants[0]))")
    default:
        print("TWO DRIVERS — this is the bug:")
        for id in s.claimants { print("  \(id)\(stamp(id))") }
        let winner = s.claimants.max(by: { (s.claims[$0] ?? 0) < (s.claims[$1] ?? 0) })
        print("newest claim: \(winner ?? "?") — the others yield on their next reachable beat")
    }
    for id in s.unreachable { print("\(id): unreachable — cannot confirm") }
    if let w = readWheel() {
        print("local beacon: \(w.driver) (claim \(String(format: "%.0f", w.claimedAt)), "
            + "\(Int(Date().timeIntervalSince1970 - w.ts))s old)")
    }
    exit(s.claimants.count > 1 ? 1 : 0)
case "stop":
    let cfg = loadConfig(); let me = selfMachine(cfg)
    try? FileManager.default.removeItem(at: drivingFlag)
    try? FileManager.default.removeItem(at: wheelFile)
    for t in macPassengers(cfg: cfg, me: me) { endRide(on: t) }
    _ = forEachPeer(otherViewers(cfg: cfg, me: me)) { clearWheel(on: $0) }
    sh("pkill -f '\(jumpViewerPattern)' 2>/dev/null")   // close the viewer locally
    print("stopped — passengers return to console")
case "console":
    let cfg = loadConfig()
    try? FileManager.default.removeItem(at: rideFile)
    let rec = Reconciler(cfg: cfg); rec.lastMode = .passenger(canvas: "", hidpi: false)
    rec.tick()
    print("console mode")
case "handback":
    let cfg = loadConfig()
    writeHandback()
    let rec = Reconciler(cfg: cfg); rec.lastMode = .passenger(canvas: "", hidpi: false)
    rec.tick()   // fresh handback -> immediate console converge
    print("handback — returned to console")
case "perf":
    // Reads the structured event log and answers "is this getting better or
    // worse". Deliberately percentile-based: an average hides exactly the tail
    // that ruins a session (one 3-minute beat matters more than fifty fast ones).
    var events: [[String: Any]] = []
    for f in [stateDir.appendingPathComponent("events.1.jsonl"), eventsFile] {
        guard let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
        for line in text.split(separator: "\n") {
            if let d = line.data(using: .utf8),
               let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
                events.append(o)
            }
        }
    }
    guard !events.isEmpty else {
        print("no events yet — \(eventsFile.path)"); exit(0)
    }
    func of(_ e: String) -> [[String: Any]] { events.filter { $0["e"] as? String == e } }
    func nums(_ rows: [[String: Any]], _ k: String) -> [Double] {
        rows.compactMap { ($0[k] as? NSNumber)?.doubleValue }
    }
    func line(_ label: String, _ xs: [Double], _ unit: String) -> String {
        xs.isEmpty ? "  \(label): none"
        : "  \(label): n=\(xs.count)  p50=\(String(format: "%.0f", percentile(xs, 0.5)))\(unit)"
          + "  p95=\(String(format: "%.0f", percentile(xs, 0.95)))\(unit)"
          + "  max=\(String(format: "%.0f", xs.max() ?? 0))\(unit)"
    }
    let ts = events.compactMap { ($0["ts"] as? NSNumber)?.doubleValue }
    let span = (ts.max() ?? 0) - (ts.min() ?? 0)
    let df = DateFormatter(); df.dateFormat = "MM-dd HH:mm"
    print("MIRA perf — \(events.count) events over \(String(format: "%.1f", span / 3600))h "
        + "(since \(df.string(from: Date(timeIntervalSince1970: ts.min() ?? 0))))")

    let conv = of("converge")
    let convOK = conv.filter { $0["ok"] as? Bool == true }
    print("convergence")
    print(line("duration", nums(convOK, "ms"), "ms"))
    let fails = conv.filter { $0["ok"] as? Bool == false }
    if fails.isEmpty { print("  failures: none") } else {
        var byReason: [String: Int] = [:]
        for f in fails { byReason[(f["why"] as? String) ?? "?", default: 0] += 1 }
        print("  failures: \(fails.count) of \(conv.count)")
        for (why, c) in byReason.sorted(by: { $0.value > $1.value }).prefix(3) {
            print("    \(c)x  \(why)")
        }
    }

    // The lease numbers are the ones that matter: a lease that arrives already
    // most-expired, or that lapses at all, is a passenger about to flap to
    // console and tear its displays down.
    let recv = of("lease_recv"), ages = nums(recv, "age")
    print("leases")
    print(line("age on arrival", ages, "s"))
    let born = ages.filter { $0 > 45 }.count
    if !ages.isEmpty && born > 0 {
        print("  arrived >50% expired: \(born)/\(ages.count) — driver stamps before a slow send")
    }
    let exp = of("lease_expire")
    print("  lapsed (passenger dropped to console): \(exp.count)")
    if !exp.isEmpty { print(line("  age at lapse", nums(exp, "age"), "s")) }

    print("driver")
    print(line("beat duration", nums(of("beat"), "ms"), "ms"))
    print("  claims: \(of("claim").count)   yields: \(of("yield").count)")

    let peers = of("peer")
    if !peers.isEmpty {
        var flaps: [String: Int] = [:]
        for p in peers where p["up"] as? Bool == false {
            flaps[(p["id"] as? String) ?? "?", default: 0] += 1
        }
        print("peers")
        for (id, c) in flaps.sorted(by: { $0.value > $1.value }) {
            print("  \(id): \(c) unreachable transitions")
        }
    }
    let sz = (try? FileManager.default.attributesOfItem(atPath: eventsFile.path)[.size] as? Int) ?? 0
    print("log: \(eventsFile.path) (\((sz ?? 0) / 1024) KB, caps at \(eventsCapBytes / 1024) KB + 1 rotation)")

case "report":
    let text = ((try? String(contentsOf: logFile, encoding: .utf8)) ?? "")
        + ((try? String(contentsOf: logFile.deletingPathExtension().appendingPathExtension("old.log"), encoding: .utf8)) ?? "")
    let lines = text.components(separatedBy: "\n")
    func count(_ needle: String) -> Int { lines.filter { $0.contains(needle) }.count }
    let convergeTimes = lines.compactMap { line -> Double? in
        guard line.contains("converged=true in ") else { return nil }
        return Double(line.components(separatedBy: " in ").last?.dropLast(1) ?? "")
    }
    let avg = convergeTimes.isEmpty ? 0 : convergeTimes.reduce(0, +) / Double(convergeTimes.count)
    print("""
    MIRA report (\(lines.count) log lines)
      daemon starts:        \(count("daemon started"))
      passenger converges:  \(count("converged=true"))  (avg \(String(format: "%.1f", avg))s)
      converge failures:    \(count("converged=false"))
      virtual create fails: \(count("virtual create FAILED"))
      console restores:     \(count("converge -> console"))
      walk-up handbacks:    \(count("handback"))
      tier changes:         \(count("tier "))
      ride failures:        \(count("ride placement FAILED"))
      scroll tap:           active=\(count("scroll tap active")) failed=\(count("scroll tap creation failed"))
    """)
case "doctor":
    let cfg = loadConfig()
    let (report, failures) = doctor(cfg: cfg, me: selfMachine(cfg))
    print(report); exit(failures == 0 ? 0 : 1)
default:
    let app = NSApplication.shared
    let delegate = MenuApp()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
