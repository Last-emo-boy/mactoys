import AppKit
import Darwin
import MacToysCore
import Observation

/// State of one File Locksmith window.
@MainActor
@Observable
final class FileLocksmithModel {
    let paths: [URL]
    private(set) var processes: [LockingProcess] = []
    private(set) var scanning = false
    /// Scanned with lsof as root: processes of every user are listed.
    private(set) var elevated = false
    private(set) var inaccessible = 0
    private(set) var lastError: String?
    /// When End process was asked for, per pid.
    private(set) var ending: [Int32: Date] = [:]
    /// Processes still alive a while after End process: offer Force Quit.
    private(set) var stuck: Set<Int32> = []
    var expanded: Set<Int32> = []

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let live: Bool
    @ObservationIgnored private let log = Log.for("filelocksmith")
    @ObservationIgnored private var generation = 0

    init(paths: [URL], live: Bool = true) {
        self.paths = paths
        self.live = live
    }

    /// For previews.
    init(sample paths: [URL], processes: [LockingProcess], inaccessible: Int = 0) {
        self.paths = paths
        self.processes = processes
        self.inaccessible = inaccessible
        live = false
    }

    // MARK: Lifecycle

    /// Scans (as administrator when `elevated`) and starts watching for processes that exit.
    func activate(elevated: Bool = false) {
        guard live else { return }
        if elevated { scanAsAdministrator() } else { scan() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pruneExited() }
        }
    }

    func deactivate() {
        timer?.invalidate()
        timer = nil
        generation += 1
    }

    // MARK: Scanning

    func refresh() {
        if elevated { scanAsAdministrator() } else { scan() }
    }

    private func scan() {
        guard live else { return }
        generation += 1
        let gen = generation
        scanning = true
        let paths = paths
        Task {
            let report = await Task.detached(priority: .userInitiated) { FileLocksmithScanner.scanReport(paths: paths) }.value
            guard gen == self.generation else { return }
            self.apply(report.processes)
            self.inaccessible = report.inaccessible
            self.scanning = false
        }
    }

    /// Lists open files of every user's processes with `lsof`, after the administrator prompt.
    func scanAsAdministrator() {
        guard live else { return }
        generation += 1
        let gen = generation
        scanning = true
        lastError = nil
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("mactoys-lsof-\(UUID().uuidString).txt")
        let command = "/usr/sbin/lsof " + LsofParser.arguments.map(Shell.quote).joined(separator: " ")
            + " > \(Shell.quote(output.path)) 2>/dev/null; /usr/sbin/chown \(getuid()) \(Shell.quote(output.path))"
        // Let the progress indicator draw before the modal password prompt.
        DispatchQueue.main.async { [weak self] in
            guard let self, gen == self.generation else { return }
            do {
                _ = try Privileged.run(command, prompt: "File Locksmith needs administrator access to see the processes of all users.")
            } catch {
                self.scanning = false
                if (error as? AppleScript.Failure)?.code != -128 {
                    self.lastError = error.localizedDescription
                    self.log.error("lsof failed: \(error.localizedDescription, privacy: .public)")
                }
                try? FileManager.default.removeItem(at: output)
                return
            }
            let paths = self.paths
            Task {
                let found = await Task.detached(priority: .userInitiated) { () -> [LockingProcess] in
                    defer { try? FileManager.default.removeItem(at: output) }
                    guard let data = try? Data(contentsOf: output) else { return [] }
                    return LsofParser.parse(String(decoding: data, as: UTF8.self), paths: paths).map(Self.enrich)
                }.value
                guard gen == self.generation else { return }
                self.elevated = true
                self.inaccessible = 0
                self.apply(found)
                self.scanning = false
            }
        }
    }

    /// Adds the start time and program path libproc can read for any process.
    nonisolated static func enrich(_ p: LockingProcess) -> LockingProcess {
        var p = p
        if let info = FileLocksmithScanner.processInfo(p.pid) {
            p.startTime = info.start
            p.executablePath = info.path ?? p.executablePath
            if p.name.isEmpty { p.name = info.name }
        }
        if p.user.isEmpty { p.user = FileLocksmithScanner.userName(p.uid) }
        return p
    }

    private func apply(_ list: [LockingProcess]) {
        processes = list
        let pids = Set(list.map(\.pid))
        ending = ending.filter { pids.contains($0.key) }
        stuck.formIntersection(pids)
        expanded.formIntersection(pids)
    }

    /// Drops processes that exited (whoever ended them) and notices End requests that were ignored.
    private func pruneExited() {
        let alive = processes.filter(FileLocksmithScanner.isRunning)
        if alive.count != processes.count { apply(alive) }
        for (pid, date) in ending where Date().timeIntervalSince(date) > 3 { stuck.insert(pid) }
    }

    // MARK: Ending processes

    func canEnd(_ p: LockingProcess) -> Bool { p.pid != getpid() && p.pid > 1 }

    /// Asks the process to quit: apps get a Quit event (so they can save), others SIGTERM.
    func end(_ p: LockingProcess) {
        guard live, canEnd(p) else { return }
        ending[p.pid] = Date()
        stuck.remove(p.pid)
        if let app = NSRunningApplication(processIdentifier: p.pid), app.activationPolicy == .regular, app.terminate() {
            return
        }
        signal(p, SIGTERM)
    }

    /// SIGKILL: the process ends at once and loses unsaved work.
    func forceQuit(_ p: LockingProcess) {
        guard live, canEnd(p) else { return }
        ending[p.pid] = Date()
        stuck.remove(p.pid)
        signal(p, SIGKILL)
    }

    private func signal(_ p: LockingProcess, _ sig: Int32) {
        if kill(p.pid, sig) == 0 { return }
        let err = errno
        guard err == EPERM else {
            if err != ESRCH { lastError = String(cString: strerror(err)) }
            return
        }
        do {
            _ = try Privileged.run("/bin/kill -\(sig) \(p.pid)",
                                   prompt: "File Locksmith needs administrator access to end “\(p.name)”.")
        } catch {
            ending[p.pid] = nil
            if (error as? AppleScript.Failure)?.code != -128 { lastError = error.localizedDescription }
        }
    }

    // MARK: Display

    /// "~/Projects/mactoys/build" or "3 items".
    var pathTitle: String {
        guard let first = paths.first else { return "No items" }
        let shown = Self.abbreviate(first.path)
        return paths.count == 1 ? shown : "\(shown) and \(paths.count - 1) more"
    }

    var isFolder: Bool {
        paths.count == 1
            && ((try? paths[0].resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? paths[0].hasDirectoryPath)
    }

    static func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path == home || path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// A path shown relative to the scanned item that contains it.
    func displayPath(_ path: String) -> String {
        let roots = paths.map { PathMatcher.resolve($0.path) } + paths.map(\.path)
        for root in roots.sorted(by: { $0.count > $1.count }) {
            if path == root { return (path as NSString).lastPathComponent }
            if path.hasPrefix(root + "/") { return String(path.dropFirst(root.count + 1)) }
        }
        return Self.abbreviate(path)
    }

    /// "PID 4182 · w33d · 7 files · DerivedData/Build.db"
    func subtitle(_ p: LockingProcess) -> String {
        var parts = ["PID \(p.pid)", p.user]
        let open = p.files.filter { $0.kind != .workingDirectory && $0.kind != .rootDirectory }
        if open.count > 1 { parts.append("\(open.count) files") }
        if let first = open.first {
            parts.append(displayPath(first.path))
        } else if p.files.contains(where: { $0.kind == .workingDirectory }) {
            parts.append("cwd")
        } else if p.files.contains(where: { $0.kind == .rootDirectory }) {
            parts.append("root")
        }
        return parts.joined(separator: " · ")
    }
}
