import CoreGraphics
import Foundation

/// A normal-level window as the window server lists it: number, owner and frame. Never titles.
public struct DimWindow: Equatable, Sendable {
    public var id: CGWindowID
    public var pid: pid_t
    /// Global top-left coordinates.
    public var frame: CGRect

    public init(id: CGWindowID, pid: pid_t, frame: CGRect) {
        self.id = id
        self.pid = pid
        self.frame = frame
    }
}

/// A display, in global top-left coordinates.
public struct DimDisplay: Equatable, Sendable {
    public var id: CGDirectDisplayID
    public var frame: CGRect

    public init(id: CGDirectDisplayID, frame: CGRect) {
        self.id = id
        self.frame = frame
    }
}

/// The active app, as far as dimming cares.
public struct DimFrontApp: Equatable, Sendable {
    /// What Accessibility says about the app's focused window.
    public enum Focus: Equatable, Sendable {
        /// No Accessibility access: the window list is all we know.
        case unknown
        /// The app has no focused window (for Finder: the desktop is focused).
        case none
        case window(CGWindowID)
    }

    public var pid: pid_t
    public var focus: Focus
    /// A regular app with a Dock icon; agents and menu bar apps are not.
    public var isRegular: Bool
    public var isFinder: Bool
    public var isExcluded: Bool

    public init(pid: pid_t, focus: Focus = .unknown, isRegular: Bool = true, isFinder: Bool = false, isExcluded: Bool = false) {
        self.pid = pid
        self.focus = focus
        self.isRegular = isRegular
        self.isFinder = isFinder
        self.isExcluded = isExcluded
    }
}

/// Where the dimming overlays go and what they leave bright.
public struct DimPlan: Equatable, Sendable {
    public enum Placement: Equatable, Sendable {
        /// Directly below this window: it and everything above it stay bright.
        case below(CGWindowID)
        /// Above every normal window: the active app has no window, so everything is dimmed.
        case front
    }

    public var placement: Placement
    /// Windows kept bright (all or the visible part of them): the active window, the app's other
    /// windows in app mode, and other displays' front windows.
    public var bright: [CGWindowID]
    /// Displays that get an overlay → the parts of it left clear (disjoint, global top-left coordinates).
    /// Displays not in the map show no overlay.
    public var holes: [CGDirectDisplayID: [DimHole]]

    public init(placement: Placement, bright: [CGWindowID], holes: [CGDirectDisplayID: [DimHole]]) {
        self.placement = placement
        self.bright = bright
        self.holes = holes
    }
}

