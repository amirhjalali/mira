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
import Foundation

let toggleScript = "\(NSHomeDirectory())/home/macrig/bin/dock-apply.sh"
let logPath = "\(NSHomeDirectory())/home/macrig/logs/dock-watch.log"
var lastMode = ""
var pending: DispatchWorkItem?

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
    if mode == lastMode { return }
    lastMode = mode
    log("display mode -> \(mode)")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = [toggleScript, mode]
    do {
        try p.run()   // non-blocking; the script handles its own retries/logging
    } catch {
        log("failed to start dock-apply.sh: \(error.localizedDescription)")
    }
}

// Display events arrive in bursts (a dock change fires several); debounce so we
// act once, after things settle.
func schedule() {
    pending?.cancel()
    let work = DispatchWorkItem { apply() }
    pending = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
}

let callback: CGDisplayReconfigurationCallBack = { _, _, _ in schedule() }
CGDisplayRegisterReconfigurationCallback(callback, nil)

// Assert the correct mode shortly after launch (e.g. at login).
DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { apply() }
log("dock-watch started")

CFRunLoopRun()
