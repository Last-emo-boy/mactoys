import CoreGraphics
import Foundation
import MacToysCore

/// A display as Window Controls sees it, in global top-left coordinates (the Accessibility space).
struct DisplayBox: Equatable, Sendable {
    /// Stable across reconnects (`NSScreen.stableID`, deduplicated).
    var key: String
    var id: CGDirectDisplayID
    var name: String
    var frame: CGRect
    /// Frame minus menu bar (and notch) and Dock.
    var visible: CGRect
    var isMain: Bool
}

/// Room kept between windows (`gap`) and between windows and the edges of the work area (`margin`).
struct Spacing: Equatable, Sendable {
    var gap: CGFloat
    var margin: CGFloat

    static let none = Spacing(gap: 0, margin: 0)
}

/// An arrow key's direction.
enum ArrowKey: String, CaseIterable, Sendable {
    case left, right, up, down

    var isHorizontal: Bool { self == .left || self == .right }
    var opposite: ArrowKey {
        switch self {
        case .left: .right
        case .right: .left
        case .up: .down
        case .down: .up
        }
    }
}

// MARK: - Placement

/// Turns placements expressed against a display (fractions, anchors, sizes) into window frames.
enum Placement {
    /// The visible frame minus the edge margin: where windows go.
    static func workArea(_ visible: CGRect, _ spacing: Spacing) -> CGRect {
        let m = max(0, min(spacing.margin, min(visible.width, visible.height) / 4))
        return visible.insetBy(dx: m, dy: m)
    }

    /// The frame covering `u` of the work area: the margin at the work area's edges, half the gap
    /// on every inner edge (so two neighbors end up exactly one gap apart). Whole points.
    static func frame(for u: UnitRect, in visible: CGRect, spacing: Spacing) -> CGRect {
        let a = workArea(visible, spacing)
        let r = u.clamped
        let half = max(0, spacing.gap) / 2
        let eps = 0.0005
        var x0 = a.minX + r.x * a.width, x1 = a.minX + r.maxX * a.width
        var y0 = a.minY + r.y * a.height, y1 = a.minY + r.maxY * a.height
        if r.x > eps { x0 += half }
        if r.maxX < 1 - eps { x1 -= half }
        if r.y > eps { y0 += half }
        if r.maxY < 1 - eps { y1 -= half }
        x0 = x0.rounded(); x1 = x1.rounded(); y0 = y0.rounded(); y1 = y1.rounded()
        return CGRect(x: x0, y: y0, width: max(1, x1 - x0), height: max(1, y1 - y0))
    }

    /// The part of the work area a frame covers, as fractions.
    static func unitRect(of frame: CGRect, in visible: CGRect, spacing: Spacing) -> UnitRect {
        let a = workArea(visible, spacing)
        guard a.width > 0, a.height > 0 else { return .full }
        return UnitRect(x: (frame.minX - a.minX) / a.width, y: (frame.minY - a.minY) / a.height,
                        width: frame.width / a.width, height: frame.height / a.height)
    }

    /// A window of `size` pinned at `anchor` of the work area (shrunk to fit it).
    static func anchored(_ size: CGSize, at anchor: Anchor, in visible: CGRect, spacing: Spacing) -> CGRect {
        let a = workArea(visible, spacing)
        let w = min(size.width, a.width), h = min(size.height, a.height)
        let u = anchor.unit
        let x = a.minX + (a.width - w) * u.x, y = a.minY + (a.height - h) * u.y
        return CGRect(x: x.rounded(), y: y.rounded(), width: w.rounded(), height: h.rounded())
    }

