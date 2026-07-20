// MIRA 2 — one binary: menu-bar app, reconciler daemon, CLI.
// See docs/DESIGN-2.md. Modes:
//   (no args)   menu-bar app
//   --daemon    reconciler loop (LaunchAgent)
//   status | claim | release | console | doctor | selftest
import AppKit
import Foundation

// MARK: - Shell

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

let BDCLI: String = {
    for c in ["/opt/homebrew/bin/betterdisplaycli", "/usr/local/bin/betterdisplaycli"]
    where FileManager.default.isExecutableFile(atPath: c) { return c }
    return "betterdisplaycli"
}()
let DISPLAYPLACER: String = {
    for c in ["/opt/homebrew/bin/displayplacer", "/usr/local/bin/displayplacer"]
    where FileManager.default.isExecutableFile(atPath: c) { return c }
    return "displayplacer"
}()

// MARK: - Config

struct Canvas: Codable { let resolution: String; let hidpi: Bool; let screen: String }
struct VScreenSpec: Codable { let aspect: [Int]; let resolutions: [String] }
struct Machine: Codable {
    let id: String, jumpName: String, host: String, tailscale: String, user: String
    let roles: [String]
}
struct Config: Codable {
    let claimTTLSeconds: Double, heartbeatSeconds: Double, reconcileSeconds: Double
    let dockMarker: String
    let canvases: [String: Canvas]
    let virtualScreens: [String: VScreenSpec]
    let machines: [Machine]
}

func repoRoot() -> URL {
    if let env = ProcessInfo.processInfo.environment["MACRIG_DIR"], !env.isEmpty {
        return URL(fileURLWithPath: env, isDirectory: true)
    }
    return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("mira", isDirectory: true)
}

func loadConfig() -> Config {
    let url = repoRoot().appendingPathComponent("config/machines.json")
    guard let data = try? Data(contentsOf: url),
          let cfg = try? JSONDecoder().decode(Config.self, from: data) else {
        fatalError("cannot load \(url.path)")
    }
    return cfg
}

func selfMachine(_ cfg: Config) -> Machine {
    let me = NSUserName()
    if let m = cfg.machines.first(where: { $0.user == me }) { return m }
    fatalError("no machine in machines.json with user \(me)")
}

// MARK: - State dir

let stateDir = URL(fileURLWithPath: NSHomeDirectory())
    .appendingPathComponent("Library/Application Support/MacRig", isDirectory: true)
let claimFile = stateDir.appendingPathComponent("claim.json")
let restoreFile = stateDir.appendingPathComponent("console-arrangement.sh")
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

// MARK: - Claim

struct Claim: Codable {
    let viewer: String       // machine id of the claiming viewer
    let canvas: String       // key into cfg.canvases
    let ts: Double           // unix time of last heartbeat
    func isLive(ttl: Double, now: Double = Date().timeIntervalSince1970) -> Bool {
        now - ts < ttl
    }
}

func readClaim() -> Claim? {
    guard let d = try? Data(contentsOf: claimFile) else { return nil }
    return try? JSONDecoder().decode(Claim.self, from: d)
}

func writeClaimLocal(_ c: Claim?) {
    try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    if let c = c, let d = try? JSONEncoder().encode(c) { try? d.write(to: claimFile) }
    else { try? FileManager.default.removeItem(at: claimFile) }
}

// MARK: - Console evidence

let virtualNames = ["Ultrawide", "Laptop"]

func consoleUser() -> String {
    sh("stat -f %Su /dev/console").out.trimmingCharacters(in: .whitespacesAndNewlines)
}

struct DisplayEntity { let name: String; let deviceType: String }

func bdIdentifiers() -> [DisplayEntity] {
    let raw = sh("\(BDCLI) get -identifiers 2>/dev/null").out
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty, let data = "[\(raw)]".data(using: .utf8),
          let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
    return arr.compactMap { o in
        guard let n = o["name"] as? String, let t = o["deviceType"] as? String else { return nil }
        return DisplayEntity(name: n, deviceType: t)
    }
}

