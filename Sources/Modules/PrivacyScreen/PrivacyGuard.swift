import AppKit
import Darwin
import Foundation
import MacToysCore

/// What the app writes while something is locked, so the guard knows whether the app's death
/// must lock the Mac.
public struct GuardMarker: Codable, Equatable, Sendable {
    public enum Scope: String, Codable, Sendable {
        /// The whole screen is locked: the guard also keeps a black backup shield under the app's.
        case screen
        /// Only apps are locked (App Lock).
        case apps
    }

    public var pid: Int32
    public var scope: Scope
    public var since: Date

    public init(pid: Int32, scope: Scope, since: Date) {
        self.pid = pid
        self.scope = scope
        self.since = since
    }

    public static func read(_ url: URL) -> GuardMarker? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(GuardMarker.self, from: data)
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// What the guard does when the watched app exits.
enum GuardDecision: Equatable {
    case lockMac
    case standDown

    /// Locks only when the marker still says the watched process holds a lock. A missing marker means
    /// the app unlocked (or never locked); a marker naming another process is stale.
    static func onAppExit(marker: GuardMarker?, watchedPID: Int32) -> GuardDecision {
        guard let marker, marker.pid == watchedPID else { return .standDown }
        return .lockMac
    }
}

/// `--pid <pid> --marker <file>`.
struct GuardArguments: Equatable {
    let pid: Int32
    let marker: URL

    static func parse(_ args: [String]) -> GuardArguments? {
        var pid: Int32?
        var marker: URL?
        var i = 0
        while i < args.count {
            let a = args[i]
            let next = i + 1 < args.count ? args[i + 1] : nil
            switch a {
            case "--pid":
                guard let next, let v = Int32(next), v > 0 else { return nil }
                pid = v
                i += 2
            case "--marker":
                guard let next, next.hasPrefix("/") else { return nil }
                marker = URL(fileURLWithPath: next)
                i += 2
            default:
                return nil
            }
        }
        guard let pid, let marker else { return nil }
        return GuardArguments(pid: pid, marker: marker)
    }

    var arguments: [String] { ["--pid", String(pid), "--marker", marker.path] }
}

/// The guard process: `mactoys privacy-guard --pid <pid> --marker <file>` (hidden subcommand).
///
/// MacToys starts it when something gets locked. It watches the app's process; if MacToys dies
/// while the marker says locked — Force Quit, a crash, `kill -9` — it locks the Mac with the real
/// macOS lock. For a screen lock it already shows a black shield just below MacToys' own, so the
/// desktop is never visible in between. Deleting the marker (unlocking) makes it exit.
public enum PrivacyGuard {
    public static let subcommand = "privacy-guard"

    /// Runs the guard. Returns only for bad arguments (exit code 64); otherwise it exits the process
    /// when its work is done.
    @MainActor
    public static func run(_ args: [String]) -> Int32 {
        guard let parsed = GuardArguments.parse(args) else {
            FileHandle.standardError.write(Data("usage: mactoys privacy-guard --pid <pid> --marker <file>\n".utf8))
            return 64
        }
        signal(SIGHUP, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        SystemLock.prepare()
        guard GuardMarker.read(parsed.marker) != nil else { return 0 }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let session = GuardSession(arguments: parsed)
        session.start()
        app.run()
        return 0
    }
}

/// The running guard (in the helper process).
@MainActor
private final class GuardSession {
    let arguments: GuardArguments
    private var exitSource: DispatchSourceProcess?
    private var markerSource: DispatchSourceFileSystemObject?
    private var poll: Timer?
    private var shields: [NSWindow] = []
    private var screenObserver: NSObjectProtocol?
    private var finishing = false
    private let log = Log.for("privacyscreen")

    init(arguments: GuardArguments) {
        self.arguments = arguments
    }

    func start() {
        let pid = arguments.pid
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.appExited() } }
        source.resume()
        exitSource = source
        watchMarker()
        poll = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshShields() }
        }
        refreshShields()
        // The app may have died before the process source was installed.
        check()
    }

    private func check() {
        guard !finishing else { return }
        if kill(arguments.pid, 0) != 0 && errno == ESRCH { appExited(); return }
        if GuardMarker.read(arguments.marker) == nil { standDown() }
    }

    /// Follows the marker file: deleted means unlocked; replaced means the lock changed scope.
    private func watchMarker() {
        markerSource?.cancel()
        markerSource = nil
        let fd = open(arguments.marker.path, O_EVTONLY)
        guard fd >= 0 else { standDown(); return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.delete, .rename, .revoke, .write],
                                                               queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.finishing else { return }
                if GuardMarker.read(self.arguments.marker) == nil { self.standDown() } else {
                    self.watchMarker()
                    self.refreshShields()
                }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        markerSource = source
    }

    private func appExited() {
        guard !finishing else { return }
        finishing = true
        switch GuardDecision.onAppExit(marker: GuardMarker.read(arguments.marker), watchedPID: arguments.pid) {
        case .standDown:
            finish()
        case .lockMac:
            let how = SystemLock.lockNow()
            log.notice("MacToys exited while locked; locked the Mac (\(how, privacy: .public))")
            try? FileManager.default.removeItem(at: arguments.marker)
            waitForSystemLock(deadline: Date().addingTimeInterval(10))
        }
    }

    /// Keeps the backup shield until the login window is up, so nothing shows in between.
    private func waitForSystemLock(deadline: Date) {
        if SystemLock.isScreenLocked || Date() > deadline {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.finish() }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.waitForSystemLock(deadline: deadline) }
    }

    private func standDown() {
        guard !finishing else { return }
        finishing = true
        finish()
    }

    private func finish() {
        for w in shields { w.orderOut(nil) }
        exit(0)
    }

    /// Black windows on every display, one level under MacToys' lock shield.
    private func refreshShields() {
        let wanted = !finishing && GuardMarker.read(arguments.marker)?.scope == .screen
        let screens = wanted ? NSScreen.screens : []
        while shields.count > screens.count { shields.removeLast().orderOut(nil) }
        for (i, screen) in screens.enumerated() {
            let window: NSWindow
            if i < shields.count {
                window = shields[i]
            } else {
                window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.isOpaque = true
                window.backgroundColor = .black
                window.ignoresMouseEvents = true
                window.isReleasedWhenClosed = false
                window.hasShadow = false
                window.animationBehavior = .none
                window.level = LockLevels.guardShield
                window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
                shields.append(window)
            }
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
        }
    }
}

