import AppKit

/// One measurement on one screen, in that screen's capture pixels.
struct RulerMark: Equatable {
    var tool: RulerTool
    /// For spacing tools: `left…right` along the pointer's row and `top…bottom` along its column.
    /// For bounds: the dragged box.
    var rect: PixelRect
    /// The pointer pixel the spacing lines cross at.
    var anchorX: Int
    var anchorY: Int

    var width: Int? { tool == .bounds || tool.measuresWidth ? rect.width : nil }
    var height: Int? { tool == .bounds || tool.measuresHeight ? rect.height : nil }
}

/// Line color, feet and units for drawing.
struct RulerStyle {
    var color: NSColor
    var drawFeet: Bool
    var extraUnit: RulerUnit
}

/// Draws measurements with Core Graphics in a flipped (top-left origin) point space, so the
/// overlay view and offscreen previews share one renderer.
enum RulerDrawing {
    static let feetHalfLength: CGFloat = 4

    /// - Parameters:
    ///   - scale: capture pixels per point on this screen.
    ///   - bounds: the drawable area, to keep labels on screen.
    ///   - note: an extra line under the newest label (tolerance changes).
    static func draw(_ marks: [RulerMark], in ctx: CGContext, scale: CGFloat, bounds: CGRect, style: RulerStyle,
                     metrics: DisplayMetrics, note: String? = nil) {
        for (i, mark) in marks.enumerated() {
            let isLast = i == marks.count - 1
            switch mark.tool {
            case .bounds: drawBounds(mark, ctx: ctx, scale: scale, style: style)
            default: drawSpacing(mark, ctx: ctx, scale: scale, style: style)
            }
            var text = MeasurementText.label(width: mark.width, height: mark.height, extra: style.extraUnit, metrics: metrics)
            if isLast, let note { text += "\n" + note }
            drawLabel(text, for: mark, ctx: ctx, scale: scale, bounds: bounds, color: style.color)
        }
    }

