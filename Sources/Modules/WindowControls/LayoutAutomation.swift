import AppKit
import MacToysCore

/// Follows the display arrangement: saves the windows of an arrangement when one of its displays
/// goes away, and restores a layout when its arrangement comes back (docking a laptop).
///
/// When displays change, macOS has already moved the windows, so the arrangement being left is
/// read from a background snapshot. Snapshots ask only the window server (no app is messaged):
/// every few seconds while automatic saving is on, before sleep, and after Window Controls moves
/// a window.
@MainActor
final class LayoutAutomation {
    private let settings: Persisted<WindowControlsSettings>
    /// Restores a layout on behalf of the automation (the module reports it with a HUD).
    var restore: ((SavedLayout) -> Void)?

    private var displays: [LayoutDisplay] = []
    private var snapshot: SavedLayout?
    private var timer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var changeWork: DispatchWorkItem?
    private var snapshotWork: DispatchWorkItem?
    private let log = Log.for("windowcontrols")
    private(set) var isRunning = false

    /// Seconds between background snapshots.
    private static let interval: TimeInterval = 10

    init(settings: Persisted<WindowControlsSettings>) {
        self.settings = settings
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        displays = Screens.layoutDisplays()
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { [weak self] in
            self?.screensChanged()
        }
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            observe(ws, name) { [weak self] in self?.takeSnapshot() }
        }
        sync()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        timer?.invalidate()
        timer = nil
        changeWork?.cancel()
        changeWork = nil
        snapshotWork?.cancel()
        snapshotWork = nil
        snapshot = nil
    }

    /// Starts or stops background snapshots to match the settings.
    func sync() {
        guard isRunning, settings.value.autoSaveOnDisconnect else {
            timer?.invalidate()
            timer = nil
            snapshot = nil
            return
        }
        guard timer == nil else { return }
        let t = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.takeSnapshot() }
        }
        t.tolerance = 2
        RunLoop.main.add(t, forMode: .common)
        timer = t
        takeSnapshot()
    }

    /// Takes a snapshot a moment after windows moved (debounced).
    func windowsMoved() {
        guard isRunning, settings.value.autoSaveOnDisconnect else { return }
        snapshotWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.takeSnapshot() }
        snapshotWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func takeSnapshot() {
        guard isRunning, settings.value.autoSaveOnDisconnect else { return }
        // Only while the arrangement is still the one we know: right after a change the windows may
        // already have been pushed around by macOS.
        guard DisplayArrangement.key(Screens.layoutDisplays()) == DisplayArrangement.key(displays) else { return }
        let found = LayoutCapture.found(excluded: settings.value.excludedApps, accessibility: false)
        snapshot = SavedLayout.assemble(name: DisplayArrangement.name(of: displays), windows: found, displays: displays)
    }

    private func screensChanged() {
        changeWork?.cancel()
        // Displays report in pieces (resolution, then arrangement); act once they have settled.
        let work = DispatchWorkItem { [weak self] in self?.arrangementSettled() }
        changeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func arrangementSettled() {
        guard isRunning else { return }
        let old = displays
        let new = Screens.layoutDisplays()
        let oldKey = DisplayArrangement.key(old), newKey = DisplayArrangement.key(new)
        guard oldKey != newKey else { return }
        displays = new
        let s = settings.value
        let lostDisplay = !Set(old.map(\.key)).isSubset(of: Set(new.map(\.key)))
        if s.autoSaveOnDisconnect, lostDisplay, let snap = snapshot, snap.arrangementKey == oldKey, !snap.windows.isEmpty {
            saveAutomatic(snap)
        }
        snapshot = nil
        if s.autoRestoreLayouts, let layout = settings.value.newestLayout(for: newKey, autoRestoreOnly: true) {
            log.info("Display arrangement returned; restoring \(layout.name, privacy: .public)")
            // Give apps a moment to finish their own moves onto the new displays.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, self.isRunning,
                      DisplayArrangement.key(Screens.layoutDisplays()) == newKey else { return }
                self.restore?(layout)
                self.windowsMoved()
            }
        } else {
            windowsMoved()
        }
    }

    /// Keeps one automatic layout per arrangement: the newest replaces the previous one.
    private func saveAutomatic(_ snap: SavedLayout) {
        var layout = snap
        layout.isAutomatic = true
        layout.autoRestore = true
        layout.created = Date()
        settings.update { s in
            if let i = s.layouts.firstIndex(where: { $0.isAutomatic && $0.arrangementKey == layout.arrangementKey }) {
                layout.id = s.layouts[i].id
                layout.name = s.layouts[i].name
                s.layouts[i] = layout
            } else {
                s.layouts.append(layout)
            }
        }
        log.info("Saved the windows of \(layout.name, privacy: .public) as the displays changed")
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping @MainActor () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { action() }
        }
        observers.append((center, token))
    }
}
