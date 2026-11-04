import AppKit
import CoreGraphics
import Foundation
import MacToysCore

/// The annotate palette's stroke sizes.
public enum MarkupSize: String, Codable, CaseIterable, Sendable, Identifiable {
    case small, medium, large, extraLarge
    public var id: String { rawValue }

    var title: String {
        switch self {
        case .small: String(localized: "Thin", comment: "Annotation stroke size")
        case .medium: String(localized: "Regular", comment: "Annotation stroke size")
        case .large: String(localized: "Bold", comment: "Annotation stroke size")
        case .extraLarge: String(localized: "Heavy", comment: "Annotation stroke size")
        }
    }

    /// Stroke width of arrows, lines, shapes and the pencil, in image points.
    var lineWidth: CGFloat {
        switch self {
        case .small: 2
        case .medium: 4
        case .large: 7
        case .extraLarge: 11
        }
    }

    var highlighterWidth: CGFloat {
        switch self {
        case .small: 10
        case .medium: 16
        case .large: 24
        case .extraLarge: 34
        }
    }

    var fontSize: CGFloat {
        switch self {
        case .small: 15
        case .medium: 21
        case .large: 30
        case .extraLarge: 44
        }
    }

    var counterDiameter: CGFloat {
        switch self {
        case .small: 22
        case .medium: 30
        case .large: 40
        case .extraLarge: 54
        }
    }
}

/// The eight annotation colors.
enum MarkupPalette {
    static let colors: [RGBA] = [
        RGBA(red: 1, green: 0.23, blue: 0.19),     // red
        RGBA(red: 1, green: 0.58, blue: 0),        // orange
        RGBA(red: 1, green: 0.8, blue: 0),         // yellow
        RGBA(red: 0.2, green: 0.78, blue: 0.35),   // green
        RGBA(red: 0.04, green: 0.52, blue: 1),     // blue
        RGBA(red: 0.69, green: 0.32, blue: 0.87),  // purple
        RGBA(red: 0.11, green: 0.11, blue: 0.12),  // black
        RGBA(red: 1, green: 1, blue: 1),           // white
    ]

    static func name(of color: RGBA) -> String {
        switch colors.firstIndex(of: color) {
        case 0: String(localized: "Red", comment: "Color name")
        case 1: String(localized: "Orange", comment: "Color name")
        case 2: String(localized: "Yellow", comment: "Color name")
        case 3: String(localized: "Green", comment: "Color name")
        case 4: String(localized: "Blue", comment: "Color name")
        case 5: String(localized: "Purple", comment: "Color name")
        case 6: String(localized: "Black", comment: "Color name")
        case 7: String(localized: "White", comment: "Color name")
        default: color.hex
        }
    }
}

/// How a text annotation stands out from the screenshot behind it.
public enum TextStyle: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Colored text with a soft shadow.
    case plain
    /// Colored text with a white outline.
    case outline
    /// White (or black) text on a rounded label in the color.
    case solid
    /// Colored text on a pale tint of the color.
    case soft
    public var id: String { rawValue }

    var title: String {
        switch self {
        case .plain: String(localized: "Plain", comment: "Text annotation style: just the text")
        case .outline: String(localized: "Outline", comment: "Text annotation style: text with an outline")
        case .solid: String(localized: "Label", comment: "Text annotation style: text on a solid colored label")
        case .soft: String(localized: "Tinted", comment: "Text annotation style: text on a pale tinted background")
        }
    }
}

/// A text annotation. `origin` is the top-left corner of the text block (inside any label padding).
struct MarkupText: Codable, Equatable, Sendable {
    var origin: CGPoint
    var string: String
    var style: TextStyle

    static func font(size: CGFloat) -> NSFont { NSFont.systemFont(ofSize: size, weight: .bold) }

    /// Padding of `solid` and `soft` labels around the text.
    static func labelInset(size: CGFloat) -> CGSize { CGSize(width: size * 0.42, height: size * 0.22) }

    /// The text block (without label padding).
    func textRect(fontSize: CGFloat) -> CGRect {
        let measured = NSAttributedString(string: string.isEmpty ? " " : string,
                                          attributes: [.font: Self.font(size: fontSize)])
            .boundingRect(with: CGSize(width: 10_000, height: 10_000), options: [.usesLineFragmentOrigin])
        return CGRect(origin: origin, size: CGSize(width: ceil(measured.width), height: ceil(measured.height)))
    }