// Pure: is a real user present at a physical screen?
func computeConsoleActive(user: String, entities: [DisplayEntity]) -> Bool {
    switch user { case "", "root", "loginwindow", "_mbsetupuser": return false; default: break }
    return entities.contains { $0.deviceType == "Display" && !virtualNames.contains($0.name) }
}

// MARK: - Desired state (pure core, selftested)

enum Mode: Equatable { case console; case target(canvas: String) }

// The one rule: a live claim makes this machine a target; otherwise, console.
// Console evidence does not veto a live claim (the viewer asked for the screen);
// it decides the default when no claim exists and gates login-time behavior.
func computeMode(claim: Claim?, ttl: Double, now: Double) -> Mode {
    if let c = claim, c.isLive(ttl: ttl, now: now) { return .target(canvas: c.canvas) }
    return .console
}

// MARK: - Displays: observation

struct DisplaysSnapshot {
    let activeNames: [String]          // section names from system_profiler
    let mirrorOn: [String: Bool]
    let mainName: String?
}

func parseDisplaysProfile(_ text: String) -> DisplaysSnapshot {
    var names: [String] = [], mirror: [String: Bool] = [:], main: String?
    var current: String?
    for line in text.components(separatedBy: "\n") {
        if line.hasPrefix("        "), !line.hasPrefix("         "), line.hasSuffix(":") {
            current = String(line.dropFirst(8).dropLast())
            names.append(current!)
        } else if let c = current {
            if line.contains("Mirror: On") { mirror[c] = true }
            if line.contains("Mirror: Off") { mirror[c] = false }
            if line.contains("Main Display: Yes") { main = c }
        }
    }
    return DisplaysSnapshot(activeNames: names, mirrorOn: mirror, mainName: main)
}

func displaysSnapshot() -> DisplaysSnapshot {
    parseDisplaysProfile(sh("system_profiler SPDisplaysDataType 2>/dev/null").out)
}

// BetterDisplay answers once per matching entity ("on,on"); every value must match.
func allValuesAre(_ expected: String, _ actual: String) -> Bool {
    let vals = actual.trimmingCharacters(in: .whitespacesAndNewlines)
        .components(separatedBy: ",").filter { !$0.isEmpty }
    return !vals.isEmpty && vals.allSatisfy { $0 == expected }
}

func vsConnected(_ name: String) -> Bool {
    allValuesAre("on", sh("\(BDCLI) get -name=\(name) -connected 2>/dev/null").out)
}

// MARK: - displayplacer helpers

// The last "displayplacer \"..." line of `displayplacer list` is the exact
// command that restores the current arrangement.
func parseRestoreCommand(_ listOutput: String) -> String? {
    listOutput.components(separatedBy: "\n").last { $0.hasPrefix("displayplacer \"") }
}

struct PlacerScreen { let persistentId: String; let type: String }

func parsePlacerScreens(_ listOutput: String) -> [PlacerScreen] {
    var out: [PlacerScreen] = []
    var pid: String?
    for line in listOutput.components(separatedBy: "\n") {
        if line.hasPrefix("Persistent screen id: ") {
            pid = String(line.dropFirst("Persistent screen id: ".count))
        } else if line.hasPrefix("Type: "), let p = pid {
            out.append(PlacerScreen(persistentId: p, type: String(line.dropFirst("Type: ".count))))
            pid = nil
        }
    }
    return out
}

// MARK: - Reconciler

final class Reconciler {
    let cfg: Config
    let me: Machine
    var lastMode: Mode?
    init(cfg: Config) { self.cfg = cfg; self.me = selfMachine(cfg) }

    func targetInvariantHolds(_ canvas: Canvas) -> Bool {
        let snap = displaysSnapshot()
        guard vsConnected(canvas.screen), snap.mainName == canvas.screen else { return false }
        let physicals = snap.activeNames.filter { !virtualNames.contains($0) }
        return physicals.allSatisfy { snap.mirrorOn[$0] == true }
    }

