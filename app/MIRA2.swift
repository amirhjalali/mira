// MIRA 2 — one binary: menu-bar app, passenger daemon, CLI. Native display
// engine (CGVirtualDisplay + CoreGraphics config) — no BetterDisplay, no
// displayplacer. See docs/DESIGN-2.md and docs/PROPOSAL-fleet.md.
//
//   (no args)    menu-bar app (driver UI)
//   --daemon     reconciler daemon (every Mac; passengers converge here)
//   drive | stop | status | doctor | console | selftest
import AppKit
import Foundation

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
    if p.isRunning { p.terminate() }
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
    let type: String?             // "mac" (default) | "windows"
}
struct Config: Codable {
    let rideTTLSeconds: Double, heartbeatSeconds: Double, reconcileSeconds: Double
    let homeSubnetPrefix: String
    let dockedCanvas: String
    let canvases: [String: Canvas]
    let machines: [Machine]
}

func repoRoot() -> URL {
    if let env = ProcessInfo.processInfo.environment["MACRIG_DIR"], !env.isEmpty {
        return URL(fileURLWithPath: env, isDirectory: true)
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
    if let m = cfg.machines.first(where: { $0.user == me }) { return m }
    fatalError("no machine in machines.json with user \(me)")
}

// MARK: - State

let stateDir = URL(fileURLWithPath: NSHomeDirectory())
    .appendingPathComponent("Library/Application Support/MacRig", isDirectory: true)
let rideFile = stateDir.appendingPathComponent("ride.json")
let drivingFlag = stateDir.appendingPathComponent("driving")
let arrangementFile = stateDir.appendingPathComponent("arrangement.json")
let logFile = repoRoot().appendingPathComponent("logs/mira2.log")

func log(_ msg: String) {
    let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let line = "\(df.string(from: Date())) \(msg)\n"
    if let h = try? FileHandle(forWritingTo: logFile) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
    } else {
        try? line.write(to: logFile, atomically: true, encoding: .utf8)
    }
    FileHandle.standardOutput.write(line.data(using: .utf8)!)
}

// MARK: - Ride (a driver's claim on this passenger)

struct Ride: Codable {
    let driver: String
    let canvas: String
    let hidpi: Bool
    let ts: Double
    func isLive(ttl: Double, now: Double = Date().timeIntervalSince1970) -> Bool {
        now - ts < ttl
    }
}

func readRide() -> Ride? {
    guard let d = try? Data(contentsOf: rideFile) else { return nil }
    return try? JSONDecoder().decode(Ride.self, from: d)
}

// MARK: - Mode (pure, selftested)

enum Mode: Equatable { case console; case passenger(canvas: String, hidpi: Bool) }

func computeMode(ride: Ride?, ttl: Double, now: Double) -> Mode {
    if let r = ride, r.isLive(ttl: ttl, now: now) {
        return .passenger(canvas: r.canvas, hidpi: r.hidpi)
    }
    return .console
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

// MARK: - Native display engine

let miraVendorID: UInt32 = 0x4D49_5241 & 0xFFFF  // "RA" tail of 'MIRA'

final class DisplayEngine {
    private var virtualDisplay: CGVirtualDisplay?
    private(set) var virtualID: CGDirectDisplayID = 0

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
        if virtualDisplay != nil { return true }
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
        log("virtual display created id=\(virtualID) for \(canvas.width)x\(canvas.height)")
        return true
    }

    func destroyVirtual() {
        if virtualDisplay != nil { log("virtual display destroyed") }
        virtualDisplay = nil
        virtualID = 0
    }

    // Choose a mode on the virtual display: UI size WxH at 2x (hidpi) or 1x.
    func setVirtualMode(canvas: Canvas, hidpi: Bool) -> Bool {
        guard virtualID != 0 else { return false }
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(virtualID, opts) as? [CGDisplayMode] else { return false }
        let want = modes.first { m in
            m.width == canvas.width && m.height == canvas.height &&
            (hidpi ? m.pixelWidth == canvas.width * 2 : m.pixelWidth == canvas.width)
        }
        guard let mode = want else { return false }
        var cfg: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&cfg)
        CGConfigureDisplayWithDisplayMode(cfg, virtualID, mode, nil)
        return CGCompleteDisplayConfiguration(cfg, .permanently) == .success
    }

    func mirrorPhysicalsOntoVirtual() -> Bool {
        guard virtualID != 0 else { return false }
        var cfg: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&cfg)
        for p in physicalDisplays() { CGConfigureDisplayMirrorOfDisplay(cfg, p, virtualID) }
        CGConfigureDisplayOrigin(cfg, virtualID, 0, 0)  // main
        return CGCompleteDisplayConfiguration(cfg, .permanently) == .success
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
        guard virtualID != 0, CGDisplayIsMain(virtualID) != 0 else { return false }
        guard Int(CGDisplayPixelsWide(virtualID)) == (hidpi ? canvas.width : canvas.width) else { return false }
        let m = CGDisplayCopyDisplayMode(virtualID)
        if hidpi, let m = m, m.pixelWidth != canvas.width * 2 { return false }
        for p in physicalDisplays() where CGDisplayMirrorsDisplay(p) != virtualID { return false }
        return true
    }
}