    private static func drawSpacing(_ m: RulerMark, ctx: CGContext, scale s: CGFloat, style: RulerStyle) {
        ctx.saveGState()
        ctx.setStrokeColor(style.color.cgColor)
        ctx.setLineWidth(1)
        ctx.setLineCap(.butt)
        let ay = (CGFloat(m.anchorY) + 0.5) / s, ax = (CGFloat(m.anchorX) + 0.5) / s
        if m.tool.measuresWidth {
            let x0 = CGFloat(m.rect.left) / s, x1 = CGFloat(m.rect.right + 1) / s
            ctx.move(to: CGPoint(x: x0, y: ay)); ctx.addLine(to: CGPoint(x: x1, y: ay))
            if style.drawFeet {
                for x in [x0 + 0.5, x1 - 0.5] {
                    ctx.move(to: CGPoint(x: x, y: ay - feetHalfLength)); ctx.addLine(to: CGPoint(x: x, y: ay + feetHalfLength))
                }
            }
        }
        if m.tool.measuresHeight {
            let y0 = CGFloat(m.rect.top) / s, y1 = CGFloat(m.rect.bottom + 1) / s
            ctx.move(to: CGPoint(x: ax, y: y0)); ctx.addLine(to: CGPoint(x: ax, y: y1))
            if style.drawFeet {
                for y in [y0 + 0.5, y1 - 0.5] {
                    ctx.move(to: CGPoint(x: ax - feetHalfLength, y: y)); ctx.addLine(to: CGPoint(x: ax + feetHalfLength, y: y))
                }
            }
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    private static func drawBounds(_ m: RulerMark, ctx: CGContext, scale s: CGFloat, style: RulerStyle) {
        let r = boxRect(m, scale: s)
        ctx.saveGState()
        ctx.setFillColor(style.color.withAlphaComponent(0.12).cgColor)
        ctx.fill(r)
        ctx.setStrokeColor(style.color.cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        ctx.stroke(r.insetBy(dx: 0.5, dy: 0.5))
        ctx.restoreGState()
    }

    static func boxRect(_ m: RulerMark, scale s: CGFloat) -> CGRect {
        CGRect(x: CGFloat(m.rect.left) / s, y: CGFloat(m.rect.top) / s,
               width: CGFloat(m.rect.width) / s, height: CGFloat(m.rect.height) / s)
    }

    private static func drawLabel(_ text: String, for m: RulerMark, ctx: CGContext, scale s: CGFloat, bounds: CGRect,
                                  color: NSColor) {
        let lines = text.split(separator: "\n").map(String.init)
        let first: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                                                    .foregroundColor: NSColor.white]
        let rest: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium),
                                                   .foregroundColor: NSColor.white.withAlphaComponent(0.85)]
        let strings = lines.enumerated().map { NSAttributedString(string: $1, attributes: $0 == 0 ? first : rest) }
        let sizes = strings.map { $0.size() }
        let textWidth = sizes.map(\.width).max() ?? 0
        let textHeight = sizes.map(\.height).reduce(0, +)
        let pad = CGSize(width: 7, height: 3)
        let size = CGSize(width: ceil(textWidth) + pad.width * 2, height: ceil(textHeight) + pad.height * 2)

        var origin: CGPoint
        if m.tool == .bounds {
            let box = boxRect(m, scale: s)
            origin = CGPoint(x: box.midX - size.width / 2, y: box.midY - size.height / 2)
            if box.width < size.width + 8 || box.height < size.height + 8 { origin.y = box.maxY + 6 }
        } else {
            let p = CGPoint(x: (CGFloat(m.anchorX) + 0.5) / s, y: (CGFloat(m.anchorY) + 0.5) / s)
            origin = CGPoint(x: p.x + 12, y: p.y + 12)
            if origin.x + size.width > bounds.maxX - 4 { origin.x = p.x - 12 - size.width }
            if origin.y + size.height > bounds.maxY - 4 { origin.y = p.y - 12 - size.height }
        }
        origin.x = min(max(origin.x, bounds.minX + 4), bounds.maxX - size.width - 4)
        origin.y = min(max(origin.y, bounds.minY + 4), bounds.maxY - size.height - 4)
        let rect = CGRect(origin: origin, size: size)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 4, color: NSColor.black.withAlphaComponent(0.3).cgColor)
        ctx.setFillColor(color.cgColor)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil))
        ctx.fillPath()
        ctx.restoreGState()

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        var y = rect.minY + pad.height
        for (str, sz) in zip(strings, sizes) {
            str.draw(at: CGPoint(x: rect.minX + pad.width + (textWidth - sz.width) / 2, y: y))
            y += sz.height
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Draws one screen's marks; forwards input to the session.
final class RulerCanvas: NSView {
    weak var session: RulerSession?
    let index: Int
    var marks: [RulerMark] = [] { didSet { needsDisplay = true } }
    var note: String? { didSet { needsDisplay = true } }
    var style: RulerStyle
    var scale: CGFloat
    var metrics: DisplayMetrics

    init(frame: CGRect, index: Int, style: RulerStyle, scale: CGFloat, metrics: DisplayMetrics) {
        self.index = index
        self.style = style
        self.scale = scale
        self.metrics = metrics
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // A nearly invisible wash keeps clicks on this window when the background is live.
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.004).cgColor)
        ctx.fill(dirtyRect)
        RulerDrawing.draw(marks, in: ctx, scale: scale, bounds: bounds, style: style, metrics: metrics, note: note)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate],
                                       owner: self, userInfo: nil))
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }
    override func mouseMoved(with event: NSEvent) { session?.pointerMoved() }
    override func mouseDown(with event: NSEvent) { session?.mouseDown(shift: event.modifierFlags.contains(.shift)) }
    override func mouseDragged(with event: NSEvent) { session?.pointerMoved() }
    override func mouseUp(with event: NSEvent) { session?.mouseUp(shift: event.modifierFlags.contains(.shift)) }
    override func rightMouseDown(with event: NSEvent) { session?.cancelInteraction() }
    override func scrollWheel(with event: NSEvent) {
        let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 10 : event.scrollingDeltaY
        session?.scroll(dy)
    }
}
