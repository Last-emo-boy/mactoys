import AppKit
import QuartzCore

/// Draws the dimming layer of one display: a flat color with holes where windows stay bright.
///
/// Coordinates are display-local, top-left origin (the layer tree is flipped). Windows that just
/// lost focus fade into the dim on their own layers, so the rest of the screen never flickers.
final class DimOverlayView: NSView {
    private let base = CAShapeLayer()
    private var fades: [CAShapeLayer] = []
    private var color = NSColor.black.cgColor
    private var alpha: Float = 0.4

    override init(frame: NSRect) {
        super.init(frame: frame)
        let root = CALayer()
        root.isGeometryFlipped = true
        layer = root
        wantsLayer = true
        base.fillRule = .evenOdd
        base.actions = ["path": NSNull(), "fillColor": NSNull(), "opacity": NSNull(), "bounds": NSNull(), "position": NSNull()]
        root.addSublayer(base)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// - Parameters:
    ///   - holes: clear areas, display-local and disjoint.
    ///   - fadeIn: areas that were bright a moment ago and now darken over `duration` (disjoint from `holes`).
    ///   - animateStyle: animate a color or opacity change over `duration`.
    func apply(holes: [DimHole], fadeIn: [DimHole], color newColor: CGColor, alpha newAlpha: Float, duration: TimeInterval,
               animateStyle: Bool) {
        clearFades()
        let bounds = CGRect(origin: .zero, size: frame.size)
        let styleChanged = newColor != color || newAlpha != alpha
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        base.frame = bounds
        base.path = Self.path(bounds: bounds, holes: holes + fadeIn, cutOut: true)
        CATransaction.commit()

        if styleChanged {
            if animateStyle, duration > 0 {
                animate(base, key: "fillColor", from: base.fillColor ?? newColor, to: newColor, duration: duration)
                animate(base, key: "opacity", from: base.opacity, to: newAlpha, duration: duration)
            }
            color = newColor
            alpha = newAlpha
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            base.fillColor = newColor
            base.opacity = newAlpha
            CATransaction.commit()
        }

        guard !fadeIn.isEmpty else { return }
        let fade = CAShapeLayer()
        fade.frame = bounds
        fade.fillColor = color
        fade.path = Self.path(bounds: bounds, holes: fadeIn, cutOut: false)
        fade.opacity = alpha
        layer?.addSublayer(fade)
        fades.append(fade)
        let finalHoles = holes
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak fade] in
            MainActor.assumeIsolated {
                guard let self, let fade, self.fades.contains(fade) else { return }
                self.clearFades()
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.base.path = Self.path(bounds: CGRect(origin: .zero, size: self.frame.size), holes: finalHoles, cutOut: true)
                CATransaction.commit()
            }
        }
        animate(fade, key: "opacity", from: Float(0), to: alpha, duration: max(duration, 0.01))
        CATransaction.commit()
    }

    private func clearFades() {
        for f in fades { f.removeFromSuperlayer() }
        fades.removeAll()
    }

    private func animate(_ layer: CALayer, key: String, from: Any, to: Any, duration: TimeInterval) {
        let a = CABasicAnimation(keyPath: key)
        a.fromValue = from
        a.toValue = to
        a.duration = duration
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(a, forKey: key)
    }

    /// The bounds with the (disjoint) holes punched out by the even-odd rule, or only the holes.
    /// Holes are clipped to the bounds: a part outside them would be filled instead of cut.
    static func path(bounds: CGRect, holes: [DimHole], cutOut: Bool, radius: CGFloat = DimHole.windowRadius) -> CGPath {
        let path = CGMutablePath()
        if cutOut { path.addRect(bounds) }
        for h in holes {
            if bounds.contains(h.rect) {
                h.add(to: path, radius: radius)
                continue
            }
            let clipped = h.rect.intersection(bounds)
            if !clipped.isNull, clipped.width > 0, clipped.height > 0 { path.addRect(clipped) }
        }
        return path
    }
}