    /// The window resized by `width` × `height`: pinned at `anchor` of the work area, or around its
    /// own center (`inPlace`), and kept inside the work area.
    static func resized(_ frame: CGRect, width: Dimension, height: Dimension, anchor: Anchor, inPlace: Bool,
                        in visible: CGRect, spacing: Spacing) -> CGRect {
        let a = workArea(visible, spacing)
        let size = CGSize(width: width.resolve(available: a.width, current: frame.width),
                          height: height.resolve(available: a.height, current: frame.height))
        guard inPlace else { return anchored(size, at: anchor, in: visible, spacing: spacing) }
        let r = CGRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height)
        return clamp(r, into: a)
    }

    /// The window moved, at its size, to `anchor` of the work area.
    static func moved(_ frame: CGRect, to anchor: Anchor, in visible: CGRect, spacing: Spacing) -> CGRect {
        anchored(frame.size, at: anchor, in: visible, spacing: spacing)
    }

    /// Shrinks `r` to fit `area` and moves it inside; whole points.
    static func clamp(_ r: CGRect, into area: CGRect) -> CGRect {
        guard area.width > 0, area.height > 0 else { return r }
        let w = min(r.width, area.width), h = min(r.height, area.height)
        let x = min(max(r.minX, area.minX), area.maxX - w)
        let y = min(max(r.minY, area.minY), area.maxY - h)
        return CGRect(x: x.rounded(), y: y.rounded(), width: w.rounded(), height: h.rounded())
    }

    /// Where a window on `source` goes on `target`. A window against an edge of the work area keeps
    /// its share of it (a left half stays a left half); any other window keeps its size and its
    /// relative position.
    static func transfer(_ frame: CGRect, from source: DisplayBox, to target: DisplayBox, spacing: Spacing) -> CGRect {
        let sa = workArea(source.visible, spacing), ta = workArea(target.visible, spacing)
        guard sa.width > 0, sa.height > 0 else { return clamp(frame, into: ta) }
        let sx = ta.width / sa.width, sy = ta.height / sa.height
        let tol: CGFloat = 2
        let placed = abs(frame.minX - sa.minX) <= tol || abs(frame.maxX - sa.maxX) <= tol
            || abs(frame.minY - sa.minY) <= tol || abs(frame.maxY - sa.maxY) <= tol
        if placed {
            let r = CGRect(x: ta.minX + (frame.minX - sa.minX) * sx, y: ta.minY + (frame.minY - sa.minY) * sy,
                           width: frame.width * sx, height: frame.height * sy)
            return clamp(r, into: ta)
        }
        let cx = ta.minX + (frame.midX - sa.minX) * sx, cy = ta.minY + (frame.midY - sa.minY) * sy
        let r = CGRect(x: cx - frame.width / 2, y: cy - frame.height / 2, width: frame.width, height: frame.height)
        return clamp(r, into: ta)
    }

    /// Where a window goes when its app kept a size of its own (a minimum, a fixed step): against
    /// the same work-area edges as `target`, else centered on it.
    static func realigned(actual: CGSize, target: CGRect, area: CGRect) -> CGRect {
        let tol: CGFloat = 1
        let left = abs(target.minX - area.minX) <= tol, right = abs(target.maxX - area.maxX) <= tol
        let top = abs(target.minY - area.minY) <= tol, bottom = abs(target.maxY - area.maxY) <= tol
        let x = right && !left ? target.maxX - actual.width : left ? target.minX : target.midX - actual.width / 2
        let y = bottom && !top ? target.maxY - actual.height : top ? target.minY : target.midY - actual.height / 2
        let r = CGRect(x: x, y: y, width: actual.width, height: actual.height)
        guard actual.width <= area.width, actual.height <= area.height else {
            return CGRect(origin: CGPoint(x: x.rounded(), y: y.rounded()), size: actual)
        }
        return clamp(r, into: area)
    }

    /// Whether two frames are the same within `tolerance` points on every edge.
    static func isClose(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 3) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.maxX - b.maxX) <= tolerance && abs(a.maxY - b.maxY) <= tolerance
    }
}

// MARK: - Grid

/// A cell of the resize grid: column and row from the top-left, 0-based.
struct GridCell: Hashable, Sendable {
    var column: Int
    var row: Int
}

/// The resize grid shown in the palette: columns × rows over the work area.
struct GridSpec: Equatable, Sendable {
    static let range = 1...24

    let columns: Int
    let rows: Int

    init(columns: Int, rows: Int) {
        self.columns = min(max(columns, Self.range.lowerBound), Self.range.upperBound)
        self.rows = min(max(rows, Self.range.lowerBound), Self.range.upperBound)
    }

