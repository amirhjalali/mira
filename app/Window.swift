// MIRA window UI. Compiled with the other sources by tests/run.sh.
import SwiftUI

struct WindowsStatus { let pc: WindowsPC; let online: Bool?; let lastSeen: String?; let sessionOpen: Bool }

// Pure, selftested.
func rdpFileText(_ pc: WindowsPC) -> String {
    "full address:s:\(rdpEndpoint(pc))\nprompt for credentials on client:i:0\nscreen mode id:i:2\n"
}

// Windows App owns the session; MIRA only brings it forward or starts it.
func openWindowsPC(_ pc: WindowsPC, sessionOpen: Bool) {
    if sessionOpen { sh("open -a 'Windows App'"); return }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(pc.id).rdp")
    try? rdpFileText(pc).write(to: url, atomically: true, encoding: .utf8)
    sh("open -a 'Windows App' \(shellQuote(url.path))")
}

final class MiraModel: ObservableObject {
    let cfg: Config, me: Machine
    @Published var statuses: [String: MachineStatus] = [:]
    @Published var lastSeen: [String: Date] = [:]
    @Published var unreachable: Set<String> = []
    @Published var pcs: [WindowsStatus] = []
    @Published var notes: [String: String] = [:]
    @Published var refreshed: Date?
    private var timer: Timer?
    private var inFlight = Set<String>()
    private let lock = NSLock()

    init(cfg: Config, me: Machine) { self.cfg = cfg; self.me = me }
    var macs: [Machine] { cfg.machines.filter { ($0.type ?? "mac") == "mac" } }
    var driver: String? { currentDriver(statuses, unreachable: unreachable) }

    func start() {
        guard timer == nil else { refresh(); return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
    }
    func stop() { timer?.invalidate(); timer = nil }

    func refresh() {
        macs.forEach(poll)
        DispatchQueue.global(qos: .utility).async { [self] in
            let ts = parseTailscale(sh("tailscale status --json 2>/dev/null || /Applications/Tailscale.app/Contents/MacOS/Tailscale status --json 2>/dev/null", timeout: 8).out)
            let open = Set(readJSON(LocalStatus.self, localStatusFile)?.rdpEndpoints ?? [])
            let list = (cfg.windowsPCs ?? []).map { pc in
                WindowsStatus(pc: pc, online: ts[pc.tailscale]?.online ?? nil,
                              lastSeen: ts[pc.tailscale]?.lastSeen, sessionOpen: open.contains(rdpEndpoint(pc)))
            }
            DispatchQueue.main.async { self.pcs = list; self.refreshed = Date() }
        }
    }

    private func poll(_ m: Machine) {
        lock.lock()
        guard !inFlight.contains(m.id) else { lock.unlock(); return }
        inFlight.insert(m.id); lock.unlock()
        DispatchQueue.global(qos: .utility).async { [self] in
            let r = m.id == me.id
                ? sh("\(shellQuote(Bundle.main.executablePath ?? CommandLine.arguments[0])) inspect-machine", timeout: 10)
                : peerRun(m, miraExec("inspect-machine"), timeout: 12, force: true)
            let s = try? JSONDecoder().decode(MachineStatus.self, from: Data(r.out.utf8))
            lock.lock(); inFlight.remove(m.id); lock.unlock()
            DispatchQueue.main.async {
                if let s = s { self.statuses[m.id] = s; self.lastSeen[m.id] = Date(); self.unreachable.remove(m.id) }
                else { self.unreachable.insert(m.id) }
            }
        }
    }

    func act(_ kind: String, on m: Machine) {
        notes[m.id] = "…"
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var r = ControlRequest(kind: kind)
            if kind == "stop" { r.session = currentSession(me) }
            let reply = m.id == me.id ? requestDaemon(r) : remoteControl(m, r)
            DispatchQueue.main.async { self.notes[m.id] = reply.message; self.poll(m) }
        }
    }
    func connect(_ m: Machine) {
        notes[m.id] = "Opening…"
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let r = openSessionWindows(cfg: cfg, me: me, targets: [m])
            DispatchQueue.main.async { self.notes[m.id] = sessionWindowSummary(opened: r.opened, kept: r.kept) }
        }
    }
    func name(_ id: String) -> String { cfg.machines.first { $0.id == id }?.jumpName ?? id }
}

struct MiraView: View {
    @ObservedObject var model: MiraModel
    let columns = [GridItem(.adaptive(minimum: 280), spacing: 12)]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(model.driver.map { "\(model.name($0)) is driving" } ?? "Nobody is driving").font(.headline)
                    Spacer()
                    if let t = model.refreshed {
                        Text("Updated \(t.formatted(date: .omitted, time: .standard))").foregroundStyle(.secondary).font(.caption)
                    }
                    Button("Refresh") { model.refresh() }
                }
                Text("Macs").font(.title3.bold())
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    ForEach(model.macs, id: \.id) { m in MacCard(model: model, machine: m) }
                }
                if !model.pcs.isEmpty {
                    Text("Windows").font(.title3.bold())
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(model.pcs, id: \.pc.id) { s in PCCard(status: s) }
                    }
                }
            }.padding(16)
        }.frame(minWidth: 620, minHeight: 460)
    }
}

