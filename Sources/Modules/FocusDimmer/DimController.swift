import AppKit
import ApplicationServices
import MacToysCore

/// Runs the dimming: one overlay per display, kept directly below the active window.
///
/// Focus changes come from app activation, clicks anywhere (a global mouse monitor, which needs no
/// permission) and a light poll of the window list while dimming is on; with Accessibility the
/// focused window is read directly and switching windows inside an app is reported at once.
@MainActor
final class DimController {
    private struct Overlay {
        let panel: OverlayPanel
        let view: DimOverlayView
        /// Display frame, global top-left coordinates.
        let frame: CGRect
        var fadingOut = false
        /// Bumped on every fade, so a finished fade-out only orders out a panel nobody showed again.
        var generation = 0

        @MainActor var isShowing: Bool { panel.isVisible && !fadingOut }
    }

    private(set) var isRunning = false
    private var settings = FocusDimmerSettings()
    private var overlays: [CGDirectDisplayID: Overlay] = [:]
    private var displays: [DimDisplay] = []
    private var shown = false
    private var lastPlan: DimPlan?
    /// Windows that were above the overlay when `lastPlan` was applied (they were bright too).
    private var lastAbove: Set<CGWindowID> = []
    private var timer: Timer?
    private var mouseMonitor: Any?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var refreshScheduled = false
    private var dark = SystemAppearance.isDark
    private let focus = FocusTracker()
    private let log = Log.for("focusdimmer")

    /// Called when dimming starts or stops showing (for the settings page).
    var onShownChange: ((Bool) -> Void)?

    init() {
        focus.onChange = { [weak self] in self?.scheduleRefresh(after: 0.02) }
    }

    // MARK: Lifecycle

    func start(_ settings: FocusDimmerSettings) {
        self.settings = settings
        guard !isRunning else { refresh(); return }
        isRunning = true
        dark = SystemAppearance.isDark
        buildOverlays()
        observe()
        focus.track(NSWorkspace.shared.frontmostApplication)
        startTimer()
        refresh()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        stopTimer()
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        focus.stop()
        for overlay in overlays.values {
            overlay.panel.orderOut(nil)
            overlay.panel.close()
        }
        overlays.removeAll()
        lastPlan = nil
        lastAbove = []
        setShown(false)
    }

    /// New settings while running: re-plan, animating color and intensity changes.
    func update(_ settings: FocusDimmerSettings) {
        self.settings = settings
        if isRunning { refresh() }
    }

    // MARK: Refresh

    func scheduleRefresh(after delay: TimeInterval) {
        guard isRunning, !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }

    func refresh() {
        guard isRunning else { return }
        let snapshot = WindowSnapshot.take(excluding: Set(overlays.values.map { CGWindowID($0.panel.windowNumber) }))
        let front = frontApp()
        let decision = DimPlanner.decide(windows: snapshot.windows, front: front, displays: displays,
                                         options: settings.options, activeDisplay: NSScreen.underMouse?.displayID)
        switch decision {
        case .keep:
            break
        case .reveal:
            hide()
        case .dim(let plan):
            show(plan, snapshot: snapshot)
        }
    }

