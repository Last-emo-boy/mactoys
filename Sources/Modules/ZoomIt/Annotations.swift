import AppKit
import MacToysCore

/// Draw-mode tools. Pen and highlighter turn into shapes while modifiers are held, as in ZoomIt.
public enum DrawTool: String, CaseIterable, Sendable, Identifiable {
    case pen, highlighter, line, rectangle, ellipse, arrow, text, blur, eraser

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .pen: String(localized: "Pen", comment: "Drawing tool")
        case .highlighter: String(localized: "Highlighter (⇧ + color key)", comment: "Drawing tool and its key")
        case .line: String(localized: "Line (hold ⇧)", comment: "Drawing tool and its key")
        case .rectangle: String(localized: "Rectangle (hold ⌃)", comment: "Drawing tool and its key")
        case .ellipse: String(localized: "Ellipse (hold Tab)", comment: "Drawing tool and its key (the Tab key)")
        case .arrow: String(localized: "Arrow (hold ⌃⇧)", comment: "Drawing tool and its key")
        case .text: String(localized: "Text (T, ⇧T right-aligned)", comment: "Drawing tool and its keys (T is the letter key)")
        case .blur: String(localized: "Blur pen (X)", comment: "Drawing tool and its key (X is the letter key)")
        case .eraser: String(localized: "Eraser", comment: "Drawing tool")
        }
    }

    public var symbol: String {
        switch self {
        case .pen: "pencil"
        case .highlighter: "highlighter"
        case .line: "line.diagonal"
        case .rectangle: "square"
        case .ellipse: "circle"
        case .arrow: "arrow.up.right"
        case .text: "textformat"
        case .blur: "drop.halffull"
        case .eraser: "eraser"
        }
    }

    /// The tool a drag uses, given the selected tool and the held modifiers:
    /// ⇧ line, ⌃ (or ⌘) rectangle, Tab ellipse, ⌃⇧ arrow. Only pen and highlighter are modified.
    public static func effective(_ tool: DrawTool, shift: Bool, control: Bool, tab: Bool) -> DrawTool {
        guard tool == .pen || tool == .highlighter else { return tool }
        if control && shift { return .arrow }
        if control { return .rectangle }
        if tab { return .ellipse }
        if shift { return .line }
        return tool
    }
}

/// A text annotation. `origin` is the top-left corner, or the top-right one when right-aligned.
public struct TextItem: Equatable, Sendable {
    public var text: String
    public var origin: CGPoint
    public var fontName: String
    public var size: CGFloat
    public var rightAligned: Bool

    var font: NSFont {
        (fontName.isEmpty ? nil : NSFont(name: fontName, size: size))
            ?? NSFontManager.shared.font(withFamily: fontName, traits: [], weight: 5, size: size)
            ?? NSFont.systemFont(ofSize: size, weight: .semibold)
    }
}

/// One drawn item, in overlay points (origin top-left).
public struct Annotation: Equatable, Sendable {
    public enum Shape: Equatable, Sendable {
        case pen([CGPoint])
        case line(CGPoint, CGPoint)
        case rectangle(CGPoint, CGPoint)
        case ellipse(CGPoint, CGPoint)
        case arrow(CGPoint, CGPoint)
        case text(TextItem)
        case blur([CGPoint])
    }

    public var shape: Shape
    public var color: RGBA
    public var width: CGFloat
    public var highlighter: Bool

    public init(shape: Shape, color: RGBA, width: CGFloat, highlighter: Bool = false) {
        self.shape = shape
        self.color = color
        self.width = width
        self.highlighter = highlighter
    }

    /// Highlighter strokes are wider and translucent.
    public static func strokeWidth(pen width: CGFloat, highlighter: Bool) -> CGFloat {
        highlighter ? max(12, width * 3) : width
    }

    // MARK: Geometry

    /// The two ends of the arrowhead strokes at `b`.
    public static func arrowWings(from a: CGPoint, to b: CGPoint, width: CGFloat) -> (CGPoint, CGPoint) {
        let angle = atan2(b.y - a.y, b.x - a.x)
        let length = max(14, width * 3.5)
        let spread = CGFloat.pi / 7
        return (CGPoint(x: b.x - length * cos(angle - spread), y: b.y - length * sin(angle - spread)),
                CGPoint(x: b.x - length * cos(angle + spread), y: b.y - length * sin(angle + spread)))
    }

    public static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// Area the item paints, for invalidation.
    public var bounds: CGRect {
        let r: CGRect
        switch shape {
        case .pen(let pts), .blur(let pts): r = Self.boundingBox(pts)
        case .line(let a, let b), .rectangle(let a, let b), .ellipse(let a, let b): r = Self.rect(a, b)
        case .arrow(let a, let b):
            let (w1, w2) = Self.arrowWings(from: a, to: b, width: width)
            r = Self.boundingBox([a, b, w1, w2])
        case .text(let t): r = Self.textRect(t)
        }
        return r.insetBy(dx: -width - 2, dy: -width - 2)
    }

