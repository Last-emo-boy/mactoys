import AppKit
import Carbon.HIToolbox
import MacToysCore

/// Watches mouse and keyboard through the shared event tap for finished selections, and for
/// anything that should close the bar (typing, clicking elsewhere, scrolling).
///
/// The tap handler runs for every event on the main thread: it only compares numbers and
/// sets flags; reading the selection happens later, from a timer.
@MainActor
final class SelectionMonitor {
    struct Config {
        var autoShow = true
        var triggers = TextActionsSettings.Triggers()
        var required = TextActionsSettings.RequiredModifier.none
        var delay: TimeInterval = 0.15
        var showShortcut: Shortcut?
    }

    var config = Config()
    /// The frontmost app is excluded (or is MacToys itself); cached on app switches.
    var frontmostExcluded = false
    /// A selection gesture finished: kind, pointer and where a drag started (global top-left).
    var onSelection: ((SelectionGesture.Kind, CGPoint, CGPoint?) -> Void)?
    /// Something happened that closes the bar.
    var onDismiss: (() -> Void)?
    /// Keys while the bar is in keyboard mode; true when the bar used the key.
    var onBarKey: ((Int, Bool) -> Bool)?

    // Bar state, mirrored here for the hot path.
    var barVisible = false
    var barKeyboard = false
    var barFrame = CGRect.null

    private static let tapID = "textactions"
    private static let longPressDelay: TimeInterval = 0.5
    private var running = false
    private var timer: DispatchSourceTimer?
    private var mouseDown = false
    private var downPoint = CGPoint.zero
    private var maxTravel: CGFloat = 0
    private var shiftSelecting = false
    private var pending: (kind: SelectionGesture.Kind, pointer: CGPoint, start: CGPoint?)?
    /// Key-ups of keys the bar consumed, so the app never sees a lone key-up.
    private var swallowedUps = [Bool](repeating: false, count: 128)

    func start() {
        guard !running else { return }
        running = true
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.timerFired() } }
        timer.schedule(deadline: .distantFuture)
        timer.resume()
        self.timer = timer
        InputTap.shared.add(Self.tapID, priority: 10,
                            events: [.leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .otherMouseDown,
                                     .scrollWheel, .keyDown, .keyUp, .flagsChanged]) { [weak self] type, event in
            self?.handle(type, event) ?? .pass
        }
    }

    func stop() {
        guard running else { return }
        running = false
        InputTap.shared.remove(Self.tapID)
        timer?.cancel()
        timer = nil
        pending = nil
        mouseDown = false
        shiftSelecting = false
        swallowedUps = [Bool](repeating: false, count: 128)
    }

    /// Forgets a selection that is about to be shown (a new gesture started).
    func cancelPending() {
        guard pending != nil else { return }
        pending = nil
        timer?.schedule(deadline: .distantFuture)
    }

    private func schedule(_ kind: SelectionGesture.Kind, after delay: TimeInterval, pointer: CGPoint, start: CGPoint?) {
        pending = (kind, pointer, start)
        timer?.schedule(deadline: .now() + max(0.02, delay))
    }

    private func timerFired() {
        guard let p = pending else { return }
        pending = nil
        if p.kind == .longPress {
            guard mouseDown, maxTravel < SelectionGesture.dragThreshold else { return }
        }
        onSelection?(p.kind, p.pointer, p.start)
    }

    private func dismiss() {
        DispatchQueue.main.async { [weak self] in self?.onDismiss?() }
    }

    // MARK: Hot path

    private func handle(_ type: CGEventType, _ event: CGEvent) -> TapDecision {
        switch type {
        case .leftMouseDown:
            let p = event.location
            if barVisible && barFrame.contains(p) { return .pass }
            if barVisible { dismiss() }
            cancelPending()
            mouseDown = true
            downPoint = p
            maxTravel = 0
            if config.autoShow && config.triggers.longPress && !frontmostExcluded {
                schedule(.longPress, after: Self.longPressDelay, pointer: p, start: nil)
            }
        case .leftMouseDragged:
            guard mouseDown else { return .pass }
            let p = event.location
            maxTravel = max(maxTravel, hypot(p.x - downPoint.x, p.y - downPoint.y))
            if maxTravel >= SelectionGesture.dragThreshold, pending?.kind == .longPress { cancelPending() }
        case .leftMouseUp:
            guard mouseDown else { return .pass }
            mouseDown = false
            if pending?.kind == .longPress { cancelPending() }
            guard config.autoShow, !frontmostExcluded else { return .pass }
            let up = event.location
            let clicks = Int(event.getIntegerValueField(.mouseEventClickState))
            if let kind = SelectionGesture.classify(down: downPoint, up: up, clickCount: clicks, flags: Modifiers(event.flags),
                                                    triggers: config.triggers, required: config.required) {
                schedule(kind, after: config.delay, pointer: up, start: downPoint)
            }
        case .rightMouseDown, .otherMouseDown:
            cancelPending()
            if barVisible && !barFrame.contains(event.location) { dismiss() }
        case .scrollWheel:
            if barVisible && !barKeyboard && !barFrame.contains(event.location) { dismiss() }
        case .keyDown:
            return keyDown(event)
        case .keyUp:
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            if code >= 0, code < 128, swallowedUps[code] {
                swallowedUps[code] = false
                return .consume
            }
        case .flagsChanged:
            if shiftSelecting && !event.flags.contains(.maskShift) {
                shiftSelecting = false
                guard config.autoShow, config.triggers.keyboard, !frontmostExcluded,
                      SelectionGesture.modifiersAllow(Modifiers(event.flags), required: config.required) else { return .pass }
                schedule(.keyboard, after: max(config.delay, 0.12), pointer: event.location, start: nil)
            }
        default:
            break
        }
        return .pass
    }

    private func keyDown(_ event: CGEvent) -> TapDecision {
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        if barVisible {
            if barKeyboard, let onBarKey, onBarKey(code, event.flags.contains(.maskShift)) {
                if code >= 0, code < 128 { swallowedUps[code] = true }
                return .consume
            }
            if config.showShortcut?.matches(event) != true { dismiss() }
        }
        cancelPending()
        if config.autoShow, config.triggers.keyboard, event.flags.contains(.maskShift), Self.isNavigation(code) {
            shiftSelecting = true
        }
        return .pass
    }

    private static func isNavigation(_ code: Int) -> Bool {
        switch code {
        case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow, kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown: true
        default: false
        }
    }
}
