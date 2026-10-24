import CoreGraphics
import Foundation

/// Window edges a resize drags (a corner is two edges).
public struct GrabEdges: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let left = GrabEdges(rawValue: 1 << 0)
    public static let right = GrabEdges(rawValue: 1 << 1)
    public static let top = GrabEdges(rawValue: 1 << 2)
    public static let bottom = GrabEdges(rawValue: 1 << 3)
}

/// Pure move/resize math in top-left (y down) coordinates. No allocations: safe for the event path.
public enum GrabGeometry {
    /// Smallest size a resize shrinks a window to (apps may enforce a larger minimum).
    public static let minimumSize = CGSize(width: 160, height: 90)

    /// The edge or corner to resize from when grabbing `point` inside `frame`: the window is cut
    /// into thirds; the outer thirds pick corners and edges, and the center picks the nearest edge.
    public static func edges(for point: CGPoint, in frame: CGRect) -> GrabEdges {
        guard frame.width > 0, frame.height > 0 else { return [.right, .bottom] }
        let u = (point.x - frame.minX) / frame.width
        let v = (point.y - frame.minY) / frame.height
        var e: GrabEdges = []
        if u < 1.0 / 3 { e.insert(.left) } else if u > 2.0 / 3 { e.insert(.right) }
        if v < 1.0 / 3 { e.insert(.top) } else if v > 2.0 / 3 { e.insert(.bottom) }
        guard e.isEmpty else { return e }
        let left = point.x - frame.minX, right = frame.maxX - point.x
        let top = point.y - frame.minY, bottom = frame.maxY - point.y
        let nearest = min(left, right, top, bottom)
        if nearest == left { return .left }
        if nearest == right { return .right }
        if nearest == top { return .top }
        return .bottom
    }

    /// `start` moved by `delta`, on whole points.
    public static func moved(_ start: CGRect, by delta: CGSize) -> CGRect {
        CGRect(x: (start.minX + delta.width).rounded(), y: (start.minY + delta.height).rounded(),
               width: start.width, height: start.height)
    }

    /// `start` with `edges` dragged by `delta`. The opposite edges stay put and the window keeps
    /// at least `minSize` (or its starting size, if it was already smaller).
    public static func resized(_ start: CGRect, edges: GrabEdges, by delta: CGSize,
                               minSize: CGSize = minimumSize) -> CGRect {
        let minW = min(minSize.width, start.width), minH = min(minSize.height, start.height)
        var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY
        if edges.contains(.left) { minX = min(start.minX + delta.width, start.maxX - minW) }
        if edges.contains(.right) { maxX = max(start.maxX + delta.width, start.minX + minW) }
        if edges.contains(.top) { minY = min(start.minY + delta.height, start.maxY - minH) }
        if edges.contains(.bottom) { maxY = max(start.maxY + delta.height, start.minY + minH) }
        minX = minX.rounded(); minY = minY.rounded(); maxX = maxX.rounded(); maxY = maxY.rounded()
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Where the origin must go after an app clamped a left/top resize to `actual` size,
    /// so the opposite edges stay where the drag put them.
    public static func anchoredOrigin(for target: CGRect, actual: CGSize, edges: GrabEdges) -> CGPoint {
        CGPoint(x: edges.contains(.left) ? target.maxX - actual.width : target.minX,
                y: edges.contains(.top) ? target.maxY - actual.height : target.minY)
    }

    /// The readout text: "x 412  y 188  ·  1280 × 820".
    public static func readout(_ frame: CGRect) -> String {
        "x \(Int(frame.minX.rounded()))  y \(Int(frame.minY.rounded()))  ·  \(Int(frame.width.rounded())) × \(Int(frame.height.rounded()))"
    }
}
