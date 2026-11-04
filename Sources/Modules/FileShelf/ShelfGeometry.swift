import CoreGraphics

/// Sizes of a shelf panel and where new shelves go. Cocoa coordinates (y up).
enum ShelfGeometry {
    static let collapsedSize = CGSize(width: 156, height: 176)
    static let expandedWidth: CGFloat = 372
    static let headerHeight: CGFloat = 52
    static let gridColumns = 3
    static let gridSpacing: CGFloat = 8
    static let contentPadding: CGFloat = 12
    static let tileHeight: CGFloat = 132
    static let rowHeight: CGFloat = 46
    static let maxExpandedHeight: CGFloat = 500
    static let minExpandedHeight: CGFloat = 236
    /// Gap kept between a shelf and the screen edge, and between stacked shelves.
    static let margin: CGFloat = 16

    static func size(expanded: Bool, itemCount: Int, layout: ShelfLayout) -> CGSize {
        guard expanded else { return collapsedSize }
        let content: CGFloat
        switch layout {
        case .grid:
            let rows = max(1, (itemCount + gridColumns - 1) / gridColumns)
            content = CGFloat(rows) * tileHeight + CGFloat(rows - 1) * gridSpacing + contentPadding * 2
        case .list:
            content = CGFloat(max(1, itemCount)) * rowHeight + contentPadding
        }
        let height = min(maxExpandedHeight, max(minExpandedHeight, headerHeight + content))
        return CGSize(width: expandedWidth, height: height.rounded())
    }

    /// The frame for a new shelf of `size`: centered on the pointer, or stacked along a screen edge
    /// below the shelves already there. Never on top of another shelf's origin, always on screen.
    static func newFrame(size: CGSize, placement: ShelfPlacement, pointer: CGPoint, visible: CGRect,
                         occupied: [CGRect]) -> CGRect {
        switch placement {
        case .pointer:
            var frame = CGRect(x: pointer.x - size.width / 2, y: pointer.y - size.height * 0.55,
                               width: size.width, height: size.height)
            frame = clamp(frame, to: visible)
            // Cascade when a shelf already sits exactly here (e.g. ⌃⌥S pressed twice).
            var tries = 0
            while tries < 12, occupied.contains(where: { abs($0.minX - frame.minX) < 8 && abs($0.maxY - frame.maxY) < 8 }) {
                frame = clamp(frame.offsetBy(dx: 24, dy: -24), to: visible)
                tries += 1
            }
            return frame
        case .rightEdge, .leftEdge:
            let x = placement == .rightEdge ? visible.maxX - size.width - margin : visible.minX + margin
            var top = visible.maxY - margin
            while top - size.height >= visible.minY + margin {
                let candidate = CGRect(x: x, y: top - size.height, width: size.width, height: size.height)
                guard let blocker = occupied.first(where: { $0.insetBy(dx: -margin / 2, dy: -margin / 2).intersects(candidate) }) else {
                    return candidate
                }
                top = blocker.minY - margin
            }
            // The edge is full: overlap the first slot, nudged so both stay visible.
            return clamp(CGRect(x: x + (placement == .rightEdge ? -24 : 24), y: visible.maxY - margin - size.height - 24,
                                width: size.width, height: size.height), to: visible)
        }
    }

    /// `frame` resized to `size`, keeping its top edge and horizontal center, kept on screen.
    static func resized(_ frame: CGRect, to size: CGSize, within visible: CGRect) -> CGRect {
        let resized = CGRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height, width: size.width, height: size.height)
        return clamp(resized, to: visible)
    }

    static func clamp(_ frame: CGRect, to visible: CGRect) -> CGRect {
        var f = frame
        f.origin.x = min(max(f.minX, visible.minX), visible.maxX - f.width)
        f.origin.y = min(max(f.minY, visible.minY), visible.maxY - f.height)
        return f
    }
}
