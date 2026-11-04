import AppKit
import ApplicationServices
import MacToysCore

/// Auto Tiling's runtime: knows every window, keeps the board, and turns any change (a window
/// opening, closing, minimizing; a Space or display change; a setting) into one coalesced
/// re-tile whose frame changes are applied in a single batch off the main thread.
///
/// Rectangles are in global top-left coordinates (Accessibility space) throughout.
@MainActor
final class TilingEngine {
    let settings: Persisted<AutoTilingSettings>
    /// Bundle id → smallest size its windows accept (stays on this Mac).
    let learned: Persisted<[String: LearnedSize]>
    let status = TilingStatus()
    let highlight = HighlightOverlay()
    let spotlight = SpotlightOverlay()

    private lazy var tracker = WindowTracker(engine: self)
    private let applier = FrameApplier()
    private let stageManager = StageManagerMonitor()
    private let log = Log.for("autotile")
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    private struct SplitOverride {
        var kind: TileLayoutKind
        var shape: DisplayShape
        var main: MainSize
        var weights: [[Int]: [Double]]
    }

    private struct OwnMove {
        var frame: CGRect
        var until: TimeInterval
    }

    struct CleanSpace: Equatable {
        var display: String
        var window: CGWindowID
    }

    /// What lies under the pointer while a tiled window is dragged.
    enum DropTarget: Equatable {
        /// Another tile: drop to swap with its window.
        case tile(display: String, window: CGWindowID, frame: CGRect)
        /// A display without tiled windows: drop to move there.
        case display(key: String, area: CGRect)
    }

    /// A tiled window under the pointer.
    struct Hit: Equatable {
        var display: String
        var window: CGWindowID
        var frame: CGRect
        var radius: CGFloat
    }

    private(set) var isRunning = false
    private(set) var displays: [TileDisplay] = []
    private(set) var board = TileBoard()
    private var windows: [CGWindowID: TrackedWindow] = [:]
    private var ids: [WindowRef: CGWindowID] = [:]
    /// On-screen windows that are never tiled (dialogs, panels…) or not listed by their app yet;
    /// the value is when to look again (infinity: never).
    private var ignored: [CGWindowID: TimeInterval] = [:]
    private var overrides: [String: SplitOverride] = [:]
    private var zoomed: [String: CGWindowID] = [:]
    private(set) var cleanSpace: CleanSpace?
    private(set) var noPeek = false
    private(set) var focusedID: CGWindowID?
    private var focusedFrame: CGRect?
    private var lastActive: [String: CGWindowID] = [:]
    private(set) var plans: [String: TilePlan] = [:]
    private(set) var present: Set<CGWindowID> = []
    private var ownMoves: [CGWindowID: OwnMove] = [:]
    private var retries: [CGWindowID: Int] = [:]
    private var dirty: Set<CGWindowID> = []
    private var retileWork: DispatchWorkItem?
    private var retileDeadline: TimeInterval = 0
    private var screensWork: DispatchWorkItem?
    private var focusWork: DispatchWorkItem?
    private var waitingForMouseUp = false
    private var watchdog: Timer?
    /// The last app other than MacToys that was frontmost (for the "Tile <app>" switch).
    private(set) var lastExternalApp: NSRunningApplication?

    /// Called after every re-tile and focus change (hover features refresh their hit areas).
    var onLayout: (() -> Void)?

    init(settings: Persisted<AutoTilingSettings>, learned: Persisted<[String: LearnedSize]>) {
        self.settings = settings
        self.learned = learned
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ownPID { lastExternalApp = app }
    }

    /// Tiling arranges windows right now: running, not paused, Stage Manager off.
    var isActive: Bool { isRunning && !settings.value.paused && !stageManager.isOn }

    var isStageManagerOn: Bool { stageManager.isOn }

    /// For FancyZones: whether Auto Tiling arranges this display.
    func manages(displayID: CGDirectDisplayID) -> Bool {
        isActive && displays.contains { $0.displayID == displayID }
    }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private static var leftButtonDown: Bool { CGEventSource.buttonState(.combinedSessionState, button: .left) }

    // MARK: Lifecycle

    /// Starts watching and tiling. Does nothing without Accessibility (call again once granted).
    func start() {
        guard !isRunning, AXIsProcessTrusted() else { return }
        isRunning = true
        displays = TileDisplay.current()
        stageManager.start { [weak self] on in self?.stageManagerChanged(on) }
        tracker.start()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.watch() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
        updateFocus()
        retileNow()
        log.info("Auto Tiling started")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        tracker.stop()
        stageManager.stop()
        watchdog?.invalidate()
        watchdog = nil
        for work in [retileWork, screensWork, focusWork] { work?.cancel() }
        retileWork = nil
        screensWork = nil
        focusWork = nil
        highlight.tearDown()
        spotlight.tearDown()
        board = TileBoard()
        windows.removeAll()
        ids.removeAll()
        ignored.removeAll()
        overrides.removeAll()
        zoomed.removeAll()
        cleanSpace = nil
        noPeek = false
        focusedID = nil
        focusedFrame = nil
        lastActive.removeAll()
        plans.removeAll()
        present.removeAll()
        ownMoves.removeAll()
        retries.removeAll()
        dirty.removeAll()
        waitingForMouseUp = false
        learned.flush()
        publish()
        onLayout?()
        log.info("Auto Tiling stopped")
    }