    /// The grid for a display: with `swapOnPortrait`, a portrait display gets the columns as rows,
    /// so a 6 × 4 grid stays 4 wide and 6 tall on a monitor turned on its side.
    static func oriented(columns: Int, rows: Int, for visible: CGRect, swapOnPortrait: Bool) -> GridSpec {
        let portrait = visible.height > visible.width
        let landscapeWide = columns >= rows
        if swapOnPortrait && portrait && landscapeWide { return GridSpec(columns: rows, rows: columns) }
        return GridSpec(columns: columns, rows: rows)
    }

    /// The cell under `p` in a grid drawn `size` large; points outside snap to the nearest cell.
    func cell(at p: CGPoint, in size: CGSize) -> GridCell {
        guard size.width > 0, size.height > 0 else { return GridCell(column: 0, row: 0) }
        let c = Int((p.x / size.width * CGFloat(columns)).rounded(.down))
        let r = Int((p.y / size.height * CGFloat(rows)).rounded(.down))
        return GridCell(column: min(max(c, 0), columns - 1), row: min(max(r, 0), rows - 1))
    }

    /// The rectangle of cells spanned by two corner cells, in either order, as fractions.
    func unitRect(from a: GridCell, to b: GridCell) -> UnitRect {
        let c0 = min(a.column, b.column), c1 = max(a.column, b.column)
        let r0 = min(a.row, b.row), r1 = max(a.row, b.row)
        let w = Double(columns), h = Double(rows)
        return UnitRect(x: Double(c0) / w, y: Double(r0) / h, width: Double(c1 - c0 + 1) / w, height: Double(r1 - r0 + 1) / h)
    }

    /// Number of cells spanned by two corners: (columns, rows).
    func span(from a: GridCell, to b: GridCell) -> (columns: Int, rows: Int) {
        (abs(a.column - b.column) + 1, abs(a.row - b.row) + 1)
    }
}

// MARK: - Keyboard mode

/// Geometry of keyboard mode: halves and quarters, growing and shrinking, nudging.
enum KeyboardGeometry {
    /// Smallest size ⇧-arrows shrink a window to.
    static let minimumSize = CGSize(width: 200, height: 120)

    /// An arrow gives a half of the screen; a second, perpendicular arrow right after gives the
    /// quarter between both (← then ↑: top left).
    static func half(_ arrow: ArrowKey, after previous: ArrowKey?) -> UnitRect {
        if let p = previous, p.isHorizontal != arrow.isHorizontal {
            let h = arrow.isHorizontal ? arrow : p, v = arrow.isHorizontal ? p : arrow
            return UnitRect(x: h == .left ? 0 : 0.5, y: v == .up ? 0 : 0.5, width: 0.5, height: 0.5)
        }
        switch arrow {
        case .left: return UnitRect(x: 0, y: 0, width: 0.5, height: 1)
        case .right: return UnitRect(x: 0.5, y: 0, width: 0.5, height: 1)
        case .up: return UnitRect(x: 0, y: 0, width: 1, height: 0.5)
        case .down: return UnitRect(x: 0, y: 0.5, width: 1, height: 0.5)
        }
    }

    /// Where an arrow sends a window: the half (or, after a perpendicular arrow, the quarter) of its
    /// display; a window already filling that half goes on to the display beyond it, landing on the
    /// facing half (← from the left half: the right half of the display on the left).
    static func halfTarget(_ arrow: ArrowKey, previous: ArrowKey?, frame: CGRect, displays: [DisplayBox],
                           spacing: Spacing) -> CGRect? {
        guard let d = DisplayNavigator.index(showing: frame, in: displays) else { return nil }
        let region = half(arrow, after: previous)
        let target = Placement.frame(for: region, in: displays[d].visible, spacing: spacing)
        let isQuarter = region.width < 1 && region.height < 1
        if !isQuarter, Placement.isClose(frame, target, tolerance: 3),
           let n = DisplayNavigator.neighbor(of: d, toward: arrow, in: displays) {
            return Placement.frame(for: half(arrow.opposite, after: nil), in: displays[n].visible, spacing: spacing)
        }
        return target
    }

