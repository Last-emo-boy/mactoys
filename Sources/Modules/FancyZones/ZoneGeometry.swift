import CoreGraphics
import Foundation
import MacToysCore

/// How the zone under the pointer is chosen when several zones overlap it.
public enum OverlapAlgorithm: String, Codable, CaseIterable, Sendable {
    case smallest, largest, closestCenter, positional

    public var title: String {
        switch self {
        case .smallest: "Activate the smallest zone by area"
        case .largest: "Activate the largest zone by area"
        case .closestCenter: "Activate the zone whose center is closest to the pointer"
        case .positional: "Split the overlapped area into multiple activation targets"
        }
    }
}

/// A keyboard move direction.
public enum ZoneDirection: String, Codable, CaseIterable, Sendable {
    case left, right, up, down

    /// Unit vector in top-left (y down) coordinates.
    public var vector: CGVector {
        switch self {
        case .left: CGVector(dx: -1, dy: 0)
        case .right: CGVector(dx: 1, dy: 0)
        case .up: CGVector(dx: 0, dy: -1)
        case .down: CGVector(dx: 0, dy: 1)
        }
    }

    /// Right and down advance the zone index; left and up go back.
    public var isForward: Bool { self == .right || self == .down }
}

/// Pure zone geometry: layout → rectangles, hit testing, spans and keyboard navigation.
/// All rectangles use top-left (y down) coordinates, like Accessibility and CGEvent.
public enum ZoneGeometry {
    /// Zone rectangles of `layout` inside `rect` (usually a display's visible frame).
    /// `spacing` is the gap around and between grid zones; Focus and canvas layouts ignore it.
    public static func zones(for layout: ZoneLayout, in rect: CGRect, spacing: CGFloat) -> [CGRect] {
        guard rect.width > 0, rect.height > 0 else { return [] }
        switch layout.kind {
        case .blank: return []
        case .focus: return focus(count: layout.zoneCount, in: rect)
        case .canvas: return layout.canvas?.zones(in: rect) ?? []
        default: return layout.gridModel?.zones(in: rect, spacing: spacing) ?? []
        }
    }

    /// The Focus template: cascaded zones of 60 % of the area, 50 pt apart.
    public static func focus(count: Int, in rect: CGRect) -> [CGRect] {
        guard count > 0 else { return [] }
        let w = rect.width * 0.6, h = rect.height * 0.6
        let step: CGFloat = count > 1 ? 50 : 0
        return (0..<count).map { i in
            let x = min(rect.minX + rect.width * 0.2 + step * CGFloat(i), rect.maxX - w)
            let y = min(rect.minY + rect.height * 0.2 + step * CGFloat(i), rect.maxY - h)
            return rounded(CGRect(x: x, y: y, width: w, height: h))
        }
    }

    /// Rounds each edge to whole points.
    public static func rounded(_ r: CGRect) -> CGRect {
        let x0 = r.minX.rounded(), y0 = r.minY.rounded(), x1 = r.maxX.rounded(), y1 = r.maxY.rounded()
        return CGRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
    }

    /// Maps rectangles from one frame to another (e.g. a display's zones into a thumbnail).
    public static func scaled(_ rects: [CGRect], from source: CGRect, to target: CGRect) -> [CGRect] {
        guard source.width > 0, source.height > 0 else { return [] }
        let sx = target.width / source.width, sy = target.height / source.height
        return rects.map {
            CGRect(x: target.minX + ($0.minX - source.minX) * sx, y: target.minY + ($0.minY - source.minY) * sy,
                   width: $0.width * sx, height: $0.height * sy)
        }
    }

