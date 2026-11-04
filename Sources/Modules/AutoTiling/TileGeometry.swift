import CoreGraphics
import Foundation

/// Result of laying out a tree with minimum sizes.
public enum TileSolveResult: Equatable, Sendable {
    /// One frame per tile, indexed by tile number.
    case placed([CGRect])
    /// Tile `tile` (the one asking for the most room where space ran out) can't fit.
    case tooSmall(tile: Int)
}

/// Pure layout geometry: tile frames from a split tree, with exact gaps, whole-point edges and
/// per-tile minimum sizes. All rectangles are in top-left coordinates (y grows downward).
public enum TileGeometry {
    /// Where tiles go on a display: the visible frame (no menu bar or Dock) less the edge reserve,
    /// inset by `gap` so windows keep the same distance from the display edges as from each other,
    /// rounded inward to whole points.
    public static func area(visibleFrame: CGRect, reserve: EdgeReserve?, gap: CGFloat) -> CGRect {
        var r = visibleFrame
        if let reserve {
            r.origin.x += reserve.left
            r.origin.y += reserve.top
            r.size.width -= reserve.left + reserve.right
            r.size.height -= reserve.top + reserve.bottom
        }
        r = r.insetBy(dx: gap, dy: gap)
        let minX = r.minX.rounded(.up), minY = r.minY.rounded(.up)
        let maxX = r.maxX.rounded(.down), maxY = r.maxY.rounded(.down)
        return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }

    /// Frames for every tile of `tree` (indexed by tile number). Never fails: without minimum
    /// sizes every tile gets its share.
    public static func frames(_ tree: TileTree, in area: CGRect, gap: CGFloat) -> [CGRect] {
        if case .placed(let frames) = solve(tree, in: area, gap: gap, minimums: []) { return frames }
        return []
    }

    /// Lays out `tree` in `area`. `minimums[i]` is tile i's smallest acceptable size (missing or
    /// zero when unknown). Split lines move so every tile gets at least its minimum, keeping the
    /// other tiles' proportions; when that is impossible the tile asking for the most room in the
    /// split that overflows is reported.
    public static func solve(_ tree: TileTree, in area: CGRect, gap: CGFloat, minimums: [CGSize]) -> TileSolveResult {
        let g = max(0, gap.rounded())
        var frames = Array(repeating: CGRect.zero, count: tree.count)
        let mins: (Int) -> CGSize = { i in
            minimums.indices.contains(i) ? CGSize(width: max(0, minimums[i].width.rounded(.up)),
                                                  height: max(0, minimums[i].height.rounded(.up))) : .zero
        }
        do {
            try place(tree, in: area, gap: g, mins: mins, into: &frames)
            return .placed(frames)
        } catch let failure as SolveFailure {
            return .tooSmall(tile: failure.tile)
        } catch {
            return .placed(frames)
        }
    }

    private struct SolveFailure: Error {
        let tile: Int
    }

    private static func place(_ node: TileTree, in rect: CGRect, gap: CGFloat, mins: (Int) -> CGSize,
                              into frames: inout [CGRect]) throws {
        switch node {
        case .tile(let i):
            let m = mins(i)
            if rect.width < m.width || rect.height < m.height { throw SolveFailure(tile: i) }
            if frames.indices.contains(i) { frames[i] = rect }
        case .split(let axis, let children, let weights):
            let length = axis == .horizontal ? rect.width : rect.height
            let cross = axis == .horizontal ? rect.height : rect.width
            let available = max(0, (length - gap * CGFloat(children.count - 1)).rounded(.down))
            // Every child must fit across the split…
            for child in children where minimumExtent(child, along: axis.other, gap: gap, mins: mins) > cross {
                throw SolveFailure(tile: largestTile(in: child, along: axis.other, mins: mins))
            }
            // …and all of them along it.
            let childMins = children.map { minimumExtent($0, along: axis, gap: gap, mins: mins) }
            if childMins.reduce(0, +) > available {
                throw SolveFailure(tile: largestTile(in: node, along: axis, mins: mins))
            }
            let extents = distribute(available, weights: weights, minimums: childMins)
            var start = axis == .horizontal ? rect.minX : rect.minY
            for (child, extent) in zip(children, extents) {
                let sub = axis == .horizontal
                    ? CGRect(x: start, y: rect.minY, width: extent, height: rect.height)
                    : CGRect(x: rect.minX, y: start, width: rect.width, height: extent)
                try place(child, in: sub, gap: gap, mins: mins, into: &frames)
                start += extent + gap
            }
        }
    }

