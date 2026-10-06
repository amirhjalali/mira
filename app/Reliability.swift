// MIRA session control. Compiled together with MIRA.swift by tests/run.sh.
import AppKit
import Foundation
import Darwin

let miraVersion = "2.2.0"
let miraBuild = "20261006.1"
var daemonOwnsState = false
var singletonFD: Int32 = -1
var snapshotFile: URL { stateDir.appendingPathComponent("runtime.json") }
var fenceFile: URL { stateDir.appendingPathComponent("session-fence.json") }
var localHoldFile: URL { stateDir.appendingPathComponent("local-hold.json") }
var fleetFile: URL { stateDir.appendingPathComponent("fleet.json") }
var sessionOpenFile: URL { stateDir.appendingPathComponent("open-sessions.json") }

func atomicJSON<T: Encodable>(_ value: T, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(value).write(to: url, options: .atomic)
}
func readJSON<T: Decodable>(_ type: T.Type, _ url: URL) -> T? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(type, from: data)
}
func removeState(_ url: URL) { try? FileManager.default.removeItem(at: url) }

struct SessionID: Codable, Equatable, Comparable {
    let driver: String
    let claim: Double
    static func < (l: Self, r: Self) -> Bool {
        l.claim == r.claim ? l.driver < r.driver : l.claim < r.claim
    }
    var valid: Bool { !driver.isEmpty && claim.isFinite && claim > 0 }
}
struct SessionFence: Codable { let session: SessionID; let ended: Bool; var revision: Double = 0 }
extension Ride {
    var session: SessionID { SessionID(driver: driver, claim: claimedAt ?? 0) }
    var geometryKey: String { "\(driver)|\(claimedAt ?? 0)|\(canvas)|\(canvasW ?? 0)x\(canvasH ?? 0)|\(hidpi)" }
}
func currentSession(_ me: Machine) -> SessionID? {
    readDriverClaim().map { SessionID(driver: me.id, claim: $0) }
}
func sessionAccepts(_ incoming: SessionID, fence: SessionFence?) -> Bool {
    guard incoming.valid else { return false }
    guard let f = fence else { return true }
    return incoming > f.session || (incoming == f.session && !f.ended)
}
func ownsRelease(_ wanted: SessionID, current: SessionID?) -> Bool { current == wanted }

struct ControlRequest: Codable {
    var id = UUID().uuidString
    var created = Date().timeIntervalSince1970
    var kind: String
    var session: SessionID? = nil
    var ride: Ride? = nil
    var target: String? = nil
    var include: Bool? = nil
    var explicit: Bool = false
    var revision: Double? = nil
}
struct ControlReply: Codable {
    let ok: Bool
    let message: String
    var winner: SessionID? = nil
    var runtime: RuntimeSnapshot? = nil
}
struct RuntimeSnapshot: Codable {
    let machine: String
    let build: String
    let pid: Int32
    let ts: Double
    let role: String
    let session: SessionID?
    let state: String
    let detail: String
    let width: Int?
    let height: Int?
    let pixelWidth: Int?
    let pixelHeight: Int?
    let fdCount: Int
}
struct PeerSnapshot: Codable {
    let session: SessionID
    let ts: Double
    let state: String
    let detail: String
    let runtime: RuntimeSnapshot?
}
struct FleetSnapshot: Codable { var peers: [String: PeerSnapshot] = [:] }