    private func frontApp() -> DimFrontApp? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        return DimFrontApp(pid: pid, focus: focus.focus(for: pid), isRegular: app.activationPolicy == .regular,
                           isFinder: app.bundleIdentifier == "com.apple.finder",
                           isExcluded: settings.excludedApps.matches(app: app))
    }

    // MARK: Presentation

    private var style: (color: CGColor, alpha: Float) {
        let alpha = DimIntensity.alpha(settings.intensity(dark: dark) / 100)
        return (settings.color.withAlpha(1).cgColor, Float(alpha))
    }

    private func show(_ plan: DimPlan, snapshot: WindowSnapshot) {
        let duration = settings.effectiveFade
        let (color, alpha) = style
        let above = snapshot.windows(above: plan.placement)
        let nowBright = Set(plan.bright).union(above)
        let wasBright = shown ? Set(lastPlan?.bright ?? []).union(lastAbove) : []
        let lost = wasBright.subtracting(nowBright)

        for (id, var overlay) in overlays {
            guard let holes = plan.holes[id] else {
                fadeOut(id)
                continue
            }
            let local = holes.map { Self.local($0, in: overlay.frame) }
            let showing = overlay.isShowing
            var fadeIn: [DimHole] = []
            if showing, !lost.isEmpty, duration > 0 {
                fadeIn = snapshot.visibleRegions(of: lost, clip: overlay.frame, excluding: holes.map(\.rect))
                    .map { Self.local($0, in: overlay.frame) }
            }
            overlay.view.apply(holes: local, fadeIn: fadeIn, color: color, alpha: alpha, duration: duration,
                               animateStyle: showing)
            // Draw the new holes before the window server moves the overlay over the old active window.
            CATransaction.flush()
            order(overlay.panel, plan.placement, snapshot: snapshot)
            if !showing {
                overlay.fadingOut = false
                overlay.generation += 1
                overlays[id] = overlay
                let panel = overlay.panel
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = duration
                    panel.animator().alphaValue = 1
                }
            }
        }
        lastPlan = plan
        lastAbove = above
        setShown(true)
    }

    private func hide() {
        for id in overlays.keys { fadeOut(id) }
        lastPlan = nil
        lastAbove = []
        setShown(false)
    }

    private func setShown(_ value: Bool) {
        guard value != shown else { return }
        shown = value
        onShownChange?(value)
    }

    /// Puts the panel right below the active window (or above all normal windows) unless it is already there.
    private func order(_ panel: OverlayPanel, _ placement: DimPlan.Placement, snapshot: WindowSnapshot) {
        let id = CGWindowID(panel.windowNumber)
        switch placement {
        case .below(let window):
            if !snapshot.isDirectlyBelow(id, window) { panel.order(.below, relativeTo: Int(window)) }
        case .front:
            if !snapshot.isAboveAllWindows(id) {
                if let top = snapshot.windows.first { panel.order(.above, relativeTo: Int(top.id)) } else { panel.orderFrontRegardless() }
            }
        }
    }

    private func fadeOut(_ id: CGDirectDisplayID) {
        guard var overlay = overlays[id], overlay.isShowing else { return }
        overlay.fadingOut = true
        overlay.generation += 1
        overlays[id] = overlay
        let generation = overlay.generation
        let panel = overlay.panel
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = settings.effectiveFade
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.overlays[id]?.generation == generation else { return }
                panel.orderOut(nil)
                panel.alphaValue = 0
            }
        })
    }

    private static func local(_ hole: DimHole, in display: CGRect) -> DimHole {
        hole.offsetBy(dx: -display.minX, dy: -display.minY)
    }

    // MARK: Displays

    private func buildOverlays() {
        for overlay in overlays.values {
            overlay.panel.orderOut(nil)
            overlay.panel.close()
        }
        overlays.removeAll()
        displays = NSScreen.screens.map { DimDisplay(id: $0.displayID, frame: $0.axFrame) }
        for screen in NSScreen.screens {
            let panel = OverlayPanel(frame: screen.frame, interactive: false, acceptsKey: false, level: .normal)
            panel.isExcludedFromWindowsMenu = true
            panel.alphaValue = 0
            let view = DimOverlayView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.autoresizingMask = [.width, .height]
            panel.contentView = view
            overlays[screen.displayID] = Overlay(panel: panel, view: view, frame: screen.axFrame)
        }
        lastPlan = nil
        lastAbove = []
        setShown(false)
    }

    // MARK: Observation

    private func observe() {
        func on(_ center: NotificationCenter, _ name: Notification.Name, _ body: @escaping @MainActor (Notification) -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { note in
                MainActor.assumeIsolated { body(note) }
            }
            observers.append((center, token))
        }
        let ws = NSWorkspace.shared.notificationCenter
        on(ws, NSWorkspace.didActivateApplicationNotification) { [weak self] note in
            guard let self else { return }
            self.focus.track(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
            self.refresh()
            // An activated app raises its windows a moment later.
            self.scheduleRefresh(after: 0.12)
        }
        for name in [NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            on(ws, name) { [weak self] _ in self?.scheduleRefresh(after: 0.05) }
        }
        on(ws, NSWorkspace.screensDidSleepNotification) { [weak self] _ in self?.stopTimer() }
        on(ws, NSWorkspace.screensDidWakeNotification) { [weak self] _ in self?.startTimer() }
        on(ws, NSWorkspace.sessionDidResignActiveNotification) { [weak self] _ in self?.stopTimer() }
        on(ws, NSWorkspace.sessionDidBecomeActiveNotification) { [weak self] _ in
            self?.startTimer()
            self?.scheduleRefresh(after: 0.1)
        }
        on(.default, NSApplication.didChangeScreenParametersNotification) { [weak self] _ in
            guard let self else { return }
            self.buildOverlays()
            self.refresh()
        }
        on(DistributedNotificationCenter.default(), Notification.Name("AppleInterfaceThemeChangedNotification")) { [weak self] _ in
            guard let self else { return }
            self.dark = SystemAppearance.isDark
            self.refresh()
        }
        // A click raises a window (or reveals the desktop); look right after it lands.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRefresh(after: 0.04) }
        }
    }

    /// Catches what no notification reports: ⌘` between windows without Accessibility, windows
    /// opening, closing, moving or resizing. One window-list read, a few times a second.
    private func startTimer() {
        guard isRunning, timer == nil else { return }
        let t = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

/// One read of the window server's list: normal-level windows front to back, plus where the
/// overlays currently sit.
struct WindowSnapshot {
    /// Normal-level windows without the overlays, front to back.
    var windows: [DimWindow] = []
    /// Window numbers at the normal level including overlays, front to back.
    var order: [CGWindowID] = []
    var overlays: Set<CGWindowID> = []

    static func take(excluding overlays: Set<CGWindowID>) -> WindowSnapshot {
        var snapshot = WindowSnapshot(overlays: overlays)
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                    as? [[String: Any]]) ?? []
        for d in list {
            guard let layer = d[kCGWindowLayer as String] as? Int, layer == 0,
                  let id = d[kCGWindowNumber as String] as? CGWindowID,
                  let pid = d[kCGWindowOwnerPID as String] as? pid_t,
                  let boundsDict = d[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: boundsDict) else { continue }
            if overlays.contains(id) {
                snapshot.order.append(id)
                continue
            }
            let alpha = d[kCGWindowAlpha as String] as? Double ?? 1
            guard alpha > 0.01, frame.width >= 40, frame.height >= 40 else { continue }
            snapshot.order.append(id)
            snapshot.windows.append(DimWindow(id: id, pid: pid, frame: frame))
        }
        return snapshot
    }

    /// Whether `overlay` sits below `window` with nothing but other overlays between them.
    func isDirectlyBelow(_ overlay: CGWindowID, _ window: CGWindowID) -> Bool {
        guard let start = order.firstIndex(of: window) else { return false }
        for id in order[(start + 1)...] {
            if id == overlay { return true }
            if !overlays.contains(id) { return false }
        }
        return false
    }

    func isAboveAllWindows(_ overlay: CGWindowID) -> Bool {
        for id in order {
            if id == overlay { return true }
            if !overlays.contains(id) { return false }
        }
        return false
    }

    /// Windows lying above the overlay for a placement (the active window and anything above it).
    func windows(above placement: DimPlan.Placement) -> Set<CGWindowID> {
        guard case .below(let id) = placement, let index = windows.firstIndex(where: { $0.id == id }) else { return [] }
        return Set(windows[...index].map(\.id))
    }

    /// The parts of these windows not covered by any window above them or by `excluding`, clipped to `clip`.
    func visibleRegions(of ids: Set<CGWindowID>, clip: CGRect, excluding: [CGRect]) -> [DimHole] {
        var result: [DimHole] = []
        for (i, w) in windows.enumerated() where ids.contains(w.id) {
            var region = [w.frame.intersection(clip)].filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
            for cover in windows[..<i].map(\.frame) + excluding where !region.isEmpty {
                region = DimPlanner.subtract(region, cover)
            }
            result += region.map { DimHole(rect: $0, window: w.frame) }
        }
        return result
    }
}

