import CoreGraphics
import Foundation
import MacToysCore

/// A left or right side of a display.
public enum HorizontalSide: Equatable, Sendable {
    case left, right

    public init?(_ d: SwipeDirection) {
        switch d {
        case .left: self = .left
        case .right: self = .right
        case .up, .down: return nil
        }
    }
}

/// A cell range on a display grid of 1–3 columns and 1–2 rows: halves, thirds, two thirds,
/// quarters, sixths, or the whole display (fill).
public struct Tile: Codable, Hashable, Sendable {
    public var columns: Int
    public var rows: Int
    public var column: Int
    public var columnSpan: Int
    public var row: Int
    public var rowSpan: Int

    public init(columns: Int, rows: Int = 1, column: Int, columnSpan: Int = 1, row: Int = 0, rowSpan: Int = 1) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
        self.column = min(max(0, column), self.columns - 1)
        self.columnSpan = min(max(1, columnSpan), self.columns - self.column)
        self.row = min(max(0, row), self.rows - 1)
        self.rowSpan = min(max(1, rowSpan), self.rows - self.row)
    }

    public static let fill = Tile(columns: 1, column: 0)

    public static func half(_ side: HorizontalSide) -> Tile {
        Tile(columns: 2, column: side == .left ? 0 : 1)
    }

    public static func quarter(_ side: HorizontalSide, top: Bool) -> Tile {
        Tile(columns: 2, rows: 2, column: side == .left ? 0 : 1, row: top ? 0 : 1)
    }

    public var isFill: Bool { column == 0 && row == 0 && columnSpan == columns && rowSpan == rows }
    /// Spans the full width (fill, or a top or bottom half).
    public var isFullWidth: Bool { column == 0 && columnSpan == columns }

    public func touches(_ side: HorizontalSide) -> Bool {
        side == .left ? column == 0 : column + columnSpan == columns
    }

    /// The widths a tile cycles through when swiped toward the edge it sits on:
    /// a half, a third, two thirds, and back to a half.
    static let widthCycle: [(columns: Int, span: Int)] = [(2, 1), (3, 1), (3, 2)]

    /// The next width in the cycle, against `side`, in the same rows.
    public func cycled(toward side: HorizontalSide) -> Tile {
        let index = Self.widthCycle.firstIndex { $0.columns == columns && $0.span == columnSpan }
        let next = Self.widthCycle[index.map { ($0 + 1) % Self.widthCycle.count } ?? 0]
        return Tile(columns: next.columns, rows: rows, column: side == .left ? 0 : next.columns - next.span,
                    columnSpan: next.span, row: row, rowSpan: rowSpan)
    }

    /// One column further toward `side`, same size; nil when it already touches that edge.
    public func slid(toward side: HorizontalSide) -> Tile? {
        guard !touches(side) else { return nil }
        var t = self
        t.column += side == .left ? -1 : 1
        return t
    }

    /// The frame in `area` (a display's work area, top-left coordinates). Cell edges fall on whole
    /// points and neighbors share them, so tiles meet exactly; `gap` keeps that much space between
    /// tiled windows and around them.
    public func frame(in area: CGRect, gap: CGFloat = 0) -> CGRect {
        func edge(_ i: Int, of n: Int, from start: CGFloat, length: CGFloat) -> CGFloat {
            (start + length * CGFloat(i) / CGFloat(n)).rounded()
        }
        func inset(_ i: Int, of n: Int) -> CGFloat { i == 0 || i == n ? gap : gap / 2 }
        let x0 = edge(column, of: columns, from: area.minX, length: area.width) + inset(column, of: columns)
        let x1 = edge(column + columnSpan, of: columns, from: area.minX, length: area.width) - inset(column + columnSpan, of: columns)
        let y0 = edge(row, of: rows, from: area.minY, length: area.height) + inset(row, of: rows)
        let y1 = edge(row + rowSpan, of: rows, from: area.minY, length: area.height) - inset(row + rowSpan, of: rows)
        let left = x0.rounded(.down), top = y0.rounded(.down)
        return CGRect(x: left, y: top, width: max(1, x1.rounded(.down) - left), height: max(1, y1.rounded(.down) - top))
    }

    /// Every cell of this tile's grid, for the faint grid drawn behind the preview.
    public func cells(in area: CGRect, gap: CGFloat = 0) -> [CGRect] {
        guard columns * rows > 1 else { return [] }
        var list: [CGRect] = []
        for r in 0..<rows {
            for c in 0..<columns {
                list.append(Tile(columns: columns, rows: rows, column: c, row: r).frame(in: area, gap: gap))
            }
        }
        return list
    }

    /// The share of the display it covers: "½", "⅓", "⅔", "¼", "⅙".
    public var fraction: String {
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
        let part = columnSpan * rowSpan, whole = columns * rows, d = gcd(part, whole)
        switch (part / d, whole / d) {
        case (1, 1): return "1"
        case (1, 2): return "½"
        case (1, 3): return "⅓"
        case (2, 3): return "⅔"
        case (1, 4): return "¼"
        case (1, 6): return "⅙"
        case let (p, w): return "\(p)/\(w)"
        }
    }

    /// "Left Half", "Top Right Sixth"…
    public var title: String {
        if isFill { return String(localized: "Fill", comment: "Window Gestures tile: the whole free area of the screen") }
        let top = rows == 2 && rowSpan == 1 && row == 0
        let bottom = rows == 2 && rowSpan == 1 && row == 1
        let left = column == 0, right = column + columnSpan == columns
        switch (columns, columnSpan) {
        case (2, 1):
            if top { return left ? String(localized: "Top Left Quarter") : String(localized: "Top Right Quarter") }
            if bottom { return left ? String(localized: "Bottom Left Quarter") : String(localized: "Bottom Right Quarter") }
            return left ? String(localized: "Left Half") : String(localized: "Right Half")
        case (3, 1):
            if top {
                return left ? String(localized: "Top Left Sixth") : right ? String(localized: "Top Right Sixth")
                    : String(localized: "Top Center Sixth")
            }
            if bottom {
                return left ? String(localized: "Bottom Left Sixth") : right ? String(localized: "Bottom Right Sixth")
                    : String(localized: "Bottom Center Sixth")
            }
            return left ? String(localized: "Left Third") : right ? String(localized: "Right Third")
                : String(localized: "Center Third")
        case (3, 2):
            if top {
                return left ? String(localized: "Top Left Two Thirds", comment: "Window Gestures tile: the top half of the left two thirds")
                    : String(localized: "Top Right Two Thirds", comment: "Window Gestures tile: the top half of the right two thirds")
            }
            if bottom {
                return left ? String(localized: "Bottom Left Two Thirds", comment: "Window Gestures tile: the bottom half of the left two thirds")
                    : String(localized: "Bottom Right Two Thirds", comment: "Window Gestures tile: the bottom half of the right two thirds")
            }
            return left ? String(localized: "Left Two Thirds") : String(localized: "Right Two Thirds")
        case (1, 1):
            return top ? String(localized: "Top Half") : String(localized: "Bottom Half")
        default:
            return String(localized: "Tile", comment: "Window Gestures: a window position on the screen grid")
        }
    }
}