    /// ⇧-arrows: → wider, ← narrower, ↓ taller, ↑ shorter, by `step`. A window against one side of
    /// the work area stays against it; a full-width (or full-height) window shrinks around its
    /// center; a window that would grow past the work area grows the other way instead.
    static func resized(_ frame: CGRect, arrow: ArrowKey, step: CGFloat, area: CGRect,
                        minimum: CGSize = minimumSize) -> CGRect {
        let grow = arrow == .right || arrow == .down
        let delta = grow ? step : -step
        let tol: CGFloat = 2
        var r = frame
        if arrow.isHorizontal {
            let floor = min(minimum.width, frame.width)
            let w = min(max(frame.width + delta, floor), max(area.width, floor))
            let atLeft = abs(frame.minX - area.minX) <= tol, atRight = abs(frame.maxX - area.maxX) <= tol
            if atLeft && atRight { r.origin.x = frame.midX - w / 2 }
            else if atRight { r.origin.x = frame.maxX - w }
            r.size.width = w
            if r.width <= area.width {
                if r.maxX > area.maxX { r.origin.x = area.maxX - r.width }
                if r.minX < area.minX { r.origin.x = area.minX }
            }
        } else {
            let floor = min(minimum.height, frame.height)
            let h = min(max(frame.height + delta, floor), max(area.height, floor))
            let atTop = abs(frame.minY - area.minY) <= tol, atBottom = abs(frame.maxY - area.maxY) <= tol
            if atTop && atBottom { r.origin.y = frame.midY - h / 2 }
            else if atBottom { r.origin.y = frame.maxY - h }
            r.size.height = h
            if r.height <= area.height {
                if r.maxY > area.maxY { r.origin.y = area.maxY - r.height }
                if r.minY < area.minY { r.origin.y = area.minY }
            }
        }
        return CGRect(x: r.minX.rounded(), y: r.minY.rounded(), width: r.width.rounded(), height: r.height.rounded())
    }

    /// ⌥-arrows: the window moved by `step`, kept inside `area` along the axes where it fits.
    static func nudged(_ frame: CGRect, arrow: ArrowKey, step: CGFloat, area: CGRect) -> CGRect {
        var r = frame
        switch arrow {
        case .left: r.origin.x -= step
        case .right: r.origin.x += step
        case .up: r.origin.y -= step
        case .down: r.origin.y += step
        }
        if r.width <= area.width { r.origin.x = min(max(r.minX, area.minX), area.maxX - r.width) }
        if r.height <= area.height { r.origin.y = min(max(r.minY, area.minY), area.maxY - r.height) }
        return CGRect(x: r.minX.rounded(), y: r.minY.rounded(), width: r.width, height: r.height)
    }
}

// MARK: - Displays

/// Finding displays: the one showing a window, and the one a "move to display" step goes to.
enum DisplayNavigator {
    /// Indices of `displays` in reading order: left to right, then top to bottom.
    static func readingOrder(_ displays: [DisplayBox]) -> [Int] {
        displays.indices.sorted { a, b in
            let fa = displays[a].frame, fb = displays[b].frame
            return fa.minX != fb.minX ? fa.minX < fb.minX : fa.minY < fb.minY
        }
    }

    /// The display showing a frame: the one containing its center, else the one it overlaps most.
    static func index(showing frame: CGRect, in displays: [DisplayBox]) -> Int? {
        guard !displays.isEmpty else { return nil }
        let c = CGPoint(x: frame.midX, y: frame.midY)
        if let i = displays.firstIndex(where: { $0.frame.contains(c) }) { return i }
        let best = displays.indices.max { displays[$0].frame.intersection(frame).area < displays[$1].frame.intersection(frame).area }
        if let best, displays[best].frame.intersection(frame).area > 0 { return best }
        return displays.indices.min { displays[$0].frame.distance(to: c) < displays[$1].frame.distance(to: c) }
    }