/// A clear piece of an overlay: part of a bright window's visible region.
public struct DimHole: Equatable, Sendable {
    /// Corners of a rectangle, top-left coordinates.
    public struct Corners: OptionSet, Equatable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let topLeft = Corners(rawValue: 1 << 0)
        public static let topRight = Corners(rawValue: 1 << 1)
        public static let bottomLeft = Corners(rawValue: 1 << 2)
        public static let bottomRight = Corners(rawValue: 1 << 3)
        public static let all: Corners = [.topLeft, .topRight, .bottomLeft, .bottomRight]
    }

    public var rect: CGRect
    /// The corners of `rect` that are corners of the window, drawn rounded like the window's.
    public var corners: Corners

    public init(rect: CGRect, corners: Corners = []) {
        self.rect = rect
        self.corners = corners
    }

    /// A piece of `window`'s region; its corners that coincide with the window's are rounded.
    public init(rect: CGRect, window: CGRect) {
        func same(_ a: CGPoint, _ b: CGPoint) -> Bool { abs(a.x - b.x) < 0.5 && abs(a.y - b.y) < 0.5 }
        var c: Corners = []
        if same(CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: window.minX, y: window.minY)) { c.insert(.topLeft) }
        if same(CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: window.maxX, y: window.minY)) { c.insert(.topRight) }
        if same(CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: window.minX, y: window.maxY)) { c.insert(.bottomLeft) }
        if same(CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: window.maxX, y: window.maxY)) { c.insert(.bottomRight) }
        self.init(rect: rect, corners: c)
    }

    public func offsetBy(dx: CGFloat, dy: CGFloat) -> DimHole {
        DimHole(rect: rect.offsetBy(dx: dx, dy: dy), corners: corners)
    }

    /// Approximate corner radius of a macOS 26 window.
    public static let windowRadius: CGFloat = 16

    /// Adds the piece to `path`, its window corners rounded (in a top-left space).
    public func add(to path: CGMutablePath, radius: CGFloat = DimHole.windowRadius) {
        let r = min(radius, rect.width / 2, rect.height / 2)
        guard !corners.isEmpty, r > 0.5 else { path.addRect(rect); return }
        func inset(_ corner: Corners) -> CGFloat { corners.contains(corner) ? r : 0 }
        let (x0, y0, x1, y1) = (rect.minX, rect.minY, rect.maxX, rect.maxY)
        path.move(to: CGPoint(x: x0 + inset(.topLeft), y: y0))
        path.addLine(to: CGPoint(x: x1 - inset(.topRight), y: y0))
        if corners.contains(.topRight) { path.addArc(tangent1End: CGPoint(x: x1, y: y0), tangent2End: CGPoint(x: x1, y: y0 + r), radius: r) }
        path.addLine(to: CGPoint(x: x1, y: y1 - inset(.bottomRight)))
        if corners.contains(.bottomRight) { path.addArc(tangent1End: CGPoint(x: x1, y: y1), tangent2End: CGPoint(x: x1 - r, y: y1), radius: r) }
        path.addLine(to: CGPoint(x: x0 + inset(.bottomLeft), y: y1))
        if corners.contains(.bottomLeft) { path.addArc(tangent1End: CGPoint(x: x0, y: y1), tangent2End: CGPoint(x: x0, y: y1 - r), radius: r) }
        path.addLine(to: CGPoint(x: x0, y: y0 + inset(.topLeft)))
        if corners.contains(.topLeft) { path.addArc(tangent1End: CGPoint(x: x0, y: y0), tangent2End: CGPoint(x: x0 + r, y: y0), radius: r) }
        path.closeSubpath()
    }
}

public enum DimDecision: Equatable, Sendable {
    /// Leave the overlays as they are (a menu bar app or panel is active only briefly).
    case keep
    /// Show nothing.
    case reveal
    case dim(DimPlan)
}

