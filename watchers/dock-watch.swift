// dock-watch.swift — fires the instant a display is connected/disconnected and
// runs dock-apply.sh, which (1) matches both remote Macs to this MacBook's screen
// shape and (2) toggles this MacBook's WiFi (off when docked, on when undocked).
//
//   external display present (docked to the BenQ ultrawide) -> "ultrawide"
//   built-in only (undocked, laptop screen)                 -> "laptop"
//
// Event-driven via CoreGraphics' display-reconfiguration callback — no polling,
// so the switch starts the moment you plug/unplug. Runs as a LaunchAgent.
//
// Build:  swiftc -O watchers/dock-watch.swift -o build/dock-watch

import CoreGraphics
import AppKit
import Foundation

let root = ProcessInfo.processInfo.environment["MACRIG_DIR"] ?? "\(NSHomeDirectory())/macrig"
let toggleScript = "\(root)/bin/dock-apply.sh"
let healthScript = "\(root)/bin/sync-display-now.sh"
let logPath = "\(root)/logs/dock-watch.log"
var lastMode = ""
var pending: DispatchWorkItem?
var isApplying = false
var isChecking = false
var retryCount = 0

func log(_ message: String) {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let line = "\(formatter.string(from: Date())) \(message)\n"
    let url = URL(fileURLWithPath: logPath)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let handle = FileHandle(forWritingAtPath: logPath) {
        handle.seekToEndOfFile()
        if let data = line.data(using: .utf8) { handle.write(data) }
        handle.closeFile()
    } else {
        try? line.write(toFile: logPath, atomically: true, encoding: .utf8)
    }
}

// "ultrawide" if any ACTIVE display is external; otherwise "laptop".
func currentMode() -> String {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return lastMode }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return lastMode }
    for id in ids where CGDisplayIsBuiltin(id) == 0 {
        return "ultrawide"
    }
    return "laptop"
}

func apply() {
    let mode = currentMode()
    if mode.isEmpty || mode == lastMode || isApplying { return }
    isApplying = true
    log("display mode requested -> \(mode)")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = [toggleScript, mode]
    p.terminationHandler = { process in
        DispatchQueue.main.async {
            isApplying = false
            if process.terminationStatus == 0 {
                lastMode = mode
                retryCount = 0
                log("display mode applied -> \(mode)")
            } else {
                retryCount += 1
                log("dock-apply failed for \(mode): exit \(process.terminationStatus), retry \(retryCount)/3")
                if retryCount <= 3 && currentMode() == mode {
                    schedule(after: [5.0, 15.0, 30.0][retryCount - 1], resetRetries: false)
                }
                return
            }

            // A second display event may have arrived while the script ran.
            if currentMode() != lastMode {
                schedule(after: 1.0, resetRetries: false)
            }
        }
    }
    do {
        try p.run()
    } catch {
        isApplying = false
        log("failed to start dock-apply.sh: \(error.localizedDescription)")
        retryCount += 1
        if retryCount <= 3 { schedule(after: 5.0, resetRetries: false) }
    }
}

// Display events arrive in bursts (a dock change fires several); debounce so we
// act once, after things settle.
func schedule(after delay: TimeInterval = 1.5, resetRetries: Bool = true) {
    DispatchQueue.main.async {
        if resetRetries { retryCount = 0 }
        pending?.cancel()
        let work = DispatchWorkItem { apply() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

// Jump can dynamically resize a virtual screen without a local display event.
// This is a cheap SSH state check; the shell helper only performs a full switch
// when a target's active screen, resolution, or counterpart has drifted.
func checkRemoteDisplays() {
    if isApplying || isChecking { return }
    isChecking = true
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [healthScript, "--check"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    process.terminationHandler = { process in
        DispatchQueue.main.async {
            isChecking = false
            if process.terminationStatus != 0 && process.terminationStatus != 75 {
                log("periodic display verification failed: exit \(process.terminationStatus)")
            }
        }
    }
    do {
        try process.run()
    } catch {
        isChecking = false
        log("periodic display verification could not start: \(error.localizedDescription)")
    }
}

let callback: CGDisplayReconfigurationCallBack = { _, _, _ in schedule() }
CGDisplayRegisterReconfigurationCallback(callback, nil)

// A closed-lid or dock removal can happen while macOS is asleep, in which case
// CoreGraphics never delivers the display transition to this process. Force a
// fresh reconciliation after wake instead of trusting the pre-sleep mode.
let wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didWakeNotification,
    object: nil,
    queue: .main
) { _ in
    log("system wake -> display reconciliation")
    lastMode = ""
    schedule(after: 3.0)
}

// A five-minute safety net catches remote-only resolution drift. Event and
// network recovery paths remain the fast path, so this is normally read-only.
let healthTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
    checkRemoteDisplays()
}

// Assert the correct mode shortly after launch (e.g. at login).
DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { apply() }
log("dock-watch started")

CFRunLoopRun()