    func ensureVirtualScreen(_ name: String) {
        let ids = bdIdentifiers()
        if ids.contains(where: { $0.name == name && $0.deviceType == "VirtualScreen" }) { return }
        guard let spec = cfg.virtualScreens[name] else { return }
        let hidpi = cfg.canvases.values.first { $0.screen == name }?.hidpi ?? false
        log("creating virtual screen \(name)")
        sh("""
        \(BDCLI) create -type=VirtualScreen -virtualScreenName=\(name) \
          -aspectWidth=\(spec.aspect[0]) -aspectHeight=\(spec.aspect[1]) \
          -useResolutionList=on -resolutionList="\(spec.resolutions.joined(separator: ","))" \
          -virtualScreenHiDPI=\(hidpi ? "on" : "off")
        """, timeout: 60)
        sleep(3)
    }

    func captureArrangementIfNeeded() {
        // Only capture from a clean console state, never mid-target.
        guard lastMode == nil || lastMode == .console else { return }
        let listing = sh("\(DISPLAYPLACER) list", timeout: 20).out
        if let restore = parseRestoreCommand(listing) {
            try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
            try? "#!/bin/bash\n\(DISPLAYPLACER.replacingOccurrences(of: "displayplacer", with: "displayplacer"))\n"
                .write(to: restoreFile, atomically: true, encoding: .utf8)
            try? "#!/bin/bash\n\(restore)\n".write(to: restoreFile, atomically: true, encoding: .utf8)
        }
    }

    func convergeTarget(canvasKey: String) {
        guard let canvas = cfg.canvases[canvasKey] else { return }
        if targetInvariantHolds(canvas) { return }
        log("converge -> target(\(canvasKey))")
        captureArrangementIfNeeded()
        ensureVirtualScreen(canvas.screen)
        // A machine in target mode never streams outward: end our own viewer.
        sh("pkill -x 'Jump Desktop' 2>/dev/null")
        // Wake displays so the virtual screen can materialize, then connect.
        sh("caffeinate -u -t 20 >/dev/null 2>&1 &")
        sh("\(BDCLI) set -name=\(canvas.screen) -connected=on", timeout: 20); sleep(3)
        if !vsConnected(canvas.screen) {  // zombie half-connect: force a cycle
            sh("\(BDCLI) set -name=\(canvas.screen) -connected=off"); sleep(3)
            sh("\(BDCLI) set -name=\(canvas.screen) -connected=on", timeout: 20); sleep(3)
        }
        // Pick the mode: prefer HiDPI row when the canvas wants it.
        let modes = sh("\(BDCLI) get -name=\(canvas.screen) -displayModeList 2>/dev/null").out
        var modeNumber: String?
        for line in modes.components(separatedBy: "\n") {
            let f = line.split(separator: " ").map(String.init)
            guard f.count >= 3, f[2] == canvas.resolution else { continue }
            let isHi = line.contains("HiDPI")
            if canvas.hidpi == isHi { modeNumber = f[0]; break }
            if modeNumber == nil { modeNumber = f[0] }
        }
        if let n = modeNumber {
            sh("\(BDCLI) set -name=\(canvas.screen) -displayModeNumber=\(n)"); sleep(2)
        }
        // Mirror every physical screen onto the virtual and make it main.
        let placer = sh("\(DISPLAYPLACER) list", timeout: 20).out
        let screens = parsePlacerScreens(placer)
        // displayplacer names virtual screens by size class; identify physicals
        // as "MacBook built in screen" or screens whose type mentions inch and
        // whose id is not the virtual's. The virtual is the one whose current
        // resolution equals the canvas (fallback: first screen listed).
        let virtualId = screens.first { s in
            placer.contains("Persistent screen id: \(s.persistentId)")
        }.map { _ in "" }
        _ = virtualId // resolved below via mirror grouping by exclusion
        let idList = screens.map { $0.persistentId }
        if idList.count >= 2 {
            let grouped = idList.joined(separator: "+")
            sh("\(DISPLAYPLACER) \"id:\(grouped) res:\(canvas.resolution) scaling:\(canvas.hidpi ? "on" : "off") origin:(0,0) degree:0\" 2>&1 | grep -v 'could not find res' || true", timeout: 30)
        }
        sh("\(BDCLI) set -name=\(canvas.screen) -main=on"); sleep(1)
        let ok = targetInvariantHolds(canvas)
        log("target(\(canvasKey)) converged=\(ok)")
        lastMode = .target(canvas: canvasKey)
    }

