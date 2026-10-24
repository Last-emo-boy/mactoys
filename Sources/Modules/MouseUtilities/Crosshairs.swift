import AppKit
import Carbon.HIToolbox
import MacToysCore
import QuartzCore

/// Mouse Pointer Crosshairs: lines through the pointer across every display (or of a fixed length),
/// with a gap in the middle and an optional border.
@MainActor
final class Crosshairs {
    static let tapID = "mouseutils.crosshairs"

    private(set) var settings: CrosshairsSettings
    private(set) var isActive = false
    private let overlays = ScreenOverlays(level: .screenSaver)
    private var fills: [[CALayer]] = []
    private var borders: [[CALayer]] = []
    private var pointer = CGPoint.zero
    /// Whether another utility has hidden the pointer (Auto Hide Cursor).
    var pointerHidden: () -> Bool = { false }
    var onChange: (() -> Void)?

    init(settings: CrosshairsSettings) {
        self.settings = settings
        overlays.onBuild = { [weak self] surfaces in self?.build(surfaces) }
    }

    func update(_ s: CrosshairsSettings) {
        settings = s
        guard isActive else { return }
        restyle()
        redraw()
    }

    func setActive(_ on: Bool) {
        guard on != isActive else { return }
        isActive = on
        if on {
            pointer = MouseSynth.location
            overlays.show()
            redraw()
            InputTap.shared.add(Self.tapID, priority: 0,
                                events: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]) { [weak self] _, event in
                self?.moved(to: event.location)
                return .pass
            }
        } else {
            InputTap.shared.remove(Self.tapID)
            overlays.hide()
            fills = []
            borders = []
        }
        onChange?()
    }

    func toggle() {
        guard isActive || ensureAccessibility() else { return }
        setActive(!isActive)
        HUD.show("Crosshairs \(isActive ? "on" : "off")", symbol: "scope")
    }

    /// Re-evaluates visibility (called when Auto Hide Cursor hides or shows the pointer).
    func pointerVisibilityChanged() {
        guard isActive else { return }
        redraw()
    }

    private func moved(to p: CGPoint) {
        pointer = p
        redraw()
    }

    private func build(_ surfaces: [ScreenOverlays.Surface]) {
        fills = []
        borders = []
        for s in surfaces {
            var f: [CALayer] = [], b: [CALayer] = []
            for _ in 0..<4 {
                let border = CALayer()
                let fill = CALayer()
                s.root.addSublayer(border)
                s.root.addSublayer(fill)
                b.append(border)
                f.append(fill)
            }
            fills.append(f)
            borders.append(b)
        }
        restyle()
    }

    private func restyle() {
        let fill = settings.color.cgColor(alpha: 1)
        let border = settings.borderColor.cgColor(alpha: 1)
        for group in fills { for l in group { l.backgroundColor = fill } }
        for group in borders { for l in group { l.backgroundColor = border } }
        for s in overlays.surfaces { s.root.opacity = Float(settings.opacity) }
    }

    private func redraw() {
        let hide = settings.hideWhenPointerHidden && pointerHidden()
        let desktop = overlays.surfaces.reduce(CGRect.null) { $0.union($1.frame) }
        let arms = CrosshairGeometry.arms(center: pointer, bounds: desktop, radius: settings.centerRadius,
                                          thickness: max(settings.thickness, 1),
                                          length: settings.fixedLength ? settings.length : nil,
                                          orientation: settings.orientation)
        let b = CGFloat(settings.borderSize)
        withoutAnimation {
            for (i, s) in overlays.surfaces.enumerated() where i < fills.count {
                for j in 0..<4 {
                    guard !hide, j < arms.count else {
                        fills[i][j].isHidden = true
                        borders[i][j].isHidden = true
                        continue
                    }
                    let local = arms[j].offsetBy(dx: -s.frame.minX, dy: -s.frame.minY)
                    fills[i][j].isHidden = false
                    fills[i][j].frame = local
                    borders[i][j].isHidden = b <= 0
                    borders[i][j].frame = local.insetBy(dx: -b, dy: -b)
                }
            }
        }
    }
}

/// The gliding cursor (accessibility): one shortcut steers the pointer with sweeping lines,
/// then clicks. Esc or a mouse click cancels.
@MainActor
final class GlidingCursorController {
    static let tapID = "mouseutils.glide"

    var travelSpeed: Double = 25
    var delaySpeed: Double = 5
    var color = RGBA(hex: "#FF0000") ?? .accent
    var thickness: Double = 3
    private var machine = GlidingCursor()
    private var timer: Timer?
    private var panel: OverlayPanel?
    private var vertical = CALayer()
    private var horizontal = CALayer()
    private var screenFrame = CGRect.zero

    var isActive: Bool { machine.isActive }

    /// The shortcut was pressed: start, or advance to the next phase.
    func press() {
        if !machine.isActive {
            guard ensureAccessibility() else { return }
            begin()
            return
        }
        if let click = machine.press() {
            finish()
            MouseSynth.warp(to: click)
            MouseSynth.button(.left, down: true, at: click)
            MouseSynth.button(.left, down: false, at: click)
        }
        draw()
    }

    func cancel() {
        guard machine.isActive else { return }
        machine.cancel()
        finish()
    }

    private func begin() {
        let p = MouseSynth.location
        guard let screen = ScreenGeometry.screen(containingAX: p) else { return }
        screenFrame = screen.axFrame
        machine.start(at: p, in: screenFrame)
        let panel = OverlayPanel(frame: screen.frame, level: .screenSaver)
        let view = LayerHostView(frame: CGRect(origin: .zero, size: screen.frame.size), scale: screen.backingScaleFactor)
        panel.contentView = view
        vertical = CALayer()
        horizontal = CALayer()
        for l in [vertical, horizontal] {
            l.backgroundColor = color.cgColor
            l.shadowColor = NSColor.black.cgColor
            l.shadowOpacity = 0.35
            l.shadowRadius = 2
            l.shadowOffset = .zero
            view.root.addSublayer(l)
        }
        panel.orderFrontRegardless()
        self.panel = panel
        draw()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.machine.tick(fast: CGFloat(self.travelSpeed), slow: CGFloat(self.delaySpeed))
                self.draw()
            }
        }
        InputTap.shared.add(Self.tapID, priority: 40, events: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] type, event in
            guard let self else { return .pass }
            if type == .keyDown {
                guard event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_Escape) else { return .pass }
                self.cancel()
                return .consume
            }
            self.cancel()
            return .pass
        }
    }

    private func finish() {
        timer?.invalidate()
        timer = nil
        InputTap.shared.remove(Self.tapID)
        panel?.orderOut(nil)
        panel = nil
    }

    private func draw() {
        let local = CGPoint(x: machine.position.x - screenFrame.minX, y: machine.position.y - screenFrame.minY)
        let t = CGFloat(max(thickness, 1))
        withoutAnimation {
            vertical.frame = CGRect(x: local.x - t / 2, y: 0, width: t, height: screenFrame.height)
            let showHorizontal = machine.phase == .yFast || machine.phase == .ySlow
            horizontal.isHidden = !showHorizontal
            horizontal.frame = CGRect(x: 0, y: local.y - t / 2, width: screenFrame.width, height: t)
            let slow = machine.phase == .xSlow || machine.phase == .ySlow
            vertical.opacity = machine.phase == .xFast || machine.phase == .xSlow ? 1 : 0.55
            (showHorizontal ? horizontal : vertical).backgroundColor = (slow ? color.withAlpha(1) : color.withAlpha(0.8)).cgColor
        }
    }
}
