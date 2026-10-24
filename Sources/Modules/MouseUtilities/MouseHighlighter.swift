import AppKit
import MacToysCore
import QuartzCore

/// Mouse Highlighter: shows where you click. Circle draws a dot under a held button that fades
/// after release; Spotlight dims the screen except around the pointer; Ripple sends a pulse out
/// from each click and keeps a ring on the pointer while the button is held.
@MainActor
final class MouseHighlighter {
    static let tapID = "mouseutils.highlighter"

    private(set) var settings: HighlighterSettings
    private(set) var isActive = false
    private let overlays = ScreenOverlays(level: .screenSaver)
    /// Per surface: the dimmed backdrop (Spotlight) and the always-on pointer circle.
    private var backdrops: [CAShapeLayer] = []
    private var pointerDots: [CAShapeLayer] = []
    /// Marks attached to held buttons (0 left, 1 right).
    private var held: [Int: CALayer] = [:]
    private var pointer = CGPoint.zero
    var onChange: (() -> Void)?

    init(settings: HighlighterSettings) {
        self.settings = settings
        overlays.onBuild = { [weak self] surfaces in self?.build(surfaces) }
    }

    func update(_ s: HighlighterSettings) {
        settings = s
        guard isActive else { return }
        for layer in held.values { layer.removeFromSuperlayer() }
        held = [:]
        restyle()
        drawPointer()
    }

