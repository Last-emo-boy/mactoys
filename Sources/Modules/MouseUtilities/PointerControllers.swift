import AppKit
import Carbon.HIToolbox
import MacToysCore

/// CursorWrap: pushing the pointer past an outer edge of the desktop brings it in on the far side.
@MainActor
final class CursorWrap {
    static let tapID = "mouseutils.cursorwrap"

    private(set) var settings: CursorWrapSettings
    private(set) var isActive = false
    private var displays: [CGRect] = []
    private var screenObserver: NSObjectProtocol?
    var onChange: (() -> Void)?

    init(settings: CursorWrapSettings) { self.settings = settings }

    func update(_ s: CursorWrapSettings) { settings = s }

    func setActive(_ on: Bool) {
        guard on != isActive else { return }
        isActive = on
        if on {
            displays = NSScreen.screens.map(\.axFrame)
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.displays = NSScreen.screens.map(\.axFrame) }
            }
            InputTap.shared.add(Self.tapID, priority: 20,
                                events: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]) { [weak self] type, event in
                self?.handle(type, event)
                return .pass
            }
        } else {
            InputTap.shared.remove(Self.tapID)
            if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
            screenObserver = nil
        }
        onChange?()
    }

    func toggle() {
        guard isActive || ensureAccessibility() else { return }
        setActive(!isActive)
        HUD.show(isActive ? "CursorWrap on" : "CursorWrap off", symbol: "arrow.left.and.right.square")
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        if type != .mouseMoved && settings.disableWhileDragging { return }
        if settings.disableOnSingleMonitor && displays.count < 2 { return }
        switch settings.activation {
        case .always: break
        case .holdingControl: guard event.flags.contains(.maskControl) else { return }
        case .holdingShift: guard event.flags.contains(.maskShift) else { return }
        }
        let delta = CGVector(dx: event.getDoubleValueField(.mouseEventDeltaX), dy: event.getDoubleValueField(.mouseEventDeltaY))
        guard let target = CursorWrapMath.wrap(event.location, delta: delta, displays: displays, mode: settings.mode) else { return }
        MouseSynth.warp(to: target)
        event.location = target
    }
}

/// Auto Hide Cursor: hides the pointer while you type and/or after it sits still; intentional
/// movement, a click or scrolling brings it back.
@MainActor
final class AutoHideCursor {
    static let tapID = "mouseutils.autohide"

    private(set) var settings: AutoHideSettings
    private var running = false
    private var hidePoint = CGPoint.zero
    private var lastMove: TimeInterval = 0
    private var idleTimer: Timer?
    private(set) var isHidden = false
    var onHiddenChange: ((Bool) -> Void)?

    init(settings: AutoHideSettings) { self.settings = settings }

    func update(_ s: AutoHideSettings) {
        settings = s
        if running { scheduleIdleCheck() }
        if !s.hideWhileTyping && !s.hideWhenIdle { reveal() }
    }

    func start() {
        guard !running else { return }
        running = true
        lastMove = ProcessInfo.processInfo.systemUptime
        InputTap.shared.add(Self.tapID, priority: 0,
                            events: [.keyDown, .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                                     .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { [weak self] type, event in
            self?.handle(type, event)
            return .pass
        }
        scheduleIdleCheck()
    }

    func stop() {
        guard running else { return }
        running = false
        InputTap.shared.remove(Self.tapID)
        idleTimer?.invalidate()
        idleTimer = nil
        reveal()
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .keyDown:
            guard settings.hideWhileTyping else { return }
            // Shortcuts aren't typing.
            if !event.flags.intersection([.maskCommand, .maskControl]).isEmpty { return }
            conceal(at: event.location)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel:
            lastMove = ProcessInfo.processInfo.systemUptime
            reveal()
        default:
            lastMove = ProcessInfo.processInfo.systemUptime
            guard isHidden else { return }
            let p = event.location
            if hypot(p.x - hidePoint.x, p.y - hidePoint.y) >= max(settings.movementThreshold, 0.5) { reveal() }
        }
    }

    private func conceal(at p: CGPoint) {
        guard !isHidden else { return }
        hidePoint = p
        CursorVisibility.hide()
        isHidden = true
        onHiddenChange?(true)
    }

    private func reveal() {
        guard isHidden else { return }
        CursorVisibility.show()
        isHidden = false
        onHiddenChange?(false)
    }

    private func scheduleIdleCheck() {
        idleTimer?.invalidate()
        idleTimer = nil
        guard running, settings.hideWhenIdle else { return }
        idleTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isHidden else { return }
                let idle = ProcessInfo.processInfo.systemUptime - self.lastMove
                let buttons = [CGMouseButton.left, .right, .center].contains {
                    CGEventSource.buttonState(.hidSystemState, button: $0)
                }
                if idle >= max(self.settings.idleDelay, 1) && !buttons { self.conceal(at: MouseSynth.location) }
            }
        }
    }
}

