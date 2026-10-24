import CoreGraphics
import Foundation

/// A grid layout: row heights and column widths as fractions, plus a cell → zone map.
///
/// A zone is the rectangle of cells carrying its index; several cells with the same index form a
/// merged zone. Rows and columns are global, so moving a splitter moves the whole grid line.
/// Every editing operation returns a `normalized()` grid: zones numbered column by column
/// (top to bottom, then left to right) and no duplicate rows or columns.
public struct GridLayout: Codable, Hashable, Sendable {
    /// Relative row heights, top to bottom (sum 1).
    public var rows: [Double]
    /// Relative column widths, left to right (sum 1).
    public var columns: [Double]
    /// `cells[row][column]` = zone index.
    public var cells: [[Int]]

    /// Smallest fraction a row or column may shrink to while editing.
    public static let minimumFraction = 0.03

    public init(rows: [Double], columns: [Double], cells: [[Int]]) {
        self.rows = rows
        self.columns = columns
        self.cells = cells
    }

    // MARK: Templates

    public static func columns(_ n: Int) -> GridLayout {
        let n = max(1, n)
        return GridLayout(rows: [1], columns: Array(repeating: 1 / Double(n), count: n), cells: [Array(0..<n)])
    }

    public static func rows(_ n: Int) -> GridLayout {
        let n = max(1, n)
        return GridLayout(rows: Array(repeating: 1 / Double(n), count: n), columns: [1], cells: (0..<n).map { [$0] })
    }

    /// The PowerToys "Grid" template: as square as possible; leftover cells merge at the top of
    /// the first column, which becomes one taller zone.
    public static func grid(_ n: Int) -> GridLayout {
        let n = max(1, n)
        var rowCount = 1
        while n / rowCount >= rowCount { rowCount += 1 }
        rowCount -= 1
        let columnCount = n / rowCount + (n % rowCount == 0 ? 0 : 1)
        let extra = rowCount * columnCount - n
        var cells = Array(repeating: Array(repeating: 0, count: columnCount), count: rowCount)
        var next = 0
        for c in 0..<columnCount {
            for r in 0..<rowCount {
                if c == 0 && r <= extra { cells[r][c] = 0; if r == extra { next = 1 }; continue }
                cells[r][c] = next
                next += 1
            }
        }
        return GridLayout(rows: Array(repeating: 1 / Double(rowCount), count: rowCount),
                          columns: Array(repeating: 1 / Double(columnCount), count: columnCount),
                          cells: cells).normalized()
    }

    /// The PowerToys "Priority Grid" template: a wide center zone flanked by smaller ones.
    /// Defined for 1…11 zones; more falls back to `grid`.
    public static func priority(_ n: Int) -> GridLayout {
        let n = max(1, n)
        let thirds = [1.0 / 3, 1.0 / 3, 1.0 / 3]
        let center = [0.25, 0.5, 0.25]
        let quarters = [0.25, 0.25, 0.25, 0.25]
        let defs: [(rows: [Double], columns: [Double], cells: [[Int]])] = [
            ([1], [1], [[0]]),
            ([1], [2.0 / 3, 1.0 / 3], [[0, 1]]),
            ([1], center, [[0, 1, 2]]),
            ([0.5, 0.5], center, [[0, 1, 2], [0, 1, 3]]),
            ([0.5, 0.5], center, [[0, 1, 2], [3, 1, 4]]),
            (thirds, center, [[0, 1, 2], [0, 1, 3], [4, 1, 5]]),
            (thirds, center, [[0, 1, 2], [3, 1, 4], [5, 1, 6]]),
            (thirds, quarters, [[0, 1, 2, 3], [4, 1, 2, 5], [6, 1, 2, 7]]),
            (thirds, quarters, [[0, 1, 2, 3], [4, 1, 2, 5], [6, 1, 7, 8]]),
            (thirds, quarters, [[0, 1, 2, 3], [4, 1, 5, 6], [7, 1, 8, 9]]),
            (thirds, quarters, [[0, 1, 2, 3], [4, 1, 5, 6], [7, 8, 9, 10]]),
        ]
        guard n <= defs.count else { return grid(n) }
        let d = defs[n - 1]
        return GridLayout(rows: d.rows, columns: d.columns, cells: d.cells).normalized()
    }

