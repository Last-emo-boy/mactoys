import AppKit
import MacToysCore

/// Where a gesture put a window, so the next one can cycle sizes or restore it.
struct TileRecord: Equatable {
    var tile: Tile
    /// The frame the window ended up with (apps may clamp the requested one).
    var applied: CGRect
    /// Its frame before the first gesture tiled it.
    var original: CGRect
}

/// Watches trackpad scrolls and pinches through the shared event tap and turns the ones made on a
/// title bar, the Dock or the menu bar into window actions, with a live preview of the target.
///
/// Hot path: every scroll and gesture event reaches `handle`. Events of gestures that began
/// elsewhere cost a few field reads; only a gesture's first event asks the window server what is
/// under the pointer (and, the first time for a window, where its title bar ends). Previews,
/// haptics and every Accessibility call to move a window run right after the tap returns.
@MainActor
final class GestureController {
    private static let tapID = "gestures"
    private static let gestureEvents = [GestureFields.gestureType, CGEventType(rawValue: 30)!]

    private let settings: Persisted<WindowGesturesSettings>
    let overlay = GestureOverlay()
    private let probe = TitleBarProbe()
    private let log = Log.for("gestures")
    private var installed = false
    private var observers: [NSObjectProtocol] = []

    // Read by the tap.
    private var tracker = GestureTracker()
    private var cfg = WindowGesturesSettings()
    private var dockPID: pid_t?
    private var lastEvent: TimeInterval = 0

    /// The gesture being made.
    private struct Session {
        enum Surface { case window(WindowEntry, fullScreen: Bool), dock(WindowEntry), menuBar }
        var id: Int
        var surface: Surface
        var pointer: CGPoint
        var displays: [DisplaySlot]
        /// The display under the pointer.
        var display: Int
        /// The display modifier was held: swipes send the window to another display.
        var toDisplay: Bool
        /// Resolved after the tap returns.
        var context: WindowContext?
        var dockItem: DockItem?
        var dockLookedUp = false
        /// The outcome shown in the preview.
        var shown: Outcome?
        var confirming = false
    }

    /// What a gesture leads to: something done to a window, or to an app from its Dock icon.
    enum Outcome: Equatable {
        case window(WindowAction)
        case dock(DockIntent)

        var isDestructive: Bool {
            if case .window(let a) = self { return a.isDestructive }
            return false
        }
    }

    private var session: Session?
    private var sessionCounter = 0
    private var watchdog: Timer?
    private var armWork: DispatchWorkItem?
    /// Windows a gesture tiled, by window number.
    private var records: [CGWindowID: TileRecord] = [:]

    init(settings: Persisted<WindowGesturesSettings>) {
        self.settings = settings
    }

    // MARK: Lifecycle