    /// The room a subtree needs along `axis`.
    static func minimumExtent(_ node: TileTree, along axis: SplitAxis, gap: CGFloat, mins: (Int) -> CGSize) -> CGFloat {
        switch node {
        case .tile(let i):
            let m = mins(i)
            return axis == .horizontal ? m.width : m.height
        case .split(let a, let children, _):
            let extents = children.map { minimumExtent($0, along: axis, gap: gap, mins: mins) }
            if a == axis { return extents.reduce(0, +) + gap * CGFloat(children.count - 1) }
            return extents.max() ?? 0
        }
    }

    /// The tile of a subtree asking for the most room along `axis` (the newest one on ties).
    private static func largestTile(in node: TileTree, along axis: SplitAxis, mins: (Int) -> CGSize) -> Int {
        let tiles = node.tiles
        return tiles.max { a, b in
            let ea = axis == .horizontal ? mins(a).width : mins(a).height
            let eb = axis == .horizontal ? mins(b).width : mins(b).height
            return ea != eb ? ea < eb : a < b
        } ?? tiles.last ?? 0
    }

    /// Splits `total` (whole points) by `weights`, giving every share at least its minimum and
    /// taking what that costs from the others in proportion; then rounds to whole points with
    /// the largest-remainder method so the shares add up to `total` exactly.
    static func distribute(_ total: CGFloat, weights: [Double], minimums: [CGFloat]) -> [CGFloat] {
        let n = weights.count
        guard n > 0 else { return [] }
        let positive = weights.map { $0.isFinite && $0 > 0 ? $0 : 0 }
        let sum = positive.reduce(0, +)
        let shares = sum > 0 ? positive.map { $0 / sum } : Array(repeating: 1 / Double(n), count: n)
        let mins = minimums.count == n ? minimums.map { Double(max(0, $0)) } : Array(repeating: 0, count: n)
        let t = Double(max(0, total))

        var extents = shares.map { $0 * t }
        var locked = Array(repeating: false, count: n)
        for _ in 0..<n {
            let violators = (0..<n).filter { !locked[$0] && extents[$0] < mins[$0] }
            if violators.isEmpty { break }
            for v in violators { locked[v] = true; extents[v] = mins[v] }
            let remaining = t - (0..<n).filter { locked[$0] }.reduce(0) { $0 + extents[$1] }
            let free = (0..<n).filter { !locked[$0] }
            let freeShare = free.reduce(0) { $0 + shares[$1] }
            for i in free {
                extents[i] = freeShare > 0 ? remaining * shares[i] / freeShare : remaining / Double(free.count)
            }
        }

        var whole = zip(extents, mins).map { max($0.rounded(.down), $1) }
        var leftover = Int((t - whole.reduce(0, +)).rounded())
        let order = (0..<n).sorted { a, b in
            let fa = extents[a] - extents[a].rounded(.down), fb = extents[b] - extents[b].rounded(.down)
            return fa != fb ? fa > fb : a < b
        }
        var k = 0
        while leftover > 0 && n > 0 {
            whole[order[k % n]] += 1
            leftover -= 1
            k += 1
        }
        // Rounding minimums up can overshoot by a point; take it back from the roomiest share.
        while leftover < 0, let i = (0..<n).filter({ whole[$0] - 1 >= mins[$0] }).max(by: { whole[$0] - mins[$0] < whole[$1] - mins[$1] }) {
            whole[i] -= 1
            leftover += 1
        }
        return whole.map { CGFloat($0) }
    }

    // MARK: Resizing