    func convergeConsole() {
        let snap = displaysSnapshot()
        let virtualsActive = snap.activeNames.filter { virtualNames.contains($0) }
        let alreadyClean = virtualsActive.isEmpty && !(snap.activeNames.isEmpty)
        if alreadyClean && lastMode == .console { return }
        if !virtualsActive.isEmpty || lastMode != .console {
            log("converge -> console")
            for v in virtualNames { sh("\(BDCLI) set -name=\(v) -connected=off") }
            sleep(2)
            if FileManager.default.fileExists(atPath: restoreFile.path) {
                sh("bash '\(restoreFile.path)' 2>/dev/null", timeout: 30)
                try? FileManager.default.removeItem(at: restoreFile)
            }
            sh("\(BDCLI) set -namelike=Built -main=on 2>/dev/null")
        }
        lastMode = .console
    }

    func tick() {
        let mode = computeMode(claim: readClaim(), ttl: cfg.claimTTLSeconds,
                               now: Date().timeIntervalSince1970)
        switch mode {
        case .target(let canvasKey): convergeTarget(canvasKey: canvasKey)
        case .console: convergeConsole()
        }
    }
}

// MARK: - SSH to peers (multiplexed)

func sshArgs(_ m: Machine) -> String {
    let ctl = "\(stateDir.path)/ssh-%r@%h"
    return "-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new " +
           "-o ControlMaster=auto -o ControlPath='\(ctl)' -o ControlPersist=120"
}

func peerRun(_ m: Machine, _ cmd: String, timeout: TimeInterval = 20) -> (out: String, code: Int32) {
    let q = cmd.replacingOccurrences(of: "'", with: "'\\''")
    return sh("ssh \(sshArgs(m)) \(m.user)@\(m.tailscale) '\(q)'", timeout: timeout)
}

func placeClaim(on target: Machine, canvas: String, viewer: String, cfg: Config) -> Bool {
    let claim = Claim(viewer: viewer, canvas: canvas, ts: Date().timeIntervalSince1970)
    guard let d = try? JSONEncoder().encode(claim), let json = String(data: d, encoding: .utf8)
    else { return false }
    let dir = "$HOME/Library/Application Support/MacRig"
    let r = peerRun(target, "mkdir -p \"\(dir)\" && printf %s '\(json)' > \"\(dir)/claim.json\"")
    return r.code == 0
}

func releaseClaim(on target: Machine) {
    _ = peerRun(target, "rm -f \"$HOME/Library/Application Support/MacRig/claim.json\"")
}

// MARK: - Doctor

