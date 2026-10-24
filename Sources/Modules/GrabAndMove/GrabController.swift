import AppKit
import MacToysCore

/// Carbon also declares a `WindowRef`; inside this module the name means MacToys' AX window.
typealias WindowRef = MacToysCore.WindowRef

/// Modifier + left-drag moves the window under the pointer; modifier + right-drag resizes it
/// from the nearest edge or corner. The clicks are consumed so the app underneath never sees
/// them (and no context menu appears after a right-drag).
///
/// The tap handler only records scalars. The window is identified at mouse-down from the window
/// server list (fast, no Accessibility round trip); a 60 Hz timer resolves its AX element and
/// writes the frame, so the target app is messaged at most 60 times a second.
@MainActor
final class GrabController {
    private static let tapID = "grabandmove"
    private let settings: Persisted<GrabAndMoveSettings>
    private let hud = GeometryHUD()
    private var activationObserver: NSObjectProtocol?
    private let log = Log.for("grabandmove")

    private enum Mode { case none, move, resize }

    // Written by the tap (scalars only).
    private var mode = Mode.none
    private var startPoint = CGPoint.zero
    private var pointer = CGPoint.zero
    private var startFrame = CGRect.zero
    private var edges: GrabEdges = []
    private var dirty = false
    private var windowID: CGWindowID = 0
    private var pid: pid_t = 0
    private var sessionButton = CGMouseButton.left
    private var lastEvent: TimeInterval = 0
    /// Increments per grab, so late async work from a previous grab is ignored.
    private var session = 0

    // Settings snapshot read by the tap.
    private var required: Modifiers = [.control, .command]
    private var resizeEnabled = true
    private var frontmostBlocked = false

    // Session (timer side).
    private var window: WindowRef?
    private var timer: Timer?
    private var applied = CGRect.null

    init(settings: Persisted<GrabAndMoveSettings>) {
        self.settings = settings
    }

