import AppKit
import CoreGraphics
import Foundation

/// Where a window dragged to a display edge goes: a half, a quarter, or the whole display.
public enum EdgeSnapRegion: String, Codable, CaseIterable, Sendable {
    case left, right, topLeft, topRight, bottomLeft, bottomRight, fill

    /// The target inside a display's work area (top-left coordinates, whole points).
    public func rect(in area: CGRect) -> CGRect {
        let w = (area.width / 2).rounded(), h = (area.height / 2).rounded()
        let left = CGRect(x: area.minX, y: area.minY, width: w, height: area.height)
        let right = CGRect(x: area.minX + w, y: area.minY, width: area.width - w, height: area.height)
        switch self {
        case .left: return left
        case .right: return right
        case .topLeft: return CGRect(x: left.minX, y: area.minY, width: left.width, height: h)
        case .topRight: return CGRect(x: right.minX, y: area.minY, width: right.width, height: h)
        case .bottomLeft: return CGRect(x: left.minX, y: area.minY + h, width: left.width, height: area.height - h)
        case .bottomRight: return CGRect(x: right.minX, y: area.minY + h, width: right.width, height: area.height - h)
        case .fill: return area
        }
    }
}

/// Pure edge-snap geometry, in top-left (y down) coordinates like CGEvent locations.
///
/// The pointer at a display's left or right edge picks that half, near a corner (on either edge
/// that meets there) that quarter, at the top the whole display; the bottom edge only has corners.
/// Edges are checked where the pointer is: an edge another display touches at that spot is a
/// passage between displays and never snaps, so moving a window across displays is never caught.
public enum EdgeSnap {
    /// How close (points) the pointer must come to an edge. The pointer stops at a free edge,
    /// so a few points are plenty.
    public static let threshold: CGFloat = 3

    /// Length of the corner hot spots along an edge of `length` points.
    public static func cornerLength(for length: CGFloat) -> CGFloat {
        min(160, max(48, length * 0.12))
    }

    public enum Edge: Sendable { case left, right, top, bottom }

    /// Whether another display touches `frame`'s `edge` at the pointer position `p`.
    public static func isShared(_ edge: Edge, of frame: CGRect, at p: CGPoint, others: [CGRect]) -> Bool {
        let probe: CGPoint
        switch edge {
        case .left: probe = CGPoint(x: frame.minX - 1, y: p.y)
        case .right: probe = CGPoint(x: frame.maxX + 0.5, y: p.y)
        case .top: probe = CGPoint(x: p.x, y: frame.minY - 1)
        case .bottom: probe = CGPoint(x: p.x, y: frame.maxY + 0.5)
        }
        return others.contains { $0 != frame && $0.contains(probe) }
    }

    /// The region for a pointer at `p` on the display `frame`, or nil when it is not at a free edge.
    public static func region(at p: CGPoint, display frame: CGRect, others: [CGRect],
                              threshold: CGFloat = threshold) -> EdgeSnapRegion? {
        guard frame.width > 0, frame.height > 0,
              p.x >= frame.minX - threshold, p.x <= frame.maxX + threshold,
              p.y >= frame.minY - threshold, p.y <= frame.maxY + threshold else { return nil }
        let atLeft = p.x - frame.minX <= threshold && !isShared(.left, of: frame, at: p, others: others)
        let atRight = frame.maxX - p.x <= threshold + 1 && !isShared(.right, of: frame, at: p, others: others)
        let atTop = p.y - frame.minY <= threshold && !isShared(.top, of: frame, at: p, others: others)
        let atBottom = frame.maxY - p.y <= threshold + 1 && !isShared(.bottom, of: frame, at: p, others: others)
        let cornerX = cornerLength(for: frame.width), cornerY = cornerLength(for: frame.height)
        let nearTop = p.y - frame.minY <= cornerY, nearBottom = frame.maxY - p.y <= cornerY
        let nearLeft = p.x - frame.minX <= cornerX, nearRight = frame.maxX - p.x <= cornerX
        if atLeft { return nearTop ? .topLeft : nearBottom ? .bottomLeft : .left }
        if atRight { return nearTop ? .topRight : nearBottom ? .bottomRight : .right }
        if atTop { return nearLeft ? .topLeft : nearRight ? .topRight : .fill }
        if atBottom { return nearLeft ? .bottomLeft : nearRight ? .bottomRight : nil }
        return nil
    }
}

/// macOS's own window tiling settings (System Settings › Desktop & Dock › Windows), which act on
/// the same drags as edge snap and an ⌥ activation key.
enum SystemTiling {
    private static let domain = "com.apple.WindowManager" as CFString

    /// "Drag windows to screen edges to tile" or "Drag windows to menu bar to fill screen" is on.
    static var tilesAtScreenEdges: Bool {
        CFPreferencesAppSynchronize(domain)
        return flag("EnableTilingByEdgeDrag") || flag("EnableTopTilingByEdgeDrag")
    }

    /// "Hold ⌥ key while dragging windows to tile" is on.
    static var tilesWithOptionKey: Bool {
        CFPreferencesAppSynchronize(domain)
        return flag("EnableTilingOptionAccelerator")
    }

    /// Opens Desktop & Dock settings, where those options live.
    @MainActor
    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    /// These options are on unless the user turned them off (no value is stored until then).
    private static func flag(_ key: String) -> Bool {
        (CFPreferencesCopyAppValue(key as CFString, domain) as? Bool) ?? true
    }
}
