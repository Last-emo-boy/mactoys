import CoreGraphics
import Foundation

/// Everything that decides how one display is tiled.
public struct TileSpec: Equatable, Sendable {
    public var kind: TileLayoutKind
    public var shape: DisplayShape
    /// Share of the main window (`MainSize.fraction`).
    public var main: Double
    /// Where tiles go (`TileGeometry.area`).
    public var area: CGRect
    public var gap: CGFloat
    public var capacity: Int
    public var stackWhenFull: Bool
    /// Split weights the user set by resizing tiles (split path → weights).
    public var overrides: [[Int]: [Double]]
    /// A window in Focus mode: it covers the whole area.
    public var zoomed: TileBoard.WindowID?
    /// The smallest tile worth having, also for windows whose minimum isn't known yet.
    public var minimumTile: CGSize = .zero

    public init(kind: TileLayoutKind, shape: DisplayShape, main: Double, area: CGRect, gap: CGFloat, capacity: Int,
                stackWhenFull: Bool, overrides: [[Int]: [Double]] = [:], zoomed: TileBoard.WindowID? = nil) {
        self.kind = kind
        self.shape = shape
        self.main = main
        self.area = area
        self.gap = gap
        self.capacity = capacity
        self.stackWhenFull = stackWhenFull
        self.overrides = overrides
        self.zoomed = zoomed
    }

    /// The tree for `count` tiles with the user's split changes.
    public func tree(count: Int) -> TileTree? {
        TileTree.make(kind, count: count, shape: shape, main: main)?.applying(overrides)
    }
}

/// The arrangement of one display.
public struct TilePlan: Equatable, Sendable {
    /// Visible tiles in order, each a stack with its front window first.
    public var tiles: [[TileBoard.WindowID]] = []
    /// One frame per visible tile.
    public var tileFrames: [CGRect] = []
    /// Where every present tiled window goes (all members of a stack share their tile's frame).
    public var frames: [TileBoard.WindowID: CGRect] = [:]
    /// Windows that were too big to fit this time and now float.
    public var floated: [TileBoard.WindowID] = []
    /// Windows that floated before and found room this time.
    public var readmitted: [TileBoard.WindowID] = []

    public init() {}

    /// The tile showing a window, if any.
    public func tileIndex(of id: TileBoard.WindowID) -> Int? { tiles.firstIndex { $0.contains(id) } }
}

/// Pure planning of a display: rebalance the board, lay the tiles out and settle windows that
/// can't get small enough (they float) or that found room again (they rejoin).
public enum TilePlanner {
    public static func plan(_ board: inout TileBoard, display: String, present: Set<TileBoard.WindowID>,
                            spec: TileSpec, minimum: (TileBoard.WindowID) -> CGSize) -> TilePlan {
        var plan = TilePlan()
        board.rebalance(display, capacity: spec.capacity, present: present, stackWhenFull: spec.stackWhenFull)
        guard var placed = solve(&board, display: display, present: present, spec: spec, minimum: minimum,
                                 floated: &plan.floated) else { return plan }
        // Windows that floated for want of room try again, one at a time, in the order they came.
        let waiting = board.floating.filter { $0.value.display == display && $0.value.reason == .tooBig
            && present.contains($0.key) && !plan.floated.contains($0.key) }.keys.sorted()
        for id in waiting {
            var trial = board
            guard trial.unfloat(id, capacity: spec.capacity, present: present, stackWhenFull: false) == .tiled else { continue }
            let tiles = trial.visibleTiles(on: display, present: present)
            guard let tree = spec.tree(count: tiles.count),
                  case .placed(let frames) = TileGeometry.solve(tree, in: spec.area, gap: spec.gap,
                                                                minimums: tiles.map { stackMinimum($0, spec, minimum) })
            else { continue }
            board = trial
            placed = (tiles, frames)
            plan.readmitted.append(id)
        }
        plan.tiles = placed.tiles
        plan.tileFrames = placed.frames
        for (stack, frame) in zip(placed.tiles, placed.frames) {
            for id in stack { plan.frames[id] = frame }
        }
        if let z = spec.zoomed, plan.frames[z] != nil { plan.frames[z] = spec.area }
        return plan
    }

    /// Lays the display out, floating the window that doesn't fit until everything does.
    private static func solve(_ board: inout TileBoard, display: String, present: Set<TileBoard.WindowID>, spec: TileSpec,
                              minimum: (TileBoard.WindowID) -> CGSize,
                              floated: inout [TileBoard.WindowID]) -> (tiles: [[TileBoard.WindowID]], frames: [CGRect])? {
        for _ in 0..<64 {
            let tiles = board.visibleTiles(on: display, present: present)
            guard let tree = spec.tree(count: tiles.count) else { return nil }
            switch TileGeometry.solve(tree, in: spec.area, gap: spec.gap, minimums: tiles.map { stackMinimum($0, spec, minimum) }) {
            case .placed(let frames):
                return (tiles, frames)
            case .tooSmall(let t):
                guard tiles.indices.contains(t) else { return nil }
                // The member of that stack needing the most room floats.
                let stack = tiles[t]
                let id = stack.max { a, b in
                    let ma = minimum(a), mb = minimum(b)
                    return ma.width * ma.height < mb.width * mb.height
                } ?? stack[0]
                board.float(id, reason: .tooBig, display: display)
                floated.append(id)
            }
        }
        return nil
    }

    /// A stack's tile must fit every window in it (and be worth having).
    static func stackMinimum(_ stack: [TileBoard.WindowID], _ spec: TileSpec, _ minimum: (TileBoard.WindowID) -> CGSize) -> CGSize {
        stack.reduce(spec.minimumTile) { acc, id in
            let m = minimum(id)
            return CGSize(width: max(acc.width, m.width), height: max(acc.height, m.height))
        }
    }

    /// A centered frame for a window that floats because it can't get small enough.
    public static func centered(size: CGSize, in area: CGRect) -> CGRect {
        let w = min(size.width, max(area.width, 1)), h = min(size.height, max(area.height, 1))
        return CGRect(x: (area.midX - w / 2).rounded(), y: (area.midY - h / 2).rounded(), width: w.rounded(), height: h.rounded())
    }
}
