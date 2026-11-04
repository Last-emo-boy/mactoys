import CoreGraphics
import Foundation

/// How the windows of one display share it.
public enum TileLayoutKind: String, Codable, CaseIterable, Sendable, Identifiable {
    /// A main window, the others in a grid beside it (2 × 2 with four windows).
    case grid
    /// Side-by-side columns of equal width.
    case columns
    /// Stacked rows of equal height.
    case rows
    /// A main window and one stack of the others beside it.
    case side

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .grid: String(localized: "Grid", comment: "Auto Tiling layout: a main window with the others in a grid")
        case .columns: String(localized: "Columns", comment: "Auto Tiling layout: side-by-side columns")
        case .rows: String(localized: "Rows", comment: "Auto Tiling layout: stacked rows")
        case .side: String(localized: "Side", comment: "Auto Tiling layout: a main window with a stack beside it")
        }
    }

    public var symbol: String {
        switch self {
        case .grid: "square.grid.2x2"
        case .columns: "rectangle.split.3x1"
        case .rows: "rectangle.split.1x2"
        case .side: "rectangle.lefthalf.inset.filled"
        }
    }

    /// Whether the main window size setting changes this layout.
    public var hasMainWindow: Bool { self == .grid || self == .side }
}

/// The share of the display the main window takes in Grid and Side.
public enum MainSize: String, Codable, CaseIterable, Sendable, Identifiable {
    case half, sixty, twoThirds

    public var id: String { rawValue }

    public var fraction: Double {
        switch self {
        case .half: 0.5
        case .sixty: 0.6
        case .twoThirds: 2.0 / 3.0
        }
    }

    public var title: String {
        switch self {
        case .half: String(localized: "Half", comment: "Auto Tiling main window size: 50 % of the display")
        case .sixty: String(localized: "60 %", comment: "Auto Tiling main window size: 60 % of the display")
        case .twoThirds: String(localized: "Two-thirds", comment: "Auto Tiling main window size: 2/3 of the display")
        }
    }
}

/// The proportions of a display, which change how layouts are drawn.
public enum DisplayShape: String, Sendable, Equatable, CaseIterable {
    case landscape, ultrawide, portrait

    /// Width ÷ height from which a display counts as ultrawide (21:9 is 2.33, 32:9 is 3.56).
    public static let ultrawideAspect: CGFloat = 2.1

    public init(size: CGSize) {
        if size.height > size.width {
            self = .portrait
        } else if size.height > 0, size.width / size.height >= Self.ultrawideAspect {
            self = .ultrawide
        } else {
            self = .landscape
        }
    }

    /// How many windows a display of this shape takes when the user allows `setting` (1–4).
    /// Ultrawide displays take a fifth window when four are allowed.
    public func capacity(maxWindows setting: Int) -> Int {
        let base = min(max(setting, 1), 4)
        return self == .ultrawide && base == 4 ? 5 : base
    }

    public var title: String {
        switch self {
        case .landscape: String(localized: "Landscape", comment: "Display shape")
        case .ultrawide: String(localized: "Ultrawide", comment: "Display shape")
        case .portrait: String(localized: "Portrait", comment: "Display shape: a display turned on its side")
        }
    }
}

/// Which way a split lays out its children.
public enum SplitAxis: String, Sendable, Equatable {
    /// Children side by side, left to right.
    case horizontal
    /// Children stacked, top to bottom.
    case vertical

    var other: SplitAxis { self == .horizontal ? .vertical : .horizontal }
}

/// A layout as a tree of splits: every leaf is one tile, numbered 0 (the main tile) to n − 1 in
/// the order windows fill them. Weights are the children's shares of their parent's length.
public enum TileTree: Equatable, Sendable {
    case tile(Int)
    case split(SplitAxis, [TileTree], [Double])

    /// Width of the narrow stack column of Side on ultrawide displays.
    static let ultrawideStackShare = 0.22