// MARK: - Arrangement capture / restore (origins of physical displays)

struct SavedDisplay: Codable { let id: UInt32; let x: Int; let y: Int; let main: Bool }

func captureArrangement(engine: DisplayEngine) {
    guard !FileManager.default.fileExists(atPath: arrangementFile.path) else { return }
    let saved = engine.physicalDisplays().map { d -> SavedDisplay in
        let b = CGDisplayBounds(d)
        return SavedDisplay(id: d, x: Int(b.origin.x), y: Int(b.origin.y),
                            main: CGDisplayIsMain(d) != 0)
    }
    try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    if let d = try? JSONEncoder().encode(saved) { try? d.write(to: arrangementFile) }
}

func restoreArrangement(engine: DisplayEngine) {
    engine.unmirrorAll()
    guard let data = try? Data(contentsOf: arrangementFile),
          let saved = try? JSONDecoder().decode([SavedDisplay].self, from: data) else {
        if let first = engine.physicalDisplays().first { engine.setMain(first) }
        return
    }
    var cfg: CGDisplayConfigRef?
    CGBeginDisplayConfiguration(&cfg)
    for s in saved where engine.onlineDisplays().contains(s.id) {
        CGConfigureDisplayOrigin(cfg, s.id, Int32(s.x), Int32(s.y))
    }
    CGCompleteDisplayConfiguration(cfg, .permanently)
    if let main = saved.first(where: { $0.main }), engine.onlineDisplays().contains(main.id) {
        engine.setMain(main.id)
    } else if let first = engine.physicalDisplays().first {
        engine.setMain(first)
    }
    try? FileManager.default.removeItem(at: arrangementFile)
}

// MARK: - Reconciler

final class Reconciler {
    let cfg: Config
    let me: Machine
    let engine = DisplayEngine()
    var lastMode: Mode?

    init(cfg: Config) { self.cfg = cfg; self.me = selfMachine(cfg) }

    func tick() {
        let mode = computeMode(ride: readRide(), ttl: cfg.rideTTLSeconds,
                               now: Date().timeIntervalSince1970)
        switch mode {
        case .passenger(let canvasKey, let hidpi):
            guard let canvas = cfg.canvases[canvasKey] else { return }
            let wantHi = hidpi && canvas.hidpi
            // A passenger never streams outward — enforce every tick, not just
            // on transition (the viewer can be relaunched under us).
            sh("pkill -x 'Jump Desktop' 2>/dev/null")
            if engine.passengerInvariantHolds(canvas: canvas, hidpi: wantHi),
               lastMode == mode { return }
            log("converge -> passenger(\(canvasKey), hidpi=\(wantHi))")
            captureArrangement(engine: engine)
            sh("pkill -x 'Jump Desktop' 2>/dev/null")          // never stream outward
            sh("caffeinate -u -t 15 >/dev/null 2>&1 &")        // wake display stack
            guard engine.ensureVirtual(canvas: canvas) else { log("virtual create FAILED"); return }
            _ = engine.setVirtualMode(canvas: canvas, hidpi: wantHi)
            _ = engine.mirrorPhysicalsOntoVirtual()
            let ok = engine.passengerInvariantHolds(canvas: canvas, hidpi: wantHi)
            log("passenger converged=\(ok)")
            lastMode = mode
        case .console:
            if lastMode == .console || (lastMode == nil && engine.virtualID == 0
                && !FileManager.default.fileExists(atPath: arrangementFile.path)) {
                lastMode = .console; return
            }
            log("converge -> console")
            engine.destroyVirtual()
            restoreArrangement(engine: engine)
            lastMode = .console
        }
    }
}

// MARK: - SSH to peers (multiplexed; sockets live in ~/.ssh — no spaces)

func sshArgs() -> String {
    "-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new " +
    "-o ControlMaster=auto -o ControlPath=~/.ssh/mira-%C -o ControlPersist=120"
}

func peerRun(_ m: Machine, _ cmd: String, timeout: TimeInterval = 20) -> (out: String, code: Int32) {
    let q = cmd.replacingOccurrences(of: "'", with: "'\\''")
    return sh("ssh \(sshArgs()) \(m.user)@\(m.tailscale) '\(q)'", timeout: timeout)
}

// MARK: - Driver side

