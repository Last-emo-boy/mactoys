import AppKit
import MacToysCore
import SwiftUI

/// Everything Auto Tiling does with the mouse: drag a tiled window onto another tile to swap
/// (the target lights up), resize a tile so its neighbors follow, the quick-action pill above a
/// window's title bar, and activating windows on hover.
///
/// The event-tap handler only copies a few scalars. A 60 Hz timer runs while the button is down
/// (Accessibility reads, hit tests, the target overlay) and a 10 Hz timer while the pointer moves
/// with hover features on; neither runs otherwise.
@MainActor
final class MouseController {
    private unowned let engine: TilingEngine
    private static let tapID = "autotile.mouse"

    private enum Phase { case idle, pressed, candidate, dragging, resizing, ignored }

    // Written by the tap handler (scalars only).
    private var phase = Phase.idle
    private var location = CGPoint.zero
    private var pressLocation = CGPoint.zero
    private var optionDown = false
    private var lastEvent: TimeInterval = 0
    private var hoverWanted = false
    private var hoverScheduled = false

    // Drag session, owned by the pump.
    private var pump: Timer?
    private var ticks = 0
    private var window: CGWindowID?
    private var ref: WindowRef?
    private var startFrame = CGRect.zero
    private var target: TilingEngine.DropTarget?
    private var targetPanel: OverlayPanel?
    private let targetModel = SwapTargetModel()
    /// The target's frame (top-left coordinates).
    private var targetFrame = CGRect.zero

    // Hover.
    private var hoverTimer: Timer?
    private var lastHoverPoint = CGPoint(x: -1, y: -1)
    private var restSince: TimeInterval = 0
    private var focusAttempt: CGWindowID?
    private var pillPanel: OverlayPanel?
    private var pillWindow: CGWindowID?
    private var pillFrame = CGRect.zero
    private var pillLeftAt: TimeInterval?

    private(set) var isRunning = false
    private var dragToSwap = true
    private var quickActions = true
    private var focusFollowsMouse = false
    private var focusDelay: TimeInterval = 0.25

    init(engine: TilingEngine) {
        self.engine = engine
    }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func start(_ s: AutoTilingSettings) {
        isRunning = true
        configure(s)
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        InputTap.shared.remove(Self.tapID)
        installedHover = nil
        hoverWanted = false
        endSession()
        stopHover()
        hidePill()
        targetPanel?.close()
        targetPanel = nil
        pillPanel?.close()
        pillPanel = nil
    }

    /// Picks up setting changes; the tap listens to pointer moves only when a hover feature is on.
    func configure(_ s: AutoTilingSettings) {
        dragToSwap = s.dragToSwap
        quickActions = s.quickActionsAboveWindows
        focusFollowsMouse = s.focusFollowsMouse
        focusDelay = min(max(s.focusDelay, 0), 2000) / 1000
        guard isRunning else { return }
        let wantsHover = quickActions || focusFollowsMouse
        if wantsHover != installedHover {
            installedHover = wantsHover
            hoverWanted = wantsHover
            var events: [CGEventType] = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
            if wantsHover { events.append(.mouseMoved) }
            InputTap.shared.add(Self.tapID, priority: 35, events: events) { [weak self] type, event in
                self?.handle(type, event) ?? .pass
            }
        }
        if !wantsHover {
            stopHover()
            hidePill()
        } else if !quickActions {
            hidePill()
        }
    }

    /// Whether the installed tap listens to pointer moves (nil: not installed).
    private var installedHover: Bool?

    /// Layout changed: the pill follows its window or goes.
    func layoutChanged() {
        guard let id = pillWindow else { return }
        guard engine.isActive, let w = engine.window(id), engine.isTiled(id) || engine.isFloating(id) else {
            hidePill()
            return
        }
        if w.frame.minY != pillFrame.minY - 6 || abs(w.frame.midX - pillFrame.midX) > 1 { hidePill() }
    }

    // MARK: Tap (hot path: scalars only)