    /// Accessibility was just granted: observers made before don't deliver.
    func accessibilityGranted() {
        if isRunning { tracker.rewatchAll(); setNeedsRetile() } else { start() }
    }

    func settingsChanged(from old: AutoTilingSettings, to new: AutoTilingSettings) {
        guard isRunning else { publish(); return }
        // A new layout or main size starts from even splits.
        for d in displays where old.layout(for: d.key) != new.layout(for: d.key) { overrides[d.key] = nil }
        if new.paused && !old.paused {
            // Pausing leaves every window where it is.
            zoomed.removeAll()
            cleanSpace = nil
        }
        setNeedsRetile(delay: 0.02)
        updateOverlays()
        publish()
    }

    private func stageManagerChanged(_ on: Bool) {
        log.info("Stage Manager \(on ? "on" : "off", privacy: .public)")
        if on {
            zoomed.removeAll()
            cleanSpace = nil
            plans.removeAll()
            updateOverlays()
            publish()
        } else {
            setNeedsRetile(delay: 0.2)
        }
    }

    /// Every two seconds: the Dock or menu bar changed size without telling anyone, or a
    /// notification was missed.
    private func watch() {
        guard isRunning else { return }
        let fresh = TileDisplay.current()
        if fresh != displays { screensChanged() }
        let t = Self.now
        ownMoves = ownMoves.filter { $0.value.until > t }
    }

    // MARK: Events (from the tracker)

    /// Coalesces requests: one re-tile runs at the earliest deadline asked for.
    func setNeedsRetile(delay: TimeInterval = 0.04) {
        guard isRunning else { return }
        let deadline = Self.now + delay
        if let work = retileWork {
            if deadline >= retileDeadline { return }      // one is already coming sooner
            work.cancel()
        }
        let work = DispatchWorkItem { [weak self] in self?.retileNow() }
        retileWork = work
        retileDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func windowCreated(_ ref: WindowRef) {
        guard isRunning, ref.pid != ownPID, let app = NSRunningApplication(processIdentifier: ref.pid),
              app.activationPolicy == .regular else { return }
        AXUIElementSetMessagingTimeout(ref.element, 0.3)
        guard let id = ref.windowID else { return }
        if let again = ignored[id], again != .infinity { ignored[id] = nil }
        guard ignored[id] == nil else { return }
        track(ref, id: id, app: app)
        setNeedsRetile()
        // It may not be on screen yet: look again while it appears.
        for delay in [0.35, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.setNeedsRetile() }
        }
    }

    func windowEvent(_ notification: String, _ ref: WindowRef) {
        guard isRunning else { return }
        switch notification {
        case kAXUIElementDestroyedNotification:
            guard let id = ids[ref] else { return }
            // Some apps recycle elements: trust the destroy only when the window is really gone.
            AXUIElementSetMessagingTimeout(ref.element, 0.2)
            if ref.frame == nil {
                forget(id)
                setNeedsRetile(delay: 0.01)
            }
        case kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification:
            guard let id = ids[ref] ?? ref.windowID, windows[id] != nil else { setNeedsRetile(); return }
            windows[id]?.isMinimized = notification == kAXWindowMiniaturizedNotification
            setNeedsRetile(delay: 0.01)
        case kAXWindowMovedNotification, kAXWindowResizedNotification:
            guard let id = ids[ref] else {
                // An untracked window may have just become tileable (left full screen, grew).
                setNeedsRetile(delay: 0.2)
                return
            }
            if let own = ownMoves[id], own.until > Self.now { return }
            dirty.insert(id)
            setNeedsRetile(delay: 0.06)
        default:
            break
        }
    }

    func appTerminated(_ pid: pid_t) {
        guard isRunning else { return }
        for w in windows.values where w.pid == pid { forget(w.id) }
        if lastExternalApp?.processIdentifier == pid { lastExternalApp = nil }
        setNeedsRetile(delay: 0.01)
    }

    func appActivated(_ app: NSRunningApplication?) {
        if let app, app.processIdentifier != ownPID { lastExternalApp = app }
        focusChanged()
    }