    // MARK: Structure

    /// Rectangular cell map matching the fractions, positive fractions, no negative zone ids.
    /// Every other operation assumes this; grids read from disk are checked first.
    public var isWellFormed: Bool {
        !rows.isEmpty && !columns.isEmpty && cells.count == rows.count
            && cells.allSatisfy { $0.count == columns.count && $0.allSatisfy { $0 >= 0 } }
            && rows.allSatisfy { $0.isFinite && $0 > 0 } && columns.allSatisfy { $0.isFinite && $0 > 0 }
    }

    /// Well formed, zones numbered 0..<n without gaps, and every zone a filled rectangle of cells.
    public var isValid: Bool {
        guard isWellFormed else { return false }
        let count = zoneCount
        guard Set(cells.flatMap { $0 }).count == count else { return false }
        for (z, s) in spans.enumerated() {
            for r in s.rows { for c in s.columns where cells[r][c] != z { return false } }
        }
        return true
    }

    public var rowCount: Int { rows.count }
    public var columnCount: Int { columns.count }
    public var zoneCount: Int { (cells.flatMap { $0 }.max() ?? -1) + 1 }

    /// Cell ranges covered by a zone.
    public struct Span: Hashable, Sendable {
        public var rows: ClosedRange<Int>
        public var columns: ClosedRange<Int>
    }

    /// The cell span of every zone, indexed by zone.
    public var spans: [Span] {
        var result = [Span?](repeating: nil, count: zoneCount)
        for (r, row) in cells.enumerated() {
            for (c, z) in row.enumerated() where z >= 0 && z < result.count {
                if let s = result[z] {
                    result[z] = Span(rows: min(s.rows.lowerBound, r)...max(s.rows.upperBound, r),
                                     columns: min(s.columns.lowerBound, c)...max(s.columns.upperBound, c))
                } else {
                    result[z] = Span(rows: r...r, columns: c...c)
                }
            }
        }
        return result.map { $0 ?? Span(rows: 0...0, columns: 0...0) }
    }

    /// Start positions (unit coordinates) of each column, plus 1 at the end.
    public var columnEdges: [Double] { Self.edges(columns) }
    public var rowEdges: [Double] { Self.edges(rows) }

    private static func edges(_ fractions: [Double]) -> [Double] {
        var result = [0.0]
        var sum = 0.0
        for f in fractions { sum += f; result.append(sum) }
        if let last = result.last, last > 0 { result = result.map { $0 / last } }
        return result
    }

    /// Zone rectangles in the unit square (no spacing).
    public var unitRects: [CGRect] {
        let ce = columnEdges, re = rowEdges
        return spans.map { s in
            CGRect(x: ce[s.columns.lowerBound], y: re[s.rows.lowerBound],
                   width: ce[s.columns.upperBound + 1] - ce[s.columns.lowerBound],
                   height: re[s.rows.upperBound + 1] - re[s.rows.lowerBound])
        }
    }

