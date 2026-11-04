import AppKit
import ApplicationServices
import MacToysCore

/// Notices the pointer resting on a window's green title-bar button, and (optionally) double-clicks on it.
///
/// Pointer moves arrive through a passive global monitor that only records the time and starts a
/// short timer. Once the pointer rests, the window server is asked which window is under it (no app
/// is messaged); only near a window's top-left corner does one Accessibility hit test ask the app
/// what is there. So a resting pointer costs at most one hit test, and a moving one none.
@MainActor
final class ZoomButtonWatcher {
    /// The green button under the pointer and its window.
    struct Hit {
        let window: WindowRef
        let button: AXUIElement
        /// Global top-left coordinates.
        let buttonRect: CGRect
        let windowFrame: CGRect
    }

    /// The pointer rested on a green button for the hover delay.
    var onHover: ((Hit) -> Void)?
    /// The green button was double-clicked (with the option on).
    var onDoubleClick: ((Hit) -> Void)?
    /// While true (the palette is open) no new hover is reported.
    var isPaused: () -> Bool = { false }

    private var hoverEnabled = false
    private var doubleClickEnabled = false
    private var hoverDelay: TimeInterval = 0.25
    private var excluded: [String] = []

    private var moveMonitor: Any?
    private var timer: Timer?
    private var lastMove: TimeInterval = 0
    private var probed = false
    private(set) var hit: Hit?
    /// `hit?.buttonRect` as a scalar copy the event tap reads.
    private var hitRect = CGRect.null
    // Double-click state (tap side).
    private var pendingClick: DispatchWorkItem?
    private var swallowUp = false
    private var tapAdded = false
    private static let tapID = "windowcontrols.zoombutton"
    /// How long the pointer must rest before the hit test runs (separately from the hover delay, so
    /// a double-click right after arriving still finds the button).
    private static let probeRest: TimeInterval = 0.06

    var isRunning: Bool { moveMonitor != nil }

    /// Starts or reconfigures watching. Both options off stops it.
    func configure(hover: Bool, doubleClick: Bool, delay: TimeInterval, excluded: [String]) {
        hoverEnabled = hover
        doubleClickEnabled = doubleClick
        hoverDelay = min(max(delay, 0.1), 2)
        self.excluded = excluded
        if hover || doubleClick {
            if moveMonitor == nil {
                moveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
                    MainActor.assumeIsolated { self?.pointerMoved() }
                }
            }
        } else {
            removeMonitor()
        }
        if doubleClick {
            // Added once: settings change often (a slider moving), and re-adding rebuilds the tap.
            if !tapAdded {
                tapAdded = true
                InputTap.shared.add(Self.tapID, priority: 55, events: [.leftMouseDown, .leftMouseUp]) { [weak self] type, event in
                    self?.handleClick(type, event) ?? .pass
                }
            }
        } else {
            removeTap()
        }
    }

    func stop() {
        removeMonitor()
        removeTap()
    }

    private func removeTap() {
        if tapAdded { InputTap.shared.remove(Self.tapID) }
        tapAdded = false
        cancelPendingClick()
    }

    private func removeMonitor() {
        if let moveMonitor { NSEvent.removeMonitor(moveMonitor) }
        moveMonitor = nil
        timer?.invalidate()
        timer = nil
        clearHit()
    }

    private func clearHit() {
        hit = nil
        hitRect = .null
    }

    // MARK: Resting pointer

    private func pointerMoved() {
        lastMove = ProcessInfo.processInfo.systemUptime
        probed = false
        if !hitRect.isNull {
            let p = ScreenGeometry.toAX(NSEvent.mouseLocation)
            if !hitRect.insetBy(dx: -2, dy: -2).contains(p) { clearHit() }
        }
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let rest = ProcessInfo.processInfo.systemUptime - lastMove
        guard rest >= Self.probeRest else { return }
        if !probed {
            probed = true
            hit = NSEvent.pressedMouseButtons == 0 && AXIsProcessTrusted() ? probe(at: ScreenGeometry.toAX(NSEvent.mouseLocation)) : nil
            hitRect = hit?.buttonRect ?? .null
        }
        guard let hit, hoverEnabled else { return stopTimer() }
        guard rest >= hoverDelay else { return }
        stopTimer()
        guard !isPaused(), NSEvent.pressedMouseButtons == 0 else { return }
        onHover?(hit)
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    /// The green button under a point (global top-left coordinates), if any.
    private func probe(at p: CGPoint) -> Hit? {
        let own = ProcessInfo.processInfo.processIdentifier
        // The window server knows which window is there without asking its app.
        let number = NSWindow.windowNumber(at: ScreenGeometry.toCocoa(p), belowWindowWithWindowNumber: 0)
        guard number > 0, NSApp.window(withWindowNumber: number) == nil,
              let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(number)) as? [[String: Any]])?.first,
              (info[kCGWindowLayer as String] as? Int) == 0,
              let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != own,
              let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDict) else { return nil }
        // Title-bar buttons sit in the top-left corner, also under a tall unified toolbar.
        let dx = p.x - bounds.minX, dy = p.y - bounds.minY
        guard dx >= 0, dy >= 0, dx < 170, dy < 70 else { return nil }
        if excluded.matches(app: NSRunningApplication(processIdentifier: pid)) { return nil }

        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.15)
        var found: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(p.x), Float(p.y), &found) == .success, let button = found else {
            return nil
        }
        AXUIElementSetMessagingTimeout(button, 0.15)
        let subrole: String? = button.ax(kAXSubroleAttribute)
        guard subrole == "AXFullScreenButton" || subrole == kAXZoomButtonSubrole as String else { return nil }
        guard let windowElement: AXUIElement = button.ax(kAXWindowAttribute),
              let window = WindowRef(element: windowElement), window.pid == pid else { return nil }
        AXUIElementSetMessagingTimeout(windowElement, 0.25)
        guard !window.isFullScreen, let frame = window.frame,
              let posValue: AXValue = button.ax(kAXPositionAttribute), let sizeValue: AXValue = button.ax(kAXSizeAttribute) else {
            return nil
        }
        var origin = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(posValue, .cgPoint, &origin), AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        return Hit(window: window, button: button, buttonRect: CGRect(origin: origin, size: size), windowFrame: frame)
    }

    // MARK: Double-click (event tap: scalars only)

    private func handleClick(_ type: CGEventType, _ event: CGEvent) -> TapDecision {
        switch type {
        case .leftMouseDown:
            guard !hitRect.isNull, hitRect.contains(event.location),
                  Modifiers(event.flags).subtracting(.function).isEmpty else { return .pass }
            let clicks = event.getIntegerValueField(.mouseEventClickState)
            if clicks >= 2, pendingClick != nil {
                cancelPendingClick()
                swallowUp = true
                DispatchQueue.main.async { [weak self] in
                    guard let self, let hit = self.hit else { return }
                    self.onDoubleClick?(hit)
                }
                return .consume
            }
            guard clicks == 1, let button = hit?.button else { return .pass }
            // Hold the click back: a second one makes it a double-click; otherwise the button gets
            // its usual press once the double-click interval has passed.
            let work = DispatchWorkItem { [weak self] in
                self?.pendingClick = nil
                AXUIElementPerformAction(button, kAXPressAction as CFString)
            }
            pendingClick = work
            swallowUp = true
            DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
            return .consume
        case .leftMouseUp:
            guard swallowUp else { return .pass }
            swallowUp = false
            return .consume
        default:
            return .pass
        }
    }

    private func cancelPendingClick() {
        pendingClick?.cancel()
        pendingClick = nil
        swallowUp = false
    }
}