/// One display: its full frame and work area (menu bar and Dock excluded), top-left coordinates.
public struct DisplaySlot: Equatable, Sendable {
    public var id: CGDirectDisplayID
    public var frame: CGRect
    public var work: CGRect

    public init(id: CGDirectDisplayID, frame: CGRect, work: CGRect) {
        self.id = id
        self.frame = frame
        self.work = work
    }
}

/// Display arrangement math for moving windows between displays.
public enum DisplayMap {
    /// The display next to `index` in `direction`, by physical arrangement: the nearest one whose
    /// center lies that way (preferring ones in line), else — wrapping around — the farthest one
    /// the other way. With two displays, every direction reaches the other one.
    public static func neighbor(of index: Int, toward direction: SwipeDirection, in frames: [CGRect]) -> Int? {
        guard frames.indices.contains(index), frames.count > 1 else { return nil }
        let c = frames[index].center
        func offset(_ i: Int) -> (along: CGFloat, across: CGFloat) {
            let p = frames[i].center
            switch direction {
            case .left: return (c.x - p.x, abs(p.y - c.y))
            case .right: return (p.x - c.x, abs(p.y - c.y))
            case .up: return (c.y - p.y, abs(p.x - c.x))
            case .down: return (p.y - c.y, abs(p.x - c.x))
            }
        }
        let others = frames.indices.filter { $0 != index }
        let ahead = others.filter { offset($0).along > 1 }
        if let best = ahead.min(by: { score(offset($0)) < score(offset($1)) }) { return best }
        return others.min { offset($0).along < offset($1).along }       // wrap: the farthest behind
    }

    private static func score(_ o: (along: CGFloat, across: CGFloat)) -> CGFloat { o.along + 2 * o.across }

    /// `frame` moved from work area `from` to `to`: same size when it fits (else shrunk to fit), at
    /// the same relative place in the free space, on whole points.
    public static func remap(_ frame: CGRect, from: CGRect, to: CGRect) -> CGRect {
        let w = min(frame.width, to.width), h = min(frame.height, to.height)
        func relative(_ pos: CGFloat, _ start: CGFloat, _ free: CGFloat) -> CGFloat {
            free > 0 ? min(max((pos - start) / free, 0), 1) : 0.5
        }
        let rx = relative(frame.minX, from.minX, from.width - frame.width)
        let ry = relative(frame.minY, from.minY, from.height - frame.height)
        return CGRect(x: (to.minX + rx * (to.width - w)).rounded(), y: (to.minY + ry * (to.height - h)).rounded(),
                      width: w.rounded(), height: h.rounded())
    }

    /// Where a window returns when restored: its old frame if it still shows on a display, else
    /// the old size centered in `work`.
    public static func restored(_ original: CGRect, displays: [CGRect], work: CGRect) -> CGRect {
        let visible = displays.contains { $0.intersection(original).area >= min(original.area, 40 * 40) * 0.5 }
        if visible { return original }
        let w = min(original.width, work.width), h = min(original.height, work.height)
        return CGRect(x: (work.midX - w / 2).rounded(), y: (work.midY - h / 2).rounded(), width: w, height: h)
    }
}