/// Reads the active app's focused window through Accessibility, when MacToys has access, and
/// reports focus changes inside the app (⌘`, clicks between its windows) as they happen.
@MainActor
final class FocusTracker {
    var onChange: (() -> Void)?
    private var pid: pid_t?
    private var watcher: AXWatcher?
    private var current: DimFrontApp.Focus = .unknown

    /// What is known about `pid`'s focused window.
    func focus(for pid: pid_t) -> DimFrontApp.Focus {
        pid == self.pid ? current : .unknown
    }

    func track(_ app: NSRunningApplication?) {
        guard let app else { return }
        let pid = app.processIdentifier
        guard pid != self.pid || watcher == nil else { return }
        stop()
        guard AXIsProcessTrusted() else { return }
        self.pid = pid
        let watcher = AXWatcher(pid: pid) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.read()
                self.onChange?()
            }
        }
        watcher?.add(kAXFocusedWindowChangedNotification)
        watcher?.add(kAXMainWindowChangedNotification)
        self.watcher = watcher
        read()
    }

    func stop() {
        watcher?.invalidate()
        watcher = nil
        pid = nil
        current = .unknown
    }

    private func read() {
        guard let pid else { current = .unknown; return }
        let app = AXUIElementCreateApplication(pid)
        // A hung app must not stall MacToys.
        AXUIElementSetMessagingTimeout(app, 0.15)
        var value: CFTypeRef?
        switch AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) {
        case .success:
            guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { current = .unknown; return }
            // CFGetTypeID checked above, so the cast cannot fail.
            let element = value as! AXUIElement
            current = MacToysCore.WindowRef(element: element, pid: pid).windowID.map { .window($0) } ?? .unknown
        case .noValue:
            current = .none
        default:
            current = .unknown
        }
    }
}

/// The system-wide appearance (MacToys' own windows may be forced light or dark in General).
enum SystemAppearance {
    static var isDark: Bool {
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        return (CFPreferencesCopyAppValue("AppleInterfaceStyle" as CFString, kCFPreferencesAnyApplication) as? String) == "Dark"
    }
}
