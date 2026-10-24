import AppKit
import MacToysCore

struct ProcessEntry: Sendable, Hashable {
    let pid: Int32
    let cpu: Double
    /// Resident memory in bytes.
    let memory: Int64
    let user: String
    let path: String
    var name: String { (path as NSString).lastPathComponent }

    /// Parses `ps -axo pid=,pcpu=,rss=,user=,comm=` output.
    static func parse(_ output: String) -> [ProcessEntry] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard parts.count == 5, let pid = Int32(parts[0]), let cpu = Double(parts[1]), let rss = Int64(parts[2]) else { return nil }
            return ProcessEntry(pid: pid, cpu: cpu, memory: rss * 1024, user: String(parts[3]),
                                path: String(parts[4]).trimmingCharacters(in: .whitespaces))
        }
    }
}

/// Processes (`kill`): list running processes with CPU and memory, quit or kill them.
@MainActor
final class ProcessesProvider: SearchProvider {
    let id = "processes"
    let name = "Processes"
    let summary = "Find running processes and quit or kill them"
    let icon = ItemIcon.symbol("cpu", .red)
    let defaultKeyword = "kill"
    let globalByDefault = false
    let examples = ["kill chrome", "kill  (sorted by CPU)"]

    private let engine: LauncherEngine
    private var cache: [ProcessEntry] = []
    private var cachedAt: Date?

    init(engine: LauncherEngine) { self.engine = engine }

    var commands: [PaletteItem] {
        [pageCommand(title: "Running Processes", subtitle: "Quit or kill processes", keywords: ["kill", "task manager", "activity", "ps"])]
    }

    func launcherWillShow() { cachedAt = nil }

    func search(_ query: SearchQuery) async -> [PaletteItem] {
        let text = query.text.trimmingCharacters(in: .whitespaces)
        guard query.scoped || text.count >= 3 else { return [] }
        let list = await processes()
        guard !Task.isCancelled else { return [] }
        let apps = Dictionary(NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { a, _ in a })
        if text.isEmpty {
            return list.sorted { $0.cpu > $1.cpu }.prefix(300).enumerated().map { i, p in
                item(p, app: apps[p.pid], score: 1000 - Double(i))
            }
        }
        if let pid = Int32(text), let p = list.first(where: { $0.pid == pid }) {
            return [item(p, app: apps[p.pid], score: 1000)]
        }
        return list.compactMap { p in
            let appName = apps[p.pid]?.localizedName
            guard let s = FuzzyMatcher.best(text, title: appName ?? p.name, keywords: [p.name]) else { return nil }
            return item(p, app: apps[p.pid], score: (query.scoped ? s : s * 0.6) + min(p.cpu, 50) / 10)
        }
    }

    private func processes() async -> [ProcessEntry] {
        if let at = cachedAt, Date().timeIntervalSince(at) < 2 { return cache }
        let out = await AsyncProcess.run("/bin/ps", ["-axo", "pid=,pcpu=,rss=,user=,comm="], timeout: 5)
        cache = ProcessEntry.parse(out.stdout).filter { $0.pid != ProcessInfo.processInfo.processIdentifier }
        cachedAt = Date()
        return cache
    }

    func item(_ p: ProcessEntry, app: NSRunningApplication?, score: Double) -> PaletteItem {
        let memory = ByteCountFormatter.string(fromByteCount: p.memory, countStyle: .memory)
        let title = app?.localizedName ?? p.name
        let confirmKill = engine.options.value.processesConfirmKill
        let iconPath = app?.bundleURL?.path
        func signal(_ sig: Int32, _ label: String) -> ActionOutcome {
            if kill(p.pid, sig) == 0 {
                HUD.show("\(label) \(title)", symbol: "xmark.circle")
            } else {
                HUD.show(errno == EPERM ? "Not permitted to signal \(title)" : "Couldn’t signal \(title)",
                         symbol: "exclamationmark.triangle")
            }
            cachedAt = nil
            return .refresh
        }
        let killAction = PaletteAction(id: "kill", title: "Kill Process", symbol: "xmark.octagon", shortcut: ActionKeys.trash,
                                       destructive: true) {
            guard confirmKill else { return signal(SIGKILL, "Killed") }
            return .confirm(Confirmation(title: "Kill \(title) (\(p.pid))?", message: "It stops immediately; unsaved work is lost.",
                                         confirmTitle: "Kill") { signal(SIGKILL, "Killed") })
        }
        let quit = PaletteAction(id: "quit", title: app != nil ? "Quit App" : "Terminate Process", symbol: "xmark.circle") {
            if let app {
                app.terminate()
                self.cachedAt = nil
                return .refresh
            }
            return signal(SIGTERM, "Terminated")
        }
        var actions = [killAction,
                       PaletteAction(id: "copypid", title: "Copy PID", symbol: "number", shortcut: ActionKeys.copy) {
                           Launch.copy(String(p.pid))
                           return .dismiss
                       },
                       PaletteAction(id: "reveal", title: "Show Executable in Finder", symbol: "folder", shortcut: ActionKeys.secondary) {
                           Launch.reveal(URL(fileURLWithPath: p.path))
                           return .dismiss
                       }]
        if app != nil {
            actions.insert(PaletteAction(id: "activate", title: "Switch to App", symbol: "macwindow") {
                .dismissThen { app?.activate() }
            }, at: 0)
        }
        return PaletteItem(
            id: "processes:\(p.pid)", title: title, subtitle: "PID \(p.pid) · \(String(format: "%.1f", p.cpu))% CPU · \(memory) · \(p.user)",
            icon: iconPath.map { .file($0) } ?? .symbol("gearshape.2.fill", .graphite), providerID: id,
            accessory: String(format: "%.1f%%", p.cpu), score: score, primary: quit, actions: actions,
            details: ItemDetails(icon: iconPath.map { .file($0) } ?? .symbol("gearshape.2.fill", .graphite), title: title,
                                 subtitle: p.path, rows: [
                                     DetailRow(label: "PID", value: String(p.pid)),
                                     DetailRow(label: "CPU", value: String(format: "%.1f %%", p.cpu)),
                                     DetailRow(label: "Memory", value: memory),
                                     DetailRow(label: "User", value: p.user),
                                 ]),
            isPinnable: false)
    }
}