    /// Zone rectangles in `rect`: `spacing` around the outside and between zones, and every
    /// column (row) keeps its share of the space left after spacing, so equal fractions give
    /// equal zone sizes.
    public func zones(in rect: CGRect, spacing: CGFloat) -> [CGRect] {
        let (xs, xe) = Self.tracks(fractions: columns, start: rect.minX, length: rect.width, spacing: spacing)
        let (ys, ye) = Self.tracks(fractions: rows, start: rect.minY, length: rect.height, spacing: spacing)
        return spans.map { s in
            let x0 = xs[s.columns.lowerBound], x1 = xe[s.columns.upperBound]
            let y0 = ys[s.rows.lowerBound], y1 = ye[s.rows.upperBound]
            return ZoneGeometry.rounded(CGRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0)))
        }
    }

    private static func tracks(fractions: [Double], start: CGFloat, length: CGFloat,
                               spacing: CGFloat) -> ([CGFloat], [CGFloat]) {
        let total = fractions.reduce(0, +)
        let available = max(0, length - spacing * CGFloat(fractions.count + 1))
        var starts: [CGFloat] = [], ends: [CGFloat] = []
        var pos = start + spacing
        for f in fractions {
            let size = total > 0 ? available * CGFloat(f / total) : 0
            starts.append(pos)
            ends.append(pos + size)
            pos += size + spacing
        }
        return (starts, ends)
    }

    // MARK: Editing

    /// Splits `zone` with a line at unit position `position` — an x for a vertical line
    /// (side-by-side zones), a y for a horizontal one. Returns self when the line would leave a
    /// sliver smaller than `minimumFraction`.
    public func splitting(zone: Int, vertical: Bool, at position: Double) -> GridLayout {
        guard zone >= 0 && zone < zoneCount else { return self }
        if !vertical {
            return transposed().splitting(zone: zone, vertical: true, at: position).transposed().normalized()
        }
        let span = spans[zone]
        let edges = columnEdges
        let lo = edges[span.columns.lowerBound], hi = edges[span.columns.upperBound + 1]
        guard position - lo >= Self.minimumFraction, hi - position >= Self.minimumFraction else { return self }

        var g = self
        let newZone = zoneCount
        // Reuse an existing column boundary inside the zone when the line falls on it.
        if let k = span.columns.dropLast().first(where: { abs(edges[$0 + 1] - position) < 0.005 }) {
            for r in span.rows { for c in (k + 1)...span.columns.upperBound { g.cells[r][c] = newZone } }
            return g.normalized()
        }
        guard let c = span.columns.first(where: { edges[$0] < position && position < edges[$0 + 1] }) else { return self }
        let left = position - edges[c], right = edges[c + 1] - position
        g.columns[c] = left
        g.columns.insert(right, at: c + 1)
        for r in 0..<g.cells.count { g.cells[r].insert(g.cells[r][c], at: c + 1) }
        for r in span.rows { for col in (c + 1)...(span.columns.upperBound + 1) { g.cells[r][col] = newZone } }
        return g.normalized()
    }

    /// The zones a merge of `selection` combines: the smallest rectangle of whole zones containing it.
    public func mergeClosure(_ selection: Set<Int>) -> Set<Int> {
        let all = spans
        let picked = selection.filter { $0 >= 0 && $0 < all.count }
        guard let first = picked.first else { return [] }
        var rowsRange = all[first].rows, colsRange = all[first].columns
        func grow(_ s: Span) -> Bool {
            let r = min(rowsRange.lowerBound, s.rows.lowerBound)...max(rowsRange.upperBound, s.rows.upperBound)
            let c = min(colsRange.lowerBound, s.columns.lowerBound)...max(colsRange.upperBound, s.columns.upperBound)
            defer { rowsRange = r; colsRange = c }
            return r != rowsRange || c != colsRange
        }
        for z in picked { _ = grow(all[z]) }
        var changed = true
        while changed {
            changed = false
            for s in all where s.rows.overlaps(rowsRange) && s.columns.overlaps(colsRange) {
                if grow(s) { changed = true }
            }
        }
        return Set(all.indices.filter { all[$0].rows.overlaps(rowsRange) && all[$0].columns.overlaps(colsRange) })
    }

    /// Merges the selection (grown to a rectangle, see `mergeClosure`) into one zone.
    public func merging(_ selection: Set<Int>) -> GridLayout {
        let zones = mergeClosure(selection)
        guard zones.count > 1, let target = zones.min() else { return self }
        var g = self
        for r in 0..<g.cells.count {
            for c in 0..<g.cells[r].count where zones.contains(g.cells[r][c]) { g.cells[r][c] = target }
        }
        return g.normalized()
    }

    /// A draggable divider segment between two zones.
    public struct Splitter: Hashable, Sendable {
        /// True for a vertical line (between columns).
        public var vertical: Bool
        /// The boundary after column (row) `index`.
        public var index: Int
        /// Unit position of the line.
        public var position: Double
        /// Unit extent along the line.
        public var range: ClosedRange<Double>
    }

    /// Every visible divider segment, for the grid editor.
    public var splitters: [Splitter] {
        var result: [Splitter] = []
        let ce = columnEdges, re = rowEdges
        for k in 0..<max(0, columnCount - 1) {
            var runStart: Int?
            for r in 0...rowCount {
                let split = r < rowCount && cells[r][k] != cells[r][k + 1]
                if split, runStart == nil { runStart = r }
                if !split, let s = runStart {
                    result.append(Splitter(vertical: true, index: k, position: ce[k + 1], range: re[s]...re[r]))
                    runStart = nil
                }
            }
        }
        for k in 0..<max(0, rowCount - 1) {
            var runStart: Int?
            for c in 0...columnCount {
                let split = c < columnCount && cells[k][c] != cells[k + 1][c]
                if split, runStart == nil { runStart = c }
                if !split, let s = runStart {
                    result.append(Splitter(vertical: false, index: k, position: re[k + 1], range: ce[s]...ce[c]))
                    runStart = nil
                }
            }
        }
        return result
    }

    /// Moves the boundary after column (row) `index` to unit position `position`, keeping both
    /// neighbors at least `minimumFraction` wide.
    public func movingSplitter(vertical: Bool, index: Int, to position: Double) -> GridLayout {
        var g = self
        let edges = vertical ? columnEdges : rowEdges
        guard index >= 0, index + 2 < edges.count else { return self }
        let lo = edges[index] + Self.minimumFraction, hi = edges[index + 2] - Self.minimumFraction
        guard lo <= hi else { return self }
        let p = min(max(position, lo), hi)
        if vertical {
            g.columns = Self.fractions(edges)
            g.columns[index] = p - edges[index]
            g.columns[index + 1] = edges[index + 2] - p
        } else {
            g.rows = Self.fractions(edges)
            g.rows[index] = p - edges[index]
            g.rows[index + 1] = edges[index + 2] - p
        }
        return g
    }

    private static func fractions(_ edges: [Double]) -> [Double] {
        zip(edges.dropFirst(), edges).map { $0 - $1 }
    }

    /// Swaps rows and columns.
    public func transposed() -> GridLayout {
        let t = (0..<columnCount).map { c in (0..<rowCount).map { r in cells[r][c] } }
        return GridLayout(rows: columns, columns: rows, cells: t)
    }

    /// Collapses identical neighboring rows/columns, renumbers zones column by column, and
    /// rescales fractions to sum to 1.
    public func normalized() -> GridLayout {
        guard !cells.isEmpty, !rows.isEmpty, !columns.isEmpty else { return .columns(1) }
        var g = self
        // Collapse duplicate adjacent rows.
        var r = 1
        while r < g.cells.count {
            if g.cells[r] == g.cells[r - 1] {
                g.rows[r - 1] += g.rows[r]
                g.rows.remove(at: r)
                g.cells.remove(at: r)
            } else { r += 1 }
        }
        // Collapse duplicate adjacent columns.
        var c = 1
        while c < g.columns.count {
            if g.cells.allSatisfy({ $0[c] == $0[c - 1] }) {
                g.columns[c - 1] += g.columns[c]
                g.columns.remove(at: c)
                for i in 0..<g.cells.count { g.cells[i].remove(at: c) }
            } else { c += 1 }
        }
        // Renumber column-major by first appearance.
        var map: [Int: Int] = [:]
        for col in 0..<g.columns.count {
            for row in 0..<g.rows.count where map[g.cells[row][col]] == nil {
                map[g.cells[row][col]] = map.count
            }
        }
        g.cells = g.cells.map { $0.map { map[$0] ?? 0 } }
        let rs = g.rows.reduce(0, +), cs = g.columns.reduce(0, +)
        if rs > 0 { g.rows = g.rows.map { $0 / rs } }
        if cs > 0 { g.columns = g.columns.map { $0 / cs } }
        return g
    }
}