func doctor(cfg: Config, me: Machine) -> (report: String, failures: Int) {
    var lines: [String] = ["MIRA 2 Doctor — \(me.id)"], failures = 0
    let targets = cfg.machines.filter { $0.id != me.id && $0.roles.contains("target") }
    let group = DispatchGroup()
    let lock = NSLock()
    var peerLines: [String] = []
    for t in targets {
        group.enter()
        DispatchQueue.global().async {
            var l: [String] = []
            let probe = peerRun(t, """
            echo user=$(whoami); \
            test -x /opt/homebrew/bin/betterdisplaycli && echo bdcli=ok || echo bdcli=missing; \
            /opt/homebrew/bin/betterdisplaycli get -identifiers 2>/dev/null | grep -c VirtualScreen; \
            cat "$HOME/Library/Application Support/MacRig/claim.json" 2>/dev/null || echo no-claim
            """, timeout: 15)
            if probe.code != 0 {
                l.append("✗ \(t.id) unreachable"); lock.lock(); failures += 1; lock.unlock()
            } else {
                let o = probe.out
                l.append(o.contains("bdcli=ok") ? "✓ \(t.id) reachable, BetterDisplay ok"
                                                : "✗ \(t.id) missing BetterDisplay CLI")
                if !o.contains("bdcli=ok") { lock.lock(); failures += 1; lock.unlock() }
                l.append(o.contains("no-claim") ? "  \(t.id): no active claim"
                                                : "  \(t.id): claim present")
            }
            lock.lock(); peerLines.append(contentsOf: l); lock.unlock()
            group.leave()
        }
    }
    group.wait()
    lines.append(contentsOf: peerLines.sorted())
    // Transport: a busy screensharingd while we are a target means VNC.
    let vnc = sh("ps -Aro pcpu,comm | awk '$2 ~ /screensharingd/ && $1+0 > 5'").out
    if !vnc.trimmingCharacters(in: .whitespaces).isEmpty {
        lines.append("✗ inbound session is VNC (screensharingd busy) — use the Fluid entry")
        failures += 1
    } else {
        lines.append("✓ no VNC session detected")
    }
    lines.append(failures == 0 ? "Doctor: ready" : "Doctor: \(failures) failure(s)")
    return (lines.joined(separator: "\n"), failures)
}

// MARK: - Viewer actions

func currentCanvasKey(cfg: Config) -> String {
    let displays = sh("system_profiler SPDisplaysDataType 2>/dev/null").out
    return displays.contains(cfg.dockMarker) ? "ultrawide" : "laptop"
}

func claimAllTargets(cfg: Config, me: Machine) -> String {
    let canvas = currentCanvasKey(cfg: cfg)
    var results: [String] = []
    for t in cfg.machines where t.id != me.id && t.roles.contains("target") {
        let ok = placeClaim(on: t, canvas: canvas, viewer: me.id, cfg: cfg)
        results.append("\(t.id): \(ok ? "claimed (\(canvas))" : "CLAIM FAILED")")
    }
    return results.joined(separator: "\n")
}

func releaseAllTargets(cfg: Config, me: Machine) {
    for t in cfg.machines where t.id != me.id && t.roles.contains("target") { releaseClaim(on: t) }
}

// MARK: - Daemon