    func start() {
        refreshConfig()
        guard observers.isEmpty else { return }
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil,
                                        queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.appActivated(app) }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil,
                                        queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDock() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.cancelSession()
                self?.overlay.tearDown()
            }
        })
    }

    func stop() {
        uninstallTap()
        for o in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(o)
            NotificationCenter.default.removeObserver(o)
        }
        observers.removeAll()
        cancelSession()
        overlay.tearDown()
        probe.clear()
        records.removeAll()
    }

    /// Re-reads the settings; installs the tap while gestures are on, removes it while paused.
    func refreshConfig() {
        let s = settings.value
        cfg = s
        // In place: a gesture in progress keeps its state; the next one starts with the new values.
        tracker.thresholds = SwipeThresholds(sensitivity: s.sensitivity)
        tracker.allowsTurns = s.cornerSwipes
        tracker.pinchThreshold = PinchRecognizer(sensitivity: s.sensitivity).threshold
        tracker.reversed = s.reverseDirections
        if s.active { installTap() } else { uninstallTap(); cancelSession() }
    }

    private func installTap() {
        guard !installed else { return }
        installed = true
        refreshDock()
        InputTap.shared.add(Self.tapID, priority: 30, events: [.scrollWheel] + Self.gestureEvents) { [weak self] type, event in
            self?.handle(type, event) ?? .pass
        }
    }

    private func uninstallTap() {
        guard installed else { return }
        installed = false
        InputTap.shared.remove(Self.tapID)
    }

    private func refreshDock() {
        dockPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
    }

    private func appActivated(_ app: NSRunningApplication?) {
        guard installed else { return }
        if app?.bundleIdentifier == "com.apple.dock" { refreshDock() }
        // Look up the front window's title bar now, so the first gesture on it needn't.
        let fallback = CGFloat(cfg.titleBarHeight)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.probe.prewarm(app, fallback: fallback) }
    }

    // MARK: Tap (hot path)

    private func handle(_ type: CGEventType, _ event: CGEvent) -> TapDecision {
        var t = tracker
        let step: GestureTracker.Step
        if type == .scrollWheel {
            step = t.handle(ScrollSample(event)) { kind in begin(kind, at: event.location, flags: event.flags) }
        } else {
            step = t.handle(TrackpadGesture(event), at: ProcessInfo.processInfo.systemUptime) { kind in
                begin(kind, at: event.location, flags: event.flags)
            }
        }
        tracker = t
        if step.consume || step.effect != nil { lastEvent = ProcessInfo.processInfo.systemUptime }
        if let effect = step.effect, let id = session?.id {
            DispatchQueue.main.async { [weak self] in self?.apply(effect, session: id) }
        }
        return step.consume ? .consume : .pass
    }

    /// A gesture is starting at `p`: decides whether it is ours and, if so, opens a session.
    private func begin(_ kind: GestureKind, at p: CGPoint, flags: CGEventFlags) -> Bool {
        // Leave scrolls during a window drag (zone cycling, Grab And Move) to whoever handles them.
        if CGEventSource.buttonState(.combinedSessionState, button: .left) { return false }
        let screens = NSScreen.screens
        guard let pointerScreen = screens.first(where: { $0.axFrame.contains(p) }) ?? screens.first else { return false }
        let displays = screens.map { DisplaySlot(id: $0.displayID, frame: $0.axFrame, work: $0.axVisibleFrame) }
        let strip = SurfaceHitTest.menuBarStrip(frame: pointerScreen.axFrame, work: pointerScreen.axVisibleFrame,
                                                safeTop: pointerScreen.safeAreaInsets.top)
        let context = SurfaceHitTest.Context(ownPID: ProcessInfo.processInfo.processIdentifier,
                                             dockPID: cfg.dockGestures ? dockPID : nil,
                                             displays: displays.map(\.frame),
                                             menuBar: cfg.menuBarFill ? strip : nil,
                                             skipFullScreen: cfg.disableInFullScreen)
        let fallback = CGFloat(cfg.titleBarHeight)
        let hit = CGWindowID(clamping: NSWindow.windowNumber(at: ScreenGeometry.toCocoa(p), belowWindowWithWindowNumber: 0))
        let surface = SurfaceHitTest.surface(at: p, hit: hit, entries: WindowEntry.onScreen(), context: context) { [probe] e in
            probe.band(for: e, fallback: fallback)
        }
        let sessionSurface: Session.Surface
        switch (surface, kind) {
        case let (.titleBar(e, fullScreen), _):
            guard !cfg.excludedApps.matches(app: NSRunningApplication(processIdentifier: e.pid)) else { return false }
            sessionSurface = .window(e, fullScreen: fullScreen)
        case let (.dock(e), .swipe):
            sessionSurface = .dock(e)
        case (.menuBar, .swipe):
            sessionSurface = .menuBar
        default:
            return false
        }
        if session != nil { cancelSession() }
        sessionCounter &+= 1
        let modifier = cfg.displayModifier.modifiers
        session = Session(id: sessionCounter, surface: sessionSurface, pointer: p, displays: displays,
                          display: screens.firstIndex(of: pointerScreen) ?? 0,
                          toDisplay: !modifier.isEmpty && Modifiers(flags).contains(modifier))
        startWatchdog()
        return true
    }

    // MARK: Effects (main thread, right after the tap)

    private func apply(_ effect: GestureTracker.Effect, session id: Int) {
        guard session?.id == id else { return }
        switch effect {
        case .swipeBegan, .pinchBegan:
            break
        case .strokeChanged(let stroke):
            preview(stroke.flatMap(swipeAction))
        case .swipeEnded(let stroke):
            let action = stroke.flatMap(swipeAction)
            finish(action)
        case .pinchChanged(let intent):
            pinchChanged(intent)
        case .pinchEnded(let intent):
            let held = tracker.pinch.holdProgress(at: ProcessInfo.processInfo.systemUptime, hold: cfg.confirmHold) >= 1
            let action = intent.flatMap(pinchAction)
            if let action, action.isDestructive, cfg.confirmClose, !held {
                finish(nil)
            } else {
                finish(action)
            }
        case .doubleTap:
            finish(doubleTapAction(), flash: true)
        case .swipeCancelled, .pinchCancelled:
            finish(nil)
        }
    }

    private func swipeAction(_ stroke: Stroke) -> Outcome? {
        guard var s = session else { return nil }
        switch s.surface {
        case .window:
            guard let ctx = windowContext() else { return nil }
            return GestureResolver.swipe(stroke, toDisplay: s.toDisplay, window: ctx, options: cfg.options).map(Outcome.window)
        case .menuBar:
            guard stroke.primary == .down, let ctx = windowContext() else { return nil }
            return .window(GestureResolver.tile(.fill, ctx, cfg.options))
        case .dock(let e):
            if !s.dockLookedUp {
                s.dockItem = DockItem.at(s.pointer)
                s.dockLookedUp = true
                session = s
            }
            let edge = DockEdge.of(dock: e.frame, screen: s.displays[s.display].frame)
            guard s.dockItem != nil, let intent = edge.intent(for: stroke.primary) else { return nil }
            switch intent {
            case .show: return cfg.dockUp == .nothing ? nil : .dock(.show)
            case .hide: return cfg.dockDown == .nothing ? nil : .dock(.hide)
            }
        }
    }

    private func pinchAction(_ intent: PinchIntent) -> Outcome? {
        guard let ctx = windowContext() else { return nil }
        return GestureResolver.pinch(intent, window: ctx, options: cfg.options).map(Outcome.window)
    }

    private func doubleTapAction() -> Outcome? {
        guard let ctx = windowContext() else { return nil }
        return GestureResolver.doubleTap(window: ctx, options: cfg.options).map(Outcome.window)
    }

    /// The window the gesture is about, with what a previous gesture did to it.
    private func windowContext() -> WindowContext? {
        guard var s = session else { return nil }
        if let ctx = s.context { return ctx }
        let frame: CGRect, id: CGWindowID?, fullScreen: Bool
        switch s.surface {
        case let .window(e, fs):
            frame = e.frame; id = e.id; fullScreen = fs
        case .menuBar:
            guard let w = WindowRef.focused(), w.pid != ProcessInfo.processInfo.processIdentifier,
                  !cfg.excludedApps.matches(app: w.app), let f = w.frame else { return nil }
            frame = f; id = w.windowID; fullScreen = w.isFullScreen
        case .dock:
            return nil
        }
        var record = id.flatMap { records[$0] }
        if let r = record, !r.applied.isNear(frame) {
            record = nil                   // moved or resized since: no longer in that tile
            if let id { records[id] = nil }
        }
        let display = s.displays.indices.max { s.displays[$0].frame.intersection(frame).area < s.displays[$1].frame.intersection(frame).area } ?? s.display
        let ctx = WindowContext(frame: frame, tile: record?.tile, original: record?.original, display: display,
                                displays: s.displays, isFullScreen: fullScreen)
        s.context = ctx
        session = s
        return ctx
    }

    // MARK: Preview

    private func preview(_ action: Outcome?) {
        guard var s = session else { return }
        let changed = action != s.shown
        s.shown = action
        s.confirming = false
        session = s
        armWork?.cancel()
        guard changed else { return }
        guard let action else { overlay.hide(); return }
        if cfg.haptics { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        guard cfg.showPreview, let (content, screen) = overlayContent(for: action) else { overlay.hide(); return }
        overlay.show(content, on: screen)
    }

    private func pinchChanged(_ intent: PinchIntent?) {
        guard let intent, let action = pinchAction(intent) else { preview(nil); return }
        guard action.isDestructive, cfg.confirmClose, var s = session, let ctx = s.context else { preview(action); return }
        s.shown = action
        s.confirming = true
        session = s
        let quitting = action == .window(.quit)
        let name = confirmName(quitting: quitting)
        let center = ctx.frame.center
        let screen = s.displays[ctx.display].frame
        overlay.show(.confirm(center: center, armed: false, quitting: quitting, name: name), on: screen)
        overlay.runProgress(over: cfg.confirmHold)
        armWork?.cancel()
        let id = s.id, haptics = cfg.haptics
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.session?.id == id, self.session?.confirming == true else { return }
            if haptics { NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now) }
            self.overlay.show(.confirm(center: center, armed: true, quitting: quitting, name: name), on: screen)
        }
        armWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + cfg.confirmHold, execute: work)
    }

    private func confirmName(quitting: Bool) -> String {
        guard case let .window(e, _)? = session?.surface else { return "" }
        let app = NSRunningApplication(processIdentifier: e.pid)?.localizedName ?? ""
        if quitting { return app }
        let title = WindowInfo.onScreen().first { $0.id == e.id }?.title ?? ""
        return title.isEmpty ? app : title
    }

    /// The preview for an outcome and the display it shows on.
    private func overlayContent(for outcome: Outcome) -> (OverlayContent, CGRect)? {
        guard let s = session else { return nil }
        let action: WindowAction
        switch outcome {
        case .window(let a): action = a
        case .dock(let intent):
            guard case .dock(let e) = s.surface, let item = s.dockItem else { return nil }
            let anchor = item.frame ?? e.frame
            let edge = DockEdge.of(dock: e.frame, screen: s.displays[s.display].frame)
            let center: CGPoint = switch edge {
            case .bottom: CGPoint(x: anchor.midX, y: anchor.minY - 34)
            case .left: CGPoint(x: anchor.maxX + 120, y: anchor.midY)
            case .right: CGPoint(x: anchor.minX - 120, y: anchor.midY)
            }
            return (.badge(center: center, title: GestureTitles.dock(intent, app: item.name, settings: cfg),
                           symbol: GestureTitles.symbol(intent, settings: cfg)), s.displays[s.display].frame)
        }
        guard let ctx = s.context else { return nil }
        let blocked = blockedByAutoTiling(action, ctx)
        let displayIndex: Int
        if case .moveToDisplay(let i, _, _) = action { displayIndex = i } else { displayIndex = ctx.display }
        let screen = s.displays[displayIndex].frame
        if blocked {
            return (.badge(center: ctx.frame.center, title: String(localized: "Auto Tiling arranges this display"),
                           symbol: "rectangle.split.2x2"), s.displays[ctx.display].frame)
        }
        switch action {
        case let .tile(tile, frame):
            let cells = tile.cells(in: s.displays[ctx.display].work, gap: cfg.options.gap)
            return (.target(frame: frame, title: tile.title, tile: tile, symbol: nil, cells: cells), screen)
        case .restore(let frame):
            return (.target(frame: frame, title: GestureTitles.title(action), tile: nil, symbol: "arrow.uturn.backward", cells: []), screen)
        case let .moveToDisplay(i, frame, tile):
            let name = NSScreen.screens.first { $0.displayID == s.displays[i].id }?.localizedName ?? ""
            let title = name.isEmpty ? String(localized: "Move to the other display")
                : String(localized: "Move to \(name)", comment: "Window Gestures preview: the name of the display the window goes to")
            return (.target(frame: frame, title: title, tile: tile, symbol: "display", cells: []), screen)
        case .enterFullScreen:
            return (.target(frame: s.displays[ctx.display].frame.insetBy(dx: 6, dy: 6), title: GestureTitles.title(action),
                            tile: nil, symbol: GestureTitles.symbol(action), cells: []), screen)
        case .minimize, .close, .quit, .exitFullScreen:
            return (.badge(center: ctx.frame.center, title: GestureTitles.title(action), symbol: GestureTitles.symbol(action)), screen)
        }
    }

    // MARK: Acting

    /// The gesture is over: performs `action` (if any) and clears the session.
    private func finish(_ action: Outcome?, flash: Bool = false) {
        guard let s = session else { return }
        armWork?.cancel()
        stopWatchdog()
        let shownBadge = s.shown != nil
        if let action, case .window(let a) = action, let ctx = s.context, blockedByAutoTiling(a, ctx) {
            // Auto Tiling keeps this display arranged: the window stays put, and the note stays a moment.
            if cfg.showPreview, let (content, screen) = overlayContent(for: action) {
                overlay.flash(content, on: screen, for: 1.1)
            } else {
                overlay.hide()
                HUD.show("Auto Tiling arranges this display", symbol: "rectangle.split.2x2", duration: 1.1)
            }
        } else if let action {
            if flash, cfg.showPreview, let (content, screen) = overlayContent(for: action) {
                overlay.flash(content, on: screen, for: 0.45)
            } else {
                overlay.hide(after: shownBadge ? 0.08 : 0)
            }
            perform(action, in: s)
        } else {
            overlay.hide()
        }
        session = nil
    }

    private func perform(_ outcome: Outcome, in s: Session) {
        let action: WindowAction
        switch outcome {
        case .window(let a): action = a
        case .dock(let intent):
            guard let item = s.dockItem, !cfg.excludedApps.matchesApp(named: item.name, url: item.bundleURL) else { return }
            switch (intent, cfg.dockUp, cfg.dockDown) {
            case (.show, .showWindows, _): DockActions.showWindows(item)
            case (.show, .appExpose, _): DockActions.expose(item)
            case (.hide, _, .hide): DockActions.hide(item)
            case (.hide, _, .minimize): DockActions.minimizeAll(item)
            default: break
            }
            return
        }
        guard let ctx = s.context, !blockedByAutoTiling(action, ctx), let w = window(for: s) else { return }
        AXUIElementSetMessagingTimeout(w.element, 0.5)
        let id = w.windowID
        switch action {
        case let .tile(tile, frame):
            let original = id.flatMap { records[$0]?.original } ?? ctx.frame
            w.setFrame(frame)
            w.raise()
            if let id { records[id] = TileRecord(tile: tile, applied: w.frame ?? frame, original: original) }
        case .restore(let frame):
            w.setFrame(frame)
            if let id { records[id] = nil }
        case let .moveToDisplay(_, frame, tile):
            let original = id.flatMap { records[$0]?.original }
            w.setFrame(frame)
            w.raise()
            if let id {
                if let tile, let original { records[id] = TileRecord(tile: tile, applied: w.frame ?? frame, original: original) }
                else { records[id] = nil }
            }
        case .minimize:
            w.minimize()
        case .close:
            w.close()
        case .quit:
            NSRunningApplication(processIdentifier: w.pid)?.terminate()
        case .enterFullScreen:
            w.element.set("AXFullScreen", kCFBooleanTrue)
        case .exitFullScreen:
            w.element.set("AXFullScreen", kCFBooleanFalse)
        }
        log.debug("gesture action \(String(describing: action), privacy: .public)")
    }

    /// The Accessibility window behind the session.
    private func window(for s: Session) -> WindowRef? {
        switch s.surface {
        case let .window(e, _):
            guard AXIsProcessTrusted() else {
                HUD.show("Accessibility permission needed", symbol: "exclamationmark.shield")
                PermissionCenter.shared.request(.accessibility)
                return nil
            }
            // A hung app answers within half a second or not at all.
            let axApp = AXUIElementCreateApplication(e.pid)
            AXUIElementSetMessagingTimeout(axApp, 0.5)
            let list: [AXUIElement] = axApp.ax(kAXWindowsAttribute) ?? []
            return list.lazy.map { WindowRef(element: $0, pid: e.pid) }.first { $0.windowID == e.id }
        case .menuBar:
            return WindowRef.focused()
        case .dock:
            return nil
        }
    }

    /// Moving or resizing a window on (or onto) a display Auto Tiling arranges is left to it.
    private func blockedByAutoTiling(_ action: WindowAction, _ ctx: WindowContext) -> Bool {
        guard let manages = Services.autoTilingManagesDisplay else { return false }
        switch action {
        case .tile, .restore:
            return manages(ctx.displays[ctx.display].id)
        case .moveToDisplay(let i, _, _):
            return manages(ctx.displays[ctx.display].id) || manages(ctx.displays[i].id)
        case .minimize, .close, .quit, .enterFullScreen, .exitFullScreen:
            return false
        }
    }

    // MARK: Session housekeeping

    private func cancelSession() {
        armWork?.cancel()
        stopWatchdog()
        if session != nil { overlay.hide() }
        session = nil
        _ = tracker.expire()
    }

    /// An end event can get lost (the tap was disabled while the main thread was busy): a gesture
    /// with no event for 1.5 s is cancelled, so the preview never sticks.
    private func startWatchdog() {
        lastEvent = ProcessInfo.processInfo.systemUptime
        guard watchdog == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if ProcessInfo.processInfo.systemUptime - self.lastEvent > 1.5 { self.cancelSession() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }

    // MARK: Direct actions (URL actions)

    /// Applies a gesture to the focused window, as if it were made on its title bar.
    func perform(gesture: NamedGesture) -> Bool {
        guard AXIsProcessTrusted() else {
            HUD.show("Accessibility permission needed", symbol: "exclamationmark.shield")
            PermissionCenter.shared.request(.accessibility)
            return true
        }
        guard let w = WindowRef.focused(), w.pid != ProcessInfo.processInfo.processIdentifier, let frame = w.frame,
              let id = w.windowID else { return false }
        if session != nil { cancelSession() }
        let screens = NSScreen.screens
        let displays = screens.map { DisplaySlot(id: $0.displayID, frame: $0.axFrame, work: $0.axVisibleFrame) }
        let entry = WindowEntry(id: id, pid: w.pid, layer: 0, frame: frame)
        sessionCounter &+= 1
        let display = displays.indices.max { displays[$0].frame.intersection(frame).area < displays[$1].frame.intersection(frame).area } ?? 0
        session = Session(id: sessionCounter, surface: .window(entry, fullScreen: w.isFullScreen), pointer: frame.center,
                          displays: displays, display: display, toDisplay: gesture.toDisplay)
        let action: Outcome?
        switch gesture {
        case .swipe(let stroke, _): action = swipeAction(stroke)
        case .pinch(let intent): action = pinchAction(intent)
        case .doubleTap: action = doubleTapAction()
        }
        finish(action, flash: true)
        return true
    }
}

