import CoreGraphics
import MacToysCore

/// AppKit also brings in QuickDraw's `WindowRef`; inside this module the name means MacToys' AX window.
typealias WindowRef = MacToysCore.WindowRef

/// Persisted options of Crop And Lock (`cropandlock.json`).
public struct CropAndLockSettings: Codable, Equatable, Sendable {
    public var thumbnail: Shortcut? = Shortcut(0x11, [.control, .option, .shift])   // kVK_ANSI_T
    public var interactive: Shortcut? = Shortcut(0x0F, [.control, .option, .shift]) // kVK_ANSI_R
    public var screenshot: Shortcut? = Shortcut(0x01, [.control, .option, .shift])  // kVK_ANSI_S
    /// Interactive crops pass the click that brought the window forward on to the app.
    public var forwardClicks = true
    /// Closing an interactive crop moves the original window back where it was.
    public var restorePosition = true
    /// Crop windows follow you to every Space, like Picture in Picture.
    public var showOnAllSpaces = true
    public var frameRate = 30

    public init() {}
}

/// The three ways a selected area becomes a window.
enum CropMode: String, CaseIterable, Sendable {
    /// Live, read-only view of the area.
    case thumbnail
    /// Live view; clicking it brings the original window forward with the area under the pointer.
    case interactive
    /// Frozen capture with copy and save.
    case screenshot

    var title: String {
        switch self {
        case .thumbnail: "Thumbnail"
        case .interactive: "Interactive"
        case .screenshot: "Screenshot"
        }
    }

    var symbol: String {
        switch self {
        case .thumbnail: "pip"
        case .interactive: "cursorarrow.rays"
        case .screenshot: "camera.viewfinder"
        }
    }
}

/// Pure geometry for selecting and placing crops. Rectangles are top-left based (AX space for
/// global values, window-local points for crops).
enum CropGeometry {
    /// Smallest crop accepted, in points.
    static let minimumSide: CGFloat = 12

    /// The normalized rectangle between two drag points, clamped to `bounds`.
    static func selection(from a: CGPoint, to b: CGPoint, in bounds: CGRect) -> CGRect {
        func clamp(_ p: CGPoint) -> CGPoint {
            CGPoint(x: min(max(p.x, bounds.minX), bounds.maxX), y: min(max(p.y, bounds.minY), bounds.maxY))
        }
        let p = clamp(a), q = clamp(b)
        return CGRect(x: min(p.x, q.x), y: min(p.y, q.y), width: abs(p.x - q.x), height: abs(p.y - q.y)).integral
    }

    static func isUsable(_ r: CGRect) -> Bool { r.width >= minimumSide && r.height >= minimumSide }

    /// Smallest size a thumbnail may be resized to: about 40 pt on its short side, same aspect ratio.
    static func minimumContentSize(for size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return CGSize(width: 40, height: 40) }
        let factor = min(1, max(40 / size.width, 40 / size.height))
        return CGSize(width: (size.width * factor).rounded(), height: (size.height * factor).rounded())
    }

    /// The pixel rectangle of `crop` (window points) inside a capture of the whole window.
    static func pixelRect(crop: CGRect, windowSize: CGSize, imageSize: CGSize) -> CGRect {
        guard windowSize.width > 0, windowSize.height > 0 else { return .null }
        let sx = imageSize.width / windowSize.width
        let sy = imageSize.height / windowSize.height
        let r = CGRect(x: crop.minX * sx, y: crop.minY * sy, width: crop.width * sx, height: crop.height * sy)
            .integral
        return r.intersection(CGRect(origin: .zero, size: imageSize))
    }

    /// Where the source window's top-left must go so its cropped area sits at `contentOrigin`
    /// (top-left of the crop window's content, global coordinates).
    static func sourceOrigin(crop: CGRect, contentOrigin: CGPoint) -> CGPoint {
        CGPoint(x: contentOrigin.x - crop.minX, y: contentOrigin.y - crop.minY)
    }

    /// The global rectangle a crop occupies while its source window is at `windowFrame`.
    static func globalRect(crop: CGRect, windowFrame: CGRect) -> CGRect {
        crop.offsetBy(dx: windowFrame.minX, dy: windowFrame.minY)
    }

    /// Fits `rect` inside `visible` by moving it (and shrinking it, keeping its aspect ratio, if needed).
    static func keep(_ rect: CGRect, inside visible: CGRect) -> CGRect {
        guard visible.width > 0, visible.height > 0 else { return rect }
        var r = rect
        let factor = min(1, visible.width / max(r.width, 1), visible.height / max(r.height, 1))
        r.size = CGSize(width: (r.width * factor).rounded(), height: (r.height * factor).rounded())
        r.origin.x = min(max(r.minX, visible.minX), visible.maxX - r.width)
        r.origin.y = min(max(r.minY, visible.minY), visible.maxY - r.height)
        return r
    }
}
