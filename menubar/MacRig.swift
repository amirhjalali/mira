import AppKit
import Foundation
import Network

@_silgen_name("AXIsProcessTrusted")
func macrigAXIsProcessTrusted() -> Bool

extension FileHandle {
    func writeString(_ value: String) {
        if let data = value.data(using: .utf8) { write(data) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let home = NSHomeDirectory()
    lazy var root = URL(fileURLWithPath: home).appendingPathComponent("home/macrig", isDirectory: true)
    lazy var bin = root.appendingPathComponent("bin", isDirectory: true)
    lazy var stateDir = root.appendingPathComponent("state", isDirectory: true)
    lazy var logsDir = root.appendingPathComponent("logs", isDirectory: true)
    lazy var profileFile = stateDir.appendingPathComponent("profile")
    lazy var modeFile = stateDir.appendingPathComponent("mode")
    lazy var logFile = logsDir.appendingPathComponent("macrig.log")
    lazy var configFile = root.appendingPathComponent("config.sh")

    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu(), monitor = NWPathMonitor()
    let networkQueue = DispatchQueue(label: "MacRig.Network"), logQueue = DispatchQueue(label: "MacRig.Log")

    var timer: Timer?
    var pendingNetworkWork: DispatchWorkItem?
    var lastPathKey = "init"
    var isRunning = false
    var lastActionFailed = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        ensurePaths()
        log("MacRig started")
        menu.delegate = self
        menu.autoenablesItems = false  // honor manual isEnabled flags (disable actions while a script runs)
        item.menu = menu
        refreshTitle()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.refreshTitle() }
        startNetworkWatcher()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        disabled(statusLine())
        if macrigAXIsProcessTrusted() {
            disabled(sessionPresenceLine())
        } else {
            add("Grant Accessibility to MacRig…", #selector(openAccessibilitySettings))
        }
        sep()
        add("Open Both Macs", #selector(openBothMacs), enabled: !isRunning)
        sep()

        let currentMode = mode()
        let currentProfile = profile()
        let auto = add("Auto", #selector(chooseAuto), enabled: !isRunning)
        auto.state = currentMode == "auto" ? .on : .off
        for (title, value) in [("High", "high"), ("Medium", "medium"), ("Low", "low")] {
            let profileItem = add(title, #selector(chooseProfile(_:)), enabled: !isRunning)
            profileItem.representedObject = value
            profileItem.state = currentMode == "manual" && currentProfile == value ? .on : .off
        }

        sep()
        add("View Log", #selector(viewLog))
        add("Quit MacRig", #selector(quit))
    }

    @discardableResult
    func add(_ title: String, _ action: Selector?, enabled: Bool = true) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
        menuItem.target = self
        menuItem.isEnabled = enabled
        menu.addItem(menuItem)
        return menuItem
    }

    func disabled(_ title: String) {
        let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menuItem.isEnabled = false
        menu.addItem(menuItem)
    }

    func sep() { menu.addItem(.separator()) }

    @objc func openBothMacs() { runScript("open-both-macs.sh", [], label: "Open Both Macs") }

    @objc func chooseAuto() {
        writeMode("auto")
        runScript("jump-quality.sh", ["auto"], label: "Set Auto Profile")
    }

    @objc func chooseProfile(_ sender: NSMenuItem) {
        guard let selected = sender.representedObject as? String else { return }
        writeMode("manual")
        runScript("jump-quality.sh", [selected], label: "Set \(displayName(selected)) Profile")
    }

    @objc func viewLog() { ensureLog(); NSWorkspace.shared.open(logFile) }

    @objc func quit() { NSApp.terminate(nil) }

    @objc func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    func startNetworkWatcher() {
        monitor.pathUpdateHandler = { [weak self] path in self?.handle(path) }
        monitor.start(queue: networkQueue)
    }

    func handle(_ path: NWPath) {
        let interfaces = path.availableInterfaces.map { $0.name }.sorted().joined(separator: ",")
        let key = "\(path.status) [\(interfaces)]"
        guard key != lastPathKey else { return }
        lastPathKey = key
        log("path change: \(key)")
        pendingNetworkWork?.cancel()

        guard path.status == .satisfied else {
            log("network auto tune skipped: path status \(path.status)")
            return
        }

        let work = DispatchWorkItem { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.mode() == "auto" {
                    self.log("network settled -> jump-quality auto --if-changed")
                    self.runScript("jump-quality.sh", ["auto", "--if-changed"], label: "Network Auto Tune", watcher: true)
                } else {
                    self.log("network settled -> manual mode, auto tune skipped")
                }
            }
        }
        pendingNetworkWork = work
        log("network auto tune scheduled in 12s")
        networkQueue.asyncAfter(deadline: .now() + 12, execute: work)
    }

    func runScript(_ name: String, _ args: [String], label: String, watcher: Bool = false) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { self.runScript(name, args, label: label, watcher: watcher) }
            return
        }
        guard !isRunning else {
            log(watcher ? "network auto tune skipped: script already running" : "\(label) skipped: script already running")
            return
        }

        ensureLog()
        isRunning = true
        menu.update()
        let script = bin.appendingPathComponent(name)
        guard let handle = FileHandle(forWritingAtPath: logFile.path) else {
            finishStartFailure(label, "could not open the log file")
            return
        }

        handle.seekToEndOfFile()
        handle.writeString("\n=== \(timestamp()) \(label): /bin/bash \(([script.path] + args).joined(separator: " ")) ===\n")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path] + args
        process.standardOutput = handle
        process.standardError = handle
        process.terminationHandler = { [weak self] process in
            let code = process.terminationStatus
            handle.writeString("\n=== \(self?.timestamp() ?? "") \(label): exit \(code) ===\n")
            handle.closeFile()
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRunning = false
                self.lastActionFailed = code != 0
                if code != 0 { self.notify("\(label) failed with exit \(code).") }
                self.refreshTitle()
                self.menu.update()
            }
        }

        do {
            try process.run()
        } catch {
            handle.closeFile()
            finishStartFailure(label, error.localizedDescription)
        }
    }

