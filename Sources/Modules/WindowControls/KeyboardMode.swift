import AppKit
import Carbon.HIToolbox
import MacToysCore
import SwiftUI

/// Keyboard mode (⌃⌥K): a HUD lists the keys while arrows, ⇧/⌥-arrows, Space, Return, number keys
/// and Tab arrange the focused window; Esc (or a click, or a while without keys) leaves.
///
/// Keys reach the shared event tap only while the mode is open. The tap handler maps the key code
/// to an action in O(1), swallows the key and queues the action, so Accessibility calls to the
/// window's app never run inside the tap.
@MainActor
final class KeyboardMode {
    enum Action: Equatable {
        case half(ArrowKey)
        case resize(ArrowKey)
        case nudge(ArrowKey, fine: Bool)
        case center, fill, nextDisplay, undo
        /// 1-based number of a custom control.
        case control(Int)
        case cycle(forward: Bool)
        case leave

        /// Whether holding the key repeats the action.
        var repeats: Bool {
            switch self {
            case .resize, .nudge: true
            default: false
            }
        }
    }

    private let settings: Persisted<WindowControlsSettings>
    private let mover: WindowMover
    private let model = KeyboardHUDModel()
    private var hudPanel: OverlayPanel?
    private var ringPanel: OverlayPanel?
    private var target: WindowRef?
    private var lastArrow: (arrow: ArrowKey, time: TimeInterval)?
    private var cycleOrder: [CGWindowID] = []
    private var idleTimer: Timer?
    private var clickMonitor: Any?
    private var clearAction: DispatchWorkItem?
    /// Key codes whose key-down was swallowed, so their key-up is swallowed too.
    private var swallowUp = [Bool](repeating: false, count: 128)
    private var toggleShortcut: Shortcut?
    private static let tapID = "windowcontrols.keyboard"
    /// Two arrows within this many seconds make a quarter.
    private static let comboWindow: TimeInterval = 0.6
    private static let idleTimeout: TimeInterval = 20

    private(set) var isActive = false

    init(settings: Persisted<WindowControlsSettings>, mover: WindowMover) {
        self.settings = settings
        self.mover = mover
    }

    func toggle() { isActive ? leave() : enter() }