struct Dot: View {
    let color: Color
    var body: some View { Circle().fill(color).frame(width: 9, height: 9) }
}

struct MacCard: View {
    @ObservedObject var model: MiraModel
    let machine: Machine
    @State private var confirmKill = false
    @State private var confirmDisplay = false
    var body: some View {
        let s = model.statuses[machine.id]
        let down = model.unreachable.contains(machine.id)
        let stale = s?.outbound?.contains { $0.stale } == true
        let warn = s.map { $0.audioWarning != nil || $0.display == "wrong" || !$0.warnings.isEmpty } ?? false
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Dot(color: down || s == nil ? .gray : stale ? .red : warn ? .orange : .green)
                Text(machine.jumpName).font(.headline)
                Spacer()
                Text(down ? "unreachable" : (s?.role ?? "…")).font(.caption).padding(.horizontal, 6)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }
            if down, let seen = model.lastSeen[machine.id] {
                Text("Last seen \(seen.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
            }
            if let s = s { details(s, down: down, stale: stale) }
            HStack {
                if machine.id == model.me.id {
                    if s?.role == "driver" { Button("Stop Driving") { model.act("stop", on: machine) } }
                    else if mayDrive(roles: machine.roles) { Button("Drive from Here") { model.act("drive", on: machine) } }
                    if s?.role == "passenger" { Button("Use Locally") { model.act("local", on: machine) } }
                } else if offersConnect(myRole: model.statuses[model.me.id]?.role, me: model.me, target: machine) {
                    Button("Connect") { model.connect(machine) }
                }
                if let note = model.notes[machine.id] { Text(note).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .confirmationDialog("Close every Jump session \(machine.jumpName) is holding?", isPresented: $confirmKill) {
            Button("Close Sessions", role: .destructive) { model.act("close-viewer", on: machine) }
        }
        .confirmationDialog("Re-apply \(machine.jumpName)'s display layout? Screens may flicker.", isPresented: $confirmDisplay) {
            Button("Re-apply Layout") { model.act("fix-display", on: machine) }
        }
    }

    @ViewBuilder func details(_ s: MachineStatus, down: Bool, stale: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let out = s.outbound, !out.isEmpty {
                HStack {
                    Text("Viewing: " + out.map { model.name($0.peer) + ($0.stale ? " (stale)" : "") }.joined(separator: ", "))
                        .foregroundStyle(stale ? .red : .primary)
                    if stale { Button("Kill") { confirmKill = true } }
                }
            }
            if s.inboundCount > 0 {
                Text("Being viewed: \(s.inboundCount) session(s), oldest \(age(s.inboundOldestSeconds))")
            }
            HStack {
                Text("Audio: \(s.output ?? "?") / \(s.input ?? "?")")
                if s.audioWarning != nil { Button("Fix") { model.act("fix-audio", on: machine) } }
            }
            if let w = s.audioWarning { Text(w).foregroundStyle(.orange) }
            HStack {
                Text("Display: \(s.displayDetail)").foregroundStyle(s.display == "wrong" ? .orange : .primary)
                if s.display == "wrong" { Button("Fix") { confirmDisplay = true } }
            }
            ForEach(s.warnings, id: \.self) { Text($0).foregroundStyle(.orange) }
            Text("Build \(s.build)").foregroundStyle(.secondary)
        }.font(.caption).opacity(down ? 0.5 : 1)
    }

    func age(_ s: Double?) -> String {
        guard let s = s else { return "?" }
        return s >= 3600 ? "\(Int(s / 3600))h" : "\(Int(s / 60))m"
    }
}

struct PCCard: View {
    let status: WindowsStatus
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Dot(color: status.online == true ? .green : status.online == false ? .gray : .yellow)
                Text(status.pc.name).font(.headline)
                Spacer()
                Text(status.online == true ? "online" : status.online == false ? "offline" : "unknown").font(.caption)
            }
            Text(status.pc.tailscaleName + " · " + rdpEndpoint(status.pc)).font(.caption).foregroundStyle(.secondary)
            if status.online == false, let seen = status.lastSeen { Text("Last seen \(seen.prefix(10))").font(.caption) }
            if status.sessionOpen { Text("Session open from this Mac").font(.caption).foregroundStyle(.green) }
            Button(status.sessionOpen ? "Show" : "Connect") { openWindowsPC(status.pc, sessionOpen: status.sessionOpen) }
                .disabled(status.online == false)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

final class MiraWindowController: NSObject, NSWindowDelegate {
    let model: MiraModel
    let window: NSWindow
    init(cfg: Config, me: Machine) {
        model = MiraModel(cfg: cfg, me: me)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "MIRA"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: MiraView(model: model))
        window.delegate = self
        window.center()
    }
    func show() {
        model.start()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) { model.stop() }
}
