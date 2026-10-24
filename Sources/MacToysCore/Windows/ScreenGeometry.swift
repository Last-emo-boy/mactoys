import AppKit

/// Conversions between Cocoa coordinates (origin bottom-left of the primary display, y up)
/// and global top-left coordinates used by Accessibility, CGEvent and CGWindowList.
public enum ScreenGeometry {
    /// Height of the primary display — the pivot for flipping.
    public static var primaryHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 0
    }

    public static func toAX(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    public static func toCocoa(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    public static func toAX(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: primaryHeight - p.y) }
    public static func toCocoa(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: primaryHeight - p.y) }

    /// Union of all display frames in top-left coordinates.
    public static var desktopAXFrame: CGRect {
        NSScreen.screens.map(\.axFrame).reduce(CGRect.null) { $0.union($1) }
    }

    /// The screen containing a top-left point (nearest screen when outside all of them).
    public static func screen(containingAX point: CGPoint) -> NSScreen? {
        if let s = NSScreen.screens.first(where: { $0.axFrame.contains(point) }) { return s }
        return NSScreen.screens.min { a, b in
            a.axFrame.distance(to: point) < b.axFrame.distance(to: point)
        }
    }

    /// The screen showing most of a top-left rect.
    public static func screen(forAX rect: CGRect) -> NSScreen? {
        NSScreen.screens.max { a, b in
            a.axFrame.intersection(rect).area < b.axFrame.intersection(rect).area
        } ?? NSScreen.main
    }
}

extension NSScreen {
    /// Full frame in global top-left coordinates.
    public var axFrame: CGRect { ScreenGeometry.toAX(frame) }
    /// Frame minus menu bar and Dock, in global top-left coordinates.
    public var axVisibleFrame: CGRect { ScreenGeometry.toAX(visibleFrame) }

    public var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }

    /// Stable across reconnects: vendor/model/serial when available.
    public var stableID: String {
        let id = displayID
        return "\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(CGDisplaySerialNumber(id))"
    }

    public var isBuiltIn: Bool { CGDisplayIsBuiltin(displayID) != 0 }

    /// The screen under the mouse pointer.
    public static var underMouse: NSScreen? {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main
    }
}

extension CGRect {
    public var area: CGFloat { isNull || isEmpty ? 0 : width * height }
    public var center: CGPoint { CGPoint(x: midX, y: midY) }

    public func distance(to p: CGPoint) -> CGFloat {
        let dx = max(minX - p.x, 0, p.x - maxX)
        let dy = max(minY - p.y, 0, p.y - maxY)
        return (dx * dx + dy * dy).squareRoot()
    }
}