/// Decides what to dim from a front-to-back list of normal windows.
///
/// The overlay is a normal-level window ordered directly below the active window, so the active
/// window, its sheets and popovers, menus, the Dock and all system UI stay above it untouched and
/// nothing has to follow the window when it moves. Windows that must stay bright but lie below the
/// overlay (the active app's other windows, another display's front window) get holes cut out:
/// their frames minus the dimmed windows above them.
public enum DimPlanner {
    /// - Parameters:
    ///   - windows: on-screen normal-level windows, front to back, without the overlays themselves.
    ///   - front: the active app, or nil when there is none.
    ///   - activeDisplay: the display to treat as active when no window is (the pointer's display).
    public static func decide(windows: [DimWindow], front: DimFrontApp?, displays: [DimDisplay], options: DimOptions,
                              activeDisplay: CGDirectDisplayID? = nil) -> DimDecision {
        guard let front, !displays.isEmpty else { return .keep }
        if front.isExcluded { return .reveal }

        let focused = frontWindowIndex(windows: windows, front: front)
        switch focused {
        case .reveal: return .reveal
        case .keep: return .keep
        case .noWindow:
            // A regular app with every window closed or minimized: nothing is active, dim everything.
            let active = activeDisplay ?? displays[0].id
            let shown = displays.filter { $0.id == active || options.otherDisplays != .leave }
            var holes: [CGDirectDisplayID: [DimHole]] = [:]
            var lit: [CGWindowID] = []
            for d in shown {
                let extra = options.otherDisplays == .highlightFront && d.id != active
                    ? topWindow(on: d, in: windows, displays: displays).map { [$0.id] } ?? [] : []
                lit += extra
                holes[d.id] = Self.holes(bright: Set(extra), stack: windows, clip: d.frame)
            }
            if options.onlyWithOtherWindows, !hasDimmedVisible(windows: windows, belowIndex: -1, bright: [],
                                                              holes: holes, displays: shown) {
                return .reveal
            }
            return .dim(DimPlan(placement: .front, bright: lit, holes: holes))
        case .window(let index):
            let main = windows[index]
            let bright: [DimWindow] = options.highlight == .frontApp ? windows.filter { $0.pid == front.pid } : [main]
            let brightIDs = Set(bright.map(\.id))
            let active = display(for: main.frame, in: displays)?.id ?? activeDisplay ?? displays[0].id
            let shown = displays.filter { $0.id == active || options.otherDisplays != .leave }
            let below = Array(windows[(index + 1)...])
            var holes: [CGDirectDisplayID: [DimHole]] = [:]
            var lit = bright.map(\.id)
            for d in shown {
                var litHere = brightIDs
                if options.otherDisplays == .highlightFront, d.id != active,
                   let top = topWindow(on: d, in: below, displays: displays), !brightIDs.contains(top.id) {
                    litHere.insert(top.id)
                    lit.append(top.id)
                }
                holes[d.id] = Self.holes(bright: litHere, stack: below, clip: d.frame)
            }
            if options.onlyWithOtherWindows, !hasDimmedVisible(windows: windows, belowIndex: index, bright: brightIDs,
                                                              holes: holes, displays: shown) {
                return .reveal
            }
            return .dim(DimPlan(placement: .below(main.id), bright: lit, holes: holes))
        }
    }

    enum FrontWindow: Equatable {
        case window(Int)
        case noWindow
        case reveal
        case keep
    }

    /// Index of the active window in `windows`.
    static func frontWindowIndex(windows: [DimWindow], front: DimFrontApp) -> FrontWindow {
        var index: Int?
        if case .window(let id) = front.focus { index = windows.firstIndex { $0.id == id } }
        if index == nil {
            if front.focus == .none, front.isFinder { return .reveal }   // the desktop has focus
            if let top = windows.firstIndex(where: { $0.pid == front.pid }) {
                index = front.focus == .unknown ? attachedParent(of: top, in: windows) : top
            }
        }
        guard let index else {
            if front.isFinder { return .reveal }                         // no Finder window: the desktop
            return front.isRegular ? .noWindow : .keep
        }
        // Finder active while its windows stay behind other apps' windows: the desktop was clicked.
        if front.isFinder, windows[..<index].contains(where: { $0.pid != front.pid }) { return .reveal }
        return .window(index)
    }

    /// Without Accessibility the app's topmost window may be a sheet, popover or panel hanging off
    /// the real window. Such a child lies entirely inside its parent, which sits directly below it.
    static func attachedParent(of index: Int, in windows: [DimWindow]) -> Int {
        var i = index
        while i + 1 < windows.count {
            let child = windows[i], next = windows[i + 1]
            guard next.pid == child.pid, next.frame.insetBy(dx: -1, dy: -1).contains(child.frame) else { break }
            i += 1
        }
        return i
    }

    /// The display showing most of `frame`.
    static func display(for frame: CGRect, in displays: [DimDisplay]) -> DimDisplay? {
        let best = displays.max { area($0.frame.intersection(frame)) < area($1.frame.intersection(frame)) }
        guard let best, area(best.frame.intersection(frame)) > 0 else { return nil }
        return best
    }

    /// The topmost window that lies mostly on `display`.
    static func topWindow(on display: DimDisplay, in stack: [DimWindow], displays: [DimDisplay]) -> DimWindow? {
        stack.first { self.display(for: $0.frame, in: displays)?.id == display.id }
    }