    /// Whether `p` touches the item (the eraser).
    public func hit(_ p: CGPoint, tolerance: CGFloat) -> Bool {
        let t = tolerance + width / 2
        switch shape {
        case .pen(let pts), .blur(let pts): return Self.distance(p, toPolyline: pts) <= t
        case .line(let a, let b): return Self.distance(p, a, b) <= t
        case .arrow(let a, let b):
            let (w1, w2) = Self.arrowWings(from: a, to: b, width: width)
            return min(Self.distance(p, a, b), Self.distance(p, b, w1), Self.distance(p, b, w2)) <= t
        case .rectangle(let a, let b):
            let r = Self.rect(a, b)
            let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY),
                           CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.minY)]
            return Self.distance(p, toPolyline: corners) <= t
        case .ellipse(let a, let b):
            return Self.distance(p, toPolyline: Self.ellipsePoints(Self.rect(a, b))) <= t
        case .text(let item):
            return Self.textRect(item).insetBy(dx: -tolerance, dy: -tolerance).contains(p)
        }
    }

    static func textRect(_ t: TextItem) -> CGRect {
        let size = NSAttributedString(string: t.text.isEmpty ? " " : t.text, attributes: [.font: t.font]).size()
        let x = t.rightAligned ? t.origin.x - size.width : t.origin.x
        return CGRect(x: x, y: t.origin.y, width: size.width, height: size.height)
    }

    static func boundingBox(_ pts: [CGPoint]) -> CGRect {
        guard let first = pts.first else { return .null }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for p in pts { minX = min(minX, p.x); minY = min(minY, p.y); maxX = max(maxX, p.x); maxY = max(maxY, p.y) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    static func ellipsePoints(_ r: CGRect, count: Int = 72) -> [CGPoint] {
        (0...count).map { i in
            let a = CGFloat(i) / CGFloat(count) * 2 * .pi
            return CGPoint(x: r.midX + r.width / 2 * cos(a), y: r.midY + r.height / 2 * sin(a))
        }
    }

    /// Distance from `p` to the segment `a`–`b`.
    public static func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        let t = len2 == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        let cx = a.x + t * dx, cy = a.y + t * dy
        return hypot(p.x - cx, p.y - cy)
    }

    static func distance(_ p: CGPoint, toPolyline pts: [CGPoint]) -> CGFloat {
        guard let first = pts.first else { return .infinity }
        if pts.count == 1 { return hypot(p.x - first.x, p.y - first.y) }
        var best = CGFloat.infinity
        for i in 1..<pts.count { best = min(best, distance(p, pts[i - 1], pts[i])) }
        return best
    }
}

/// Paints annotations into a y-down (flipped) Core Graphics context.
enum AnnotationRenderer {
    /// - Parameter blurred: the background, already blurred and sized to `canvas`, for blur strokes.
    static func draw(_ items: [Annotation], in ctx: CGContext, blurred: CGImage?, canvas: CGRect) {
        for item in items { draw(item, in: ctx, blurred: blurred, canvas: canvas) }
    }

    static func draw(_ item: Annotation, in ctx: CGContext, blurred: CGImage?, canvas: CGRect) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        let color = item.color.withAlpha(item.highlighter ? 0.42 : item.color.alpha).cgColor
        ctx.setStrokeColor(color)
        ctx.setFillColor(color)
        ctx.setLineWidth(item.width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        switch item.shape {
        case .pen(let pts):
            ctx.addPath(smoothPath(pts))
            ctx.strokePath()
        case .line(let a, let b):
            ctx.move(to: a); ctx.addLine(to: b)
            ctx.strokePath()
        case .arrow(let a, let b):
            let (w1, w2) = Annotation.arrowWings(from: a, to: b, width: item.width)
            ctx.move(to: a); ctx.addLine(to: b)
            ctx.move(to: w1); ctx.addLine(to: b); ctx.addLine(to: w2)
            ctx.strokePath()
        case .rectangle(let a, let b):
            ctx.stroke(Annotation.rect(a, b))
        case .ellipse(let a, let b):
            ctx.strokeEllipse(in: Annotation.rect(a, b))
        case .text(let t):
            drawText(t, color: item.color, in: ctx)
        case .blur(let pts):
            guard let blurred else { return }
            ctx.addPath(smoothPath(pts))
            ctx.replacePathWithStrokedPath()
            ctx.clip()
            drawUpright(blurred, in: canvas, ctx: ctx)
        }
    }

    /// A pen path smoothed through the midpoints of its samples.
    static func smoothPath(_ pts: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = pts.first else { return path }
        path.move(to: first)
        if pts.count == 1 { path.addLine(to: first); return path }
        if pts.count == 2 { path.addLine(to: pts[1]); return path }
        for i in 1..<pts.count - 1 {
            let mid = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: pts[i])
        }
        path.addLine(to: pts[pts.count - 1])
        return path
    }

    static func drawText(_ t: TextItem, color: RGBA, in ctx: CGContext, caret: Bool = false) {
        let style = NSMutableParagraphStyle()
        style.alignment = t.rightAligned ? .right : .left
        let attrs: [NSAttributedString.Key: Any] = [.font: t.font, .foregroundColor: color.nsColor, .paragraphStyle: style]
        let string = NSAttributedString(string: t.text, attributes: attrs)
        let rect = Annotation.textRect(t)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        string.draw(with: rect.insetBy(dx: -1, dy: 0), options: [.usesLineFragmentOrigin])
        NSGraphicsContext.restoreGraphicsState()
        if caret {
            let lineHeight = t.font.ascender - t.font.descender + t.font.leading
            let lastLine = t.text.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? ""
            let lastWidth = NSAttributedString(string: lastLine, attributes: [.font: t.font]).size().width
            let x = t.rightAligned ? t.origin.x + 1 : t.origin.x + lastWidth + 1
            let y = rect.maxY - lineHeight
            ctx.setFillColor(color.cgColor)
            ctx.fill(CGRect(x: x, y: y + 2, width: max(2, t.size / 14), height: lineHeight - 4))
        }
    }

    /// Draws an image the right way up into a y-down context.
    static func drawUpright(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: rect.minY + rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: rect)
        ctx.restoreGState()
    }
}