    /// Everything the annotation paints, label included.
    func frame(fontSize: CGFloat) -> CGRect {
        let r = textRect(fontSize: fontSize)
        switch style {
        case .plain, .outline: return r.insetBy(dx: -2, dy: -1)
        case .solid, .soft:
            let inset = Self.labelInset(size: fontSize)
            return r.insetBy(dx: -inset.width, dy: -inset.height)
        }
    }
}

/// One annotation, in image points (top-left origin of the uncropped capture).
struct MarkupItem: Codable, Equatable, Identifiable, Sendable {
    enum Shape: Codable, Equatable, Sendable {
        /// `bend` pushes the middle of the arrow sideways by that many points (0: straight).
        case arrow(from: CGPoint, to: CGPoint, bend: CGFloat)
        case line(from: CGPoint, to: CGPoint)
        case rectangle(CGRect, filled: Bool)
        case ellipse(CGRect, filled: Bool)
        case text(MarkupText)
        case highlighter([CGPoint])
        case pencil([CGPoint])
        case counter(center: CGPoint, number: Int)
        case blur(CGRect)
        case pixelate(CGRect)
        /// Dims everything outside the rect (or the oval in it).
        case spotlight(CGRect, oval: Bool)
    }

    /// Handles a selected item shows.
    enum Handle: Equatable, Sendable {
        case start, end, bend
        case box(AreaGeometry.Handle)
    }

    var id = UUID()
    var shape: Shape
    var color: RGBA
    var size: MarkupSize

    init(id: UUID = UUID(), shape: Shape, color: RGBA, size: MarkupSize) {
        self.id = id
        self.shape = shape
        self.color = color
        self.size = size
    }

    // MARK: Geometry

    /// Width of the stroke this item paints.
    var strokeWidth: CGFloat {
        if case .highlighter = shape { return size.highlighterWidth }
        return size.lineWidth
    }

    /// Whether the item redacts or dims the image rather than drawing on it.
    var isEffect: Bool {
        switch shape {
        case .blur, .pixelate, .spotlight: true
        default: false
        }
    }

    /// The rect of box-shaped items.
    var box: CGRect? {
        switch shape {
        case .rectangle(let r, _), .ellipse(let r, _), .blur(let r), .pixelate(let r), .spotlight(let r, _): r
        default: nil
        }
    }