func runDaemon(cfg: Config) -> Never {
    let rec = Reconciler(cfg: cfg)
    let me = rec.me
    log("mira2 daemon started on \(me.id)")
    var heartbeatCountdown = 0.0
    while true {
        rec.tick()
        // Viewer duty: heartbeat our claims so targets keep them alive.
        if me.roles.contains("viewer") {
            heartbeatCountdown -= cfg.reconcileSeconds
            if heartbeatCountdown <= 0,
               FileManager.default.fileExists(atPath: stateDir.appendingPathComponent("claiming").path) {
                _ = claimAllTargets(cfg: cfg, me: me)
                heartbeatCountdown = cfg.heartbeatSeconds
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
    func rebuild() {
        let m = NSMenu()
        let claiming = FileManager.default.fileExists(
            atPath: stateDir.appendingPathComponent("claiming").path)
        m.addItem(withTitle: claiming ? "Workspace: active" : "Workspace: released",
                  action: nil, keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(withTitle: "Start Workspace", action: #selector(start), keyEquivalent: "").target = self
        m.addItem(withTitle: "Release Targets", action: #selector(releaseTargets), keyEquivalent: "").target = self
        m.addItem(withTitle: "Run Doctor", action: #selector(runDoctor), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "Quit MIRA 2", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = m
    }
    @objc func start() {
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: stateDir.appendingPathComponent("claiming").path, contents: nil)
        let result = claimAllTargets(cfg: cfg, me: me)
        for t in cfg.machines where t.id != me.id && t.roles.contains("target") {
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
        notify("Workspace started\n\(result)")
        rebuild()
    }
    @objc func releaseTargets() {
        try? FileManager.default.removeItem(at: stateDir.appendingPathComponent("claiming"))
        releaseAllTargets(cfg: cfg, me: me)
        notify("Targets released — they return to console mode")
        rebuild()
    }
    @objc func runDoctor() {
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
    // allValuesAre: per-entity answers
    expect(allValuesAre("on", "on"), "single on")
    expect(allValuesAre("on", "on,on"), "double on")
    expect(!allValuesAre("on", "on,off"), "mixed rejected")
    expect(!allValuesAre("on", ""), "empty rejected")
    // computeMode: claims and TTL
    let now = 1_000_000.0
    let live = Claim(viewer: "air", canvas: "laptop", ts: now - 10)
    let stale = Claim(viewer: "air", canvas: "laptop", ts: now - 120)
    expect(computeMode(claim: live, ttl: 90, now: now) == .target(canvas: "laptop"), "live claim -> target")
    expect(computeMode(claim: stale, ttl: 90, now: now) == .console, "stale claim -> console")
    expect(computeMode(claim: nil, ttl: 90, now: now) == .console, "no claim -> console")
    // console evidence
    let physical = [DisplayEntity(name: "Color LCD", deviceType: "Display")]
    let virtualOnly = [DisplayEntity(name: "Laptop", deviceType: "Display"),
                       DisplayEntity(name: "Laptop", deviceType: "VirtualScreen")]
    expect(computeConsoleActive(user: "amir", entities: physical), "user+physical -> active")
    expect(!computeConsoleActive(user: "loginwindow", entities: physical), "loginwindow -> inactive")
    expect(!computeConsoleActive(user: "amir", entities: virtualOnly), "virtual-only -> inactive")
    // displayplacer parsing
    let listing = """
    Persistent screen id: AAA-111
    Type: MacBook built in screen
    Resolution: 3456x2234

    Persistent screen id: BBB-222
    Type: 24 inch external screen

    Execute the command below to restore:
    displayplacer "id:AAA-111 res:1728x1117 origin:(0,0)" "id:BBB-222 res:1470x956 origin:(1728,0)"
    """
    let screens = parsePlacerScreens(listing)
    expect(screens.count == 2 && screens[0].persistentId == "AAA-111", "placer screens parsed")
    expect(parseRestoreCommand(listing)?.hasPrefix("displayplacer \"id:AAA-111") == true, "restore cmd parsed")
    // profile parsing
    let prof = """
    Graphics/Displays:
          Displays:
            Laptop:
              Main Display: Yes
              Mirror: On
            Color LCD:
              Mirror: On
    """
    let snap = parseDisplaysProfile(prof)
    expect(snap.activeNames == ["Laptop", "Color LCD"], "profile names")
    expect(snap.mainName == "Laptop", "profile main")
    expect(snap.mirrorOn["Color LCD"] == true, "profile mirror")
    // config loads and self-identifies
    let cfg = loadConfig()
    expect(cfg.machines.count == 3, "config has 3 machines")
    expect(cfg.canvases["laptop"]?.hidpi == true, "laptop canvas is HiDPI")
    print(failures == 0 ? "MIRA2 selftest: OK" : "MIRA2 selftest: \(failures) FAILURES")
    exit(failures == 0 ? 0 : 1)
}

// MARK: - Main

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "selftest": selftest()
case "--daemon": runDaemon(cfg: loadConfig())
case "status":
    let cfg = loadConfig()
    let me = selfMachine(cfg)
    let mode = computeMode(claim: readClaim(), ttl: cfg.claimTTLSeconds,
                           now: Date().timeIntervalSince1970)
    print("machine: \(me.id)  mode: \(mode)  console: \(computeConsoleActive(user: consoleUser(), entities: bdIdentifiers()))")
case "claim":
    let cfg = loadConfig(); print(claimAllTargets(cfg: cfg, me: selfMachine(cfg)))
case "release":
    let cfg = loadConfig(); releaseAllTargets(cfg: cfg, me: selfMachine(cfg)); print("released")
case "console":
    let cfg = loadConfig(); writeClaimLocal(nil); Reconciler(cfg: cfg).convergeConsole(); print("console mode")
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