    func focusChanged() {
        guard isRunning else { return }
        focusWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.updateFocus() }
        focusWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: work)
        // Closing a window moves focus: re-flow even when the app never reports the close.
        setNeedsRetile(delay: 0.15)
    }

    func spaceChanged() {
        guard isRunning else { return }
        // The shared window is on the Space we left.
        if let c = cleanSpace {
            cleanSpace = nil
            if zoomed[c.display] == c.window { zoomed[c.display] = nil }
        }
        setNeedsRetile(delay: 0.05)
        focusChanged()
    }

    func screensChanged() {
        guard isRunning else { return }
        screensWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.displaysChanged() }
        screensWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func displaysChanged() {
        guard isRunning else { return }
        let fresh = TileDisplay.current()
        let keys = Set(fresh.map(\.key))
        let gone = displays.map(\.key).filter { !keys.contains($0) }
        displays = fresh
        // macOS moved the windows of a display that went away; read where to.
        dirty.formUnion(windows.keys)
        refreshDirty()
        for key in gone {
            let first = board.slots[key]?.first?.first.flatMap { windows[$0]?.frame }
            let target = first.flatMap { TileDisplay.showing($0, in: fresh) } ?? fresh.first { $0.isMain } ?? fresh.first
            if let target { board.merge(display: key, into: target.key) }
            overrides[key] = nil
            zoomed[key] = nil
            lastActive[key] = nil
            if cleanSpace?.display == key { cleanSpace = nil }
        }
        retileNow()
    }

    // MARK: Tracking

    /// Windows of `pid` as Accessibility lists them, with a short timeout for hung apps.
    private static func axWindows(of pid: pid_t, timeout: Float = 0.3) -> [WindowRef] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        let list: [AXUIElement] = app.ax(kAXWindowsAttribute) ?? []
        return list.map { element in
            AXUIElementSetMessagingTimeout(element, timeout)
            return WindowRef(element: element, pid: pid)
        }
    }

    /// The app's observer was (re)made: watch its tracked windows for closing again.
    func watcherReplaced(pid: pid_t) {
        for w in windows.values where w.pid == pid { tracker.watchDestroy(w.ref) }
    }

    /// Finds minimized windows not seen yet (they are off screen, so discovery misses them).
    func trackMinimizedWindows() {
        guard isRunning else { return }
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && !app.isTerminated && app.processIdentifier != ownPID && !app.isHidden {
            for ref in Self.axWindows(of: app.processIdentifier, timeout: 0.15) where ref.isMinimized {
                guard let id = ref.windowID, windows[id] == nil, ignored[id] != .infinity else { continue }
                track(ref, id: id, app: app)
            }
        }
    }

    /// Starts tracking a window that may be tiled; marks it ignored when it never will be.
    @discardableResult
    private func track(_ ref: WindowRef, id: CGWindowID, app: NSRunningApplication) -> Bool {
        if windows[id] != nil { return true }
        guard let frame = ref.frame else { return false }
        let traits = WindowTraits(role: ref.role, subrole: ref.subrole, isResizable: ref.isResizable,
                                  isFullScreen: ref.isFullScreen, isMinimized: ref.isMinimized, size: frame.size,
                                  bundleID: app.bundleIdentifier, appName: app.localizedName ?? "",
                                  isOwnApp: app.processIdentifier == ownPID)
        guard frame.width >= 40, frame.height >= 40 else { return false }   // still opening
        if TileEligibility.evaluate(traits, excludedApps: []) == .never {
            ignored[id] = .infinity
            return false
        }
        let toolbar = ref.element.children.contains { $0.role == "AXToolbar" }
        windows[id] = TrackedWindow(ref: ref, id: id, pid: ref.pid, bundleID: app.bundleIdentifier,
                                    appName: app.localizedName ?? "", frame: frame, isMinimized: traits.isMinimized,
                                    isFullScreen: traits.isFullScreen, cornerRadius: WindowCorners.radius(hasToolbar: toolbar),
                                    firstSeen: Self.now)
        ids[ref] = id
        tracker.watchDestroy(ref)
        return true
    }

    private func forget(_ id: CGWindowID) {
        if let w = windows.removeValue(forKey: id) { ids[w.ref] = nil }
        board.remove(id)
        ownMoves[id] = nil
        retries[id] = nil
        dirty.remove(id)
        present.remove(id)
        for (key, z) in zoomed where z == id { zoomed[key] = nil }
        for (key, a) in lastActive where a == id { lastActive[key] = nil }
        if cleanSpace?.window == id { cleanSpace = nil }
        if focusedID == id { focusedID = nil; focusedFrame = nil }
    }

    /// Finds on-screen windows we haven't seen (a Space switch, an app that just launched).
    private func discover(_ onScreen: [WindowInfo]) {
        let t = Self.now
        var unknown: [pid_t: Set<CGWindowID>] = [:]
        for info in onScreen where windows[info.id] == nil && info.pid != ownPID {
            if let again = ignored[info.id], again > t { continue }
            unknown[info.pid, default: []].insert(info.id)
        }
        for (pid, wanted) in unknown {
            guard let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular else {
                for id in wanted { ignored[id] = .infinity }
                continue
            }
            for ref in Self.axWindows(of: pid) {
                guard let id = ref.windowID, wanted.contains(id) else { continue }
                track(ref, id: id, app: app)
            }
            // Windows the app doesn't list (yet): look again in a while.
            for id in wanted where windows[id] == nil && ignored[id] == nil { ignored[id] = t + 2 }
        }
        if ignored.count > 1500 {
            let visible = Set(onScreen.map(\.id))
            ignored = ignored.filter { visible.contains($0.key) }
        }
    }

    /// Re-reads the frames of windows that something other than Auto Tiling moved.
    private func refreshDirty() {
        guard !dirty.isEmpty else { return }
        let list = dirty
        dirty.removeAll()
        for id in list {
            guard var w = windows[id] else { continue }
            AXUIElementSetMessagingTimeout(w.ref.element, 0.25)
            guard let f = w.ref.frame else { forget(id); continue }
            w.frame = f
            w.isFullScreen = w.ref.isFullScreen
            windows[id] = w
            // Moved onto another display (a keyboard tool, a display going away): it belongs there now.
            guard let home = board.display(of: id), let there = TileDisplay.showing(f, in: displays), there.key != home,
                  !w.isFullScreen else { continue }
            if board.isTiled(id) {
                board.move(id, to: there.key, at: .last, capacity: capacity(of: there), present: present.union([id]),
                           stackWhenFull: settings.value.stackWhenFull)
            } else if let reason = board.floating[id]?.reason {
                board.float(id, reason: reason, display: there.key)
            }
        }
    }

    /// Windows that take part in tiling right now: on screen, not minimized, full screen or
    /// hidden, and not from an app the user doesn't tile.
    private func presentWindows(onScreen: Set<CGWindowID>) -> Set<CGWindowID> {
        let excluded = settings.value.excludedApps
        var hidden: [pid_t: Bool] = [:]
        var result = Set<CGWindowID>()
        for w in windows.values where !w.isMinimized && !w.isFullScreen && onScreen.contains(w.id) {
            let isHidden = hidden[w.pid] ?? (NSRunningApplication(processIdentifier: w.pid)?.isHidden ?? true)
            hidden[w.pid] = isHidden
            if isHidden || AppList.contains(excluded, bundleID: w.bundleID, name: w.appName) { continue }
            result.insert(w.id)
        }
        return result
    }

    /// New windows join the board, front to back (so the window in front becomes the main one
    /// when tiling starts).
    private func admit(_ present: Set<CGWindowID>, order: [WindowInfo]) {
        let s = settings.value
        var newcomers = order.map(\.id).filter { present.contains($0) && !board.contains($0) }
        newcomers += present.filter { !board.contains($0) && !newcomers.contains($0) }.sorted()
        for id in newcomers {
            guard let w = windows[id], let d = TileDisplay.showing(w.frame, in: displays) else { continue }
            board.add(id, to: d.key, capacity: capacity(of: d), present: present, stackWhenFull: s.stackWhenFull,
                      active: lastActive[d.key])
        }
    }

    // MARK: Re-tiling

    func capacity(of d: TileDisplay) -> Int { d.shape.capacity(maxWindows: settings.value.maxWindows) }

    /// Layout, area, gaps and the user's split changes for one display.
    func spec(for d: TileDisplay) -> TileSpec {
        let s = settings.value
        let choice = s.layout(for: d.key)
        let gap = s.gapPoints
        let reserve = s.reserve.applies(to: d.key) ? s.reserve : nil
        var spec = TileSpec(kind: choice.kind, shape: d.shape, main: choice.main.fraction,
                            area: TileGeometry.area(visibleFrame: d.visibleFrame, reserve: reserve, gap: gap), gap: gap,
                            capacity: capacity(of: d), stackWhenFull: s.stackWhenFull)
        if let o = overrides[d.key], o.kind == choice.kind, o.shape == d.shape, o.main == choice.main {
            spec.overrides = o.weights
        }
        spec.zoomed = zoomed[d.key]
        spec.minimumTile = CGSize(width: 220, height: 140)
        return spec
    }

    private func minimum(of id: CGWindowID) -> CGSize {
        guard let w = windows[id] else { return .zero }
        var m = w.minimum
        if let bid = w.bundleID, let l = learned.value[bid] {
            m = CGSize(width: max(m.width, l.width), height: max(m.height, l.height))
        }
        return m
    }

    func retileNow() {
        retileWork?.cancel()
        retileWork = nil
        guard isRunning else { return }
        // Never move windows under a pressed mouse button (a drag, a resize, a selection).
        if Self.leftButtonDown {
            if !waitingForMouseUp {
                waitingForMouseUp = true
                pollMouseUp()
            }
            return
        }
        refreshDirty()
        let onScreen = WindowInfo.onScreen()
        discover(onScreen)
        present = presentWindows(onScreen: Set(onScreen.map(\.id)))
        admit(present, order: onScreen)
        guard isActive else {
            plans.removeAll()
            updateOverlays()
            publish()
            onLayout?()
            return
        }
        var moves: [FrameApplier.Move] = []
        var fresh: [String: TilePlan] = [:]
        for d in displays {
            let spec = spec(for: d)
            let plan = TilePlanner.plan(&board, display: d.key, present: present, spec: spec) { self.minimum(of: $0) }
            fresh[d.key] = plan
            for (id, frame) in plan.frames { enqueue(id, frame, into: &moves) }
            for id in plan.floated {
                guard let w = windows[id] else { continue }
                let m = minimum(of: id)
                let size = CGSize(width: max(w.frame.width, m.width), height: max(w.frame.height, m.height))
                enqueue(id, TilePlanner.centered(size: size, in: spec.area), into: &moves)
            }
        }
        plans = fresh
        apply(moves)
        updateOverlays()
        publish()
        onLayout?()
    }

    private func pollMouseUp() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.waitingForMouseUp else { return }
            if Self.leftButtonDown { self.pollMouseUp(); return }
            self.waitingForMouseUp = false
            self.retileNow()
        }
    }

    /// The mouse button went up after a drag or resize (the mouse controller saw it first).
    func mouseReleased() {
        guard waitingForMouseUp else { return }
        waitingForMouseUp = false
        setNeedsRetile(delay: 0.01)
    }

    private static func isClose(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 1) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    private func enqueue(_ id: CGWindowID, _ frame: CGRect, into moves: inout [FrameApplier.Move]) {
        guard let w = windows[id] else { return }
        if let own = ownMoves[id], own.frame == frame, own.until > Self.now { return }   // on its way
        if Self.isClose(w.frame, frame) { return }
        moves.append(FrameApplier.Move(ref: w.ref, id: id, frame: frame))
    }

    private func apply(_ moves: [FrameApplier.Move]) {
        guard !moves.isEmpty else { return }
        let until = Self.now + 1.0
        for m in moves { ownMoves[m.id] = OwnMove(frame: m.frame, until: until) }
        applier.apply(moves) { [weak self] results in self?.applied(results) }
    }

    /// Frames read back after moving: learn minimum sizes, retry refused positions.
    private func applied(_ results: [FrameApplier.Result]) {
        guard isRunning else { return }
        var again = false
        for r in results {
            guard var w = windows[r.id], let actual = r.actual else { continue }
            w.frame = actual
            let wider = actual.width > r.requested.width + 2
            let taller = actual.height > r.requested.height + 2
            if wider || taller {
                // The app kept a larger size: that is its minimum.
                if wider { w.minimum.width = max(w.minimum.width, actual.width) }
                if taller { w.minimum.height = max(w.minimum.height, actual.height) }
                if let bid = w.bundleID { learn(bid, width: wider ? actual.width : nil, height: taller ? actual.height : nil) }
                again = true
            } else if !Self.isClose(actual, r.requested, tolerance: 2) {
                let n = (retries[r.id] ?? 0) + 1
                retries[r.id] = n
                if n <= 2 { again = true }
            } else {
                retries[r.id] = nil
            }
            windows[r.id] = w
            // Notifications from this move may still trickle in.
            ownMoves[r.id] = OwnMove(frame: r.requested, until: Self.now + 0.5)
        }
        updateOverlays()
        onLayout?()
        if again { setNeedsRetile(delay: 0.05) }
    }

    private func learn(_ bundleID: String, width: CGFloat?, height: CGFloat?) {
        var entry = learned.value[bundleID] ?? LearnedSize(width: 0, height: 0)
        if let width { entry.width = max(entry.width, Double(width.rounded(.up))) }
        if let height { entry.height = max(entry.height, Double(height.rounded(.up))) }
        if learned.value[bundleID] != entry {
            learned.value[bundleID] = entry
            log.info("Learned minimum \(Int(entry.width))×\(Int(entry.height)) for \(bundleID, privacy: .public)")
        }
    }

    // MARK: Focus

    private func updateFocus() {
        focusWork?.cancel()
        focusWork = nil
        guard isRunning, let app = NSWorkspace.shared.frontmostApplication else { return }
        // With MacToys in front (its settings, a flyout), the window the user worked in stays focused.
        guard app.processIdentifier != ownPID else { return }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.25)
        var id: CGWindowID?
        var frame: CGRect?
        if let element: AXUIElement = axApp.ax(kAXFocusedWindowAttribute) {
            AXUIElementSetMessagingTimeout(element, 0.25)
            let ref = WindowRef(element: element, pid: app.processIdentifier)
            id = ids[ref] ?? ref.windowID
            frame = id.flatMap { windows[$0]?.frame } ?? ref.frame
        }
        focusedID = id
        focusedFrame = frame
        if let id, let loc = board.location(of: id) {
            board.bringToFront(id)
            lastActive[loc.display] = id
            // Focus mode ends when another window on its display comes forward.
            if let z = zoomed[loc.display], z != id, cleanSpace?.window != z {
                zoomed[loc.display] = nil
                setNeedsRetile(delay: 0.01)
            }
        }
        updateOverlays()
        publish()
        onLayout?()
    }

    // MARK: Overlays and status

    func updateOverlays() {
        let s = settings.value
        guard isActive else {
            highlight.hide()
            spotlight.hide()
            return
        }
        var items: [HighlightOverlay.Item] = []
        for d in displays where plans[d.key] != nil {
            let tiles = board.visibleTiles(on: d.key, present: present)
            if let z = zoomed[d.key], let w = windows[z] {
                // The window in Focus mode covers the others: only it is marked.
                items.append(.init(display: d.displayID, frame: w.frame, radius: w.cornerRadius, active: z == focusedID,
                                   stackCount: 1))
                continue
            }
            for stack in tiles {
                guard let front = stack.first, let w = windows[front] else { continue }
                items.append(.init(display: d.displayID, frame: w.frame, radius: w.cornerRadius, active: front == focusedID,
                                   stackCount: stack.count))
            }
        }
        // Under the No peek veil or the Clean Space curtain only the window in use is marked.
        if noPeek || cleanSpace != nil { items = items.filter(\.active).map { var i = $0; i.stackCount = 1; return i } }
        let color = s.highlightUsesAccent ? NSColor.controlAccentColor : s.highlightColor.nsColor
        highlight.update(items, displays: displays, style: s.highlight, color: color, gap: s.gapPoints)

        var veil: SpotlightOverlay.Hole?
        if noPeek, let f = focusedID.flatMap({ windows[$0]?.frame }) ?? focusedFrame {
            veil = .init(frame: f, radius: focusedID.flatMap { windows[$0]?.cornerRadius } ?? WindowCorners.titlebarRadius)
        }
        var curtain: (display: TileDisplay, hole: SpotlightOverlay.Hole)?
        if let c = cleanSpace, let w = windows[c.window], let d = displays.first(where: { $0.key == c.display }) {
            curtain = (d, .init(frame: w.frame, radius: w.cornerRadius))
        }
        spotlight.update(displays: displays, veil: veil, darkness: s.noPeekDarkness, blur: s.noPeekBlur, curtain: curtain)
    }

    /// Refreshes what the settings page shows.
    func publish() {
        let s = settings.value
        let list = isRunning ? displays : TileDisplay.current()
        let shown: [TilingStatus.Display] = list.map { d in
            let choice = s.layout(for: d.key)
            let tiles = isRunning ? board.visibleTiles(on: d.key, present: present) : []
            return TilingStatus.Display(
                id: d.key, name: d.name, number: d.number, shape: d.shape,
                aspect: d.frame.height > 0 ? d.frame.width / d.frame.height : 1.6, isMain: d.isMain, isBuiltIn: d.isBuiltIn,
                kind: choice.kind, main: choice.main, capacity: capacity(of: d),
                tiles: tiles.map { stack in
                    TilingStatus.Tile(apps: stack.compactMap { id in
                        windows[id].map { TilingStatus.App(bundleID: $0.bundleID, name: $0.appName) }
                    })
                })
        }
        let st = status
        if st.running != isRunning { st.running = isRunning }
        if st.paused != s.paused { st.paused = s.paused }
        if st.stageManager != stageManager.isOn { st.stageManager = stageManager.isOn }
        if st.displays != shown { st.displays = shown }
        let floating = board.floating.keys.filter { present.contains($0) }.count
        if st.floating != floating { st.floating = floating }
        if st.noPeek != noPeek { st.noPeek = noPeek }
        if st.cleanSpace != (cleanSpace != nil) { st.cleanSpace = cleanSpace != nil }
        if st.focusMode != !zoomed.isEmpty { st.focusMode = !zoomed.isEmpty }
    }

    // MARK: Queries for the mouse, quick actions and Tab View

    func display(_ key: String) -> TileDisplay? { displays.first { $0.key == key } }

    func window(_ id: CGWindowID) -> TrackedWindow? { windows[id] }

    var focusedDisplay: TileDisplay? {
        if let id = focusedID, let key = board.display(of: id), let d = display(key) { return d }
        if let f = focusedFrame { return TileDisplay.showing(f, in: displays) }
        return nil
    }

    /// The display the user works on: the focused window's, else the one under the pointer.
    func activeDisplay() -> TileDisplay? {
        if isRunning { updateFocus() }
        let list = displays.isEmpty ? TileDisplay.current() : displays
        return focusedDisplay ?? TileDisplay.containing(ScreenGeometry.toAX(NSEvent.mouseLocation), in: list)
    }

    /// The visible tiled window at a point, or a floating one (they float above the tiles).
    func hit(at p: CGPoint) -> Hit? {
        guard isActive else { return nil }
        for d in displays where d.frame.contains(p) {
            if let z = zoomed[d.key], let w = windows[z], w.frame.contains(p) {
                return Hit(display: d.key, window: z, frame: w.frame, radius: w.cornerRadius)
            }
            guard zoomed[d.key] == nil else { return nil }
            for id in floatingWindows(on: d.key) {
                guard let w = windows[id], w.frame.contains(p) else { continue }
                return Hit(display: d.key, window: id, frame: w.frame, radius: w.cornerRadius)
            }
            for stack in board.visibleTiles(on: d.key, present: present) {
                guard let front = stack.first, let w = windows[front], w.frame.contains(p) else { continue }
                return Hit(display: d.key, window: front, frame: w.frame, radius: w.cornerRadius)
            }
        }
        return nil
    }

    func isTiled(_ id: CGWindowID) -> Bool { board.isTiled(id) && present.contains(id) }

    func isFloating(_ id: CGWindowID) -> Bool { board.floating[id] != nil }

    /// Where a dragged window would go if dropped at `p`.
    func dropTarget(at p: CGPoint, dragging id: CGWindowID) -> DropTarget? {
        guard isActive, let d = TileDisplay.containing(p, in: displays), d.frame.contains(p),
              let plan = plans[d.key] else { return nil }
        let tiles = board.visibleTiles(on: d.key, present: present)
        if tiles.isEmpty { return .display(key: d.key, area: spec(for: d).area) }
        for (i, stack) in tiles.enumerated() where plan.tileFrames.indices.contains(i) {
            guard plan.tileFrames[i].insetBy(dx: -settings.value.gapPoints / 2, dy: -settings.value.gapPoints / 2).contains(p),
                  !stack.contains(id), let front = stack.first else { continue }
            return .tile(display: d.key, window: front, frame: plan.tileFrames[i])
        }
        return nil
    }

    /// Visible tiles of a display, front window first.
    func tiles(on key: String) -> [[CGWindowID]] { board.visibleTiles(on: key, present: present) }

    /// Present floating windows of a display.
    func floatingWindows(on key: String) -> [CGWindowID] {
        board.floating.filter { $0.value.display == key && present.contains($0.key) }.keys.sorted()
    }

    /// Tracked windows that are minimized.
    var minimizedWindows: [TrackedWindow] { windows.values.filter(\.isMinimized).sorted { $0.id < $1.id } }

    // MARK: Commands

    /// Brings a window forward and activates its app.
    func activate(_ id: CGWindowID) {
        guard let w = windows[id] else { return }
        AXUIElementSetMessagingTimeout(w.ref.element, 0.3)
        if w.isMinimized { w.ref.minimize(false) }
        w.ref.focus()
        // Cooperative activation may ignore a background app's request; Accessibility doesn't.
        AXUIElementCreateApplication(w.pid).set(kAXFrontmostAttribute, kCFBooleanTrue)
    }

    /// The focused window if it's tiled.
    private func focusedTiled() -> (id: CGWindowID, display: TileDisplay)? {
        updateFocus()
        guard let id = focusedID, isTiled(id), let key = board.display(of: id), let d = display(key) else { return nil }
        return (id, d)
    }

    /// Uses `kind` on a display (the active one by default). Choosing the layout a display
    /// already has evens out tiles the user resized.
    func applyLayout(_ kind: TileLayoutKind, on target: TileDisplay? = nil) {
        guard let d = target ?? activeDisplay() else { return }
        var choice = settings.value.layout(for: d.key)
        if choice.kind == kind {
            if overrides.removeValue(forKey: d.key) != nil {
                HUD.show(String(localized: "\(kind.title) · evened out", comment: "HUD: tile sizes reset; %@ is a layout name"),
                         symbol: kind.symbol)
                setNeedsRetile(delay: 0)
                return
            }
        } else {
            choice.kind = kind
            settings.value.layouts[d.key] = choice
        }
        let message = displays.count > 1
            ? String(localized: "\(kind.title) on \(d.name)", comment: "HUD: a layout name, then a display name")
            : kind.title
        HUD.show(message, symbol: kind.symbol)
    }

    /// Swaps the focused window with its neighbor; past the display edge it moves to the next display.
    func swapFocused(_ direction: TileDirection) {
        guard isActive, let (id, d) = focusedTiled(), let plan = plans[d.key], let t = plan.tileIndex(of: id) else { return }
        if let n = TileGeometry.neighbor(of: t, direction, in: plan.tileFrames), let other = plan.tiles[n].first {
            board.swap(id, other)
            retileNow()
            return
        }
        guard let i = TileGeometry.display(beside: d.frame, direction, in: displays.map(\.frame)) else { return }
        let target = displays[i]
        board.move(id, to: target.key, at: direction == .right || direction == .down ? .first : .last,
                   capacity: capacity(of: target), present: present, stackWhenFull: settings.value.stackWhenFull)
        lastActive[target.key] = id
        retileNow()
    }

    func makeMainFocused() {
        guard isActive, let (id, _) = focusedTiled() else { return }
        makeMain(id)
    }

    func makeMain(_ id: CGWindowID) {
        guard isActive else { return }
        board.makeMain(id, present: present)
        retileNow()
    }

    func cycleStack(forward: Bool) {
        guard isActive, let (id, _) = focusedTiled() else { return }
        guard let next = board.cycleStack(of: id, forward: forward, present: present), let w = windows[next],
              let loc = board.location(of: next), let stack = board.slots[loc.display]?[loc.slot] else {
            HUD.show("No other windows in this tile", symbol: "square.stack")
            return
        }
        activate(next)
        let members = stack.filter(present.contains)
        let position = (members.firstIndex(of: next) ?? 0) + 1
        HUD.show(String(localized: "\(w.appName) · \(position) of \(members.count)",
                        comment: "HUD when cycling a stack of windows: app name, position, number of windows"),
                 symbol: "square.stack.fill")
    }

    /// Floats a tiled window (centered, above the tiles) or tiles a floating one again.
    func toggleFloat(_ id: CGWindowID? = nil) {
        guard isActive else { return }
        if id == nil { updateFocus() }
        guard let id = id ?? focusedID, let w = windows[id] else { return }
        if board.isTiled(id) {
            board.float(id, reason: .user)
            if let key = board.display(of: id), let d = display(key) {
                let area = spec(for: d).area
                let m = minimum(of: id)
                let size = CGSize(width: max(m.width, (area.width * 0.62).rounded()), height: max(m.height, (area.height * 0.7).rounded()))
                apply([FrameApplier.Move(ref: w.ref, id: id, frame: TilePlanner.centered(size: size, in: area))])
            }
            activate(id)
            HUD.show(String(localized: "Floating · \(w.appName)", comment: "HUD: the window floats above the tiles; %@ is the app"),
                     symbol: "macwindow.on.rectangle")
        } else if board.floating[id] != nil {
            let d = board.display(of: id).flatMap(display)
            board.unfloat(id, capacity: d.map(capacity(of:)) ?? 4, present: present, stackWhenFull: settings.value.stackWhenFull,
                          active: d.flatMap { lastActive[$0.key] })
            HUD.show(String(localized: "Tiled · \(w.appName)", comment: "HUD: the window joins the tiles again; %@ is the app"),
                     symbol: "rectangle.split.2x2")
        } else {
            return
        }
        retileNow()
    }

    /// Sends a window to the next display (left to right, wrapping).
    func sendToNextDisplay(_ id: CGWindowID? = nil) {
        guard isActive else { return }
        if id == nil { updateFocus() }
        guard let id = id ?? focusedID, board.isTiled(id), let key = board.display(of: id),
              let i = displays.firstIndex(where: { $0.key == key }) else { return }
        guard displays.count > 1 else {
            HUD.show("No other display", symbol: "display")
            return
        }
        let target = displays[(i + 1) % displays.count]
        board.move(id, to: target.key, at: .last, capacity: capacity(of: target), present: present,
                   stackWhenFull: settings.value.stackWhenFull)
        lastActive[target.key] = id
        retileNow()
        activate(id)
    }

    /// Focus mode: the focused window fills its display; again, and every window is back.
    func toggleFocusMode() {
        guard isActive, let (id, d) = focusedTiled() else { return }
        if zoomed[d.key] == id {
            zoomed[d.key] = nil
            if cleanSpace?.window == id { cleanSpace = nil }
            HUD.show(AutoTilingModule.focusOff, symbol: "arrow.down.right.and.arrow.up.left")
        } else {
            zoomed[d.key] = id
            HUD.show(AutoTilingModule.focusOn, symbol: "arrow.up.left.and.arrow.down.right")
        }
        retileNow()
        activate(id)
    }

    /// No peek: everything but the window in use goes dark.
    func toggleNoPeek() {
        guard isActive else { return }
        noPeek.toggle()
        updateFocus()
        HUD.show(noPeek ? "No peek on" : "No peek off", symbol: noPeek ? "eye.slash" : "eye")
        updateOverlays()
        publish()
    }

    /// Clean Space: the focused window fills its display and everything else there is covered,
    /// for sharing the screen.
    func toggleCleanSpace() {
        guard isActive else { return }
        if let c = cleanSpace {
            cleanSpace = nil
            if zoomed[c.display] == c.window { zoomed[c.display] = nil }
            HUD.show("Clean Space off", symbol: "rectangle.dashed")
        } else {
            guard let (id, d) = focusedTiled() else {
                HUD.show("Focus a tiled window first", symbol: "macwindow")
                return
            }
            zoomed[d.key] = id
            cleanSpace = CleanSpace(display: d.key, window: id)
            activate(id)
            HUD.show("Clean Space on", symbol: "rectangle.inset.filled")
        }
        retileNow()
    }

    /// Settles a drag: swap with the tile under the pointer, move to an empty display, or float
    /// (⌥ held). Anything else snaps back.
    func finishDrag(_ id: CGWindowID, target: DropTarget?, float: Bool, frame: CGRect?) {
        guard isRunning else { return }
        if let frame { windows[id]?.frame = frame }
        if float, board.isTiled(id) {
            board.float(id, reason: .user)
        } else if let target, isActive {
            switch target {
            case .tile(_, let other, _):
                board.swap(id, other)
            case .display(let key, _):
                if let d = display(key) {
                    board.move(id, to: key, at: .last, capacity: capacity(of: d), present: present,
                               stackWhenFull: settings.value.stackWhenFull)
                }
            }
        }
        mouseReleased()
        setNeedsRetile(delay: 0)
    }

    /// The user resized a tiled window: move the split lines so its neighbors follow.
    func finishResize(_ id: CGWindowID, frame: CGRect) {
        guard isActive else { mouseReleased(); return }
        windows[id]?.frame = frame
        defer {
            mouseReleased()
            setNeedsRetile(delay: 0)
        }
        guard let key = board.display(of: id), let d = display(key), let plan = plans[key],
              let t = plan.tileIndex(of: id), plan.tileFrames.indices.contains(t) else { return }
        let old = plan.tileFrames[t]
        var spec = spec(for: d)
        let mins = plan.tiles.map { TilePlanner.stackMinimum($0, spec) { self.minimum(of: $0) } }
        let moves: [(TileEdge, CGFloat, CGFloat)] = [(.left, old.minX, frame.minX), (.right, old.maxX, frame.maxX),
                                                     (.top, old.minY, frame.minY), (.bottom, old.maxY, frame.maxY)]
        var changed = false
        for (edge, from, to) in moves where abs(to - from) > 3 {
            guard let tree = spec.tree(count: plan.tiles.count),
                  let r = TileGeometry.resize(tree, in: spec.area, gap: spec.gap, tile: t, edge: edge, to: to,
                                              minimumExtent: 160, minimums: mins) else { continue }
            spec.overrides[r.path] = r.weights
            changed = true
        }
        guard changed else { return }
        let choice = settings.value.layout(for: key)
        overrides[key] = SplitOverride(kind: choice.kind, shape: d.shape, main: choice.main, weights: spec.overrides)
    }

    /// Hides the dragged window's border while it moves.
    func beginDrag(_ id: CGWindowID) {
        highlight.hide(window: windows[id]?.frame)
    }

    /// Forgets every learned minimum size.
    func forgetLearnedSizes() {
        learned.value = [:]
        for id in windows.keys { windows[id]?.minimum = .zero }
        setNeedsRetile()
    }
}
