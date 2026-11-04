import CoreGraphics
import Foundation

/// The parts of the settings that decide what a gesture does.
public struct GestureOptions: Equatable, Sendable {
    public var halves = true
    public var cycleSizes = true
    public var corners = true
    public var up = WindowGesturesSettings.UpAction.fill
    public var down = WindowGesturesSettings.DownAction.restoreThenMinimize
    public var pinchIn = WindowGesturesSettings.PinchInAction.closeWindow
    public var pinchOut = WindowGesturesSettings.PinchOutAction.fill
    public var doubleTap = WindowGesturesSettings.DoubleTapAction.toggleFill
    public var gap: CGFloat = 0

    public init(halves: Bool = true, cycleSizes: Bool = true, corners: Bool = true,
                up: WindowGesturesSettings.UpAction = .fill,
                down: WindowGesturesSettings.DownAction = .restoreThenMinimize,
                pinchIn: WindowGesturesSettings.PinchInAction = .closeWindow,
                pinchOut: WindowGesturesSettings.PinchOutAction = .fill,
                doubleTap: WindowGesturesSettings.DoubleTapAction = .toggleFill, gap: CGFloat = 0) {
        self.halves = halves
        self.cycleSizes = cycleSizes
        self.corners = corners
        self.up = up
        self.down = down
        self.pinchIn = pinchIn
        self.pinchOut = pinchOut
        self.doubleTap = doubleTap
        self.gap = gap
    }
}

/// What the resolver knows about the window under the gesture.
public struct WindowContext: Equatable, Sendable {
    /// Current frame, top-left coordinates.
    public var frame: CGRect
    /// The tile a gesture put the window in, if it hasn't been moved or resized since.
    public var tile: Tile?
    /// The frame it had before a gesture first tiled it.
    public var original: CGRect?
    /// Index of its display in `displays`.
    public var display: Int
    public var displays: [DisplaySlot]
    public var isFullScreen: Bool

    public init(frame: CGRect, tile: Tile? = nil, original: CGRect? = nil, display: Int = 0,
                displays: [DisplaySlot], isFullScreen: Bool = false) {
        self.frame = frame
        self.tile = tile
        self.original = original
        self.display = display
        self.displays = displays
        self.isFullScreen = isFullScreen
    }

    var work: CGRect { displays.indices.contains(display) ? displays[display].work : frame }
}

/// Something done to a window.
public enum WindowAction: Equatable, Sendable {
    /// Move into a tile of its display (`frame` is where that is).
    case tile(Tile, frame: CGRect)
    /// Back to the frame it had before it was tiled.
    case restore(frame: CGRect)
    /// To another display (index into the context's displays), keeping its tile if it has one.
    case moveToDisplay(Int, frame: CGRect, tile: Tile?)
    case minimize
    case close
    case quit
    case enterFullScreen
    case exitFullScreen

    /// Where the window will be, for the preview, when the action moves or resizes it.
    public var targetFrame: CGRect? {
        switch self {
        case .tile(_, let f), .restore(let f), .moveToDisplay(_, let f, _): f
        case .minimize, .close, .quit, .enterFullScreen, .exitFullScreen: nil
        }
    }

    /// Close and quit can lose work: they may ask for a confirmation hold.
    public var isDestructive: Bool { self == .close || self == .quit }
}

/// Gesture → action. Swipes:
/// - ← / →: the left or right half. Again toward the same edge: a third, then two thirds, then a
///   half again. The other way: one column over, same size (a third slides to the center third).
/// - An L-shaped or diagonal swipe: that corner's quarter; again: a sixth, then two thirds wide.
/// - ↑: fill (or full screen). ↓: restore a tiled window, else minimize.
/// - With the display modifier: to the next display that way, keeping the tile.
public enum GestureResolver {
    public static func swipe(_ stroke: Stroke, toDisplay: Bool = false, window w: WindowContext,
                             options o: GestureOptions) -> WindowAction? {
        if toDisplay { return moveToDisplay(stroke.primary, window: w, options: o) }
        if w.isFullScreen {
            return stroke == Stroke(.down) ? .exitFullScreen : nil
        }
        if let h = stroke.horizontal.flatMap(HorizontalSide.init), let v = stroke.vertical, o.corners {
            return tile(horizontal(h, from: w.tile, row: v == .up ? 0 : 1, options: o), w, o)
        }
        switch stroke.primary {
        case .left, .right:
            guard o.halves, let side = HorizontalSide(stroke.primary) else { return nil }
            return tile(horizontal(side, from: w.tile, row: nil, options: o), w, o)
        case .up:
            switch o.up {
            case .fill: return tile(.fill, w, o)
            case .fullScreen: return .enterFullScreen
            case .nothing: return nil
            }
        case .down:
            switch o.down {
            case .restoreThenMinimize: return restore(w) ?? .minimize
            case .minimize: return .minimize
            case .nothing: return nil
            }
        }
    }

    public static func pinch(_ intent: PinchIntent, window w: WindowContext, options o: GestureOptions) -> WindowAction? {
        switch intent {
        case .pinchIn:
            switch o.pinchIn {
            case .closeWindow: return .close
            case .quitApp: return .quit
            case .minimize: return w.isFullScreen ? nil : .minimize
            case .nothing: return nil
            }
        case .pinchOut:
            guard !w.isFullScreen else { return nil }
            switch o.pinchOut {
            case .fill: return tile(.fill, w, o)
            case .fullScreen: return .enterFullScreen
            case .nothing: return nil
            }
        }
    }

    public static func doubleTap(window w: WindowContext, options o: GestureOptions) -> WindowAction? {
        switch o.doubleTap {
        case .toggleFill:
            if w.isFullScreen { return .exitFullScreen }
            if w.tile?.isFill == true, let back = restore(w) { return back }
            return tile(.fill, w, o)
        case .toggleFullScreen:
            return w.isFullScreen ? .exitFullScreen : .enterFullScreen
        case .nothing:
            return nil
        }
    }

    /// The tile a horizontal swipe toward `side` leads to. `row` restricts it to the top (0) or
    /// bottom (1) row for corner swipes.
    static func horizontal(_ side: HorizontalSide, from current: Tile?, row: Int?, options o: GestureOptions) -> Tile {
        let base = row.map { Tile.quarter(side, top: $0 == 0) } ?? .half(side)
        guard let t = current, !t.isFullWidth else { return base }
        if let row, !(t.rows == 2 && t.rowSpan == 1 && t.row == row) { return base }
        if t.touches(side) { return o.cycleSizes ? t.cycled(toward: side) : t }
        return t.slid(toward: side) ?? t
    }

    static func tile(_ t: Tile, _ w: WindowContext, _ o: GestureOptions) -> WindowAction {
        .tile(t, frame: t.frame(in: w.work, gap: o.gap))
    }

    static func restore(_ w: WindowContext) -> WindowAction? {
        guard w.tile != nil, let original = w.original else { return nil }
        return .restore(frame: DisplayMap.restored(original, displays: w.displays.map(\.frame), work: w.work))
    }

    static func moveToDisplay(_ d: SwipeDirection, window w: WindowContext, options o: GestureOptions) -> WindowAction? {
        guard !w.isFullScreen, w.displays.indices.contains(w.display),
              let target = DisplayMap.neighbor(of: w.display, toward: d, in: w.displays.map(\.frame)) else { return nil }
        let to = w.displays[target].work
        if let t = w.tile { return .moveToDisplay(target, frame: t.frame(in: to, gap: o.gap), tile: t) }
        return .moveToDisplay(target, frame: DisplayMap.remap(w.frame, from: w.work, to: to), tile: nil)
    }
}
