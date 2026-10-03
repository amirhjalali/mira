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
}