    /// A text picture of a layout (for the CLI): each character cell shows the number of the
    /// zone covering its center (1–9, then A–Z; the last zone wins where zones overlap), `·` for none.
    public static func preview(_ layout: ZoneLayout, width: Int = 32, height: Int = 10,
                               reference: CGSize = CGSize(width: 1600, height: 1000)) -> String {
        let w = max(1, width), h = max(1, height)
        let zones = layout.zones(in: CGRect(origin: .zero, size: reference))
        let symbols = Array("123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        var lines: [String] = []
        for row in 0..<h {
            var line = ""
            for col in 0..<w {
                let p = CGPoint(x: (CGFloat(col) + 0.5) / CGFloat(w) * reference.width,
                                y: (CGFloat(row) + 0.5) / CGFloat(h) * reference.height)
                if let i = zones.lastIndex(where: { $0.containsInclusive(p) }) {
                    line.append(i < symbols.count ? symbols[i] : "#")
                } else {
                    line.append("·")
                }
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Hit testing

    /// The zones to highlight for a pointer at `point` (PowerToys semantics):
    /// every zone within `distance` of the point, so dragging near the shared edge of two
    /// adjacent zones selects both; a single zone only counts when the point is inside it; and
    /// when the candidates overlap each other one of them is chosen with `algorithm`.
    public static func zones(at point: CGPoint, in zones: [CGRect], distance: CGFloat,
                             algorithm: OverlapAlgorithm = .smallest) -> [Int] {
        var captured: [Int] = []
        var strict = 0
        for (i, z) in zones.enumerated() where z.width > 0 && z.height > 0 {
            if z.insetBy(dx: -distance, dy: -distance).containsInclusive(point) { captured.append(i) }
            if z.containsInclusive(point) { strict += 1 }
        }
        if captured.count == 1 && strict == 0 { return [] }
        guard captured.count > 1 else { return captured }
        var overlap = false
        outer: for a in 0..<captured.count {
            for b in (a + 1)..<captured.count {
                let i = zones[captured[a]].intersection(zones[captured[b]])
                if !i.isNull && i.width > 0 && i.height > 0 { overlap = true; break outer }
            }
        }
        guard overlap else { return captured }
        return [choose(among: captured, zones: zones, point: point, algorithm: algorithm)]
    }

    private static func choose(among candidates: [Int], zones: [CGRect], point: CGPoint,
                               algorithm: OverlapAlgorithm) -> Int {
        switch algorithm {
        case .smallest:
            return candidates.min { zones[$0].area < zones[$1].area } ?? candidates[0]
        case .largest:
            return candidates.max { zones[$0].area < zones[$1].area } ?? candidates[0]
        case .closestCenter:
            return candidates.min { distanceSquared(zones[$0].center, point) < distanceSquared(zones[$1].center, point) }
                ?? candidates[0]
        case .positional:
            // The shared (overlapping) area is cut into vertical bands, smallest zone first.
            let sorted = candidates.sorted { zones[$0].area < zones[$1].area }
            let shared = sorted.dropFirst().reduce(zones[sorted[0]]) { $0.intersection(zones[$1]) }
            guard !shared.isNull, shared.width > 0 else { return sorted[0] }
            let fraction = min(max((point.x - shared.minX) / shared.width, 0), 0.9999)
            return sorted[Int(fraction * CGFloat(sorted.count))]
        }
    }

    /// The bounding rectangle of the given zones (what a window snapped across them fills).
    public static func union(of indices: [Int], in zones: [CGRect]) -> CGRect {
        indices.filter { zones.indices.contains($0) }.reduce(CGRect.null) { $0.union(zones[$1]) }
    }

    /// Every zone lying inside the bounding box of `a` ∪ `b`: the range selected when spanning
    /// from one zone to another (⌘ while dragging, or extending with the keyboard).
    public static func span(from a: [Int], to b: [Int], in zones: [CGRect]) -> [Int] {
        let box = union(of: a + b, in: zones)
        guard !box.isNull else { return [] }
        let slack = box.insetBy(dx: -0.5, dy: -0.5)
        return zones.indices.filter { slack.contains(zones[$0]) }
    }

    /// The zones a window frame currently fills: a single zone or a span that matches within `tolerance`.
    public static func zonesMatching(frame: CGRect, in zones: [CGRect], tolerance: CGFloat = 3) -> [Int] {
        func close(_ a: CGRect, _ b: CGRect) -> Bool {
            abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance &&
                abs(a.maxX - b.maxX) <= tolerance && abs(a.maxY - b.maxY) <= tolerance
        }
        if let i = zones.firstIndex(where: { close($0, frame) }) { return [i] }
        let inside = zones.indices.filter { frame.insetBy(dx: -tolerance, dy: -tolerance).contains(zones[$0]) }
        guard !inside.isEmpty, close(union(of: inside, in: zones), frame) else { return [] }
        return inside
    }

    // MARK: Keyboard navigation

    /// Zone-index mode: the zone after (right/down) or before (left/up) the window's zones.
    /// A window in no zone goes to the first zone (forward) or the last (backward).
    /// Returns nil past either end unless `wrap` is on.
    public static func index(after current: [Int], count: Int, direction: ZoneDirection, wrap: Bool) -> Int? {
        guard count > 0 else { return nil }
        guard let lo = current.min(), let hi = current.max() else { return direction.isForward ? 0 : count - 1 }
        let next = direction.isForward ? hi + 1 : lo - 1
        if next >= 0 && next < count { return next }
        guard wrap else { return nil }
        return direction.isForward ? 0 : count - 1
    }

    /// Relative-position mode: the zone closest to `rect` in `direction`. Zones are compared by
    /// their centers; perpendicular offset costs twice as much as distance along the direction,
    /// and only zones strictly ahead count.
    public static func zone(from rect: CGRect, direction: ZoneDirection, in zones: [CGRect]) -> Int? {
        let d = direction.vector
        let c = rect.center
        let eccentricity: CGFloat = 2
        var best: Int?
        var bestScore = CGFloat.greatestFiniteMagnitude
        for (i, z) in zones.enumerated() {
            let vx = z.midX - c.x, vy = z.midY - c.y
            let along = vx * d.dx + vy * d.dy
            let across = vy * d.dx - vx * d.dy
            guard along > 0.5 else { continue }
            let score = along * along + eccentricity * eccentricity * across * across
            if score < bestScore { bestScore = score; best = i }
        }
        return best
    }

    /// Relative-position wrap-around: the zone reached by entering `area` from its opposite edge
    /// at the window's height (left/right) or horizontal position (up/down).
    public static func wrappedZone(from rect: CGRect, direction: ZoneDirection, in zones: [CGRect],
                                   area: CGRect) -> Int? {
        var origin = rect
        let size = CGSize(width: 2, height: 2)
        switch direction {
        case .right: origin = CGRect(origin: CGPoint(x: area.minX - 1e4, y: rect.midY - 1), size: size)
        case .left: origin = CGRect(origin: CGPoint(x: area.maxX + 1e4, y: rect.midY - 1), size: size)
        case .down: origin = CGRect(origin: CGPoint(x: rect.midX - 1, y: area.minY - 1e4), size: size)
        case .up: origin = CGRect(origin: CGPoint(x: rect.midX - 1, y: area.maxY + 1e4), size: size)
        }
        return zone(from: origin, direction: direction, in: zones)
    }

    private static func distanceSquared(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        (a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)
    }
}

extension CGRect {
    /// `contains` that also accepts points on the right and bottom edges.
    func containsInclusive(_ p: CGPoint) -> Bool {
        p.x >= minX && p.x <= maxX && p.y >= minY && p.y <= maxY
    }
}