    /// Area the item paints (for invalidation, selection outlines and hit slop).
    var bounds: CGRect {
        let pad = strokeWidth / 2 + 2
        switch shape {
        case .arrow(let a, let b, let bend):
            let pts = MarkupGeometry.arrowCurve(from: a, to: b, bend: bend)
            let head = MarkupGeometry.arrowHeadLength(width: strokeWidth)
            return MarkupGeometry.boundingBox(pts).insetBy(dx: -head, dy: -head)
        case .line(let a, let b): return MarkupGeometry.boundingBox([a, b]).insetBy(dx: -pad, dy: -pad)
        case .rectangle(let r, _), .ellipse(let r, _): return r.insetBy(dx: -pad, dy: -pad)
        case .blur(let r), .pixelate(let r), .spotlight(let r, _): return r
        case .text(let t): return t.frame(fontSize: size.fontSize)
        case .highlighter(let pts), .pencil(let pts): return MarkupGeometry.boundingBox(pts).insetBy(dx: -pad, dy: -pad)
        case .counter(let c, _):
            let d = size.counterDiameter
            return CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d).insetBy(dx: -2, dy: -2)
        }
    }

    /// Whether `p` picks the item. Outlines are picked near the stroke, filled shapes and regions anywhere inside.
    func hit(_ p: CGPoint, tolerance: CGFloat) -> Bool {
        let t = tolerance + strokeWidth / 2
        switch shape {
        case .arrow(let a, let b, let bend):
            return MarkupGeometry.distance(p, toPolyline: MarkupGeometry.arrowCurve(from: a, to: b, bend: bend)) <= t
                || MarkupGeometry.distance(p, b, b) <= MarkupGeometry.arrowHeadLength(width: strokeWidth)
        case .line(let a, let b):
            return MarkupGeometry.distance(p, a, b) <= t
        case .rectangle(let r, let filled):
            if filled { return r.insetBy(dx: -t, dy: -t).contains(p) }
            return MarkupGeometry.distance(p, toPolyline: MarkupGeometry.corners(r)) <= t
        case .ellipse(let r, let filled):
            if filled { return MarkupGeometry.ellipseContains(r.insetBy(dx: -t, dy: -t), p) }
            return MarkupGeometry.distance(p, toPolyline: MarkupGeometry.ellipsePoints(r)) <= t
        case .blur(let r), .pixelate(let r):
            return r.insetBy(dx: -tolerance, dy: -tolerance).contains(p)
        case .spotlight(let r, let oval):
            // The spotlight is picked by its edge or inside it — clicks in the dimmed area reach what's below.
            if oval { return MarkupGeometry.ellipseContains(r.insetBy(dx: -tolerance, dy: -tolerance), p) }
            return r.insetBy(dx: -tolerance, dy: -tolerance).contains(p)
        case .text(let text):
            return text.frame(fontSize: size.fontSize).insetBy(dx: -tolerance, dy: -tolerance).contains(p)
        case .highlighter(let pts), .pencil(let pts):
            return MarkupGeometry.distance(p, toPolyline: pts) <= t
        case .counter(let c, _):
            return hypot(p.x - c.x, p.y - c.y) <= size.counterDiameter / 2 + tolerance
        }
    }

    /// Handles shown while the item is selected.
    var handles: [Handle] {
        switch shape {
        case .arrow: [.start, .end, .bend]
        case .line: [.start, .end]
        case .rectangle, .ellipse, .blur, .pixelate, .spotlight: AreaGeometry.Handle.allCases.map { .box($0) }
        case .text, .highlighter, .pencil, .counter: []
        }
    }

    func point(of handle: Handle) -> CGPoint? {
        switch (shape, handle) {
        case (.arrow(let a, _, _), .start), (.line(let a, _), .start): return a
        case (.arrow(_, let b, _), .end), (.line(_, let b), .end): return b
        case (.arrow(let a, let b, let bend), .bend): return MarkupGeometry.bendHandle(from: a, to: b, bend: bend)
        case (_, .box(let h)): return box.map { h.point(in: $0) }
        default: return nil
        }
    }

    /// The handle within `radius` of `p`.
    func handle(at p: CGPoint, radius: CGFloat) -> Handle? {
        handles.first { h in
            guard let c = point(of: h) else { return false }
            return hypot(c.x - p.x, c.y - p.y) <= radius
        }
    }

    /// The item moved by `d`.
    func moved(by d: CGVector) -> MarkupItem {
        func m(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + d.dx, y: p.y + d.dy) }
        func m(_ r: CGRect) -> CGRect { r.offsetBy(dx: d.dx, dy: d.dy) }
        var copy = self
        switch shape {
        case .arrow(let a, let b, let bend): copy.shape = .arrow(from: m(a), to: m(b), bend: bend)
        case .line(let a, let b): copy.shape = .line(from: m(a), to: m(b))
        case .rectangle(let r, let f): copy.shape = .rectangle(m(r), filled: f)
        case .ellipse(let r, let f): copy.shape = .ellipse(m(r), filled: f)
        case .blur(let r): copy.shape = .blur(m(r))
        case .pixelate(let r): copy.shape = .pixelate(m(r))
        case .spotlight(let r, let o): copy.shape = .spotlight(m(r), oval: o)
        case .text(var t):
            t.origin = m(t.origin)
            copy.shape = .text(t)
        case .highlighter(let pts): copy.shape = .highlighter(pts.map(m))
        case .pencil(let pts): copy.shape = .pencil(pts.map(m))
        case .counter(let c, let n): copy.shape = .counter(center: m(c), number: n)
        }
        return copy
    }

    /// The item with `handle` dragged to `p`. `bounds` limits box handles (the image).
    func dragging(_ handle: Handle, to p: CGPoint, in bounds: CGRect) -> MarkupItem {
        var copy = self
        switch (shape, handle) {
        case (.arrow(_, let b, let bend), .start): copy.shape = .arrow(from: p, to: b, bend: bend)
        case (.arrow(let a, _, let bend), .end): copy.shape = .arrow(from: a, to: p, bend: bend)
        case (.arrow(let a, let b, _), .bend): copy.shape = .arrow(from: a, to: b, bend: MarkupGeometry.bend(from: a, to: b, through: p))
        case (.line(_, let b), .start): copy.shape = .line(from: p, to: b)
        case (.line(let a, _), .end): copy.shape = .line(from: a, to: p)
        case (_, .box(let h)):
            guard let r = box else { return self }
            let nr = AreaGeometry.resized(r, handle: h, to: p, in: bounds.union(r))
            copy = copy.withBox(nr)
        default: break
        }
        return copy
    }

    /// Box-shaped items with their rect replaced.
    func withBox(_ r: CGRect) -> MarkupItem {
        var copy = self
        switch shape {
        case .rectangle(_, let f): copy.shape = .rectangle(r, filled: f)
        case .ellipse(_, let f): copy.shape = .ellipse(r, filled: f)
        case .blur: copy.shape = .blur(r)
        case .pixelate: copy.shape = .pixelate(r)
        case .spotlight(_, let o): copy.shape = .spotlight(r, oval: o)
        default: break
        }
        return copy
    }

    /// Whether the item is too small to keep after a drag (a stray click).
    var isDegenerate: Bool {
        switch shape {
        case .arrow(let a, let b, _), .line(let a, let b): return hypot(b.x - a.x, b.y - a.y) < 4
        case .rectangle(let r, _), .ellipse(let r, _), .blur(let r), .pixelate(let r), .spotlight(let r, _):
            return r.width < 4 || r.height < 4
        case .highlighter(let pts), .pencil(let pts): return pts.count < 2
        case .text(let t): return t.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .counter: return false
        }
    }
}

