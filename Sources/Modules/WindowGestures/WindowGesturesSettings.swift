import Foundation
import MacToysCore

/// Window Gestures settings. Every gesture has its own action; `nothing` turns it off.
public struct WindowGesturesSettings: Codable, Equatable, Sendable {
    /// Swipe up on a title bar.
    public enum UpAction: String, Codable, CaseIterable, Sendable {
        case fill, fullScreen, nothing

        public var title: String {
            switch self {
            case .fill: String(localized: "Fill the screen", comment: "Window Gestures action: make the window as large as the screen's free area")
            case .fullScreen: String(localized: "Enter full screen", comment: "Window Gestures action: macOS full screen")
            case .nothing: String(localized: "Do nothing", comment: "Window Gestures: the gesture is off")
            }
        }
    }

    /// Swipe down on a title bar.
    public enum DownAction: String, Codable, CaseIterable, Sendable {
        case restoreThenMinimize, minimize, nothing

        public var title: String {
            switch self {
            case .restoreThenMinimize: String(localized: "Restore, then minimize", comment: "Window Gestures action: first swipe restores a tiled window's size, the next one minimizes it")
            case .minimize: String(localized: "Minimize", comment: "Window Gestures action: minimize the window to the Dock")
            case .nothing: String(localized: "Do nothing", comment: "Window Gestures: the gesture is off")
            }
        }
    }

    /// Pinch in on a title bar.
    public enum PinchInAction: String, Codable, CaseIterable, Sendable {
        case closeWindow, quitApp, minimize, nothing

        public var title: String {
            switch self {
            case .closeWindow: String(localized: "Close the window", comment: "Window Gestures action")
            case .quitApp: String(localized: "Quit the app", comment: "Window Gestures action")
            case .minimize: String(localized: "Minimize", comment: "Window Gestures action: minimize the window to the Dock")
            case .nothing: String(localized: "Do nothing", comment: "Window Gestures: the gesture is off")
            }
        }
    }

    /// Pinch out on a title bar.
    public enum PinchOutAction: String, Codable, CaseIterable, Sendable {
        case fill, fullScreen, nothing

        public var title: String {
            switch self {
            case .fill: String(localized: "Fill the screen", comment: "Window Gestures action: make the window as large as the screen's free area")
            case .fullScreen: String(localized: "Enter full screen", comment: "Window Gestures action: macOS full screen")
            case .nothing: String(localized: "Do nothing", comment: "Window Gestures: the gesture is off")
            }
        }
    }

    /// Two-finger double-tap on a title bar.
    public enum DoubleTapAction: String, Codable, CaseIterable, Sendable {
        case toggleFill, toggleFullScreen, nothing

        public var title: String {
            switch self {
            case .toggleFill: String(localized: "Fill, or restore a filled window", comment: "Window Gestures action for a two-finger double-tap")
            case .toggleFullScreen: String(localized: "Enter or leave full screen", comment: "Window Gestures action for a two-finger double-tap")
            case .nothing: String(localized: "Do nothing", comment: "Window Gestures: the gesture is off")
            }
        }
    }

    /// The modifier held while swiping to send a window to another display.
    public enum DisplayModifier: String, Codable, CaseIterable, Sendable {
        case option, control, command, function, off

        public var modifiers: Modifiers {
            switch self {
            case .option: .option
            case .control: .control
            case .command: .command
            case .function: .function
            case .off: []
            }
        }

        public var glyph: String? { modifiers.symbols.first }

        public var title: String {
            switch self {
            case .option: String(localized: "⌥  Option", comment: "Modifier key; keep the key symbol")
            case .control: String(localized: "⌃  Control", comment: "Modifier key; keep the key symbol")
            case .command: String(localized: "⌘  Command", comment: "Modifier key; keep the key symbol")
            case .function: String(localized: "fn  Function", comment: "Modifier key; keep “fn”, the key's label")
            case .off: String(localized: "Off", comment: "Window Gestures: no modifier sends windows to another display")
            }
        }
    }

    /// Swipe up on an app's Dock icon.
    public enum DockUpAction: String, Codable, CaseIterable, Sendable {
        case showWindows, appExpose, nothing

        public var title: String {
            switch self {
            case .showWindows: String(localized: "Bring its windows forward", comment: "Window Gestures Dock action: unhide the app, restore minimized windows, bring them to the front")
            case .appExpose: String(localized: "Show its windows side by side", comment: "Window Gestures Dock action: the macOS App Exposé view for that app")
            case .nothing: String(localized: "Do nothing", comment: "Window Gestures: the gesture is off")
            }
        }
    }

    /// Swipe down on an app's Dock icon.
    public enum DockDownAction: String, Codable, CaseIterable, Sendable {
        case hide, minimize, nothing

        public var title: String {
            switch self {
            case .hide: String(localized: "Hide the app", comment: "Window Gestures Dock action")
            case .minimize: String(localized: "Minimize its windows", comment: "Window Gestures Dock action")
            case .nothing: String(localized: "Do nothing", comment: "Window Gestures: the gesture is off")
            }
        }
    }

    /// Gestures are recognized (the menu bar switch). The module stays enabled while paused.
    public var active = true

    // Title bar
    /// Swipe left or right for the left or right half.
    public var swipeToHalves = true
    /// Swiping again toward the same edge narrows to a third, then two thirds; the other way slides one column.
    public var cycleSizes = true
    /// An L-shaped or diagonal swipe tiles to a quarter.
    public var cornerSwipes = true
    public var swipeUp = UpAction.fill
    public var swipeDown = DownAction.restoreThenMinimize
    public var pinchIn = PinchInAction.closeWindow
    /// Pinching in to close or quit only acts after the pinch is held for `confirmHold`.
    public var confirmClose = true
    /// Seconds the pinch must be held before close or quit is armed.
    public var confirmHold: Double = 0.6
    public var pinchOut = PinchOutAction.fill
    public var doubleTap = DoubleTapAction.toggleFill
    public var displayModifier = DisplayModifier.option

    // Dock and menu bar
    public var dockGestures = true
    public var dockUp = DockUpAction.showWindows
    public var dockDown = DockDownAction.hide
    /// Swipe down on the menu bar fills the front window.
    public var menuBarFill = true

    // Recognition
    /// 0.5 (long swipes) … 2 (short flicks).
    public var sensitivity: Double = 1
    /// Height of the title bar band (points) for windows that don't say where their title bar ends.
    public var titleBarHeight: Double = 32
    /// Swap the directions, for those who think of swipes the other way round.
    public var reverseDirections = false
    public var disableInFullScreen = true

    // Feedback and tiling
    public var showPreview = true
    public var haptics = true
    /// Space (points) between tiled windows and around them.
    public var gap: Double = 0

    public var excludedApps: [String] = []
    public var cheatSheetShortcut: Shortcut?

    public init() {}

    /// What the recognizer and the action resolver need.
    var options: GestureOptions {
        GestureOptions(halves: swipeToHalves, cycleSizes: cycleSizes, corners: cornerSwipes, up: swipeUp,
                       down: swipeDown, pinchIn: pinchIn, pinchOut: pinchOut, doubleTap: doubleTap,
                       gap: CGFloat(max(0, gap)))
    }
}