/// Window levels of the lock.
enum LockLevels {
    /// The shielding level used for captured displays: above the menu bar, Dock, notifications,
    /// screen saver and every app window.
    static let shield = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
    /// The unlock island and the failed-attempt list, just above the shield.
    static let island = NSWindow.Level(rawValue: min(Int(CGShieldingWindowLevel()) + 1,
                                                     Int(CGWindowLevelForKey(.maximumWindow))))
    /// The guard's backup shield, just below MacToys' shield.
    static let guardShield = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) - 1)
}

// MARK: - App side

/// Starts and ends the guard from the app.
@MainActor
final class LockGuard {
    /// Called when the guard dies while still engaged (someone killed it).
    var onUnexpectedExit: (() -> Void)?

    private(set) var scope: GuardMarker.Scope?
    private var child: pid_t?
    private var exitSource: DispatchSourceProcess?
    private var expectingExit = false
    private let log = Log.for("privacyscreen")

    let markerURL: URL = Paths.data(for: "privacyscreen").appendingPathComponent("lock-guard.json")

    /// The bundled CLI (`MacToys.app/Contents/Helpers/mactoys`); nil when running unbundled.
    static var helperPath: String? {
        let path = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/mactoys").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    var isRunning: Bool { child != nil }

    /// Writes the marker for `scope` and makes sure a guard watches this process.
    func engage(_ scope: GuardMarker.Scope) {
        let marker = GuardMarker(pid: ProcessInfo.processInfo.processIdentifier, scope: scope, since: Date())
        do {
            try marker.write(to: markerURL)
        } catch {
            log.error("Could not write the lock marker: \(error.localizedDescription, privacy: .public)")
            return
        }
        self.scope = scope
        if child == nil { spawn() }
    }

    /// Deletes the marker and waits (briefly) for the guard to exit, so its backup shield is gone
    /// before the app removes its own.
    func disengage(then completion: @escaping @MainActor () -> Void) {
        scope = nil
        expectingExit = true
        try? FileManager.default.removeItem(at: markerURL)
        guard let pid = child else {
            expectingExit = false
            completion()
            return
        }
        var done = false
        let finish: @MainActor () -> Void = { [weak self] in
            guard !done else { return }
            done = true
            self?.reap(pid)
            completion()
        }
        pendingExit = finish
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard !done else { return }
            kill(pid, SIGKILL)
            finish()
        }
    }

    private var pendingExit: (@MainActor () -> Void)?

    private func spawn() {
        guard let path = Self.helperPath else {
            log.notice("No bundled helper; the lock runs without a guard")
            return
        }
        let args = [path, PrivacyGuard.subcommand] + GuardArguments(pid: ProcessInfo.processInfo.processIdentifier,
                                                                    marker: markerURL).arguments
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // Its own session, so signals sent to MacToys' process group don't reach it.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        var cargs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        var cenv: [UnsafeMutablePointer<CChar>?] = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for p in cargs + cenv { free(p) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, path, &actions, &attr, &cargs, &cenv)
        guard rc == 0 else {
            log.error("Could not start the lock guard: \(String(cString: strerror(rc)), privacy: .public)")
            return
        }
        child = pid
        expectingExit = false
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.childExited(pid) } }
        source.resume()
        exitSource = source
    }

    private func childExited(_ pid: pid_t) {
        guard child == pid else { return }
        if let pending = pendingExit {
            pendingExit = nil
            pending()
            return
        }
        reap(pid)
        if !expectingExit && scope != nil {
            log.error("The lock guard exited while locked")
            onUnexpectedExit?()
        }
    }

    private func reap(_ pid: pid_t) {
        exitSource?.cancel()
        exitSource = nil
        var status: Int32 = 0
        waitpid(pid, &status, WNOHANG)
        if child == pid { child = nil }
        pendingExit = nil
        expectingExit = false
    }

    /// Restarts the guard after it died unexpectedly (keeps the current scope).
    func respawnIfNeeded() {
        guard let scope, child == nil else { return }
        engage(scope)
    }
}