    func finishStartFailure(_ label: String, _ reason: String) {
        isRunning = false
        lastActionFailed = true
        log("\(label) failed to start: \(reason)")
        refreshTitle()
        notify("\(label) could not start.")
    }

    func sessionPresenceLine() -> String {
        guard let names = connectionNames() else { return "Config missing Jump names" }
        let script = """
        on run argv
          set miniName to item 1 of argv
          set airName to item 2 of argv
          tell application "System Events"
            if not (exists process "Jump Desktop") then return "Jump not running"
            tell process "Jump Desktop"
              set miniMark to "—"
              set airMark to "—"
              if (exists window miniName) then set miniMark to "✓"
              if (exists window airName) then set airMark to "✓"
              return "Mini " & miniMark & " · Air " & airMark
            end tell
          end tell
        end run
        """
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script, names.0, names.1]
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return output.isEmpty ? "Session check failed" : output
        } catch {
            return "Session check failed"
        }
    }

    func connectionNames() -> (String, String)? {
        guard let mini = configValue("MINI_NAME"), let air = configValue("AIR_NAME") else { return nil }
        return (mini, air)
    }

    func configValue(_ key: String) -> String? {
        guard let config = try? String(contentsOf: configFile, encoding: .utf8) else { return nil }
        let prefix = "\(key)=\""
        for rawLine in config.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix(prefix) else { continue }
            let start = line.index(line.startIndex, offsetBy: prefix.count)
            guard let end = line[start...].firstIndex(of: "\"") else { return nil }
            return String(line[start..<end])
        }
        return nil
    }

    func statusLine() -> String { "Profile: \(displayName(profile())) (\(mode()))" }

    func refreshTitle() {
        guard let button = item.button else { return }
        let state: (String, NSColor)
        if lastActionFailed {
            state = ("●!", .systemRed)
        } else {
            switch profile() {
            case "high": state = ("●H", .systemGreen)
            case "medium": state = ("●M", .systemOrange)
            case "low": state = ("●L", .systemRed)
            default: state = ("○", .systemGray)
            }
        }
        button.attributedTitle = NSAttributedString(string: state.0, attributes: [
            .foregroundColor: state.1, .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        ])
    }

    func profile() -> String? { read(profileFile) }
    func mode() -> String { read(modeFile) == "manual" ? "manual" : "auto" }

    func writeMode(_ value: String) {
        ensurePaths()
        do {
            try "\(value)\n".write(to: modeFile, atomically: true, encoding: .utf8)
            log("mode state -> \(value)")
        } catch {
            log("mode state write failed: \(error.localizedDescription)")
        }
        refreshTitle()
    }

    func displayName(_ value: String?) -> String {
        switch value {
        case "high": return "High"
        case "medium": return "Medium"
        case "low": return "Low"
        default: return "Unknown"
        }
    }

    func read(_ url: URL) -> String? {
        guard let value = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return value.isEmpty ? nil : value
    }

    func ensurePaths() {
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
    }

    func ensureLog() {
        ensurePaths()
        if !FileManager.default.fileExists(atPath: logFile.path) {
            FileManager.default.createFile(atPath: logFile.path, contents: nil)
        }
    }

    func log(_ message: String) {
        let line = "\(timestamp()) \(message)\n"
        logQueue.async {
            self.ensureLog()
            guard let handle = FileHandle(forWritingAtPath: self.logFile.path) else { return }
            handle.seekToEndOfFile()
            handle.writeString(line)
            handle.closeFile()
        }
    }

    func timestamp() -> String { let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"; return formatter.string(from: Date()) }

    func notify(_ message: String) {
        let escaped = message.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "display notification \"\(escaped)\" with title \"MacRig\""]
        try? process.run()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