/// Curves, distances and boxes shared by the model and the renderer.
enum MarkupGeometry {
    /// Arrowhead length for a stroke width.
    static func arrowHeadLength(width: CGFloat) -> CGFloat { max(12, width * 3.6 + 6) }

    /// Unit normal to the left of the direction a → b.
    static func normal(from a: CGPoint, to b: CGPoint) -> CGVector {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = max(hypot(dx, dy), 0.0001)
        return CGVector(dx: dy / len, dy: -dx / len)
    }

    /// Quadratic control point that puts the curve's midpoint `bend` points off the chord.
    static func control(from a: CGPoint, to b: CGPoint, bend: CGFloat) -> CGPoint {
        let n = normal(from: a, to: b)
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        return CGPoint(x: mid.x + n.dx * bend * 2, y: mid.y + n.dy * bend * 2)
    }

    /// The point the bend handle sits on: the middle of the curve.
    static func bendHandle(from a: CGPoint, to b: CGPoint, bend: CGFloat) -> CGPoint {
        let n = normal(from: a, to: b)
        return CGPoint(x: (a.x + b.x) / 2 + n.dx * bend, y: (a.y + b.y) / 2 + n.dy * bend)
    }

    /// The bend that makes the curve pass through `p` at its middle.
    static func bend(from a: CGPoint, to b: CGPoint, through p: CGPoint) -> CGFloat {
        let n = normal(from: a, to: b)
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        return (p.x - mid.x) * n.dx + (p.y - mid.y) * n.dy
    }

    /// A bend that gives a new curved arrow a gentle arc.
    static func defaultBend(from a: CGPoint, to b: CGPoint) -> CGFloat {
        hypot(b.x - a.x, b.y - a.y) * 0.18
    }

    /// Samples along the arrow (a straight arrow is its two ends).
    static func arrowCurve(from a: CGPoint, to b: CGPoint, bend: CGFloat, segments: Int = 24) -> [CGPoint] {
        guard abs(bend) > 0.5 else { return [a, b] }
        let c = control(from: a, to: b, bend: bend)
        return (0...segments).map { i in
            let t = CGFloat(i) / CGFloat(segments), u = 1 - t
            return CGPoint(x: u * u * a.x + 2 * u * t * c.x + t * t * b.x, y: u * u * a.y + 2 * u * t * c.y + t * t * b.y)
        }
    }

    /// Direction the arrow points at its tip (unit vector).
    static func tipDirection(from a: CGPoint, to b: CGPoint, bend: CGFloat) -> CGVector {
        let from = abs(bend) > 0.5 ? control(from: a, to: b, bend: bend) : a
        let dx = b.x - from.x, dy = b.y - from.y
        let len = max(hypot(dx, dy), 0.0001)
        return CGVector(dx: dx / len, dy: dy / len)
    }