    /// Whether any window that ends up dimmed is visible at all (not covered by windows above it,
    /// not inside a hole) on a display that gets an overlay.
    static func hasDimmedVisible(windows: [DimWindow], belowIndex: Int, bright: Set<CGWindowID>,
                                 holes: [CGDirectDisplayID: [DimHole]], displays: [DimDisplay]) -> Bool {
        guard belowIndex + 1 < windows.count else { return false }
        for i in (belowIndex + 1)..<windows.count where !bright.contains(windows[i].id) {
            for d in displays {
                var visible = [windows[i].frame.intersection(d.frame)].filter { area($0) > 1 }
                for above in windows[..<i] {
                    visible = subtract(visible, above.frame)
                    if visible.isEmpty { break }
                }
                for hole in holes[d.id] ?? [] {
                    visible = subtract(visible, hole.rect)
                    if visible.isEmpty { break }
                }
                if visible.contains(where: { area($0) > 64 }) { return true }
            }
        }
        return false
    }

    // MARK: Region math

    /// The parts of the bright windows that are not covered by a dimmed window lying above them,
    /// clipped to `clip`, as disjoint rectangles. `stack` is front to back and starts right below the overlay.
    public static func holes(bright: Set<CGWindowID>, stack: [DimWindow], clip: CGRect) -> [DimHole] {
        var holes: [DimHole] = []
        var covers: [CGRect] = []
        for w in stack {
            guard bright.contains(w.id) else {
                covers.append(w.frame)
                continue
            }
            var region = [w.frame.intersection(clip)].filter { area($0) > 0 }
            for cover in covers where !region.isEmpty {
                region = subtract(region, cover)
            }
            holes += region.map { DimHole(rect: $0, window: w.frame) }
            covers.append(w.frame)
        }
        return holes
    }

    /// `rects` minus `cut`; the pieces stay disjoint when `rects` are.
    public static func subtract(_ rects: [CGRect], _ cut: CGRect) -> [CGRect] {
        rects.flatMap { subtract($0, cut) }
    }

    /// `r` minus `cut` as up to four disjoint pieces: full-width bands above and below the overlap,
    /// then the slices left and right of it.
    public static func subtract(_ r: CGRect, _ cut: CGRect) -> [CGRect] {
        let i = r.intersection(cut)
        guard area(i) > 0 else { return [r] }
        var out: [CGRect] = []
        if i.minY > r.minY { out.append(CGRect(x: r.minX, y: r.minY, width: r.width, height: i.minY - r.minY)) }
        if i.maxY < r.maxY { out.append(CGRect(x: r.minX, y: i.maxY, width: r.width, height: r.maxY - i.maxY)) }
        if i.minX > r.minX { out.append(CGRect(x: r.minX, y: i.minY, width: i.minX - r.minX, height: i.height)) }
        if i.maxX < r.maxX { out.append(CGRect(x: i.maxX, y: i.minY, width: r.maxX - i.maxX, height: i.height)) }
        return out.filter { $0.width >= 0.5 && $0.height >= 0.5 }
    }

    static func area(_ r: CGRect) -> CGFloat { r.isNull || r.isEmpty ? 0 : r.width * r.height }
}

/// Maps the intensity slider to overlay opacity.
public enum DimIntensity {
    /// Opacity at 100 %: a nearly black backdrop that still lets the windows behind be made out.
    public static let maxAlpha = 0.9

    /// Overlay opacity for an intensity of 0…1. Steps are even in perceived lightness (CIE L*), so each
    /// notch darkens a white window by the same visible amount instead of crowding the change at the top.
    public static func alpha(_ intensity: Double) -> Double {
        let t = min(max(intensity, 0), 1)
        let darkest = lightness(1 - maxAlpha)
        return 1 - luminance(100 - t * (100 - darkest))
    }

    /// CIE L* (0…100) of a relative luminance (0…1).
    public static func lightness(_ y: Double) -> Double {
        y > 216.0 / 24389 ? 116 * cbrt(y) - 16 : y * 24389 / 27
    }

    /// Relative luminance of a CIE L* value.
    public static func luminance(_ l: Double) -> Double {
        l > 8 ? pow((l + 16) / 116, 3) : l * 27 / 24389
    }
}