    private func handle(_ type: CGEventType, _ event: CGEvent) -> TapDecision {
        switch type {
        case .mouseMoved:
            location = event.location
            if hoverTimer == nil && !hoverScheduled && hoverWanted {
                hoverScheduled = true
                DispatchQueue.main.async { [weak self] in self?.startHover() }
            }
        case .leftMouseDown:
            if phase != .idle { release() }       // the previous release never reached us
            phase = .pressed
            pressLocation = event.location
            location = pressLocation
            optionDown = event.flags.contains(.maskAlternate)
            lastEvent = Self.now
        case .leftMouseDragged:
            guard phase != .idle && phase != .ignored else { return .pass }
            location = event.location
            optionDown = event.flags.contains(.maskAlternate)
            lastEvent = Self.now
            if pump == nil { startPump() }
        case .leftMouseUp:
            guard phase != .idle else { return .pass }
            location = event.location
            optionDown = event.flags.contains(.maskAlternate)
            release()
        default:
            break
        }
        return .pass
    }

    // MARK: Drag session

    private func startPump() {
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pump = timer          // the first tick runs outside the tap callback
    }

    private func tick() {
        ticks += 1
        // A release the tap never saw (it can be disabled while the main thread is busy).
        if Self.now - lastEvent > 1, !CGEventSource.buttonState(.hidSystemState, button: .left) {
            release()
            return
        }
        switch phase {
        case .pressed:
            guard engine.isActive, !Self.isOverOwnWindow(pressLocation), let w = WindowRef.at(pressLocation) else {
                ignore()
                return
            }
            hidePill()
            // An app that stops responding must not stall the drag.
            AXUIElementSetMessagingTimeout(w.element, 0.25)
            guard let id = w.windowID, engine.isTiled(id), let f = w.frame else { ignore(); return }
            window = id
            ref = w
            startFrame = f
            phase = .candidate
        case .candidate:
            guard ticks % 2 == 0, let w = ref, let id = window else { return }
            guard let f = w.frame else { ignore(); return }
            let travelled = hypot(location.x - pressLocation.x, location.y - pressLocation.y)
            let resized = abs(f.width - startFrame.width) > 1 || abs(f.height - startFrame.height) > 1
            let moved = abs(f.minX - startFrame.minX) > 1 || abs(f.minY - startFrame.minY) > 1
            if resized && travelled > 2 {
                phase = .resizing
                engine.beginDrag(id)
            } else if moved && travelled > 2 {
                phase = .dragging
                engine.beginDrag(id)
                updateTarget()
            } else if travelled > 24 {
                ignore()      // the pointer travelled but the window stayed: selecting text, dragging a file…
            }
        case .dragging:
            updateTarget()
            updateCutout()
        case .resizing, .idle, .ignored:
            break
        }
    }

    private func updateTarget() {
        guard let id = window else { return }
        let t = dragToSwap && !optionDown ? engine.dropTarget(at: location, dragging: id) : nil
        guard t != target else { return }
        target = t
        showTarget(t)
    }

    /// Mouse released. Runs inside the tap: the Accessibility work is queued for right after.
    private func release() {
        let phase = self.phase, id = window, ref = self.ref, target = self.target, float = optionDown
        let swap = dragToSwap
        endSession()
        let engine = self.engine
        DispatchQueue.main.async {
            switch phase {
            case .dragging:
                if let id { engine.finishDrag(id, target: swap ? target : nil, float: float, frame: ref?.frame) } else { engine.mouseReleased() }
            case .resizing:
                if let id, let f = ref?.frame { engine.finishResize(id, frame: f) } else { engine.mouseReleased() }
            default:
                engine.mouseReleased()
            }
        }
    }

    private func ignore() {
        phase = .ignored
        pump?.invalidate()
        pump = nil
    }

    private func endSession() {
        pump?.invalidate()
        pump = nil
        phase = .idle
        ticks = 0
        window = nil
        ref = nil
        target = nil
        targetPanel?.orderOut(nil)
    }