    func enter() {
        guard !isActive else { return }
        guard AXIsProcessTrusted() else {
            HUD.show("Accessibility permission needed", symbol: "exclamationmark.shield")
            PermissionCenter.shared.request(.accessibility)
            return
        }
        guard let w = WindowMover.focusedWindow(), mover.canArrange(w), let frame = w.frame else {
            HUD.show("No window to arrange", symbol: "macwindow")
            return
        }
        target = w
        isActive = true
        lastArrow = nil
        cycleOrder = []
        swallowUp = [Bool](repeating: false, count: 128)
        toggleShortcut = settings.value.keyboardShortcut
        InputTap.shared.add(Self.tapID, priority: 90, events: [.keyDown, .keyUp]) { [weak self] type, event in
            self?.handle(type, event) ?? .pass
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.leave() }
        }
        refreshModel(for: w)
        presentHUD(near: frame)
        showRing(around: frame, animated: false)
        resetIdle()
    }

    func leave() {
        guard isActive else { return }
        isActive = false
        InputTap.shared.remove(Self.tapID)
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        idleTimer?.invalidate()
        idleTimer = nil
        clearAction?.cancel()
        clearAction = nil
        hudPanel?.orderOut(nil)
        ringPanel?.orderOut(nil)
        target = nil
        model.lastAction = nil
    }

    func tearDown() {
        leave()
        hudPanel?.close()
        hudPanel = nil
        ringPanel?.close()
        ringPanel = nil
    }

    // MARK: Event tap (main thread, every key while open)

    private func handle(_ type: CGEventType, _ event: CGEvent) -> TapDecision {
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        if type == .keyUp {
            guard code >= 0, code < swallowUp.count, swallowUp[code] else { return .pass }
            swallowUp[code] = false
            return .consume
        }
        guard type == .keyDown else { return .pass }
        let mods = Modifiers(event.flags).subtracting(.function)
        if mods.contains(.command) || mods.contains(.control) {
            // ⌘ and ⌃ shortcuts belong to the system and apps; the mode's own shortcut closes it.
            let isToggle = toggleShortcut?.matches(event) == true
            queue(.leave)
            return isToggle ? swallow(code) : .pass
        }
        guard let action = Self.action(keyCode: code, modifiers: mods) else {
            queue(.leave)
            return .pass
        }
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 && !action.repeats { return swallow(code) }
        queue(action)
        return swallow(code)
    }

    private func swallow(_ code: Int) -> TapDecision {
        if code >= 0, code < swallowUp.count { swallowUp[code] = true }
        return .consume
    }

    private func queue(_ action: Action) {
        DispatchQueue.main.async { [weak self] in self?.perform(action) }
    }

    /// What a key does in keyboard mode (⌘ and ⌃ are handled before); nil for keys it doesn't use.
    static func action(keyCode: Int, modifiers: Modifiers) -> Action? {
        let shift = modifiers.contains(.shift), option = modifiers.contains(.option)
        let arrow: ArrowKey? = switch keyCode {
        case kVK_LeftArrow: .left
        case kVK_RightArrow: .right
        case kVK_UpArrow: .up
        case kVK_DownArrow: .down
        default: nil
        }
        if let arrow {
            if option { return .nudge(arrow, fine: shift) }
            return shift ? .resize(arrow) : .half(arrow)
        }
        switch keyCode {
        case kVK_Space: return .center
        case kVK_Return, kVK_ANSI_KeypadEnter: return .fill
        case kVK_Tab: return .cycle(forward: !shift)
        case kVK_Escape: return .leave
        case kVK_Delete, kVK_ForwardDelete: return .undo
        case kVK_ANSI_D: return .nextDisplay
        default: break
        }
        let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        let keypad = [kVK_ANSI_Keypad1, kVK_ANSI_Keypad2, kVK_ANSI_Keypad3, kVK_ANSI_Keypad4, kVK_ANSI_Keypad5,
                      kVK_ANSI_Keypad6, kVK_ANSI_Keypad7, kVK_ANSI_Keypad8, kVK_ANSI_Keypad9]
        if let i = digits.firstIndex(of: keyCode) ?? keypad.firstIndex(of: keyCode) { return .control(i + 1) }
        return nil
    }

    // MARK: Actions

    private func perform(_ action: Action) {
        guard isActive else { return }
        resetIdle()
        if action == .leave { return leave() }
        if case .cycle(let forward) = action { return cycleWindow(forward: forward) }
        guard let w = target, let frame = w.frame else { return leave() }
        let s = settings.value
        let displays = Screens.current()
        var label: String?
        let outcome: MoveOutcome
        switch action {
        case .half(let arrow):
            let now = ProcessInfo.processInfo.systemUptime
            let previous = lastArrow.flatMap { now - $0.time < Self.comboWindow ? $0.arrow : nil }
            let combo = previous.map { $0.isHorizontal != arrow.isHorizontal } ?? false
            guard let t = KeyboardGeometry.halfTarget(arrow, previous: combo ? previous : nil, frame: frame,
                                                      displays: displays, spacing: s.spacing) else { return }
            lastArrow = combo ? nil : (arrow, now)
            label = Self.title(of: KeyboardGeometry.half(arrow, after: combo ? previous : nil))
            outcome = mover.place(w, at: t, from: frame, displays: displays)
        case .resize(let arrow):
            guard let i = DisplayNavigator.index(showing: frame, in: displays) else { return }
            let area = Placement.workArea(displays[i].visible, s.spacing)
            let t = KeyboardGeometry.resized(frame, arrow: arrow, step: CGFloat(s.resizeStep), area: area)
            label = "\(Int(t.width)) × \(Int(t.height))"
            outcome = mover.place(w, at: t, from: frame, displays: displays, focus: false)
        case .nudge(let arrow, let fine):
            guard let i = DisplayNavigator.index(showing: frame, in: displays) else { return }
            let t = KeyboardGeometry.nudged(frame, arrow: arrow, step: fine ? 1 : CGFloat(s.nudgeStep),
                                            area: displays[i].visible)
            label = "x \(Int(t.minX))   y \(Int(t.minY))"
            outcome = mover.place(w, at: t, from: frame, displays: displays, focus: false)
        case .center:
            label = BuiltInControls.title("center")
            outcome = mover.run(steps: [.move(.center)], on: w)
        case .fill:
            label = BuiltInControls.title("fill")
            outcome = mover.run(steps: [.place(.full)], on: w)
        case .nextDisplay:
            outcome = mover.run(steps: [.display(.next)], on: w)
            if case .moved(let f) = outcome, let i = DisplayNavigator.index(showing: f, in: displays) {
                label = String(localized: "Moved to \(displays[i].name)", comment: "Keyboard mode: the window went to the display with this name")
            }
        case .undo:
            outcome = mover.revert(w)
            label = String(localized: "Undone", comment: "Keyboard mode: the window was put back where it was")
        case .control(let n):
            let controls = s.keyboardControls
            guard controls.indices.contains(n - 1) else { return }
            label = controls[n - 1].displayName
            outcome = mover.run(controls[n - 1], on: w)
        case .cycle, .leave:
            return
        }
        switch outcome {
        case .moved(let f):
            showRing(around: f, animated: true)
            flash(label)
        case .unchanged:
            flash(label)
        case .tiled, .failed:
            return
        }
        model.canUndo = mover.canRevert(w)
        let arranging = action != .undo
        if arranging && !s.stayInKeyboardMode {
            // Leave once the ring has caught up, so the move reads as the mode's last act.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.leave() }
        }
    }

    /// Arranges the next (or previous) window on screen instead, front to back as they were when ⇥
    /// was first pressed, and brings it forward.
    private func cycleWindow(forward: Bool) {
        let own = ProcessInfo.processInfo.processIdentifier
        let excluded = settings.value.excludedApps
        if cycleOrder.isEmpty {
            cycleOrder = WindowInfo.onScreen().filter { info in
                guard info.pid != own, let app = NSRunningApplication(processIdentifier: info.pid) else { return false }
                return app.activationPolicy == .regular && !excluded.matches(app: app)
            }.map(\.id)
        }
        guard cycleOrder.count > 1 else { return }
        let current = target?.windowID.flatMap { cycleOrder.firstIndex(of: $0) } ?? 0
        for step in 1..<cycleOrder.count {
            let i = (current + (forward ? step : -step) % cycleOrder.count + cycleOrder.count) % cycleOrder.count
            guard let w = WindowRef.with(windowID: cycleOrder[i]), mover.canArrange(w), let frame = w.frame else { continue }
            AXUIElementSetMessagingTimeout(w.element, 0.5)
            target = w
            w.focus()
            refreshModel(for: w)
            presentHUD(near: frame)
            showRing(around: frame, animated: true)
            return
        }
    }

    // MARK: HUD

    private func refreshModel(for w: WindowRef) {
        let s = settings.value
        let app = w.app
        model.appName = app?.localizedName ?? ""
        model.appIcon = app?.icon
        model.windowTitle = w.title ?? ""
        model.lastAction = nil
        model.controls = s.keyboardControls.enumerated().map { KeyboardHUDModel.NumberedControl(number: $0.offset + 1, control: $0.element) }
        model.showCheatSheet = s.showCheatSheet
        model.multipleDisplays = NSScreen.screens.count > 1
        model.canUndo = mover.canRevert(w)
        model.displayKey = KeyCodes.name(for: UInt16(kVK_ANSI_D))
    }

    /// Shows the HUD near the bottom of the display showing `frame`.
    private func presentHUD(near frame: CGRect) {
        let displays = Screens.current()
        guard let i = DisplayNavigator.index(showing: frame, in: displays) else { return }
        let host = NSHostingView(rootView: KeyboardHUDView(model: model).padding(30))
        host.sizingOptions = []
        let size = host.fittingSize
        let visible = displays[i].visible
        let rect = CGRect(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 30,
                          width: size.width, height: size.height)
        let p = hudPanel ?? OverlayPanel(frame: .zero, level: .popUpMenu)
        p.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        p.setFrame(ScreenGeometry.toCocoa(rect), display: true)
        if !p.isVisible {
            p.alphaValue = 0
            p.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.15
                p.animator().alphaValue = 1
            }
        }
        hudPanel = p
    }

    private func showRing(around frame: CGRect, animated: Bool) {
        let p = ringPanel ?? {
            let panel = OverlayPanel(frame: .zero, level: .floating)
            panel.setContent(WindowRing())
            return panel
        }()
        ringPanel = p
        let target = ScreenGeometry.toCocoa(frame.insetBy(dx: -10, dy: -10))
        if animated && p.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                p.animator().setFrame(target, display: true)
            }
        } else {
            p.setFrame(target, display: true)
        }
        p.orderFrontRegardless()
    }

    private func flash(_ text: String?) {
        guard let text else { return }
        model.lastAction = text
        clearAction?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.model.lastAction = nil }
        clearAction = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }

    private func resetIdle() {
        idleTimer?.invalidate()
        let t = Timer(timeInterval: Self.idleTimeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.leave() }
        }
        RunLoop.main.add(t, forMode: .common)
        idleTimer = t
    }

    /// The name of a half or quarter, for the HUD.
    private static func title(of u: UnitRect) -> String? {
        let ids: [(UnitRect, String)] = [
            (UnitRect(x: 0, y: 0, width: 0.5, height: 1), "left-half"), (UnitRect(x: 0.5, y: 0, width: 0.5, height: 1), "right-half"),
            (UnitRect(x: 0, y: 0, width: 1, height: 0.5), "top-half"), (UnitRect(x: 0, y: 0.5, width: 1, height: 0.5), "bottom-half"),
            (UnitRect(x: 0, y: 0, width: 0.5, height: 0.5), "top-left"), (UnitRect(x: 0.5, y: 0, width: 0.5, height: 0.5), "top-right"),
            (UnitRect(x: 0, y: 0.5, width: 0.5, height: 0.5), "bottom-left"), (UnitRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5), "bottom-right"),
        ]
        return ids.first { $0.0 == u }.flatMap { BuiltInControls.title($0.1) }
    }
}