func atHome(cfg: Config) -> Bool {
    sh("ifconfig 2>/dev/null | awk '/inet /{print $2}'").out
        .contains(cfg.homeSubnetPrefix)
}

func measureNet(to m: Machine) -> (avg: Double, jitter: Double)? {
    let out = sh("ping -c 15 -i 0.2 -q \(m.tailscale) 2>/dev/null | awk -F/ '/round-trip/{gsub(/[^0-9.]/,\"\",$7); print $5, $7}'", timeout: 15).out
    let parts = out.split(separator: " ").compactMap { Double($0) }
    guard parts.count == 2 else { return nil }
    return (parts[0], parts[1])
}

func driverCanvasKey(cfg: Config, me: Machine, engine: DisplayEngine) -> String {
    pickCanvas(physicalWidths: engine.physicalWidths(),
               dockedCanvas: cfg.dockedCanvas,
               laptopCanvas: me.laptopCanvas ?? "laptop-pro")
}

func placeRide(on target: Machine, canvas: String, hidpi: Bool, driver: String) -> Bool {
    let ride = Ride(driver: driver, canvas: canvas, hidpi: hidpi,
                    ts: Date().timeIntervalSince1970)
    guard let d = try? JSONEncoder().encode(ride),
          let json = String(data: d, encoding: .utf8) else { return false }
    let dir = "$HOME/Library/Application Support/MacRig"
    return peerRun(target, "mkdir -p \"\(dir)\" && printf %s '\(json)' > \"\(dir)/ride.json\"").code == 0
}

func endRide(on target: Machine) {
    _ = peerRun(target, "rm -f \"$HOME/Library/Application Support/MacRig/ride.json\"")
}

func macPassengers(cfg: Config, me: Machine) -> [Machine] {
    cfg.machines.filter { $0.id != me.id && $0.roles.contains("target") && ($0.type ?? "mac") == "mac" }
}

func driveTick(cfg: Config, me: Machine, engine: DisplayEngine, previousTier: Tier) -> Tier {
    let canvas = driverCanvasKey(cfg: cfg, me: me, engine: engine)
    let home = atHome(cfg: cfg)
    let docked = canvas == cfg.dockedCanvas
    var tier = previousTier
    if let net = macPassengers(cfg: cfg, me: me).lazy.compactMap({ measureNet(to: $0) }).first {
        tier = computeTier(previous: previousTier, avgMs: net.avg, jitterMs: net.jitter,
                           home: home, docked: docked)
    }
    for t in macPassengers(cfg: cfg, me: me) {
        _ = placeRide(on: t, canvas: canvas, hidpi: tierWantsHiDPI(tier), driver: me.id)
    }
    return tier
}

// MARK: - Doctor

func doctor(cfg: Config, me: Machine) -> (report: String, failures: Int) {
    var lines = ["MIRA 2 Doctor — \(me.id)"], failures = 0
    let group = DispatchGroup(); let lock = NSLock(); var peerLines: [String] = []
    for t in macPassengers(cfg: cfg, me: me) {
        group.enter()
        DispatchQueue.global().async {
            var l: [String] = []
            let probe = peerRun(t, """
            echo user=$(whoami); \
            pgrep -f 'MIRA2 --daemon' >/dev/null && echo daemon=ok || echo daemon=missing; \
            cat "$HOME/Library/Application Support/MacRig/ride.json" 2>/dev/null || echo no-ride
            """, timeout: 15)
            if probe.code != 0 { l.append("✗ \(t.id) unreachable"); lock.lock(); failures += 1; lock.unlock() }
            else {
                let o = probe.out
                l.append("✓ \(t.id) reachable")
                if o.contains("daemon=missing") {
                    l.append("✗ \(t.id) daemon not running"); lock.lock(); failures += 1; lock.unlock()
                } else { l.append("✓ \(t.id) daemon running") }
                l.append(o.contains("no-ride") ? "  \(t.id): parked" : "  \(t.id): being driven")
            }
            lock.lock(); peerLines.append(contentsOf: l); lock.unlock()
            group.leave()
        }
    }
    group.wait()
    lines.append(contentsOf: peerLines.sorted())
    let vnc = sh("ps -Aro pcpu,comm | awk '$2 ~ /screensharingd/ && $1+0 > 5'").out
    if !vnc.trimmingCharacters(in: .whitespaces).isEmpty {
        lines.append("✗ inbound session is VNC — use the Fluid entry"); failures += 1
    } else { lines.append("✓ no VNC session detected") }
    lines.append(failures == 0 ? "Doctor: ready" : "Doctor: \(failures) failure(s)")
    return (lines.joined(separator: "\n"), failures)
}

// MARK: - Daemon