/// A gesture named in a URL action: `swipe-left`, `swipe-up-left`, `display-right`, `pinch-in`, `double-tap`…
enum NamedGesture: Equatable {
    case swipe(Stroke, toDisplay: Bool)
    case pinch(PinchIntent)
    case doubleTap

    var toDisplay: Bool {
        if case .swipe(_, let d) = self { return d }
        return false
    }

    init?(_ name: String) {
        let parts = name.lowercased().split(separator: "-").map(String.init)
        switch parts.first {
        case "pinch":
            guard parts.count == 2 else { return nil }
            switch parts[1] {
            case "in": self = .pinch(.pinchIn)
            case "out": self = .pinch(.pinchOut)
            default: return nil
            }
        case "double":
            guard parts == ["double", "tap"] else { return nil }
            self = .doubleTap
        case "swipe", "display":
            let dirs = parts.dropFirst().compactMap(SwipeDirection.init(rawValue:))
            guard dirs.count == parts.count - 1, (1...2).contains(dirs.count) else { return nil }
            if dirs.count == 2, dirs[0].isHorizontal == dirs[1].isHorizontal { return nil }
            // "swipe-up-left" names the corner; the stroke is the same either way round.
            self = .swipe(Stroke(dirs[0], turn: dirs.count == 2 ? dirs[1] : nil), toDisplay: parts[0] == "display")
        default:
            return nil
        }
    }
}

extension CGRect {
    /// Same frame give or take a few points (apps round sizes to their own increments).
    func isNear(_ other: CGRect, tolerance: CGFloat = 3) -> Bool {
        abs(minX - other.minX) <= tolerance && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }
}

extension Array where Element == String {
    /// Like `matches(app:)`, for an app that may not be running (a Dock icon).
    func matchesApp(named name: String, url: URL?) -> Bool {
        let bundleID = url.flatMap { Bundle(url: $0)?.bundleIdentifier }?.lowercased() ?? ""
        let lower = name.lowercased()
        return contains { entry in
            let e = entry.lowercased()
            return e == bundleID || (!lower.isEmpty && lower.contains(e))
        }
    }
}
