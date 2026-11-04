import AppKit
import ApplicationServices
import MacToysCore

/// The displays connected now, as Window Controls sees them.
@MainActor
enum Screens {
    static func current() -> [DisplayBox] {
        let screens = NSScreen.screens
        let keys = DisplayArrangement.keys(stableIDs: screens.map(\.stableID), displayIDs: screens.map(\.displayID))
        let main = screens.first
        return screens.enumerated().map { i, s in
            DisplayBox(key: keys[i], id: s.displayID, name: s.localizedName, frame: s.axFrame, visible: s.axVisibleFrame,
                       isMain: s == main)
        }
    }

    static func layoutDisplays() -> [LayoutDisplay] {
        current().map { LayoutDisplay(key: $0.key, name: $0.name, frame: $0.frame, visible: $0.visible, isMain: $0.isMain) }
    }
}

/// What happened when Window Controls tried to move a window.
enum MoveOutcome: Equatable {
    case moved(CGRect)
    /// Already there.
    case unchanged
    /// The window is on (or would go to) a display Auto Tiling arranges.
    case tiled
    case failed
}

/// Moves windows through Accessibility: runs controls (and their chains), remembers the frame each
/// window had before so it can be reverted, and leaves displays Auto Tiling manages alone.
@MainActor
final class WindowMover {
    private let settings: Persisted<WindowControlsSettings>
    /// The frame each window had before Window Controls last moved it.
    private var previous: [WindowRef: CGRect] = [:]
    /// Where each cycling chain left each window.
    private var cycles: [CycleKey: (index: Int, frame: CGRect)] = [:]
    /// Called after a window moved (keyboard mode redraws its ring, layouts take a new snapshot).
    var onMove: ((WindowRef, CGRect) -> Void)?
    private let log = Log.for("windowcontrols")

    private struct CycleKey: Hashable {
        let window: WindowRef
        let control: UUID
    }

    init(settings: Persisted<WindowControlsSettings>) {
        self.settings = settings
    }

    func reset() {
        previous.removeAll()
        cycles.removeAll()
    }

    // MARK: Windows