    func setActive(_ on: Bool) {
        guard on != isActive else { return }
        isActive = on
        if on {
            pointer = MouseSynth.location
            overlays.show()
            restyle()
            drawPointer()
            InputTap.shared.add(Self.tapID, priority: 0,
                                events: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                                         .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp]) { [weak self] type, event in
                self?.handle(type, event)
                return .pass
            }
        } else {
            InputTap.shared.remove(Self.tapID)
            for layer in held.values { layer.removeFromSuperlayer() }
            held = [:]
            overlays.hide()
            backdrops = []
            pointerDots = []
        }
        onChange?()
    }

    func toggle() {
        setActive(!isActive)
        HUD.show("Mouse Highlighter \(isActive ? "on" : "off")", symbol: "cursorarrow.click.2")
    }

    // MARK: - Events

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        pointer = event.location
        switch type {
        case .leftMouseDown: pressed(0)
        case .rightMouseDown: pressed(1)
        case .leftMouseUp: released(0)
        case .rightMouseUp: released(1)
        default:
            withoutAnimation {
                drawPointer()
                let follow = settings.mode != .ripple || settings.followCursorWhileHeld
                if follow { for layer in held.values { place(layer, at: pointer) } }
            }
        }
    }

    private func color(_ button: Int) -> RGBA { button == 0 ? settings.primaryColor : settings.secondaryColor }

    private func pressed(_ button: Int) {
        held[button]?.removeFromSuperlayer()
        let mark: CALayer
        switch settings.mode {
        case .circle:
            mark = Self.disc(radius: settings.radius, color: color(button))
        case .spotlight:
            mark = Self.ring(radius: settings.radius, color: color(button), width: 4)
        case .ripple:
            pulse(color: color(button), at: pointer)
            mark = heldRing(color: color(button))
        }
        withoutAnimation { place(mark, at: pointer) }
        held[button] = mark
    }

    private func released(_ button: Int) {
        guard let mark = held.removeValue(forKey: button) else { return }
        switch settings.mode {
        case .circle, .spotlight:
            fade(mark, delay: settings.fadeDelay / 1000, duration: settings.fadeDuration / 1000)
        case .ripple:
            fade(mark, delay: 0, duration: 0.15)
            if button == 1 && settings.rightReleasePulse { releasePulse(at: pointer) }
        }
    }

    // MARK: - Drawing

    private func build(_ surfaces: [ScreenOverlays.Surface]) {
        backdrops = []
        pointerDots = []
        for s in surfaces {
            let backdrop = CAShapeLayer()
            backdrop.frame = s.root.bounds
            backdrop.fillRule = .evenOdd
            backdrop.contentsScale = s.scale
            let dot = CAShapeLayer()
            dot.contentsScale = s.scale
            s.root.addSublayer(backdrop)
            s.root.addSublayer(dot)
            backdrops.append(backdrop)
            pointerDots.append(dot)
        }
        restyle()
    }

    private func restyle() {
        let spotlight = settings.mode == .spotlight
        // A transparent "always" color would make Spotlight invisible: fall back to 50 % black.
        let dim = settings.alwaysColor.alpha < 0.05 ? RGBA.black.withAlpha(0.5) : settings.alwaysColor
        let r = settings.radius
        for b in backdrops {
            b.isHidden = !spotlight
            b.fillColor = dim.cgColor
        }
        for d in pointerDots {
            d.isHidden = spotlight || settings.alwaysColor.alpha < 0.01
            d.path = CGPath(ellipseIn: CGRect(x: -r, y: -r, width: r * 2, height: r * 2), transform: nil)
            d.fillColor = settings.alwaysColor.cgColor
            d.bounds = CGRect(x: -r, y: -r, width: r * 2, height: r * 2)
        }
    }

    private func drawPointer() {
        let surfaces = overlays.surfaces
        let r = CGFloat(settings.radius)
        for (i, s) in surfaces.enumerated() where i < backdrops.count {
            let c = s.local(pointer)
            if settings.mode == .spotlight {
                let path = CGMutablePath()
                path.addRect(s.root.bounds)
                path.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
                backdrops[i].path = path
            }
            pointerDots[i].position = c
        }
    }

    /// Moves a mark onto the display under `p`.
    private func place(_ layer: CALayer, at p: CGPoint) {
        guard let s = overlays.surface(at: p) else { return }
        if layer.superlayer !== s.root {
            layer.removeFromSuperlayer()
            s.root.addSublayer(layer)
        }
        layer.contentsScale = s.scale
        layer.position = s.local(p)
    }

    private func fade(_ layer: CALayer, delay: Double, duration: Double) {
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = layer.opacity
        anim.toValue = 0
        anim.beginTime = CACurrentMediaTime() + max(delay, 0)
        anim.duration = max(duration, 0.01)
        anim.fillMode = .both
        anim.isRemovedOnCompletion = false
        layer.add(anim, forKey: "fade")
        DispatchQueue.main.asyncAfter(deadline: .now() + max(delay, 0) + max(duration, 0.01) + 0.05) {
            layer.removeFromSuperlayer()
        }
    }

    /// An expanding ring that fades out. Intensity sets its weight and, above 1, adds an echo.
    private func pulse(color: RGBA, at p: CGPoint) {
        let size = settings.rippleSize, intensity = settings.rippleIntensity
        let duration = settings.rippleDuration / 1000
        let rings = intensity > 1 ? 2 : 1
        for n in 0..<rings {
            let ring = Self.ring(radius: size / 2, color: color.withAlpha(min(1, color.alpha * (0.6 + intensity * 0.5))),
                                 width: 1.5 + 4 * intensity)
            withoutAnimation { place(ring, at: p) }
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 0.15
            grow.toValue = 1
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            let group = CAAnimationGroup()
            group.animations = [grow, fade]
            group.duration = duration
            group.beginTime = CACurrentMediaTime() + Double(n) * duration * 0.3
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            group.fillMode = .both
            group.isRemovedOnCompletion = false
            ring.add(group, forKey: "pulse")
            let total = duration * (1 + Double(n) * 0.3) + 0.05
            DispatchQueue.main.asyncAfter(deadline: .now() + total) { ring.removeFromSuperlayer() }
        }
    }

    /// The ring that stays on the pointer while a button is held (Ripple).
    private func heldRing(color: RGBA) -> CALayer {
        let ring = Self.ring(radius: settings.rippleSize * 0.32, color: color, width: 2 + 2 * settings.rippleIntensity)
        let breathe = CABasicAnimation(keyPath: "transform.scale")
        breathe.fromValue = 0.9
        breathe.toValue = 1.08
        breathe.duration = 0.6
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        ring.add(breathe, forKey: "breathe")
        return ring
    }

    /// Crosshairs that burst out when the secondary button is released (Ripple).
    private func releasePulse(at p: CGPoint) {
        let size = CGFloat(settings.rippleSize)
        let shape = CAShapeLayer()
        let path = CGMutablePath()
        path.move(to: CGPoint(x: -size / 2, y: 0)); path.addLine(to: CGPoint(x: -size * 0.15, y: 0))
        path.move(to: CGPoint(x: size * 0.15, y: 0)); path.addLine(to: CGPoint(x: size / 2, y: 0))
        path.move(to: CGPoint(x: 0, y: -size / 2)); path.addLine(to: CGPoint(x: 0, y: -size * 0.15))
        path.move(to: CGPoint(x: 0, y: size * 0.15)); path.addLine(to: CGPoint(x: 0, y: size / 2))
        shape.path = path
        shape.bounds = CGRect(x: -size / 2, y: -size / 2, width: size, height: size)
        shape.strokeColor = settings.secondaryColor.withAlpha(min(1, settings.secondaryColor.alpha + 0.2)).cgColor
        shape.lineWidth = 2 + 2 * settings.rippleIntensity
        shape.lineCap = .round
        withoutAnimation { place(shape, at: p) }
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.5
        grow.toValue = 1.3
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = settings.rippleDuration / 1000 * 0.8
        group.fillMode = .both
        group.isRemovedOnCompletion = false
        shape.add(group, forKey: "release")
        DispatchQueue.main.asyncAfter(deadline: .now() + group.duration + 0.05) { shape.removeFromSuperlayer() }
    }

    static func disc(radius: Double, color: RGBA) -> CAShapeLayer {
        let l = CAShapeLayer()
        let r = CGFloat(radius)
        l.bounds = CGRect(x: -r, y: -r, width: r * 2, height: r * 2)
        l.path = CGPath(ellipseIn: l.bounds, transform: nil)
        l.fillColor = color.cgColor
        return l
    }

    static func ring(radius: Double, color: RGBA, width: Double) -> CAShapeLayer {
        let l = CAShapeLayer()
        let r = CGFloat(radius)
        l.bounds = CGRect(x: -r, y: -r, width: r * 2, height: r * 2)
        l.path = CGPath(ellipseIn: l.bounds, transform: nil)
        l.fillColor = nil
        l.strokeColor = color.cgColor
        l.lineWidth = CGFloat(width)
        return l
    }
}
