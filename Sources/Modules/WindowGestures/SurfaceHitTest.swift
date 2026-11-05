import AppKit
import CoreGraphics
import MacToysCore

/// One on-screen window, as the window server lists it (no Accessibility involved).
public struct WindowEntry: Equatable, Sendable {
    public var id: CGWindowID
    public var pid: pid_t
    public var layer: Int
    /// Top-left coordinates.
    public var frame: CGRect
    public var alpha: Double

    public init(id: CGWindowID, pid: pid_t, layer: Int, frame: CGRect, alpha: Double = 1) {
        self.id = id
        self.pid = pid
        self.layer = layer
        self.frame = frame
        self.alpha = alpha
    }

    init?(_ d: [String: Any]) {
        guard let id = d[kCGWindowNumber as String] as? CGWindowID,
              let pid = d[kCGWindowOwnerPID as String] as? pid_t,
              let layer = d[kCGWindowLayer as String] as? Int,
              let bounds = d[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: bounds) else { return nil }
        self.init(id: id, pid: pid, layer: layer, frame: frame, alpha: d[kCGWindowAlpha as String] as? Double ?? 1)
    }

    /// On-screen windows, front to back, decoded lazily so a hit test stops at the first one that
    /// decides it. One window server call.
    static func onScreen() -> LazyMapSequence<LazyFilterSequence<LazyMapSequence<[[String: Any]], WindowEntry?>>, WindowEntry> {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return list.lazy.compactMap(WindowEntry.init)
    }
}

/// What lies under the pointer, for deciding whether a gesture is ours.
public enum GestureSurface: Equatable, Sendable {
    /// A window's title bar or toolbar. `fullScreen`: the window covers its whole display.
    case titleBar(WindowEntry, fullScreen: Bool)
    /// The Dock's icon strip.
    case dock(WindowEntry)
    /// The menu bar of a display.
    case menuBar
    /// Window content, another app's menu or palette, the desktop, a MacToys window: not ours.
    case none
}

/// Pure hit testing: which surface a point is on, given the window list.
public enum SurfaceHitTest {
    public static let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
    public static let menuBarLevel = Int(CGWindowLevelForKey(.mainMenuWindow))
    public static let statusLevel = Int(CGWindowLevelForKey(.statusWindow))

    public struct Context {
        public var ownPID: pid_t
        public var dockPID: pid_t?
        /// Every display's full frame (a window covering one exactly is full screen).
        public var displays: [CGRect]
        /// The menu bar strip of the display under the point (nil: menu bar gestures are off).
        public var menuBar: CGRect?
        /// Full-screen windows are left alone.
        public var skipFullScreen: Bool
        /// Deepest title bar band any window can have; deeper points never ask `band`.
        public var maxBand: CGFloat

        public init(ownPID: pid_t, dockPID: pid_t?, displays: [CGRect], menuBar: CGRect?,
                    skipFullScreen: Bool = true, maxBand: CGFloat = 120) {
            self.ownPID = ownPID
            self.dockPID = dockPID
            self.displays = displays
            self.menuBar = menuBar
            self.skipFullScreen = skipFullScreen
            self.maxBand = maxBand
        }
    }

    /// The surface at `p`.
    ///
    /// `hit` is the window a click at `p` would reach (`NSWindow.windowNumber(at:)`, 0 for none), and
    /// only it decides. The window list alone can't tell which windows take clicks: Notification
    /// Center and the Dock keep transparent full-screen windows in front of every app, and so do
    /// some apps' overlays. Nil: not known, the list is walked as below.
    ///
    /// Windows are checked front to back. The first normal window under the point decides: its
    /// title bar band (asked through `band`, only when the point is near its top) or nothing. The
    /// Dock is the Dock. The menu bar and its status items are looked through, and so are MacToys'
    /// own click-through overlays; any other app's floating window, menu or panel on top means
    /// nothing. With no window under it, a point in the menu bar strip is the menu bar.
    public static func surface<S: Sequence>(at p: CGPoint, hit: CGWindowID? = nil, entries: S, context c: Context,
                                            band: (WindowEntry) -> CGFloat) -> GestureSurface where S.Element == WindowEntry {
        guard let hit else { return walk(at: p, entries: entries, context: c, band: band) }
        let front = entries.first { $0.id == hit }
        return walk(at: p, entries: front.map { [$0] } ?? [], context: c, band: band)
    }

    private static func walk<S: Sequence>(at p: CGPoint, entries: S, context c: Context,
                                          band: (WindowEntry) -> CGFloat) -> GestureSurface where S.Element == WindowEntry {
        for e in entries where e.alpha > 0.01 && e.frame.contains(p) {
            if e.layer < 0 { continue }
            if e.layer == 0 {
                guard e.pid != c.ownPID else { return .none }
                let fullScreen = c.displays.contains { $0 == e.frame }
                if fullScreen && c.skipFullScreen { return .none }
                let depth = p.y - e.frame.minY
                guard depth <= c.maxBand, depth <= band(e) else { return .none }
                return .titleBar(e, fullScreen: fullScreen)
            }
            if e.layer == dockLevel, let dock = c.dockPID, e.pid == dock { return .dock(e) }
            if e.layer == menuBarLevel || e.layer == statusLevel || e.pid == c.ownPID { continue }
            return .none
        }
        if let strip = c.menuBar, strip.contains(p) { return .menuBar }
        return .none
    }

    /// The title bar band of a window: twice the distance from its top to the center of its close
    /// button, since the window buttons sit centered in the title bar or unified toolbar. Nil
    /// without a close button near the top (the caller falls back to the configured height).
    public static func band(window: CGRect, closeButton: CGRect?) -> CGFloat? {
        guard let b = closeButton, b.height > 0, b.midY > window.minY, b.midY < window.minY + 80 else { return nil }
        return min(max(2 * (b.midY - window.minY), 22), 110)
    }

    /// The menu bar strip of a display: the space above its work area (visible frame), or the
    /// camera housing's height, or the standard menu bar height when the menu bar hides itself.
    public static func menuBarStrip(frame: CGRect, work: CGRect, safeTop: CGFloat, standard: CGFloat = 24) -> CGRect {
        let inset = work.minY - frame.minY
        let height = inset > 0 && inset < 80 ? inset : safeTop > 0 ? safeTop : standard
        return CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: height)
    }
}