    /// The focused window of the frontmost app, never one of MacToys' own: an Accessibility request
    /// into our own process from the main thread would wait on itself until it times out.
    static func focusedWindow() -> WindowRef? {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return nil
        }
        guard let w = WindowRef.focused() else { return nil }
        AXUIElementSetMessagingTimeout(w.element, 0.5)
        return w
    }

    /// Whether Window Controls may move this window.
    func canArrange(_ w: WindowRef) -> Bool {
        guard w.pid != ProcessInfo.processInfo.processIdentifier, w.role == kAXWindowRole as String else { return false }
        if settings.value.excludedApps.matches(app: w.app) { return false }
        return !w.isFullScreen && !w.isMinimized
    }

    /// Whether Auto Tiling arranges the display showing `frame`.
    func isTiled(_ frame: CGRect, displays: [DisplayBox]) -> Bool {
        guard let check = Services.autoTilingManagesDisplay,
              let i = DisplayNavigator.index(showing: frame, in: displays) else { return false }
        return check(displays[i].id)
    }

    func context(for w: WindowRef, displays: [DisplayBox]? = nil) -> PlanContext {
        PlanContext(displays: displays ?? Screens.current(), spacing: settings.value.spacing, resizable: w.isResizable)
    }

    // MARK: Controls

    /// Runs a control on a window: every step at once, or, for a cycling chain, the step after the
    /// one it ran last on this window.
    @discardableResult
    func run(_ control: WindowControl, on w: WindowRef) -> MoveOutcome {
        guard let frame = w.frame else { return .failed }
        let ctx = context(for: w)
        let steps: [ControlStep]
        var cycleIndex: Int?
        if control.chainMode == .cycle && control.steps.count > 1 {
            let key = CycleKey(window: w, control: control.id)
            let last = cycles[key]
            let i = ControlPlanner.nextCycleIndex(count: control.steps.count, last: last?.index, lastFrame: last?.frame,
                                                  current: frame)
            steps = [control.steps[i]]
            cycleIndex = i
        } else {
            steps = control.steps
        }
        guard let target = ControlPlanner.plan(steps, frame: frame, context: ctx) else { return .unchanged }
        let outcome = place(w, at: target, from: frame, displays: ctx.displays)
        if let cycleIndex {
            if case .moved(let applied) = outcome {
                cycles[CycleKey(window: w, control: control.id)] = (cycleIndex, applied)
            } else if outcome == .unchanged {
                cycles[CycleKey(window: w, control: control.id)] = (cycleIndex, frame)
            }
            if cycles.count > 128 { cycles = cycles.filter { $0.key.window.position != nil } }
        }
        return outcome
    }

    /// Runs steps that aren't a saved control (keyboard mode, the grid, display buttons).
    @discardableResult
    func run(steps: [ControlStep], on w: WindowRef) -> MoveOutcome {
        guard let frame = w.frame else { return .failed }
        let ctx = context(for: w)
        guard let target = ControlPlanner.plan(steps, frame: frame, context: ctx) else { return .unchanged }
        return place(w, at: target, from: frame, displays: ctx.displays)
    }

    /// Moves a window to `target`, remembering where it was. Apps that keep a size of their own
    /// (minimum sizes, size steps) are lined up against the same edges as the target.
    /// - Parameter quiet: no HUD when Auto Tiling owns the display (layout restores report once).
    @discardableResult
    func place(_ w: WindowRef, at target: CGRect, from current: CGRect? = nil, displays: [DisplayBox]? = nil,
               quiet: Bool = false, focus: Bool = true) -> MoveOutcome {
        guard let current = current ?? w.frame else { return .failed }
        let screens = displays ?? Screens.current()
        if isTiled(current, displays: screens) || isTiled(target, displays: screens) {
            if !quiet { HUD.show("Auto Tiling arranges this display", symbol: "rectangle.split.2x2") }
            return .tiled
        }
        if Placement.isClose(current, target, tolerance: 0.5) {
            if focus && settings.value.bringToFront { w.focus() }
            return .unchanged
        }
        AXUIElementSetMessagingTimeout(w.element, 0.5)
        remember(w, current)
        w.setFrame(target)
        var final = w.frame ?? target
        if abs(final.width - target.width) > 1 || abs(final.height - target.height) > 1,
           let i = DisplayNavigator.index(showing: target, in: screens) {
            let area = Placement.workArea(screens[i].visible, settings.value.spacing)
            let aligned = Placement.realigned(actual: final.size, target: target, area: area)
            if aligned.origin != final.origin {
                w.setPosition(aligned.origin)
                final = w.frame ?? aligned
            }
        }
        if focus && settings.value.bringToFront { w.focus() }
        onMove?(w, final)
        return .moved(final)
    }

    /// Puts a window back where it was before Window Controls last moved it.
    @discardableResult
    func revert(_ w: WindowRef) -> MoveOutcome {
        guard let before = previous[w] else { return .unchanged }
        return place(w, at: before)
    }

    func canRevert(_ w: WindowRef) -> Bool { previous[w] != nil }

    /// Fills the screen, or, when the window already fills it, puts it back.
    @discardableResult
    func toggleFill(_ w: WindowRef) -> MoveOutcome {
        guard let frame = w.frame else { return .failed }
        let ctx = context(for: w)
        guard let fill = ControlPlanner.plan([.place(.full)], frame: frame, context: ctx) else { return .failed }
        if Placement.isClose(frame, fill, tolerance: 4), previous[w] != nil { return revert(w) }
        return place(w, at: fill, from: frame, displays: ctx.displays)
    }

    private func remember(_ w: WindowRef, _ frame: CGRect) {
        previous[w] = frame
        if previous.count > 96 { previous = previous.filter { $0.key.position != nil } }
    }
}
