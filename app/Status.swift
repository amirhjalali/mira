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
}
