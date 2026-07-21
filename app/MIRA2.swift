// MIRA 2 — one binary: menu-bar app, passenger daemon, CLI. Native display
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
    // Optional (decodeIfPresent via synthesized Codable — older configs stay valid).
    let handbackHoldSeconds: Double?
    let walkupInputEvents: Double?
    let reverseScroll: Bool?
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
let handbackFile = stateDir.appendingPathComponent("handback")
let hygieneFile = stateDir.appendingPathComponent("hygiene.json")
let logFile = repoRoot().appendingPathComponent("logs/mira2.log")

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

// MARK: - Handback (pure, selftested)

// Fresh handback: within the hold window. Used both to force console locally
// and to make a driver skip a walked-up target.
func handbackIsFresh(ts: Double, hold: Double, now: Double = Date().timeIntervalSince1970) -> Bool {
    now - ts < hold
}

// Clamshell convention: true = lid closed. A closed->open transition or a burst
// of real local input, while this machine is a converged passenger, hands back.
func shouldHandback(prevClamshell: Bool, nowClamshell: Bool,
                    inputBurst: Bool, passengerConverged: Bool) -> Bool {
    guard passengerConverged else { return false }
    let lidOpened = prevClamshell && !nowClamshell
    return lidOpened || inputBurst
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
            // setVirtualMode can never match and the passenger reconverges forever.
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

    // Choose a mode on the virtual display: UI size WxH at 2x (hidpi) or 1x.
    func setVirtualMode(canvas: Canvas, hidpi: Bool) -> Bool {
        guard virtualID != 0 else { return false }
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(virtualID, opts) as? [CGDisplayMode] else { return false }
        let uiMatches = modes.filter { $0.width == canvas.width && $0.height == canvas.height }
        let exact = uiMatches.first {
            hidpi ? $0.pixelWidth == canvas.width * 2 : $0.pixelWidth == canvas.width
        }
        guard let mode = exact ?? uiMatches.first else { return false }
        if exact == nil { log("mode fallback: UI \(canvas.width)x\(canvas.height) with backing \(uiMatches.first!.pixelWidth)px") }
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
        guard Int(CGDisplayPixelsWide(virtualID)) == canvas.width else { return false }
        let m = CGDisplayCopyDisplayMode(virtualID)
        if hidpi, let m = m, m.pixelWidth != canvas.width * 2 { return false }
        for p in physicalDisplays() where CGDisplayMirrorsDisplay(p) != virtualID { return false }
        return true
    }
}

// MARK: - Arrangement capture / restore (origins of physical displays)

// mirrorOf: nil = independent display; else the master display it mirrors.
struct SavedDisplay: Codable { let id: UInt32; let x: Int; let y: Int; let main: Bool; let mirrorOf: UInt32? }

