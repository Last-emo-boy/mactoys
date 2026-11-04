import CoreGraphics
import Foundation

/// A guide line the canvas editor draws while a zone edge lines up with another zone's edge.
/// Work-area coordinates.
struct SnapGuide: Hashable, Sendable {
    /// True for a vertical line at x = `position`, false for a horizontal one at y = `position`.
    var vertical: Bool
    var position: CGFloat
}

/// Snapping for drawing, moving and resizing canvas zones, in work-area coordinates (origin at
/// the top-left of the display's visible frame).
///
/// An edge within `tolerance` of another zone's edge or the display edge snaps to it; otherwise,
/// with a grid, it snaps to the nearest grid line. Edges that end up on another zone's edge get a
/// guide line (the display edge needs none: the zone visibly meets it). `free` snaps nothing (⌘ held).
struct CanvasSnapper: Equatable {
    /// How close (points) an edge must come to another edge to snap to it.
    static let defaultTolerance: CGFloat = 8

    /// Edge positions to snap to: other zones' edges and the display edges.
    var xs: [CGFloat]
    var ys: [CGFloat]
    /// The subset that draws guides: other zones' edges inside the display.
    var guideXs: [CGFloat]
    var guideYs: [CGFloat]
    /// Grid step in points; nil without a grid.
    var stepX: CGFloat?
    var stepY: CGFloat?
    var tolerance: CGFloat

    static let free = CanvasSnapper(xs: [], ys: [], guideXs: [], guideYs: [], stepX: nil, stepY: nil, tolerance: 0)

    init(xs: [CGFloat], ys: [CGFloat], guideXs: [CGFloat], guideYs: [CGFloat], stepX: CGFloat?, stepY: CGFloat?,
         tolerance: CGFloat) {
        self.xs = xs
        self.ys = ys
        self.guideXs = guideXs
        self.guideYs = guideYs
        self.stepX = stepX
        self.stepY = stepY
        self.tolerance = tolerance
    }

    /// Snaps to the edges of `zones` (except the one at `excluding`) and of `area`, and with
    /// `gridDivisions` to a grid of 1/n of the area's width and height.
    init(area: CGSize, zones: [CGRect], excluding: Int? = nil, gridDivisions: Int?,
         tolerance: CGFloat = CanvasSnapper.defaultTolerance) {
        var xs: [CGFloat] = [], ys: [CGFloat] = []
        for (i, z) in zones.enumerated() where i != excluding {
            xs += [z.minX, z.maxX]
            ys += [z.minY, z.maxY]
        }
        let n = gridDivisions.map { CGFloat(max(1, $0)) }
        // A guide along the display's own edge says nothing the edge doesn't.
        let guideXs = xs.filter { $0 > 0.5 && $0 < area.width - 0.5 }
        let guideYs = ys.filter { $0 > 0.5 && $0 < area.height - 0.5 }
        self.init(xs: xs + [0, area.width], ys: ys + [0, area.height], guideXs: guideXs, guideYs: guideYs,
                  stepX: n.map { area.width / $0 }, stepY: n.map { area.height / $0 }, tolerance: tolerance)
    }

    // MARK: Single values

    /// `v` snapped to the nearest target within tolerance, else to the grid, else unchanged.
    func snap(_ v: CGFloat, targets: [CGFloat], step: CGFloat?) -> CGFloat {
        if let t = nearest(to: v, in: targets) { return t }
        if let step, step > 0 { return (v / step).rounded() * step }
        return v
    }

    func snapX(_ v: CGFloat) -> CGFloat { snap(v, targets: xs, step: stepX) }
    func snapY(_ v: CGFloat) -> CGFloat { snap(v, targets: ys, step: stepY) }

    private func nearest(to v: CGFloat, in targets: [CGFloat]) -> CGFloat? {
        var best: CGFloat?
        for t in targets where abs(t - v) <= tolerance {
            if best.map({ abs(t - v) < abs($0 - v) }) ?? true { best = t }
        }
        return best
    }

    // MARK: Rectangles

    /// A zone moved to `r`: keeps its size and shifts so its nearest edge (on each axis) snaps.
    func move(_ r: CGRect) -> (rect: CGRect, guides: [SnapGuide]) {
        let dx = shift(edges: [r.minX, r.maxX], targets: xs, step: stepX)
        let dy = shift(edges: [r.minY, r.maxY], targets: ys, step: stepY)
        let moved = r.offsetBy(dx: dx, dy: dy)
        return (moved, guides(for: moved, edges: [.left, .right, .top, .bottom]))
    }

    /// A zone being resized by its `edges`: each moving edge snaps on its own; an edge that would
    /// make the zone smaller than `minimum` stays where the pointer put it.
    func resize(_ r: CGRect, edges: ResizeEdges, minimum: CGFloat = CanvasEditing.minimumSize) -> (rect: CGRect, guides: [SnapGuide]) {
        var minX = r.minX, maxX = r.maxX, minY = r.minY, maxY = r.maxY
        if edges.contains(.left) { let v = snapX(minX); if maxX - v >= minimum { minX = v } }
        if edges.contains(.right) { let v = snapX(maxX); if v - minX >= minimum { maxX = v } }
        if edges.contains(.top) { let v = snapY(minY); if maxY - v >= minimum { minY = v } }
        if edges.contains(.bottom) { let v = snapY(maxY); if v - minY >= minimum { maxY = v } }
        let rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        return (rect, guides(for: rect, edges: edges))
    }

    /// A new zone drawn from `start` to `end` (both clamped to `area`): each corner snaps.
    func draw(from start: CGPoint, to end: CGPoint, in area: CGSize) -> (rect: CGRect, guides: [SnapGuide]) {
        func clamp(_ p: CGPoint) -> CGPoint {
            CGPoint(x: min(max(p.x, 0), area.width), y: min(max(p.y, 0), area.height))
        }
        let a = clamp(start), b = clamp(end)
        let x0 = snapX(a.x), x1 = snapX(b.x), y0 = snapY(a.y), y1 = snapY(b.y)
        let rect = CGRect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0))
        return (rect, guides(for: rect, edges: [.left, .right, .top, .bottom]))
    }

    /// The shift that brings the closest of `edges` onto a target (within tolerance), else onto the grid.
    private func shift(edges: [CGFloat], targets: [CGFloat], step: CGFloat?) -> CGFloat {
        var best: CGFloat?
        for e in edges {
            for t in targets where abs(t - e) <= tolerance {
                if best.map({ abs(t - e) < abs($0) }) ?? true { best = t - e }
            }
        }
        if let best { return best }
        guard let step, step > 0 else { return 0 }
        return edges.map { ($0 / step).rounded() * step - $0 }.min { abs($0) < abs($1) } ?? 0
    }

    /// Guides for the `edges` of `r` that sit on another zone's edge.
    private func guides(for r: CGRect, edges: ResizeEdges) -> [SnapGuide] {
        var result: [SnapGuide] = []
        func add(_ v: CGFloat, vertical: Bool) {
            let targets = vertical ? guideXs : guideYs
            guard targets.contains(where: { abs($0 - v) < 0.5 }) else { return }
            let g = SnapGuide(vertical: vertical, position: v)
            if !result.contains(g) { result.append(g) }
        }
        if edges.contains(.left) { add(r.minX, vertical: true) }
        if edges.contains(.right) { add(r.maxX, vertical: true) }
        if edges.contains(.top) { add(r.minY, vertical: false) }
        if edges.contains(.bottom) { add(r.maxY, vertical: false) }
        return result
    }
}
