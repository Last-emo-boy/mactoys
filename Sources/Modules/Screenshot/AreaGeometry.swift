import CoreGraphics
import Foundation

/// Pure geometry of the area selection, in one display's points with a top-left origin.
enum AreaGeometry {
    /// Selections smaller than this (points, either side) count as a click, not a drag.
    static let minimumSide: CGFloat = 4

    /// The rect dragged from `anchor` to `current`, kept inside `bounds`.
    /// - Parameters:
    ///   - square: ⇧ — equal sides (the shorter drag distance wins, so the corner never overshoots the pointer).
    ///   - fromCenter: ⌥ — `anchor` is the center rather than a corner.
    static func rect(anchor: CGPoint, current: CGPoint, square: Bool, fromCenter: Bool, in bounds: CGRect) -> CGRect {
        let a = clamp(anchor, to: bounds)
        let c = clamp(current, to: bounds)
        var dx = c.x - a.x
        var dy = c.y - a.y
        if square {
            var side = min(abs(dx), abs(dy))
            if fromCenter {
                // The square must fit around the center inside the display.
                side = min(side, a.x - bounds.minX, bounds.maxX - a.x, a.y - bounds.minY, bounds.maxY - a.y)
            } else {
                side = min(side, dx < 0 ? a.x - bounds.minX : bounds.maxX - a.x,
                           dy < 0 ? a.y - bounds.minY : bounds.maxY - a.y)
            }
            dx = dx < 0 ? -side : side
            dy = dy < 0 ? -side : side
        }
        if fromCenter {
            let hx = min(abs(dx), a.x - bounds.minX, bounds.maxX - a.x)
            let hy = min(abs(dy), a.y - bounds.minY, bounds.maxY - a.y)
            return CGRect(x: a.x - hx, y: a.y - hy, width: hx * 2, height: hy * 2)
        }
        return CGRect(x: min(a.x, a.x + dx), y: min(a.y, a.y + dy), width: abs(dx), height: abs(dy))
    }

    /// `r` moved by `delta` without changing its size, stopping at the display edges.
    static func moved(_ r: CGRect, by delta: CGVector, in bounds: CGRect) -> CGRect {
        let w = min(r.width, bounds.width), h = min(r.height, bounds.height)
        let x = min(max(r.minX + delta.dx, bounds.minX), bounds.maxX - w)
        let y = min(max(r.minY + delta.dy, bounds.minY), bounds.maxY - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Arrow-key nudge: moves the selection, or with `resize` grows/shrinks its right and bottom edges.
    static func nudged(_ r: CGRect, dx: CGFloat, dy: CGFloat, resize: Bool, in bounds: CGRect) -> CGRect {
        guard resize else { return moved(r, by: CGVector(dx: dx, dy: dy), in: bounds) }
        let w = min(max(minimumSide, r.width + dx), bounds.maxX - r.minX)
        let h = min(max(minimumSide, r.height + dy), bounds.maxY - r.minY)
        return CGRect(x: r.minX, y: r.minY, width: w, height: h)
    }

    /// A selection handle: the four corners and the four edge midpoints.
    enum Handle: CaseIterable, Sendable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        func point(in r: CGRect) -> CGPoint {
            switch self {
            case .topLeft: CGPoint(x: r.minX, y: r.minY)
            case .top: CGPoint(x: r.midX, y: r.minY)
            case .topRight: CGPoint(x: r.maxX, y: r.minY)
            case .right: CGPoint(x: r.maxX, y: r.midY)
            case .bottomRight: CGPoint(x: r.maxX, y: r.maxY)
            case .bottom: CGPoint(x: r.midX, y: r.maxY)
            case .bottomLeft: CGPoint(x: r.minX, y: r.maxY)
            case .left: CGPoint(x: r.minX, y: r.midY)
            }
        }
    }

    /// The handle within `radius` of `p`, if any (corners win over edges).
    static func handle(at p: CGPoint, of r: CGRect, radius: CGFloat = 8) -> Handle? {
        Handle.allCases.first { h in
            let c = h.point(in: r)
            return abs(c.x - p.x) <= radius && abs(c.y - p.y) <= radius
        }
    }

    /// `r` with one handle dragged to `p`; the opposite edge stays put and the rect never flips past it.
    static func resized(_ r: CGRect, handle: Handle, to p: CGPoint, in bounds: CGRect) -> CGRect {
        let q = clamp(p, to: bounds)
        var minX = r.minX, maxX = r.maxX, minY = r.minY, maxY = r.maxY
        switch handle {
        case .topLeft, .left, .bottomLeft: minX = min(q.x, maxX - minimumSide)
        case .topRight, .right, .bottomRight: maxX = max(q.x, minX + minimumSide)
        case .top, .bottom: break
        }
        switch handle {
        case .topLeft, .top, .topRight: minY = min(q.y, maxY - minimumSide)
        case .bottomLeft, .bottom, .bottomRight: maxY = max(q.y, minY + minimumSide)
        case .left, .right: break
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// The selection snapped to whole device pixels: each edge rounds to the nearest pixel, so a
    /// half-point edge on a 2× display stays exact and a 1× display never gets a blurry half pixel.
    static func snapped(_ r: CGRect, scale: CGFloat) -> CGRect {
        let px = pixelRect(r, scale: scale)
        return CGRect(x: px.minX / scale, y: px.minY / scale, width: px.width / scale, height: px.height / scale)
    }

    /// The selection in image pixels (top-left origin), edges rounded to the nearest pixel.
    static func pixelRect(_ r: CGRect, scale: CGFloat) -> CGRect {
        let s = max(scale, 0.01)
        let minX = (r.minX * s).rounded(), minY = (r.minY * s).rounded()
        let maxX = (r.maxX * s).rounded(), maxY = (r.maxY * s).rounded()
        return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }

    /// Pixel dimensions shown in the size label.
    static func pixelSize(_ r: CGRect, scale: CGFloat) -> (width: Int, height: Int) {
        let px = pixelRect(r, scale: scale)
        return (Int(px.width), Int(px.height))
    }

    /// Whether a released drag is big enough to capture.
    static func isUsable(_ r: CGRect) -> Bool { r.width >= minimumSide && r.height >= minimumSide }

    /// A remembered area fitted onto a display of `bounds` (the display may have changed resolution).
    static func restored(_ r: CGRect, in bounds: CGRect) -> CGRect? {
        guard isUsable(r) else { return nil }
        let fitted = moved(r, by: .zero, in: bounds)
        return isUsable(fitted) ? fitted : nil
    }

    static func clamp(_ p: CGPoint, to bounds: CGRect) -> CGPoint {
        CGPoint(x: min(max(p.x, bounds.minX), bounds.maxX), y: min(max(p.y, bounds.minY), bounds.maxY))
    }

    /// Where the loupe sits: below-right of the pointer, flipped to the other side near the display edges.
    static func loupeOrigin(pointer p: CGPoint, size: CGSize, in bounds: CGRect, offset: CGFloat = 22) -> CGPoint {
        var x = p.x + offset
        var y = p.y + offset
        if x + size.width > bounds.maxX - 4 { x = p.x - offset - size.width }
        if y + size.height > bounds.maxY - 4 { y = p.y - offset - size.height }
        return CGPoint(x: max(bounds.minX + 4, x), y: max(bounds.minY + 4, y))
    }
}