func runDaemon(cfg: Config) -> Never {
    let rec = Reconciler(cfg: cfg)
    log("mira2 daemon started on \(rec.me.id) (driver+passenger roles: \(rec.me.roles))")
    var tier: Tier = .standard
    var beat = 0.0
    while true {
        rec.tick()
        if rec.me.roles.contains("viewer"),
           FileManager.default.fileExists(atPath: drivingFlag.path) {
            beat -= cfg.reconcileSeconds
            if beat <= 0 {
                tier = driveTick(cfg: cfg, me: rec.me, engine: rec.engine, previousTier: tier)
                beat = cfg.heartbeatSeconds
            }
        }
        Thread.sleep(forTimeInterval: cfg.reconcileSeconds)
    }
}

// MARK: - Menu bar

final class MenuApp: NSObject, NSApplicationDelegate {
    var item: NSStatusItem!
    let cfg = loadConfig()
    lazy var me = selfMachine(cfg)

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "◈"
        rebuild()
    }
    var driving: Bool { FileManager.default.fileExists(atPath: drivingFlag.path) }
    func rebuild() {
        let m = NSMenu()
        m.addItem(withTitle: driving ? "◈ driving" : "◈ parked", action: nil, keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(withTitle: "Drive from here", action: #selector(drive), keyEquivalent: "").target = self
        m.addItem(withTitle: "Stop driving", action: #selector(stop), keyEquivalent: "").target = self
        m.addItem(withTitle: "Run Doctor", action: #selector(runDoc), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "Quit MIRA 2", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = m
    }
    @objc func drive() {
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: drivingFlag.path, contents: nil)
        let engine = DisplayEngine()
        let canvas = driverCanvasKey(cfg: cfg, me: me, engine: engine)
        for t in macPassengers(cfg: cfg, me: me) {
            _ = placeRide(on: t, canvas: canvas, hidpi: true, driver: me.id)
            sh("""
            osascript -e 'tell application "Jump Desktop" to activate' \
              -e 'delay 0.6' \
              -e 'tell application "System Events" to tell process "Jump Desktop" to click menu bar item "File" of menu bar 1' \
              -e 'delay 0.4' \
              -e 'tell application "System Events" to tell process "Jump Desktop" to click menu item "Open Recent" of menu 1 of menu bar item "File" of menu bar 1' \
              -e 'delay 0.4' \
              -e 'tell application "System Events" to tell process "Jump Desktop" to click menu item "\(t.jumpName)" of menu 1 of menu item "Open Recent" of menu 1 of menu bar item "File" of menu bar 1' 2>/dev/null
            """)
        }
        notify("Driving \(macPassengers(cfg: cfg, me: me).count) passengers (\(canvas))")
        rebuild()
    }
    @objc func stop() {
        try? FileManager.default.removeItem(at: drivingFlag)
        for t in macPassengers(cfg: cfg, me: me) { endRide(on: t) }
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
        sh("osascript -e 'display notification \"\(esc)\" with title \"MIRA 2\"'")
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
    let live = Ride(driver: "air", canvas: "laptop-air", hidpi: true, ts: now - 10)
    let stale = Ride(driver: "air", canvas: "laptop-air", hidpi: true, ts: now - 120)
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
    // config sanity
    let cfg = loadConfig()
    expect(cfg.machines.count >= 3, "config has machines")
    expect(cfg.canvases[cfg.dockedCanvas] != nil, "docked canvas defined")
    for m in cfg.machines where m.roles.contains("viewer") {
        expect(m.laptopCanvas != nil && cfg.canvases[m.laptopCanvas!] != nil,
               "viewer \(m.id) has laptop canvas")
    }
    print(failures == 0 ? "MIRA2 selftest: OK" : "MIRA2 selftest: \(failures) FAILURES")
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
    print("machine: \(me.id)  mode: \(mode)  driving: \(driving)")
case "drive":
    let cfg = loadConfig(); let me = selfMachine(cfg)
    try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: drivingFlag.path, contents: nil)
    let engine = DisplayEngine()
    let canvas = driverCanvasKey(cfg: cfg, me: me, engine: engine)
    for t in macPassengers(cfg: cfg, me: me) {
        let ok = placeRide(on: t, canvas: canvas, hidpi: true, driver: me.id)
        print("\(t.id): \(ok ? "riding (\(canvas))" : "RIDE FAILED")")
    }
case "stop":
    let cfg = loadConfig(); let me = selfMachine(cfg)
    try? FileManager.default.removeItem(at: drivingFlag)
    for t in macPassengers(cfg: cfg, me: me) { endRide(on: t) }
    print("stopped — passengers return to console")
case "console":
    let cfg = loadConfig()
    try? FileManager.default.removeItem(at: rideFile)
    let rec = Reconciler(cfg: cfg); rec.lastMode = .passenger(canvas: "", hidpi: false)
    rec.tick()
    print("console mode")
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