    /// The display a step goes to from display `index`; nil when there is none (one display, no
    /// display in that direction).
    static func target(_ t: DisplayTarget, from index: Int, in displays: [DisplayBox]) -> Int? {
        guard displays.indices.contains(index), displays.count > 1 else { return nil }
        let order = readingOrder(displays)
        let pos = order.firstIndex(of: index) ?? 0
        switch t {
        case .next: return order[(pos + 1) % order.count]
        case .previous: return order[(pos - 1 + order.count) % order.count]
        case .main:
            let main = displays.firstIndex { $0.isMain } ?? order[0]
            return main == index ? nil : main
        case .left: return neighbor(of: index, toward: .left, in: displays)
        case .right: return neighbor(of: index, toward: .right, in: displays)
        case .up: return neighbor(of: index, toward: .up, in: displays)
        case .down: return neighbor(of: index, toward: .down, in: displays)
        }
    }

    /// The nearest display whose center lies in the arrow's direction; displays lined up with the
    /// current one beat displays off to the side.
    static func neighbor(of index: Int, toward arrow: ArrowKey, in displays: [DisplayBox]) -> Int? {
        let here = displays[index].frame
        var best: (Int, CGFloat)?
        for (i, d) in displays.enumerated() where i != index {
            let dx = d.frame.midX - here.midX, dy = d.frame.midY - here.midY
            let along: CGFloat, across: CGFloat
            switch arrow {
            case .left: (along, across) = (-dx, dy)
            case .right: (along, across) = (dx, dy)
            case .up: (along, across) = (-dy, dx)
            case .down: (along, across) = (dy, dx)
            }
            guard along > 1 else { continue }
            let score = along + abs(across) * 2
            if let b = best, b.1 <= score { continue }
            best = (i, score)
        }
        return best?.0
    }
}

// MARK: - Planning controls

/// What a plan needs to know about the screen and the window.
struct PlanContext {
    var displays: [DisplayBox]
    var spacing: Spacing
    /// Windows that can't be resized keep their size and are centered where the step would put them.
    var resizable = true
}

/// Turns control steps into the frame a window should get. Pure, so it is unit tested.
enum ControlPlanner {
    /// The frame after running `steps` in order on a window at `frame`; nil when no step applies
    /// (e.g. "next display" with a single display).
    static func plan(_ steps: [ControlStep], frame: CGRect, context: PlanContext) -> CGRect? {
        guard var display = DisplayNavigator.index(showing: frame, in: context.displays) else { return nil }
        var f = frame
        var changed = false
        for step in steps {
            guard let (next, d) = apply(step, frame: f, display: display, context: context) else { continue }
            f = next
            display = d
            changed = true
        }
        return changed ? f : nil
    }

    /// One step from a window at `frame` on display `display`: the new frame and display.
    static func apply(_ step: ControlStep, frame: CGRect, display: Int, context: PlanContext) -> (CGRect, Int)? {
        guard context.displays.indices.contains(display) else { return nil }
        let box = context.displays[display]
        var index = display
        var target: CGRect
        switch step.kind {
        case .place:
            target = Placement.frame(for: step.region, in: box.visible, spacing: context.spacing)
        case .resize:
            target = Placement.resized(frame, width: step.width, height: step.height, anchor: step.anchor,
                                       inPlace: step.inPlace, in: box.visible, spacing: context.spacing)
        case .move:
            target = Placement.moved(frame, to: step.anchor, in: box.visible, spacing: context.spacing)
        case .display:
            guard let t = DisplayNavigator.target(step.display, from: display, in: context.displays) else { return nil }
            index = t
            target = Placement.transfer(frame, from: box, to: context.displays[t], spacing: context.spacing)
        }
        if !context.resizable && target.size != frame.size {
            let centered = CGRect(x: target.midX - frame.width / 2, y: target.midY - frame.height / 2,
                                  width: frame.width, height: frame.height)
            target = Placement.clamp(centered, into: context.displays[index].visible)
        }
        return (target, index)
    }

    /// Which step of a cycling chain runs next: the one after the last, while the window is still
    /// where that step left it; otherwise the first.
    static func nextCycleIndex(count: Int, last: Int?, lastFrame: CGRect?, current: CGRect) -> Int {
        guard count > 0, let last, let lastFrame, Placement.isClose(lastFrame, current, tolerance: 4) else { return 0 }
        return (last + 1) % count
    }
}
