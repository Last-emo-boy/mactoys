import AppKit
import ApplicationServices
import MacToysCore

/// Watches every regular app for window and focus changes (one Accessibility observer per app)
/// and the workspace for launches, quits, hiding, Space and display changes, and reports them to
/// the engine. The engine coalesces everything into one re-tile.
@MainActor
final class WindowTracker {
    private unowned let engine: TilingEngine
    private var watchers: [pid_t: AXWatcher] = [:]
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private(set) var isRunning = false
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    /// App-level notifications every observer subscribes to.
    private static let appNotifications = [
        kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXWindowMovedNotification,
        kAXWindowResizedNotification, kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
        kAXApplicationHiddenNotification, kAXApplicationShownNotification,
    ]

    init(engine: TilingEngine) {
        self.engine = engine
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        let ws = NSWorkspace.shared.notificationCenter
        on(ws, NSWorkspace.didLaunchApplicationNotification) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.launched(app)
        }
        on(ws, NSWorkspace.didTerminateApplicationNotification) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.unwatch(app.processIdentifier)
            self?.engine.appTerminated(app.processIdentifier)
        }
        on(ws, NSWorkspace.didActivateApplicationNotification) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.engine.appActivated(app)
        }
        for name in [NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            on(ws, name) { [weak self] _ in self?.engine.setNeedsRetile() }
        }
        on(ws, NSWorkspace.activeSpaceDidChangeNotification) { [weak self] _ in self?.engine.spaceChanged() }
        on(ws, NSWorkspace.didWakeNotification) { [weak self] _ in self?.engine.screensChanged() }
        on(.default, NSApplication.didChangeScreenParametersNotification) { [weak self] _ in self?.engine.screensChanged() }
        watchRunningApps()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        for w in watchers.values { w.invalidate() }
        watchers.removeAll()
    }

    /// Replaces every observer (ones made before Accessibility was granted don't deliver).
    func rewatchAll() {
        guard isRunning else { return }
        for w in watchers.values { w.invalidate() }
        watchers.removeAll()
        watchRunningApps()
    }

    /// Also reports when this window goes away (closing posts no app-level notification).
    func watchDestroy(_ window: WindowRef) {
        watchers[window.pid]?.add(kAXUIElementDestroyedNotification, on: window.element)
    }

    private func on(_ center: NotificationCenter, _ name: Notification.Name, _ body: @escaping @MainActor (Notification) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { note in
            MainActor.assumeIsolated { body(note) }
        }
        observers.append((center, token))
    }

    private func watchRunningApps() {
        for app in NSWorkspace.shared.runningApplications { watch(app) }
    }

    private func launched(_ app: NSRunningApplication) {
        // Observers attach reliably only once the app finished launching: watch, then look again.
        watch(app)
        for delay in [0.5, 1.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.isRunning, !app.isTerminated else { return }
                if delay > 1 { self.unwatch(app.processIdentifier) }
                self.watch(app)
                self.engine.setNeedsRetile()
            }
        }
    }

    private func watch(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard AXIsProcessTrusted(), app.activationPolicy == .regular, !app.isTerminated, watchers[pid] == nil,
              pid != ownPID else { return }
        let watcher = AXWatcher(pid: pid) { [weak self] notification, element in
            MainActor.assumeIsolated { self?.received(notification, element, pid: pid) }
        }
        guard let watcher else { return }
        for n in Self.appNotifications { watcher.add(n) }
        watchers[pid] = watcher
        // A replaced observer took the per-window close watches with it.
        engine.watcherReplaced(pid: pid)
    }

    private func unwatch(_ pid: pid_t) {
        watchers[pid]?.invalidate()
        watchers[pid] = nil
    }

    private func received(_ notification: String, _ element: AXUIElement, pid: pid_t) {
        guard isRunning else { return }
        switch notification {
        case kAXWindowCreatedNotification:
            let window = WindowRef(element: element, pid: pid)
            // Give the app a moment to set the window's subrole and frame.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                guard let self, self.isRunning else { return }
                self.engine.windowCreated(window)
            }
        case kAXFocusedWindowChangedNotification:
            engine.focusChanged()
        case kAXApplicationHiddenNotification, kAXApplicationShownNotification:
            engine.setNeedsRetile()
        default:
            engine.windowEvent(notification, WindowRef(element: element, pid: pid))
        }
    }
}