    /// After the user dragged `edge` of tile `tile` to `position` (x for left/right, y for
    /// top/bottom): the split whose line that edge is, and its new weights. Only the two children
    /// on either side of the line change; both keep at least `minimumExtent` (or their known
    /// minimum). Nil when the edge is on the outside of the layout.
    public static func resize(_ tree: TileTree, in area: CGRect, gap: CGFloat, tile: Int, edge: TileEdge,
                              to position: CGFloat, minimumExtent floor: CGFloat = 120,
                              minimums: [CGSize] = []) -> (path: [Int], weights: [Double])? {
        guard let tilePath = tree.path(to: tile) else { return nil }
        let frames = Self.frames(tree, in: area, gap: gap)
        guard frames.count == tree.count else { return nil }
        let mins: (Int) -> CGSize = { i in minimums.indices.contains(i) ? minimums[i] : .zero }
        // The deepest split along the edge's axis where the tile's branch has a neighbor on that side.
        for depth in stride(from: tilePath.count - 1, through: 0, by: -1) {
            let path = Array(tilePath.prefix(depth))
            let c = tilePath[depth]
            guard case .split(let axis, let children, _)? = tree.node(at: path), axis == edge.axis else { continue }
            let a = edge.isTrailing ? c : c - 1
            guard a >= 0, a + 1 < children.count else { continue }
            // Each child's current extent along the axis is the span of its tiles.
            let spans = children.map { child -> (start: CGFloat, end: CGFloat) in
                let rects = child.tiles.map { frames[$0] }
                let u = rects.reduce(CGRect.null) { $0.union($1) }
                return axis == .horizontal ? (u.minX, u.maxX) : (u.minY, u.maxY)
            }
            var extents = spans.map { $0.end - $0.start }
            let pair = extents[a] + extents[a + 1]
            let lowA = max(floor, minimumExtent(children[a], along: axis, gap: gap, mins: mins))
            let lowB = max(floor, minimumExtent(children[a + 1], along: axis, gap: gap, mins: mins))
            guard lowA + lowB <= pair else { return nil }
            // The line sits in the middle of the gap; `position` is the dragged edge.
            let boundary = edge.isTrailing ? position : position - gap
            let newA = min(max(boundary - spans[a].start, lowA), pair - lowB)
            extents[a] = newA
            extents[a + 1] = pair - newA
            let total = extents.reduce(0, +)
            guard total > 0 else { return nil }
            return (path, extents.map { Double($0 / total) })
        }
        return nil
    }

    // MARK: Directions

    /// The tile next to tile `index` in `direction`: among the tiles on that side, the nearest,
    /// preferring ones that overlap it across the direction, then the one best centered on it.
    public static func neighbor(of index: Int, _ direction: TileDirection, in frames: [CGRect]) -> Int? {
        guard frames.indices.contains(index) else { return nil }
        return nearest(from: frames[index], direction, among: frames.indices.filter { $0 != index }.map { ($0, frames[$0]) })
    }

    /// The display next to `frame` in `direction` (index into `displays`).
    public static func display(beside frame: CGRect, _ direction: TileDirection, in displays: [CGRect]) -> Int? {
        nearest(from: frame, direction, among: displays.indices.map { ($0, displays[$0]) }.filter { $0.1 != frame })
    }

    private static func nearest(from r: CGRect, _ d: TileDirection, among candidates: [(Int, CGRect)]) -> Int? {
        let tolerance: CGFloat = 2
        let onSide = candidates.filter { _, c in
            switch d {
            case .left: c.maxX <= r.minX + tolerance
            case .right: c.minX >= r.maxX - tolerance
            case .up: c.maxY <= r.minY + tolerance
            case .down: c.minY >= r.maxY - tolerance
            }
        }
        func overlap(_ c: CGRect) -> CGFloat {
            d == .left || d == .right ? min(c.maxY, r.maxY) - max(c.minY, r.minY) : min(c.maxX, r.maxX) - max(c.minX, r.minX)
        }
        func distance(_ c: CGRect) -> CGFloat {
            switch d {
            case .left: r.minX - c.maxX
            case .right: c.minX - r.maxX
            case .up: r.minY - c.maxY
            case .down: c.minY - r.maxY
            }
        }
        func offCenter(_ c: CGRect) -> CGFloat { d == .left || d == .right ? abs(c.midY - r.midY) : abs(c.midX - r.midX) }
        let overlapping = onSide.filter { overlap($0.1) > 0 }
        let pool = overlapping.isEmpty ? onSide : overlapping
        return pool.min { a, b in
            let da = distance(a.1).rounded(), db = distance(b.1).rounded()
            if da != db { return da < db }
            let ca = offCenter(a.1), cb = offCenter(b.1)
            return ca != cb ? ca < cb : a.0 < b.0
        }?.0
    }
}

/// A direction for swapping and moving windows with the keyboard.
public enum TileDirection: String, CaseIterable, Codable, Sendable {
    case left, right, up, down
}