/// Mouse Button Lock: hold a button still to keep it down after release; the next click lets go.
@MainActor
final class MouseButtonLock {
    static let tapID = "mouseutils.buttonlock"

    private(set) var settings: ButtonLockSettings
    private var machine: ButtonLockMachine
    private var running = false

    init(settings: ButtonLockSettings) {
        self.settings = settings
        machine = ButtonLockMachine(lockable: [], holdDuration: 1.2, dragThreshold: 5)
        update(settings)
    }

    func update(_ s: ButtonLockSettings) {
        settings = s
        var lockable: Set<ButtonLockMachine.Button> = []
        if s.left { lockable.insert(.left) }
        if s.right { lockable.insert(.right) }
        if s.middle { lockable.insert(.middle) }
        machine.lockable = lockable
        machine.holdDuration = min(max(s.holdDuration, 200), 2200) / 1000
        machine.dragThreshold = min(max(s.dragThreshold, 0), 100)
    }

    func start() {
        guard !running else { return }
        running = true
        InputTap.shared.add(Self.tapID, priority: 60,
                            events: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown,
                                     .otherMouseUp, .mouseMoved, .leftMouseDragged, .rightMouseDragged,
                                     .otherMouseDragged]) { [weak self] type, event in
            self?.handle(type, event) ?? .pass
        }
    }

    func stop() {
        guard running else { return }
        running = false
        InputTap.shared.remove(Self.tapID)
        // Never leave a button logically held down.
        if let locked = machine.lockedButton {
            MouseSynth.button(MouseEvents.cgButton(locked), down: false)
        }
        machine.reset()
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> TapDecision {
        let now = ProcessInfo.processInfo.systemUptime
        if type.isMouseMoveOrDrag {
            return apply(machine.moved(to: event.location), to: event)
        }
        guard let button = Self.button(type, event) else { return .pass }
        if type.isMouseDown {
            return apply(machine.down(button, at: now, point: event.location), to: event)
        }
        let (decision, lockedNow) = machine.up(button, at: now)
        if lockedNow {
            HUD.show(Self.lockedMessage(button), symbol: "lock.fill", duration: 1.2)
            if button == .right { ContextMenuDismisser.dismissSoon() }
        }
        return apply(decision, to: event)
    }

    private func apply(_ d: ButtonLockMachine.Decision, to event: CGEvent) -> TapDecision {
        switch d {
        case .pass:
            return .pass
        case .swallow:
            return .consume
        case .becomeUp(let locked):
            event.type = MouseEvents.type(down: false, button: locked)
            event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(locked.rawValue))
            if locked == .right { ContextMenuDismisser.dismissSoon(after: 0.15) }
            return .pass
        case .becomeDrag(let locked):
            event.type = MouseEvents.dragType(locked)
            event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(locked.rawValue))
            return .pass
        case .becomeMove:
            event.type = .mouseMoved
            return .pass
        }
    }

    private static func button(_ type: CGEventType, _ event: CGEvent) -> ButtonLockMachine.Button? {
        switch type {
        case .leftMouseDown, .leftMouseUp: return .left
        case .rightMouseDown, .rightMouseUp: return .right
        case .otherMouseDown, .otherMouseUp: return MouseEvents.button(event) == 2 ? .middle : nil
        default: return nil
        }
    }

    private static func lockedMessage(_ b: ButtonLockMachine.Button) -> String {
        switch b {
        case .left: String(localized: "Left button locked · click to release")
        case .right: String(localized: "Right button locked · click to release")
        case .middle: String(localized: "Middle button locked · click to release")
        }
    }
}
