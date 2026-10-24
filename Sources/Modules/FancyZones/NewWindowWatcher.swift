import AppKit
import ApplicationServices
import MacToysCore

/// Watches every regular app for new windows (AX window-created notifications, plus a scan
/// shortly after an app launches, before its observer is reliable) and places them:
/// into the app's last known zone, or onto the display under the pointer.
@MainActor
final class NewWindowWatcher {
    private unowned let engine: ZoneEngine
    private var watchers: [pid_t: AXWatcher] = [:]
    private var seen: [pid_t: Set<WindowRef>] = [:]
    private var observers: [NSObjectProtocol] = []
    private(set) var isRunning = false

    init(engine: ZoneEngine) {
        self.engine = engine
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        let nc = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil,
                                        queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { if let app { self?.launched(app) } }
        })
        observers.append(nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil,
                                        queue: .main) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated { if let pid { self?.unwatch(pid) } }
        })
        watchRunningApps()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        let nc = NSWorkspace.shared.notificationCenter
        for o in observers { nc.removeObserver(o) }
        observers.removeAll()
        for w in watchers.values { w.invalidate() }
        watchers.removeAll()
        seen.removeAll()
    }

    /// Adds observers for apps that could not be watched before (e.g. once Accessibility is granted).
    func watchRunningApps() {
        guard isRunning else { return }
        for app in NSWorkspace.shared.runningApplications { watch(app) }
    }

    private func launched(_ app: NSRunningApplication) {
        // Observers attach reliably only once the app finished launching; scan its windows twice meanwhile.
        for delay in [0.6, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.isRunning, !app.isTerminated else { return }
                if delay > 1 { self.unwatch(app.processIdentifier) }
                self.watch(app)
                for w in WindowRef.windows(of: app.processIdentifier) { self.created(w) }
            }
        }
    }

    private func watch(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard app.activationPolicy == .regular, !app.isTerminated, watchers[pid] == nil,
              pid != ProcessInfo.processInfo.processIdentifier else { return }
        let watcher = AXWatcher(pid: pid) { [weak self] _, element in
            MainActor.assumeIsolated {
                guard let self, let w = WindowRef(element: element) else { return }
                // Give the app a moment to set the window's own frame first.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.created(w) }
            }
        }
        guard let watcher else { return }
        watcher.add(kAXWindowCreatedNotification as String)
        watchers[pid] = watcher
    }

    private func unwatch(_ pid: pid_t) {
        watchers[pid]?.invalidate()
        watchers[pid] = nil
        if NSRunningApplication(processIdentifier: pid) == nil { seen[pid] = nil }
    }

    private func created(_ w: WindowRef) {
        guard isRunning, seen[w.pid]?.contains(w) != true else { return }
        seen[w.pid, default: []].insert(w)
        if let set = seen[w.pid], set.count > 64 { seen[w.pid] = set.filter { $0.position != nil } }
        guard engine.isSnappable(w), engine.record(for: w) == nil, let frame = w.frame else { return }
        let s = engine.settings.value
        let displays = engine.displays
        if s.moveNewWindowsToLastZone, let bid = w.bundleIdentifier, let entry = engine.history.value[bid],
           let display = displays.first(where: { $0.key == entry.displayKey }),
           engine.layout(for: display).id == entry.layoutID,
           entry.zones.allSatisfy({ $0 < engine.layout(for: display).count }) {
            engine.snap(w, to: entry.zones, on: display)
            return
        }
        guard s.moveNewWindowsToActiveDisplay, let target = engine.displayUnderPointer(),
              let current = ZoneDisplay.showing(frame, in: displays), current.key != target.key else { return }
        let area = target.workArea
        let size = CGSize(width: min(frame.width, area.width), height: min(frame.height, area.height))
        let origin = CGPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2)
        w.setFrame(CGRect(origin: origin, size: size))
    }
}