    private func showTarget(_ t: TilingEngine.DropTarget?) {
        guard let t else {
            targetPanel?.orderOut(nil)
            return
        }
        let frame: CGRect
        let kind: SwapTargetView.Kind
        var radius = WindowCorners.titlebarRadius
        switch t {
        case .tile(_, let other, let f):
            frame = f
            let w = engine.window(other)
            kind = .swap(app: w?.appName ?? "")
            radius = w?.cornerRadius ?? radius
        case .display(let key, let area):
            frame = area
            kind = .move(display: engine.display(key)?.name ?? "")
        }
        targetModel.kind = kind
        targetModel.radius = radius
        targetModel.cutoutRadius = window.flatMap { engine.window($0)?.cornerRadius } ?? WindowCorners.titlebarRadius
        targetModel.generation += 1
        targetFrame = frame
        updateCutout()
        let cocoa = ScreenGeometry.toCocoa(frame)
        let panel = targetPanel ?? {
            let p = OverlayPanel(frame: cocoa, interactive: false, level: NSWindow.Level(rawValue: HighlightOverlay.level.rawValue + 1))
            p.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
            p.setContent(SwapTargetHost(model: targetModel))
            return p
        }()
        panel.setFrame(cocoa, display: true)
        panel.orderFrontRegardless()
        targetPanel = panel
    }

    /// Keeps the target from tinting the dragged window: it follows the pointer, so its frame is
    /// the start frame moved by the pointer's travel (no Accessibility read).
    private func updateCutout() {
        guard target != nil else { return }
        let dragged = startFrame.offsetBy(dx: location.x - pressLocation.x, dy: location.y - pressLocation.y)
        let local = dragged.offsetBy(dx: -targetFrame.minX, dy: -targetFrame.minY)
        if targetModel.cutout != local { targetModel.cutout = local }
    }

    /// Never hit-test MacToys' own windows through Accessibility (the request would wait on itself).
    private static func isOverOwnWindow(_ p: CGPoint) -> Bool {
        let cocoa = ScreenGeometry.toCocoa(p)
        return NSApp.windows.contains { $0.isVisible && !$0.ignoresMouseEvents && $0.frame.contains(cocoa) }
    }

    // MARK: Hover