func captureArrangement(engine: DisplayEngine) {
    guard !FileManager.default.fileExists(atPath: arrangementFile.path) else { return }
    let saved = engine.physicalDisplays().map { d -> SavedDisplay in
        let b = CGDisplayBounds(d)
        let master = CGDisplayMirrorsDisplay(d)
        return SavedDisplay(id: d, x: Int(b.origin.x), y: Int(b.origin.y),
                            main: CGDisplayIsMain(d) != 0,
                            mirrorOf: master == kCGNullDirectDisplay ? nil : master)
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
    engine.unmirrorAll()
    guard let data = try? Data(contentsOf: arrangementFile),
          let saved = try? JSONDecoder().decode([SavedDisplay].self, from: data) else {
        if let first = engine.physicalDisplays().first { engine.setMain(first) }
        return true   // nothing captured -> nothing to retry
    }
    let online = Set(engine.onlineDisplays())
    var cfg: CGDisplayConfigRef?
    CGBeginDisplayConfiguration(&cfg)
    for s in saved where online.contains(s.id) {
        if let master = s.mirrorOf, online.contains(master) {
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

    init(cfg: Config) { self.cfg = cfg; self.me = selfMachine(cfg) }

    var isLaptop: Bool { me.laptopCanvas != nil }
    var passengerConverged: Bool { if case .passenger = lastMode { return true }; return false }

    // Started by the daemon only (not one-shot CLI ticks).
    func startWatchers() { if isLaptop { walkup.start() } }

    func tick() {
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

        let mode = computeMode(ride: readRide(), ttl: cfg.rideTTLSeconds,
                               now: Date().timeIntervalSince1970)
        switch mode {
        case .passenger(let canvasKey, let hidpi):
            // Two simultaneous drivers is a bug; a machine being driven is never
            // itself a driver — drop the flag if it lingered.
            if FileManager.default.fileExists(atPath: drivingFlag.path) {
                try? FileManager.default.removeItem(at: drivingFlag)
                log("driving flag cleared: now a passenger")
            }
            guard let canvas = cfg.canvases[canvasKey] else { return }
            let wantHi = hidpi && canvas.hidpi
            // A passenger never streams outward — enforce every tick, not just
            // on transition (the viewer can be relaunched under us).
            sh("pkill -x 'Jump Desktop' 2>/dev/null; pkill -f 'MacOS/Jump Desktop$' 2>/dev/null")
            if engine.passengerInvariantHolds(canvas: canvas, hidpi: wantHi),
               lastMode == mode { checkWalkupTriggers(); return }
            log("converge -> passenger(\(canvasKey), hidpi=\(wantHi))")
            captureArrangement(engine: engine)
            applyHygiene()
            holdDisplayAwake()                                 // wake+hold display stack
            sh("pkill -x 'Jump Desktop' 2>/dev/null")          // never stream outward
            guard engine.ensureVirtual(canvas: canvas) else { log("virtual create FAILED"); return }
            engine.unmirrorAll()
            _ = engine.setVirtualMode(canvas: canvas, hidpi: wantHi)
            _ = engine.mirrorPhysicalsOntoVirtual()
            engine.setMain(engine.virtualID)
            routeAudio(passenger: true)
            let ok = engine.passengerInvariantHolds(canvas: canvas, hidpi: wantHi)
            log("passenger converged=\(ok)")
            lastMode = mode
            checkWalkupTriggers()
        case .console:
            convergeConsole()
        }
    }

    func convergeConsole() {
        if lastMode == .console || (lastMode == nil && engine.virtualID == 0
            && !FileManager.default.fileExists(atPath: arrangementFile.path)) {
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
    func checkWalkupTriggers() {
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

// An explicit Drive is a deliberate override: clear the target's own walk-up
// handback so its daemon stops forcing console, and forget any noticed state so
// the driver stops skipping it.
func clearRemoteHandback(on target: Machine) {
    _ = peerRun(target, "rm -f \"$HOME/Library/Application Support/MacRig/handback\"")
    handbackNoticed.remove(target.id)
}

func macPassengers(cfg: Config, me: Machine) -> [Machine] {
    cfg.machines.filter { $0.id != me.id && $0.roles.contains("target") && ($0.type ?? "mac") == "mac" }
}

// Targets whose fresh handback we've already logged this walk-up (log once each).
var handbackNoticed: Set<String> = []

// A target that has walked itself up (fresh handback) is left alone this beat.
func targetWalkedUp(_ t: Machine, cfg: Config) -> Bool {
    let hb = peerRun(t, "cat \"$HOME/Library/Application Support/MacRig/handback\" 2>/dev/null")
        .out.trimmingCharacters(in: .whitespacesAndNewlines)
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
        if targetWalkedUp(t, cfg: cfg) { continue }
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
    rec.startWatchers()
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

// MARK: - Scroll reversal (MenuApp only — it holds Accessibility)

// Negate classic wheel-mouse deltas; leave continuous (trackpad/Magic Mouse)
// gestures untouched. Re-enables the tap if the system disables it.
func scrollTapCallback(proxy: CGEventTapProxy, type: CGEventType,
                       event: CGEvent, userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let userInfo = userInfo,
           let tap = Unmanaged<MenuApp>.fromOpaque(userInfo).takeUnretainedValue().scrollTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passUnretained(event)
    }
    guard type == .scrollWheel,
          event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0 else {
        return Unmanaged.passUnretained(event)
    }
    // Line/point deltas are exact integers.
    for f in [CGEventField.scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2,
              .scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2] {
        event.setIntegerValueField(f, value: -event.getIntegerValueField(f))
    }
    // Fixed-point (Q16.16) deltas carry a fractional part — negate as doubles so
    // sub-integer/accelerated magnitudes survive the reversal.
    for f in [CGEventField.scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2] {
        event.setDoubleValueField(f, value: -event.getDoubleValueField(f))
    }
    return Unmanaged.passUnretained(event)
}

// MARK: - Menu bar

final class MenuApp: NSObject, NSApplicationDelegate {
    var item: NSStatusItem!
    let cfg = loadConfig()
    lazy var me = selfMachine(cfg)
    var scrollTap: CFMachPort?

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        rebuild()
        installScrollTap()
    }

    func installScrollTap() {
        guard cfg.reverseScroll ?? true else { return }
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
        m.addItem(withTitle: driving ? "Driving" : "Parked", action: nil, keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(withTitle: "Drive from here", action: #selector(drive), keyEquivalent: "").target = self
        m.addItem(withTitle: "Stop driving", action: #selector(stop), keyEquivalent: "").target = self
        m.addItem(withTitle: "Run Doctor", action: #selector(runDoc), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "Quit MIRA 2", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = m
    }
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

    @objc func drive() {
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: handbackFile)   // explicit drive overrides walk-up
        FileManager.default.createFile(atPath: drivingFlag.path, contents: nil)
        let engine = DisplayEngine()
        let canvas = driverCanvasKey(cfg: cfg, me: me, engine: engine)
        DispatchQueue.global().async { [self] in
            var opened = 0
            for t in macPassengers(cfg: cfg, me: me) {
                clearRemoteHandback(on: t)   // override any walk-up on the target
                _ = placeRide(on: t, canvas: canvas, hidpi: true, driver: me.id)
                if openJumpSession(t.jumpName) { opened += 1 }
                else if openJumpSession(t.jumpName) { opened += 1 }   // one retry
            }
            DispatchQueue.main.async {
                self.notify("Driving: \(opened)/\(macPassengers(cfg: cfg, me: me).count) sessions open (\(canvas))")
                self.rebuild()
            }
        }
    }
    @objc func stop() {
        try? FileManager.default.removeItem(at: drivingFlag)
        for t in macPassengers(cfg: cfg, me: me) { endRide(on: t) }
        sh("pkill -x 'Jump Desktop' 2>/dev/null")   // close the viewer locally
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
        clearRemoteHandback(on: t)   // explicit drive overrides target walk-up
        let ok = placeRide(on: t, canvas: canvas, hidpi: true, driver: me.id)
        print("\(t.id): \(ok ? "riding (\(canvas))" : "RIDE FAILED")")
    }
case "stop":
    let cfg = loadConfig(); let me = selfMachine(cfg)
    try? FileManager.default.removeItem(at: drivingFlag)
    for t in macPassengers(cfg: cfg, me: me) { endRide(on: t) }
    sh("pkill -x 'Jump Desktop' 2>/dev/null")   // close the viewer locally
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