func singleton(_ name: String) -> Bool {
    try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    let fd = Darwin.open(stateDir.appendingPathComponent("\(name).lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
    guard fd >= 0 else { return false }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return false }
    singletonFD = fd
    return true
}

// File IPC transports requests; only the daemon commits session/display state.
// UUID filenames avoid shared .tmp races. Expired work is rejected, not replayed.
func requestDaemon(_ request: ControlRequest, timeout: Double = 12) -> ControlReply {
    let requestURL = stateDir.appendingPathComponent("request-\(request.id).json")
    let responseURL = stateDir.appendingPathComponent("reply-\(request.id).json")
    do { try atomicJSON(request, to: requestURL) }
    catch { return ControlReply(ok: false, message: "Cannot contact Mira: \(error.localizedDescription)") }
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    defer { removeState(requestURL); removeState(responseURL) }
    while ProcessInfo.processInfo.systemUptime < deadline {
        if let answer = readJSON(ControlReply.self, responseURL) { return answer }
        usleep(50_000)
    }
    return ControlReply(ok: false, message: "Mira did not acknowledge the request; check status before retrying.")
}

func remoteControl(_ machine: Machine, _ request: ControlRequest) -> ControlReply {
    guard let data = try? JSONEncoder().encode(request) else { return ControlReply(ok: false, message: "Invalid request") }
    // Fixed paths, no GUI scripting. Each installed CLI sends to its GUI daemon.
    let payload = data.base64EncodedString()
    let command = miraExec("control \(payload)")
    let r = peerRun(machine, command, timeout: 16, force: true)
    if let answer = try? JSONDecoder().decode(ControlReply.self, from: Data(r.out.utf8)) { return answer }
    return ControlReply(ok: false, message: r.code == 124 || r.code == 255 ? "Reconnecting" : "No compatible acknowledgement (\(r.code))")
}

// No network operation executes on the display/control loop. One in-flight
// operation per peer, with bounded process lifetime and receiver-side fencing.
final class SessionTransport {
    let lock = NSLock()
    var busy = Set<String>()
    var results = FleetSnapshot()
    @discardableResult
    func send(_ machine: Machine, request: ControlRequest, session: SessionID) -> Bool {
        lock.lock()
        guard !busy.contains(machine.id) else { lock.unlock(); return false }
        busy.insert(machine.id); lock.unlock()
        DispatchQueue.global(qos: .utility).async { [self] in
            let answer = remoteControl(machine, request)
            if let winner = answer.winner, winner > session {
                var update = ControlRequest(kind: "beacon"); update.session = winner
                _ = requestDaemon(update)
            }
            if request.kind == "release", answer.ok {
                var ack = ControlRequest(kind: "release-ack"); ack.target = machine.id; ack.session = session; ack.revision = request.revision
                _ = requestDaemon(ack)
            }
            let reported = answer.runtime
            let ready = answer.ok && reported?.session == session && reported?.state == "ready"
                && Date().timeIntervalSince1970 - (reported?.ts ?? 0) < 15
            let state = ready ? "Ready" : (answer.ok ? (reported?.state == "local" ? "Local use" : "Connecting…") : answer.message)
            lock.lock()
            // A late reply cannot overwrite feedback for a newer session.
            if results.peers[machine.id].map({ $0.session <= session }) ?? true {
                results.peers[machine.id] = PeerSnapshot(session: session, ts: Date().timeIntervalSince1970,
                    state: state, detail: answer.message, runtime: reported)
                try? atomicJSON(results, to: fleetFile)
            }
            busy.remove(machine.id); lock.unlock()
        }
        return true
    }
}
let sessionTransport = SessionTransport()

struct PendingRelease: Codable { let machine: String; let session: SessionID; let revision: Double }
var pendingReleaseFile: URL { stateDir.appendingPathComponent("pending-releases.json") }
var nextReleaseAttempt = 0.0
func queueReleases(_ session: SessionID, cfg: Config, me: Machine, target: String? = nil) {
    var pending = readJSON([PendingRelease].self, pendingReleaseFile) ?? []
    for m in cfg.machines where m.id != me.id && (target == nil || m.id == target) {
        if !pending.contains(where: { $0.machine == m.id && $0.session == session }) {
            pending.append(PendingRelease(machine: m.id, session: session, revision: Date().timeIntervalSince1970))
        }
    }
    try? atomicJSON(pending, to: pendingReleaseFile)
    nextReleaseAttempt = 0
}
func serviceReleases(cfg: Config) {
    let now = ProcessInfo.processInfo.systemUptime
    guard now >= nextReleaseAttempt else { return }
    nextReleaseAttempt = now + 15
    let pending = readJSON([PendingRelease].self, pendingReleaseFile) ?? []
    // Retain tombstones across restarts. Replays are harmless and owner-scoped.
    for p in pending.suffix(16) {
        guard let m = cfg.machines.first(where: { $0.id == p.machine }) else { continue }
        var r = ControlRequest(kind: "release"); r.session = p.session; r.revision = p.revision
        sessionTransport.send(m, request: r, session: p.session)
    }
}

func handleControl(_ r: ControlRequest, rec: Reconciler) -> ControlReply {
    let now = Date().timeIntervalSince1970
    guard now - r.created < 30, r.created - now < 60 else {
        return ControlReply(ok: false, message: "Expired request — no change made")
    }
    let cfg = rec.cfg, me = rec.me
    var fence = readJSON(SessionFence.self, fenceFile)
    let own = currentSession(me)
    // Rolling upgrades inherit rides written by v2.1. Seed the fence from
    // that live owner before accepting ANY request, including a stale release.
    if let existing = readRide(), existing.session.valid,
       fence == nil || existing.session > fence!.session {
        fence = SessionFence(session: existing.session, ended: false, revision: existing.ts)
    }
    if let own = own, fence == nil || own > fence!.session {
        fence = SessionFence(session: own, ended: false, revision: own.claim)
    }
    let winner = [fence?.session, own, readRide()?.session].compactMap { $0 }.max()
    func answer(_ ok: Bool, _ message: String) -> ControlReply {
        ControlReply(ok: ok, message: message, winner: winner, runtime: readJSON(RuntimeSnapshot.self, snapshotFile))
    }
    do {
        switch r.kind {
        case "release-ack":
            let pending = (readJSON([PendingRelease].self, pendingReleaseFile) ?? []).filter {
                !($0.machine == r.target && $0.session == r.session && $0.revision == r.revision)
            }
            try atomicJSON(pending, to: pendingReleaseFile)
            return answer(true, "Release acknowledged")
        case "drive":
            guard mayDrive(roles: me.roles) else { return answer(false, "This Mac is passenger-only") }
            let claim = max(now, (winner?.claim ?? 0) + 0.001)
            let session = SessionID(driver: me.id, claim: claim)
            try String(claim).write(to: drivingFlag, atomically: true, encoding: .utf8)
            try atomicJSON(SessionFence(session: session, ended: false, revision: now), to: fenceFile)
            removeState(rideFile); removeState(wheelFile); removeState(localHoldFile); removeState(handbackFile)
            rec.breaker.reset(); lastMeasuredContent = nil
            try atomicJSON(session, to: sessionOpenFile)
            emit("claim", [("at", .n(claim))])
            // Isolated test state must never re-route the real Mac's audio.
            if ProcessInfo.processInfo.environment["MIRA_STATE_DIR"] == nil { preferHeadphonesForDriver() }
            return ControlReply(ok: true, message: "Connecting from \(me.id)", winner: session)
        case "stop":
            guard let expected = r.session, ownsRelease(expected, current: own) else {
                return answer(true, "Already stopped here — other sessions left alone")
            }
            try atomicJSON(SessionFence(session: expected, ended: true, revision: now), to: fenceFile)
            removeState(drivingFlag); removeState(sessionOpenFile)
            if readWheel()?.driver == me.id { removeState(wheelFile) }
            queueReleases(expected, cfg: cfg, me: me)
            return answer(true, "Stopped here; returning this session's passengers to local use")
        case "local":
            guard own == nil else { return answer(false, "Use Stop Driving to end this Mac's driving session") }
            let held = readRide()?.session ?? winner
            if let held = held { try atomicJSON(held, to: localHoldFile) }
            removeState(rideFile); writeHandback(); rec.breaker.reset(); rec.consoleRestoreAttempts = 0
            return answer(true, "Returning this Mac to local use")
        case "include":
            guard let id = r.target, cfg.machines.contains(where: { $0.id == id && $0.roles.contains("target") }) else {
                return answer(false, "Unknown passenger")
            }
            var excluded = loadExcluded()
            if r.include == true { excluded.remove(id) } else { excluded.insert(id) }
            saveExcluded(excluded)
            if let own = own {
                if r.include != true { queueReleases(own, cfg: cfg, me: me, target: id) }
                else {
                    let pending = (readJSON([PendingRelease].self, pendingReleaseFile) ?? []).filter { !($0.machine == id && $0.session == own) }
                    try atomicJSON(pending, to: pendingReleaseFile)
                    rec.explicitTargets.insert(id)
                }
            }
            return answer(true, r.include == true ? "Passenger included" : "Passenger removed")
        case "ride", "beacon":
            guard let s = r.session, s.valid,
                  let driver = cfg.machines.first(where: { $0.id == s.driver }), mayDrive(roles: driver.roles) else {
                return answer(false, "Invalid driver")
            }
            if let own = own, own > s { return answer(false, "Newer driver owns this Mac") }
            if r.explicit, fence?.session == s, r.created > (fence?.revision ?? 0) { fence = SessionFence(session: s, ended: false, revision: r.created) }
            guard sessionAccepts(s, fence: fence) else { return answer(false, "Stale session ignored") }
            if r.kind == "ride" {
                guard me.roles.contains("target"), let ride = r.ride, ride.session == s,
                      let seed = cfg.canvases[ride.canvas] else { return answer(false, "Invalid passenger request") }
                let c = rideCanvas(base: seed, ride: ride)
                guard c.width >= 640, c.height >= 400, c.width <= 6880, c.height <= 3824 else {
                    return answer(false, "Unsupported display size")
                }
                if let old = readRide(), old.session == s, old.ts > ride.ts { return answer(false, "Outdated lease ignored") }
                if let held = readJSON(SessionID.self, localHoldFile), held >= s, !r.explicit {
                    return answer(false, "Local use")
                }
                if r.explicit || readJSON(SessionID.self, localHoldFile).map({ s > $0 }) == true {
                    removeState(localHoldFile); removeState(handbackFile)
                }
                try atomicJSON(ride, to: rideFile)
            }
            try atomicJSON(SessionFence(session: s, ended: false, revision: max(fence?.revision ?? 0, r.ride?.ts ?? 0)), to: fenceFile)
            try atomicJSON(Wheel(driver: s.driver, claimedAt: s.claim, ts: now), to: wheelFile)
            if let own = own, s > own { relinquishWheel(to: s.driver) }
            return answer(true, "Accepted; verifying display")
        case "close-viewer":
            // A stale session is closed where its viewer lives (host-side kills reconnect).
            // Re-checked here: the window's verdict can be seconds old.
            guard own == nil else { return answer(false, "This Mac is driving — its sessions are not stale") }
            viewerCloseRequests += 1
            log("asked to close this Mac's viewer")
            if ProcessInfo.processInfo.environment["MIRA_STATE_DIR"] == nil {
                DispatchQueue.global(qos: .utility).async { killJumpViewer() }
            }
            return answer(true, "Closing this Mac's Jump sessions")
        case "fix-audio":
            fixRequests.append("audio")
            let passenger = readRide() != nil
            if ProcessInfo.processInfo.environment["MIRA_STATE_DIR"] == nil {
                repairAudio(passenger: passenger)
                guardJumpCapture(force: true)
            }
            return answer(true, passenger ? "Sound routed through Jump" : "Jump devices returned to this Mac's own")
        case "fix-display":
            // Never on the driver: a console restore unmirrors, re-routes audio and
            // resizes the viewer windows every passenger is measured from.
            guard own == nil else { return answer(false, "This Mac is driving — change its screens in System Settings") }
            fixRequests.append("display")
            // A pending snapshot is newer than any verified one: retry it, never replace it.
            if readRide() == nil, !FileManager.default.fileExists(atPath: arrangementFile.path) {
                // Re-arm the last layout MIRA itself verified; the next tick restores and re-verifies it.
                let good = stateDir.appendingPathComponent("last-console-arrangement.json")
                guard let data = try? Data(contentsOf: good) else { return answer(false, "No verified layout to restore") }
                try data.write(to: arrangementFile, options: .atomic)
            }
            rec.breaker.reset(); rec.consoleRestoreAttempts = 0; rec.lastMode = nil
            return answer(true, "Display will be re-applied on the next beat")
        case "release":
            guard let s = r.session else { return answer(false, "Missing session") }
            // A tombstone also blocks a delayed ride arriving AFTER its release.
            let revision = r.revision ?? r.created
            if let f = fence, f.session > s || (f.session == s && f.revision > revision) {
                return answer(true, "Older release ignored")
            }
            if fence == nil || s >= fence!.session {
                try atomicJSON(SessionFence(session: s, ended: true, revision: revision), to: fenceFile)
            }
            if readRide()?.session == s { removeState(rideFile) }
            if let w = readWheel(), SessionID(driver: w.driver, claim: w.claimedAt) == s { removeState(wheelFile) }
            return answer(true, "Released only the matching session")
        default: return answer(false, "Unknown control request")
        }
    } catch { return answer(false, "State write failed: \(error.localizedDescription)") }
}

func serviceCommands(_ rec: Reconciler) -> Bool {
    let files = (try? FileManager.default.contentsOfDirectory(at: stateDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    var changed = false
    for file in files where file.lastPathComponent.hasPrefix("request-") && file.pathExtension == "json" {
        guard let request = readJSON(ControlRequest.self, file), UUID(uuidString: request.id) != nil,
              file.lastPathComponent == "request-\(request.id).json" else { removeState(file); continue }
        let reply = handleControl(request, rec: rec)
        try? atomicJSON(reply, to: stateDir.appendingPathComponent("reply-\(request.id).json"))
        removeState(file); changed = true
    }
    // Clean abandoned IPC responses; never accumulate one per heartbeat forever.
    for file in files where file.lastPathComponent.hasPrefix("reply-") {
        if let d = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           Date().timeIntervalSince(d) > 60 { removeState(file) }
    }
    return changed
}

func publishRuntime(_ rec: Reconciler) {
    let me = rec.me, own = currentSession(me), ride = readRide()
    var role = own != nil ? "driver" : "local"
    var state = "local", detail = "Using this Mac locally"
    var width: Int?, height: Int?, px: Int?, py: Int?
    if let r = ride {
        role = "passenger"
        if let c = rec.cfg.canvases[r.canvas] {
            let canvas = rideCanvas(base: c, ride: r)
            let observed = inspectDisplay(rec.engine.virtualID)
            width = observed?.w; height = observed?.h; px = observed?.px; py = observed?.py
            let why = displayFailure(observed, canvas: canvas, hidpi: r.hidpi && canvas.hidpi)
            state = why == nil ? "ready" : (observed == nil ? "unknown" : "needs-attention")
            detail = why ?? "Display matches the driver"
            if !r.isLive(ttl: rec.cfg.rideTTLSeconds) {
                state = "reconnecting"; detail = "Connection uncertain; preserving the display"
            }
        }
    } else if own != nil { state = "driving"; detail = "Driving from \(me.id)" }
    else if FileManager.default.fileExists(atPath: arrangementFile.path) {
        state = "needs-attention"; detail = "Restoring the local display arrangement"
    }
    let s = RuntimeSnapshot(machine: me.id, build: miraBuild, pid: getpid(), ts: Date().timeIntervalSince1970,
        role: role, session: own ?? ride?.session, state: state, detail: detail,
        width: width, height: height, pixelWidth: px, pixelHeight: py, fdCount: openFileDescriptorCount())
    try? atomicJSON(s, to: snapshotFile)
}

struct DisplayObservation: Codable, Equatable {
    let w: Int; let h: Int; let px: Int; let py: Int
    var isMain = true
    var mirrorsMatch = true
}
func displayFailure(_ observed: DisplayObservation?, canvas: Canvas, hidpi: Bool) -> String? {
    if let why = geometryFailure(observed, canvas: canvas, hidpi: hidpi) { return why }
    guard let observed = observed else { return "Display state unavailable" }
    if !observed.isMain { return "Virtual display is not main" }
    if !observed.mirrorsMatch { return "Physical displays are not mirroring the canvas" }
    return nil
}
func geometryFailure(_ observed: DisplayObservation?, canvas: Canvas, hidpi: Bool) -> String? {
    guard let m = observed else { return "Display state unavailable" }
    let factor = hidpi ? 2 : 1
    if m.w != canvas.width || m.h != canvas.height { return "Display size \(m.w)×\(m.h); expected \(canvas.width)×\(canvas.height)" }
    if m.px != canvas.width * factor || m.py != canvas.height * factor { return "Display pixel density does not match" }
    return nil
}
func inspectDisplay(_ id: CGDirectDisplayID) -> DisplayObservation? {
    guard id != 0 else { return nil }
    let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
    let r = sh("\(shellQuote(exe)) inspect-display \(id)", timeout: 3)
    return try? JSONDecoder().decode(DisplayObservation.self, from: Data(r.out.utf8))
}
func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

// Stable geometry: measure in the GUI viewer, bind it to this driving session,
// retain through Spaces/reconnects, and require two matching observations.
struct ViewerMeasurement: Codable { let session: SessionID; let content: ContentArea; let ts: Double; let screen: ContentArea }
var measurementFile: URL { stateDir.appendingPathComponent("viewer-measurement.json") }
var measurementCandidate: ContentArea?
var measurementCount = 0
func updateViewerMeasurement(_ me: Machine) {
    guard let session = currentSession(me), let area = observedViewerContent() else { return }
    if measurementCandidate == area { measurementCount += 1 }
    else { measurementCandidate = area; measurementCount = 1 }
    guard measurementCount >= 2 else { return }
    let m = ViewerMeasurement(session: session, content: area, ts: Date().timeIntervalSince1970, screen: mainScreenPoints())
    try? atomicJSON(m, to: measurementFile)
}
func fleetRow(_ machine: Machine, session: SessionID?) -> String {
    guard let session = session else { return machine.jumpName }
    guard let p = readJSON(FleetSnapshot.self, fleetFile)?.peers[machine.id], p.session == session else {
        return "\(machine.jumpName) — Connecting…"
    }
    let text = Date().timeIntervalSince1970 - p.ts < 30 ? p.state : "Reconnecting…"
    return "\(machine.jumpName) — \(text)"
}

// No filesystem/SSH work on the event callback. Menu timer caches this role.
var localScrollOwner = true
func shouldNormalizeScroll(enabled: Bool, passenger: Bool, phase: Int64, momentum: Int64) -> Bool {
    enabled && !passenger && shouldReverseScroll(phase: phase, momentum: momentum)
}

func reliabilityTests(_ expect: (Bool, String) -> Void) {
    let firstSerial = nextVirtualSerial(), secondSerial = nextVirtualSerial()
    expect(firstSerial != secondSerial && firstSerial != 1, "candidate display identity differs from retained rollback display")
    // Sizes measured as TVs on 26.6.2: 1920x1200 at 800mm, 2048x1280 at 800mm,
    // 3840x2160 at 886mm and at 800mm. Sizes measured as monitors: 1920x1200 at
    // 443mm, 3840x2160 at 708mm, 3440x1440 at 794mm.
    for (w, h) in [(1920, 1200), (1920, 1080), (2048, 1280), (3840, 2160), (3440, 1440), (1280, 800)] {
        let s = virtualPhysicalSize(width: w, height: h)
        let inches = (s.width * s.width + s.height * s.height).squareRoot() / 25.4
        expect(inches <= 30.01 && abs(s.width / s.height - Double(w) / Double(h)) < 0.01,
               "virtual \(w)x\(h) claims a monitor (\(Int(s.width))x\(Int(s.height))mm), not a TV")
    }
    expect(virtualPhysicalSize(width: 1920, height: 1200).width < 500,
           "1920x1200 is no longer a 38-inch panel")
    let old = SessionID(driver: "pro", claim: 100)
    let new = SessionID(driver: "air13", claim: 101)
    expect(!sessionAccepts(old, fence: SessionFence(session: new, ended: false)), "late old driver cannot overwrite new owner")
    expect(!sessionAccepts(new, fence: SessionFence(session: new, ended: true)), "late heartbeat cannot resurrect stopped session")
    expect(sessionAccepts(new, fence: SessionFence(session: old, ended: true)), "new explicit session supersedes stopped owner")
    expect(!ownsRelease(old, current: new), "stale stop cannot release newer session")
    expect(ownsRelease(new, current: new), "matching stop can release its own session")
    expect(SessionID(driver: "air13", claim: 100) < old, "equal claims have deterministic ordering")
    var lease = Ride(driver: "pro", canvas: "laptop-air13", hidpi: true, ts: 20, claimedAt: 100)
    let geometry = lease.geometryKey
    lease = Ride(driver: "pro", canvas: "laptop-air13", hidpi: true, ts: 30, claimedAt: 100)
    expect(lease.geometryKey == geometry, "heartbeat alone does not reset repair breaker")
    let canvas = Canvas(width: 1280, height: 800, hidpi: true)
    expect(geometryFailure(DisplayObservation(w: 1280, h: 800, px: 2560, py: 1600), canvas: canvas, hidpi: true) == nil, "correct logical size and Retina pixels verified")
    expect(geometryFailure(DisplayObservation(w: 2560, h: 1600, px: 2560, py: 1600), canvas: canvas, hidpi: true) != nil, "double-sized desktop is not ready")
    expect(geometryFailure(DisplayObservation(w: 1280, h: 768, px: 2560, py: 1536), canvas: canvas, hidpi: true) != nil, "wrong height cannot pass display verification")
    expect(displayFailure(DisplayObservation(w: 1280, h: 800, px: 2560, py: 1600, isMain: false), canvas: canvas, hidpi: true) != nil, "correct size on a non-main canvas is not ready")
    expect(displayFailure(DisplayObservation(w: 1280, h: 800, px: 2560, py: 1600, mirrorsMatch: false), canvas: canvas, hidpi: true) != nil, "correct size without physical mirroring is not ready")
    expect(geometryFailure(nil, canvas: canvas, hidpi: true) != nil, "unreadable display is not reported ready")
    expect(!shouldNormalizeScroll(enabled: true, passenger: true, phase: 0, momentum: 0), "passenger never reverses remote wheel a second time")
    expect(shouldNormalizeScroll(enabled: true, passenger: false, phase: 0, momentum: 0), "local wheel has one owner")
    expect(!shouldNormalizeScroll(enabled: true, passenger: false, phase: 2, momentum: 0), "trackpad gesture unaffected")
    // Real process tests: exceed pipe capacity, timeout whole descendant group,
    // then repeat enough failures to expose descriptor leakage.
    let volume = sh("head -c 200000 /dev/zero", timeout: 3)
    expect(volume.code == 0 && volume.out.utf8.count == 200000, "runner drains output larger than pipe buffer")
    let t = ProcessInfo.processInfo.systemUptime
    let timed = sh("sleep 5 & wait", timeout: 0.1)
    expect(timed.code == 124 && ProcessInfo.processInfo.systemUptime - t < 2, "timeout bounds child process group")
    let count = openFileDescriptorCount()
    for _ in 0..<25 { _ = sh("sleep 2", timeout: 0.02) }
    expect(openFileDescriptorCount() <= count + 2, "repeated timeouts do not leak descriptors")
    // Exercise the actual callback against a synthetic, unposted event.
    let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: 4, wheel2: -2, wheel3: 0)!
    let fields: [CGEventField] = [.scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2,
        .scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2]
    let before = fields.map { event.getIntegerValueField($0) }
    let enabled = scrollReversalEnabled, owner = localScrollOwner
    scrollReversalEnabled = true; localScrollOwner = true
    _ = scrollTapCallback(proxy: OpaquePointer(bitPattern: 1)!, type: .scrollWheel, event: event, userInfo: nil)
    let once = fields.map { event.getIntegerValueField($0) }
    expect(zip(before, once).allSatisfy { $1 == -$0 }, "actual event callback negates line and point deltas")
    localScrollOwner = false
    _ = scrollTapCallback(proxy: OpaquePointer(bitPattern: 1)!, type: .scrollWheel, event: event, userInfo: nil)
    expect(fields.map { event.getIntegerValueField($0) } == once, "same event is unchanged on passenger")
    scrollReversalEnabled = enabled; localScrollOwner = owner
}

func controlIntegrationTests() -> Never {
    guard ProcessInfo.processInfo.environment["MIRA_STATE_DIR"] != nil,
          stateDir.path.hasPrefix("/tmp/") || stateDir.path.hasPrefix("/private/tmp/") else {
        fputs("IPC tests require an isolated /tmp MIRA_STATE_DIR\n", stderr); exit(2)
    }
    let cfg = loadConfig(), rec = Reconciler(cfg: loadConfig())
    var failures = 0
    func check(_ ok: Bool, _ title: String) { print("\(ok ? "ok" : "FAIL") - \(title)"); if !ok { failures += 1 } }
    try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    let driver = cfg.machines.first { $0.id != rec.me.id && $0.roles.contains("viewer") }!.id
    let first = SessionID(driver: driver, claim: Date().timeIntervalSince1970 - 100)
    let second = SessionID(driver: driver, claim: first.claim + 1)
    func ride(_ session: SessionID, explicit: Bool = false) -> ControlRequest {
        var r = ControlRequest(kind: "ride"); r.session = session; r.explicit = explicit
        r.ride = Ride(driver: session.driver, canvas: "laptop-air13", hidpi: true, ts: r.created, claimedAt: session.claim)
        return r
    }
    try? atomicJSON(ride(second).ride!, to: rideFile)
    check(!handleControl(ride(first), rec: rec).ok && readRide()?.session == second,
          "rolling upgrade preserves unfenced legacy ride against stale driver")
    var migrationRelease = ControlRequest(kind: "release"); migrationRelease.session = first
    check(handleControl(migrationRelease, rec: rec).ok && readRide()?.session == second,
          "rolling upgrade preserves legacy ride against stale release")
    removeState(rideFile); removeState(fenceFile)
    check(handleControl(ride(first), rec: rec).ok, "receiver accepts first driver")
    check(handleControl(ride(second), rec: rec).ok, "receiver accepts newer handoff")
    check(!handleControl(ride(first), rec: rec).ok && readRide()?.session == second, "receiver rejects delayed first driver")
    var release = ControlRequest(kind: "release"); release.session = first
    check(handleControl(release, rec: rec).ok && readRide()?.session == second, "delayed stop preserves newer ride")
    release.session = second
    check(handleControl(release, rec: rec).ok && readRide() == nil, "owner stop releases its ride")
    check(!handleControl(ride(second), rec: rec).ok && readRide() == nil, "late heartbeat cannot revive released ride")
    let inclusion = ride(second, explicit: true)
    check(handleControl(inclusion, rec: rec).ok, "explicit include revives the same driver's removed passenger")
    check(handleControl(release, rec: rec).ok && readRide()?.session == second, "older release cannot undo explicit inclusion")
    check(handleControl(ControlRequest(kind: "local"), rec: rec).ok && readRide() == nil && readDriverClaim() == nil, "local use releases one Mac without claiming fleet")
    check(!handleControl(ride(second), rec: rec).ok && readRide() == nil, "local use survives ordinary heartbeat")
    check(handleControl(ride(second, explicit: true), rec: rec).ok, "explicit include clears local hold")
    let own = handleControl(ControlRequest(kind: "drive"), rec: rec)
    check(own.ok && readRide() == nil && currentSession(rec.me) != nil, "local Drive requests one daemon-owned takeover")
    var staleStop = ControlRequest(kind: "stop"); staleStop.session = first
    let active = currentSession(rec.me)
    check(handleControl(staleStop, rec: rec).ok && currentSession(rec.me) == active, "stale menu Stop leaves current claim untouched")
    // 2026-10-01: air13 lost the wheel to the Pro by beacon, dropped its claim,
    // and kept its Jump session INTO the Pro for 13 hours — feeding the Pro's
    // meeting audio to its speakers and its mic back into the meeting.
    var olderBeacon = ControlRequest(kind: "beacon"); olderBeacon.session = first
    let closesBefore = viewerCloseRequests
    _ = handleControl(olderBeacon, rec: rec)
    check(currentSession(rec.me) == active && viewerCloseRequests == closesBefore,
          "an older driver's beacon neither unseats this Mac nor closes its viewer")
    var newerBeacon = ControlRequest(kind: "beacon")
    newerBeacon.session = SessionID(driver: driver, claim: active!.claim + 1)
    check(handleControl(newerBeacon, rec: rec).ok && currentSession(rec.me) == nil
          && viewerCloseRequests == closesBefore + 1,
          "a newer driver's beacon unseats this Mac AND closes its viewer")
    var expired = ControlRequest(kind: "local"); expired.created -= 120
    check(!handleControl(expired, rec: rec).ok, "expired queued commands are not replayed")
    // The MIRA window's repair verbs: accepted, and inert under MIRA_STATE_DIR.
    let closes = viewerCloseRequests
    check(handleControl(ControlRequest(kind: "close-viewer"), rec: rec).ok && viewerCloseRequests == closes + 1,
          "close-viewer is accepted and counted")
    check(handleControl(ControlRequest(kind: "fix-audio"), rec: rec).ok && fixRequests.last == "audio",
          "fix-audio is accepted")
    try? atomicJSON([SavedDisplay](), to: stateDir.appendingPathComponent("last-console-arrangement.json"))
    removeState(rideFile)
    check(handleControl(ControlRequest(kind: "fix-display"), rec: rec).ok
          && FileManager.default.fileExists(atPath: arrangementFile.path) && rec.lastMode == nil,
          "fix-display at console re-arms the last verified layout")
    removeState(arrangementFile)
    removeState(stateDir.appendingPathComponent("last-console-arrangement.json"))
    check(!handleControl(ControlRequest(kind: "fix-display"), rec: rec).ok,
          "fix-display with no verified layout refuses rather than guessing")
    // Final review: a Mac that is driving must refuse Kill and Fix display.
    _ = handleControl(ControlRequest(kind: "drive"), rec: rec)
    let closesWhileDriving = viewerCloseRequests
    check(!handleControl(ControlRequest(kind: "close-viewer"), rec: rec).ok && viewerCloseRequests == closesWhileDriving,
          "close-viewer refuses on the Mac that is driving")
    try? atomicJSON([SavedDisplay](), to: stateDir.appendingPathComponent("last-console-arrangement.json"))
    check(!handleControl(ControlRequest(kind: "fix-display"), rec: rec).ok && !FileManager.default.fileExists(atPath: arrangementFile.path),
          "fix-display refuses on the Mac that is driving")
    var stopNow = ControlRequest(kind: "stop"); stopNow.session = currentSession(rec.me); _ = handleControl(stopNow, rec: rec)
    try? atomicJSON([SavedDisplay(id: 9, x: 0, y: 0, main: true, mirrorOf: nil, w: 1, h: 1, hz: nil, px: nil, stableID: "pending")], to: arrangementFile)
    check(handleControl(ControlRequest(kind: "fix-display"), rec: rec).ok
          && readJSON([SavedDisplay].self, arrangementFile)?.first?.stableID == "pending",
          "fix-display never overwrites a pending restore snapshot")
    removeState(arrangementFile); removeState(stateDir.appendingPathComponent("last-console-arrangement.json"))
    // Leftovers: the passenger anti-stream guard runs on its 15 s cadence (lost in 553bdb6).
    let guardRuns = streamGuardRuns
    rec.nextStreamGuard = .distantPast
    rec.guardStream(now: Date())
    rec.guardStream(now: Date())
    check(streamGuardRuns == guardRuns + 1, "stream guard fires once, then waits")
    rec.guardStream(now: Date().addingTimeInterval(16))
    check(streamGuardRuns == guardRuns + 2, "stream guard fires again after 15 s")
    print("Control integration: \(failures == 0 ? "OK" : "FAILED")")
    exit(failures == 0 ? 0 : 1)
}

func physicalDisplayKey(_ id: CGDirectDisplayID) -> String {
    "\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(CGDisplaySerialNumber(id))"
}

// A candidate and the rollback display coexist. Reusing the vendor/product/
// serial triple makes CGVirtualDisplay initialization fail while the old one
// is still alive. The daemon is the sole caller; consecutive candidates differ.
// The physical size a virtual display claims decides whether macOS 26 treats
// it as a TV. A "TV" is held OFFLINE behind Control Center's mirror/extend
// picker until someone clicks it, so the topology transaction finds no display
// and the passenger falls back to its console screen. The old hardcoded 800x335
// mm (a 38" ultrawide) was fine for 3440x1440 but turned 1920x1200, 1920x1080
// and 2048x1280 into TVs -- the 2026-10-05 failure on the pro and the mini when
// air13 drove from a 1920x1200 desk monitor. Measured on 26.6.2: claim a desktop
// monitor's density (110 ppi) and cap the diagonal at 30"; every canvas from
// 1024x768 to 5120x2880 then comes online with no picker.
func virtualPhysicalSize(width: Int, height: Int) -> CGSize {
    let mm = { (px: Int) in Double(px) * 25.4 / 110 }
    var w = mm(width), h = mm(height)
    let diagonal = (w * w + h * h).squareRoot(), cap = 30 * 25.4
    if diagonal > cap { w *= cap / diagonal; h *= cap / diagonal }
    return CGSize(width: w.rounded(), height: h.rounded())
}

var virtualSerial: UInt32 = UInt32.random(in: 2...UInt32.max - 1)
func nextVirtualSerial() -> UInt32 {
    virtualSerial = virtualSerial == UInt32.max ? 2 : virtualSerial + 1
    return virtualSerial
}