    private func startHover() {
        hoverScheduled = false
        guard isRunning, hoverWanted, hoverTimer == nil else { return }
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.hoverTick() }
        }
        t.tolerance = 0.02
        RunLoop.main.add(t, forMode: .common)
        hoverTimer = t
        restSince = Self.now
    }

    private func stopHover() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        focusAttempt = nil
    }

    private func hoverTick() {
        let t = Self.now
        guard engine.isActive, phase == .idle || phase == .ignored else {
            hidePill()
            return
        }
        let p = location
        if p != lastHoverPoint {
            lastHoverPoint = p
            restSince = t
        }
        let rested = t - restSince
        let gap = engine.settings.value.gapPoints
        let hit = engine.hit(at: p) ?? engine.hit(at: CGPoint(x: p.x, y: p.y + gap / 2 + 2))
        if quickActions { updatePill(hit, at: p, rested: rested, now: t) }
        if focusFollowsMouse { focusIfResting(hit, at: p, rested: rested) }
        // Nothing left to watch: sleep until the pointer moves again.
        if rested > 1.2 && pillWindow == nil { stopHover() }
    }

    private func focusIfResting(_ hit: TilingEngine.Hit?, at p: CGPoint, rested: TimeInterval) {
        guard let hit else { focusAttempt = nil; return }
        guard hit.window != engine.focusedID, hit.window != focusAttempt, rested >= focusDelay,
              NSEvent.pressedMouseButtons == 0, !pillFrame.contains(p) else { return }
        focusAttempt = hit.window
        // Only the window really in front at the pointer, and never while a menu is open.
        guard !Self.menuIsOpen(), Self.frontWindow(at: p) == hit.window else { return }
        engine.activate(hit.window)
    }

    /// The window a click at a point (top-left coordinates) would reach. The window list can't tell:
    /// Notification Center, the Dock and some apps keep transparent windows in front of every app,
    /// and MacToys' overlays let clicks through.
    private static func frontWindow(at p: CGPoint) -> CGWindowID? {
        let number = NSWindow.windowNumber(at: ScreenGeometry.toCocoa(p), belowWindowWithWindowNumber: 0)
        return number > 0 ? CGWindowID(number) : nil
    }

    private static func menuIsOpen() -> Bool {
        let menuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
        return list.contains { ($0[kCGWindowLayer as String] as? Int) == menuLevel }
    }

    // MARK: Quick-action pill

    /// The strip along the top edge of a window that brings up its pill (clear of the traffic lights).
    private func triggerZone(_ frame: CGRect, gap: CGFloat) -> CGRect {
        let inset = min(96, frame.width * 0.2)
        return CGRect(x: frame.minX + inset, y: frame.minY - max(gap, 4), width: max(0, frame.width - inset * 2),
                      height: max(gap, 4) + 10)
    }

    private func updatePill(_ hit: TilingEngine.Hit?, at p: CGPoint, rested: TimeInterval, now t: TimeInterval) {
        let gap = engine.settings.value.gapPoints
        if pillWindow != nil {
            let keep = pillFrame.insetBy(dx: -8, dy: -8).contains(p)
                || (hit?.window == pillWindow && hit.map { triggerZone($0.frame, gap: gap).contains(p) } == true)
            if keep {
                pillLeftAt = nil
            } else if let left = pillLeftAt {
                if t - left > 0.35 { hidePill() }
            } else {
                pillLeftAt = t
            }
            return
        }
        guard let hit, triggerZone(hit.frame, gap: gap).contains(p), rested >= 0.25,
              NSEvent.pressedMouseButtons == 0,
              // Only for the window really in front there (a floating window may cover the tile's edge).
              Self.frontWindow(at: CGPoint(x: p.x, y: max(p.y, hit.frame.minY + 2))) == hit.window else { return }
        showPill(for: hit)
    }

    private func showPill(for hit: TilingEngine.Hit) {
        let id = hit.window
        let isMain = engine.tiles(on: hit.display).first?.first == id
        let floating = engine.isFloating(id)
        let multiple = engine.displays.count > 1
        let view = QuickActionPillView(
            isMain: isMain, isFloating: floating, canSendToDisplay: multiple,
            onMakeMain: { [weak self] in self?.pillAction { $0.makeMain(id) } },
            onToggleFloat: { [weak self] in self?.pillAction { $0.toggleFloat(id) } },
            onSendToDisplay: { [weak self] in self?.pillAction { $0.sendToNextDisplay(id) } })
        let size = QuickActionPillView.size(buttons: multiple ? 3 : 2)
        let frame = CGRect(x: (hit.frame.midX - size.width / 2).rounded(), y: hit.frame.minY + 6, width: size.width, height: size.height)
        let cocoa = ScreenGeometry.toCocoa(frame.insetBy(dx: -12, dy: -12))
        let panel = pillPanel ?? OverlayPanel(frame: cocoa, interactive: true, level: NSWindow.Level(rawValue: HighlightOverlay.level.rawValue + 1))
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.setFrame(cocoa, display: false)
        panel.setContent(view.frame(maxWidth: .infinity, maxHeight: .infinity))
        panel.orderFrontRegardless()
        pillPanel = panel
        pillWindow = id
        pillFrame = frame
        pillLeftAt = nil
    }

    private func pillAction(_ action: (TilingEngine) -> Void) {
        hidePill()
        action(engine)
    }

    private func hidePill() {
        guard pillWindow != nil else { return }
        pillWindow = nil
        pillFrame = .zero
        pillLeftAt = nil
        pillPanel?.orderOut(nil)
    }
}