    /// The default tree for `count` windows (nil for none).
    public static func make(_ kind: TileLayoutKind, count: Int, shape: DisplayShape, main: Double) -> TileTree? {
        guard count > 0 else { return nil }
        guard count > 1 else { return .tile(0) }
        let m = min(max(main, 0.2), 0.8)
        switch kind {
        case .columns:
            return .even(.horizontal, 0..<count)
        case .rows:
            return .even(.vertical, 0..<count)
        case .side:
            if shape == .ultrawide && count >= 3 {
                // Two large windows and a narrow column for the rest.
                let large = 1 - ultrawideStackShare
                let stack: TileTree = count == 3 ? .tile(2) : .even(.vertical, 2..<count)
                return .split(.horizontal, [.tile(0), .tile(1), stack], [large * m, large * (1 - m), ultrawideStackShare])
            }
            let stack: TileTree = count == 2 ? .tile(1) : .even(.vertical, 1..<count)
            let tree = TileTree.split(.horizontal, [.tile(0), stack], [m, 1 - m])
            return shape == .portrait ? tree.transposed : tree
        case .grid:
            let tree: TileTree
            if count == 4 {
                tree = .split(.horizontal, [.split(.vertical, [.tile(0), .tile(2)], [0.5, 0.5]),
                                            .split(.vertical, [.tile(1), .tile(3)], [0.5, 0.5])], [m, 1 - m])
            } else {
                // The main tile, then columns of two.
                var columns: [TileTree] = []
                var i = 1
                while i < count {
                    columns.append(i + 1 < count ? .split(.vertical, [.tile(i), .tile(i + 1)], [0.5, 0.5]) : .tile(i))
                    i += 2
                }
                let share = (1 - m) / Double(columns.count)
                tree = .split(.horizontal, [.tile(0)] + columns, [m] + Array(repeating: share, count: columns.count))
            }
            return shape == .portrait ? tree.transposed : tree
        }
    }

    static func even(_ axis: SplitAxis, _ range: Range<Int>) -> TileTree {
        .split(axis, range.map { .tile($0) }, Array(repeating: 1 / Double(range.count), count: range.count))
    }

    /// The same tree with rows and columns swapped (portrait displays put the main tile on top).
    public var transposed: TileTree {
        switch self {
        case .tile: self
        case .split(let axis, let children, let weights): .split(axis.other, children.map(\.transposed), weights)
        }
    }

    /// Number of tiles.
    public var count: Int {
        switch self {
        case .tile: 1
        case .split(_, let children, _): children.reduce(0) { $0 + $1.count }
        }
    }

    /// Tile numbers in this subtree.
    var tiles: [Int] {
        switch self {
        case .tile(let i): [i]
        case .split(_, let children, _): children.flatMap(\.tiles)
        }
    }

    /// The tree with `overrides` (split path → weights) in place of the default weights. An
    /// override whose child count doesn't match its split any more is ignored.
    public func applying(_ overrides: [[Int]: [Double]], path: [Int] = []) -> TileTree {
        guard case .split(let axis, let children, let weights) = self else { return self }
        var w = weights
        if let o = overrides[path], o.count == children.count, o.allSatisfy({ $0 > 0 && $0.isFinite }) {
            let sum = o.reduce(0, +)
            w = o.map { $0 / sum }
        }
        return .split(axis, children.enumerated().map { $1.applying(overrides, path: path + [$0]) }, w)
    }

    /// The node at `path` (child indices from the root).
    func node(at path: [Int]) -> TileTree? {
        guard let first = path.first else { return self }
        guard case .split(_, let children, _) = self, children.indices.contains(first) else { return nil }
        return children[first].node(at: Array(path.dropFirst()))
    }

    /// Child indices from the root to tile `index`, or nil when the tree doesn't have it.
    func path(to index: Int) -> [Int]? {
        switch self {
        case .tile(let i): return i == index ? [] : nil
        case .split(_, let children, _):
            for (c, child) in children.enumerated() {
                if let rest = child.path(to: index) { return [c] + rest }
            }
            return nil
        }
    }
}

/// The edges of a tile, for resizing.
public enum TileEdge: CaseIterable, Sendable {
    case left, right, top, bottom

    var axis: SplitAxis { self == .left || self == .right ? .horizontal : .vertical }
    /// Whether the edge is at the end (right, bottom) of the tile along its axis.
    var isTrailing: Bool { self == .right || self == .bottom }
}

/// Space kept free along display edges, for a third-party dock or menu bar.
public struct EdgeReserve: Codable, Equatable, Sendable {
    public var top = 0.0
    public var bottom = 0.0
    public var left = 0.0
    public var right = 0.0
    /// Display key it applies to; nil applies to every display.
    public var display: String?

    public init(top: Double = 0, bottom: Double = 0, left: Double = 0, right: Double = 0, display: String? = nil) {
        self.top = top
        self.bottom = bottom
        self.left = left
        self.right = right
        self.display = display
    }

    public var isEmpty: Bool { top <= 0 && bottom <= 0 && left <= 0 && right <= 0 }

    public func applies(to displayKey: String) -> Bool { display == nil || display == displayKey }
}
