import CoreGraphics
import MacToysCore

/// Persisted options of Always On Top (`alwaysontop.json`).
public struct AlwaysOnTopSettings: Codable, Equatable, Sendable {
    /// Where the border color comes from.
    public enum ColorMode: String, Codable, CaseIterable, Sendable {
        case accent, custom
        public var title: String {
            self == .accent ? String(localized: "System accent color") : String(localized: "Custom color")
        }
    }

    /// What brings the real window forward when its mirror is showing.
    public enum RaiseTrigger: String, Codable, CaseIterable, Sendable {
        case hover, click
        public var title: String {
            self == .hover
                ? String(localized: "Pointing at it", comment: "Always On Top: bring a pinned window forward by pointing at its mirror")
                : String(localized: "Clicking it", comment: "Always On Top: bring a pinned window forward by clicking its mirror")
        }
    }

    public var activation: Shortcut? = Shortcut(0x11, [.control, .command]) // kVK_ANSI_T
    public var showBorder = true
    public var colorMode: ColorMode = .accent
    public var customColor = RGBA(hex: "#FF9F0A") ?? .accent
    /// Border opacity in percent.
    public var opacity: Double = 100
    /// Border thickness in points.
    public var thickness: Double = 4
    public var roundedCorners = true
    public var playSound = true
    public var raiseTrigger: RaiseTrigger = .hover
    /// Frames per second of the live mirror.
    public var frameRate = 30
    public var excludedApps: [String] = []

    public init() {}
}

/// How one pinned window is shown right now.
enum PinPresentation: Equatable {
    /// Minimized, hidden, full screen or on another Space: nothing is drawn.
    case hidden
    /// The real window is frontmost: only the border, click-through.
    case border
    /// Another window is in front: a live mirror floats at the window's place.
    case mirror

    /// - Parameters:
    ///   - visible: the window is on screen in the current Space (not minimized, not hidden).
    ///   - fullScreen: the window is in its own full-screen Space.
    ///   - frontmost: the window is the focused window of the frontmost app (or is being raised).
    ///   - hasFrame: the mirror has received at least one captured frame.
    static func resolve(visible: Bool, fullScreen: Bool, frontmost: Bool, hasFrame: Bool) -> PinPresentation {
        guard visible, !fullScreen else { return .hidden }
        if frontmost || !hasFrame { return .border }
        return .mirror
    }
}

/// Geometry of the pin panel: the border sits outside the window frame, the mirror exactly on it.
/// Rectangles are in global top-left (AX) coordinates unless noted.
enum PinGeometry {
    /// Approximate corner radius of a standard macOS 26 window.
    static let windowCornerRadius: CGFloat = 12

    /// The panel covering the window plus the border ring around it.
    static func panelFrame(window: CGRect, border: CGFloat) -> CGRect {
        window.insetBy(dx: -border, dy: -border)
    }

    /// Outer and inner corner radii of the border ring.
    static func radii(rounded: Bool, border: CGFloat) -> (outer: CGFloat, inner: CGFloat) {
        rounded ? (windowCornerRadius + border, windowCornerRadius) : (0, 0)
    }

    /// Parts of `panel` covered by `others` (e.g. the focused pinned window that must stay above
    /// this mirror), in panel-local coordinates with a bottom-left origin (AppKit view space).
    static func exclusions(panel: CGRect, others: [CGRect]) -> [CGRect] {
        others.compactMap { other in
            let hit = other.intersection(panel)
            guard !hit.isNull, hit.width > 0, hit.height > 0 else { return nil }
            return CGRect(x: hit.minX - panel.minX, y: panel.maxY - hit.maxY, width: hit.width, height: hit.height)
        }
    }

    /// Clamps the stored settings to sane values.
    static func clampedThickness(_ t: Double) -> CGFloat { CGFloat(min(max(t, 1), 24)) }
}
