import AppKit
import CoreVideo
import MacToysCore
import QuartzCore

/// Content of a pin panel: the live mirror of the pinned window plus the colored border ring.
///
/// In `.border` mode the panel ignores the mouse, so the real window underneath works normally.
/// In `.mirror` mode pointing at (or clicking) the mirror asks the owner to raise the real window.
final class PinView: NSView {
    struct Style: Equatable {
        /// Ring thickness; 0 when the border is off (the mirror then fills the panel).
        var border: CGFloat
        var color: NSColor?
        var rounded: Bool
    }

    /// Called when the user points at or clicks the mirror.
    var onRaise: (() -> Void)?
    var raiseOnHover = true
    private(set) var hasFrame = false

    private let mirrorLayer = CALayer()
    private let borderLayer = CAShapeLayer()
    private let maskLayer = CAShapeLayer()
    private var style = Style(border: 4, color: nil, rounded: true)
    private var exclusions: [CGRect] = []
    private var mirroring = false
    private var hoverWork: DispatchWorkItem?
    private var tracking: NSTrackingArea?
    /// Hover must leave and re-enter before it raises again (no flicker loop if raising fails).
    private var hoverArmed = true

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(mirrorLayer)
        layer?.addSublayer(borderLayer)
        mirrorLayer.contentsGravity = .resize
        mirrorLayer.isHidden = true
        borderLayer.fillRule = .evenOdd
        maskLayer.fillRule = .evenOdd
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: State

    func apply(style newStyle: Style) {
        guard newStyle != style else { return }
        style = newStyle
        needsLayout = true
    }

    func setMirroring(_ on: Bool) {
        guard on != mirroring else { return }
        mirroring = on
        mirrorLayer.isHidden = !on
        if !on { cancelHover() }
    }

    /// Panel-local rectangles (bottom-left origin) that must stay transparent and click-through.
    func setExclusions(_ rects: [CGRect]) {
        guard rects != exclusions else { return }
        exclusions = rects
        needsLayout = true
    }

    func show(_ buffer: CVPixelBuffer) {
        guard let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mirrorLayer.contents = surface
        CATransaction.commit()
        hasFrame = true
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let b = bounds
        let t = style.border
        let inner = b.insetBy(dx: t, dy: t)
        let radii = PinGeometry.radii(rounded: style.rounded, border: t)
        mirrorLayer.frame = inner
        mirrorLayer.cornerRadius = radii.inner
        mirrorLayer.masksToBounds = radii.inner > 0

        borderLayer.frame = b
        if let color = style.color, t > 0 {
            let ring = CGMutablePath()
            ring.addPath(CGPath(roundedRect: b, cornerWidth: radii.outer, cornerHeight: radii.outer, transform: nil))
            ring.addPath(CGPath(roundedRect: inner, cornerWidth: radii.inner, cornerHeight: radii.inner, transform: nil))
            borderLayer.path = ring
            borderLayer.fillColor = color.cgColor
            borderLayer.isHidden = false
        } else {
            borderLayer.isHidden = true
        }

        if exclusions.isEmpty {
            layer?.mask = nil
        } else {
            let path = CGMutablePath()
            path.addRect(b)
            for r in exclusions { path.addRect(r) }
            maskLayer.frame = b
            maskLayer.path = path
            layer?.mask = maskLayer
        }
        CATransaction.commit()
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return isActive(at: local) ? self : nil
    }

    override func mouseEntered(with event: NSEvent) { hover(event) }
    override func mouseMoved(with event: NSEvent) { hover(event) }

    override func mouseExited(with event: NSEvent) {
        cancelHover()
        hoverArmed = true
    }

    override func mouseDown(with event: NSEvent) {
        guard isActive(at: convert(event.locationInWindow, from: nil)) else { return }
        cancelHover()
        hoverArmed = false
        onRaise?()
    }

    private func hover(_ event: NSEvent) {
        guard raiseOnHover, hoverArmed else { return }
        guard isActive(at: convert(event.locationInWindow, from: nil)) else { cancelHover(); return }
        guard hoverWork == nil else { return }
        // A short dwell so sweeping the pointer across a mirror doesn't steal focus.
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hoverWork = nil
            self.hoverArmed = false
            self.onRaise?()
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func cancelHover() {
        hoverWork?.cancel()
        hoverWork = nil
    }

    /// Whether a point (view coordinates) is on the live part of the mirror.
    private func isActive(at p: CGPoint) -> Bool {
        guard mirroring else { return false }
        let inner = bounds.insetBy(dx: style.border, dy: style.border)
        return inner.contains(p) && !exclusions.contains { $0.contains(p) }
    }
}