    static func corners(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY),
         CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.minY)]
    }

    static func ellipsePoints(_ r: CGRect, count: Int = 72) -> [CGPoint] {
        (0...count).map { i in
            let a = CGFloat(i) / CGFloat(count) * 2 * .pi
            return CGPoint(x: r.midX + r.width / 2 * cos(a), y: r.midY + r.height / 2 * sin(a))
        }
    }

    static func ellipseContains(_ r: CGRect, _ p: CGPoint) -> Bool {
        guard r.width > 0, r.height > 0 else { return false }
        let x = (p.x - r.midX) / (r.width / 2), y = (p.y - r.midY) / (r.height / 2)
        return x * x + y * y <= 1
    }

    static func boundingBox(_ pts: [CGPoint]) -> CGRect {
        guard let first = pts.first else { return .null }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for p in pts { minX = min(minX, p.x); minY = min(minY, p.y); maxX = max(maxX, p.x); maxY = max(maxY, p.y) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Distance from `p` to the segment a–b.
    static func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        let t = len2 == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    static func distance(_ p: CGPoint, toPolyline pts: [CGPoint]) -> CGFloat {
        guard let first = pts.first else { return .infinity }
        if pts.count == 1 { return hypot(p.x - first.x, p.y - first.y) }
        var best = CGFloat.infinity
        for i in 1..<pts.count { best = min(best, distance(p, pts[i - 1], pts[i])) }
        return best
    }

    /// Drops pencil samples closer than `spacing` to the previous kept one (smoother, smaller files).
    static func thinned(_ pts: [CGPoint], spacing: CGFloat) -> [CGPoint] {
        guard var last = pts.first else { return [] }
        var out = [last]
        for p in pts.dropFirst() where hypot(p.x - last.x, p.y - last.y) >= spacing {
            out.append(p)
            last = p
        }
        if let end = pts.last, out.count > 1, out.last != end { out.append(end) }
        return out
    }
}

/// A capture's annotations, crop and background — everything editable about it, saved with the history.
struct MarkupDocument: Codable, Equatable, Sendable {
    /// The capture's size in points.
    var imageSize: CGSize
    /// Image pixels per point.
    var scale: CGFloat
    var items: [MarkupItem] = []
    /// Visible part of the capture (image points); nil shows all of it.
    var crop: CGRect?
    /// The background frame; nil when off.
    var beautify: BeautifyStyle?

    var imageBounds: CGRect { CGRect(origin: .zero, size: imageSize) }
    /// The part of the image that ends up in the output.
    var contentRect: CGRect { crop.map { $0.intersection(imageBounds) } ?? imageBounds }

    /// The topmost item at `p`.
    func item(at p: CGPoint, tolerance: CGFloat) -> MarkupItem? {
        items.last { $0.hit(p, tolerance: tolerance) }
    }

    func index(of id: MarkupItem.ID) -> Int? { items.firstIndex { $0.id == id } }

    /// The number the next counter badge shows.
    var nextCounter: Int {
        let numbers = items.compactMap { item -> Int? in
            if case .counter(_, let n) = item.shape { return n }
            return nil
        }
        return (numbers.max() ?? 0) + 1
    }

    var isEdited: Bool { !items.isEmpty || crop != nil || beautify != nil }
}

/// Bounded undo/redo of whole document states (documents are small: a list of shapes).
struct UndoStack<State: Equatable> {
    private(set) var past: [State] = []
    private(set) var future: [State] = []
    let limit: Int

    init(limit: Int = 200) { self.limit = limit }

    var canUndo: Bool { !past.isEmpty }
    var canRedo: Bool { !future.isEmpty }

    /// Remembers the state before a change; a new change forgets what was undone.
    mutating func record(_ before: State) {
        if past.last == before { return }
        past.append(before)
        if past.count > limit { past.removeFirst(past.count - limit) }
        future.removeAll()
    }

    /// The state to go back to, or nil.
    mutating func undo(from current: State) -> State? {
        guard let previous = past.popLast() else { return nil }
        future.append(current)
        return previous
    }

    mutating func redo(from current: State) -> State? {
        guard let next = future.popLast() else { return nil }
        past.append(current)
        return next
    }
}