    func start() {
        refreshConfig()
        InputTap.shared.add(Self.tapID, priority: 60,
                            events: [.leftMouseDown, .leftMouseDragged, .leftMouseUp,
                                     .rightMouseDown, .rightMouseDragged, .rightMouseUp]) { [weak self] type, event in
            self?.handle(type, event) ?? .pass
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshFrontmost() }
        }
    }

    func stop() {
        InputTap.shared.remove(Self.tapID)
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        endSession()
        hud.tearDown()
    }

    /// Re-reads the settings the tap uses.
    func refreshConfig() {
        let s = settings.value
        required = s.activation.modifiers
        resizeEnabled = s.resizeWithRightDrag
        refreshFrontmost()
    }

    private func refreshFrontmost() {
        frontmostBlocked = settings.value.excludedForModifierApps.matches(app: NSWorkspace.shared.frontmostApplication)
    }

    // MARK: Tap

    private func handle(_ type: CGEventType, _ event: CGEvent) -> TapDecision {
        switch type {
        case .leftMouseDown, .rightMouseDown:
            let button: CGMouseButton = type == .leftMouseDown ? .left : .right
            if mode != .none {
                if button != sessionButton { return .consume }    // the other button during a grab
                endSession()                                      // the previous release never arrived
            }
            guard !frontmostBlocked, Modifiers(event.flags).subtracting(.shift) == required else { return .pass }
            let right = type == .rightMouseDown
            if right && !resizeEnabled { return .pass }
            return begin(at: event.location, resize: right) ? .consume : .pass
        case .leftMouseDragged, .rightMouseDragged:
            guard mode != .none else { return .pass }
            pointer = event.location
            lastEvent = ProcessInfo.processInfo.systemUptime
            dirty = true
            return .consume
        case .leftMouseUp, .rightMouseUp:
            guard mode != .none else { return .pass }
            if (type == .leftMouseUp ? CGMouseButton.left : .right) == sessionButton {
                pointer = event.location
                dirty = true
                let id = session
                DispatchQueue.main.async { [weak self] in self?.finish(id) }
            }
            return .consume
        default:
            return .pass
        }
    }

    /// Starts a grab when a movable window of an app that isn't excluded is under the pointer.
    private func begin(at point: CGPoint, resize: Bool) -> Bool {
        guard let hit = Self.windowAt(point), hit.pid != ProcessInfo.processInfo.processIdentifier,
              !settings.value.excludedApps.matches(app: NSRunningApplication(processIdentifier: hit.pid)) else { return false }
        session &+= 1
        mode = resize ? .resize : .move
        sessionButton = resize ? .right : .left
        startPoint = point
        pointer = point
        startFrame = hit.frame
        windowID = hit.id
        pid = hit.pid
        edges = resize ? GrabGeometry.edges(for: point, in: hit.frame) : []
        dirty = false
        lastEvent = ProcessInfo.processInfo.systemUptime
        applied = hit.frame
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        let id = session
        DispatchQueue.main.async { [weak self] in self?.resolveWindow(id) }
        return true
    }

    // MARK: Session

    private func resolveWindow(_ id: Int) {
        guard id == session, mode != .none, window == nil else { return }
        let w = WindowRef.windows(of: pid).first { $0.windowID == windowID } ?? WindowRef.at(startPoint)
        guard let w, w.pid == pid, !w.isFullScreen else {
            log.debug("No movable window under the pointer")
            return
        }
        window = w
        if let f = w.frame { startFrame = f; applied = f }
        if settings.value.bringToFront { w.focus() }
        tick()
    }

    private func tick() {
        if dirty, let w = window { apply(to: w) }
        // A release the tap never saw must not leave clicks swallowed: end the grab once the
        // button is up and no event arrived for a second (trackpad drag-lock reports no button).
        if mode != .none, ProcessInfo.processInfo.systemUptime - lastEvent > 1,
           !CGEventSource.buttonState(.hidSystemState, button: sessionButton) {
            endSession()
        }
    }

    private func apply(to w: WindowRef) {
        dirty = false
        let delta = CGSize(width: pointer.x - startPoint.x, height: pointer.y - startPoint.y)
        let resizing = mode == .resize
        let target = resizing ? GrabGeometry.resized(startFrame, edges: edges, by: delta)
                              : GrabGeometry.moved(startFrame, by: delta)
        guard target != applied else { return }
        if resizing {
            let growing = target.width > applied.width || target.height > applied.height
            if growing && target.origin != applied.origin { w.setPosition(target.origin) }
            w.setSize(target.size)
            if !growing && target.origin != applied.origin { w.setPosition(target.origin) }
            // Apps clamp to their own minimum size; keep the opposite edge anchored when they do.
            if !edges.isDisjoint(with: [.left, .top]), let actual = w.size, actual != target.size {
                let origin = GrabGeometry.anchoredOrigin(for: target, actual: actual, edges: edges)
                w.setPosition(origin)
                applied = CGRect(origin: origin, size: actual)
            } else {
                applied = target
            }
        } else {
            w.setPosition(target.origin)
            applied = target
        }
        if settings.value.showGeometry { hud.show(applied, resizing: resizing, near: pointer) }
    }

    private func finish(_ id: Int) {
        guard id == session, mode != .none else { return }
        if let w = window { apply(to: w) }
        endSession()
    }

    private func endSession() {
        timer?.invalidate()
        timer = nil
        mode = .none
        window = nil
        dirty = false
        applied = .null
        hud.hide()
    }

    /// The frontmost normal-level window under a point, from the window server.
    private static func windowAt(_ point: CGPoint) -> (id: CGWindowID, pid: pid_t, frame: CGRect)? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        for d in list {
            guard (d[kCGWindowLayer as String] as? Int) == 0,
                  let id = d[kCGWindowNumber as String] as? CGWindowID,
                  let pid = d[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = d[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  frame.contains(point) else { continue }
            if let alpha = d[kCGWindowAlpha as String] as? Double, alpha <= 0.01 { continue }
            return (id, pid, frame)
        }
        return nil
    }
}
