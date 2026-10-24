import Carbon.HIToolbox
import Foundation
import MacToysCore

/// Settings for every mouse utility, stored in `mouseutils.json`.
public struct MouseUtilitiesSettings: Codable, Equatable, Sendable {
    public var findMyMouse = FindMyMouseSettings()
    public var highlighter = HighlighterSettings()
    public var jump = MouseJumpSettings()
    public var crosshairs = CrosshairsSettings()
    public var cursorWrap = CursorWrapSettings()
    public var autoHide = AutoHideSettings()
    public var buttonLock = ButtonLockSettings()
    public init() {}
}

public struct FindMyMouseSettings: Codable, Equatable, Sendable {
    public enum Activation: String, Codable, CaseIterable, Sendable {
        case leftControlTwice, rightControlTwice, shake, shortcut
        public var title: String {
            switch self {
            case .leftControlTwice: "Press Left ⌃ twice"
            case .rightControlTwice: "Press Right ⌃ twice"
            case .shake: "Shake the mouse"
            case .shortcut: "Custom shortcut"
            }
        }
    }

    public var enabled = true
    public var activation: Activation = .leftControlTwice
    /// Double-⌃ only counts while ⌘ is held (the Windows-key option in PowerToys).
    public var requireCommand = false
    @NullCodable public var shortcut: Shortcut? = Shortcut(kVK_ANSI_F, [.control, .option])
    /// Pixels the pointer must travel within the interval.
    public var shakeMinimumDistance: Double = 1000
    /// Milliseconds of movement considered for a shake.
    public var shakeInterval: Double = 1000
    /// Path length as a percentage of the diagonal of the area covered: back-and-forth movement scores high.
    public var shakeFactor: Double = 400
    public var backdropColor = RGBA(hex: "#000000B3") ?? .black
    public var spotlightColor = RGBA(hex: "#FFFFFF14") ?? .white
    public var spotlightRadius: Double = 100
    public var initialZoom: Double = 9
    /// Milliseconds.
    public var animationDuration: Double = 500
    public var excludedApps: [String] = []
    /// macOS has no Game Mode API; full-screen apps (games, videos) are the closest signal.
    public var skipFullScreenApps = false
    public init() {}
}

public struct HighlighterSettings: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable {
        case spotlight, circle, ripple
        public var title: String {
            switch self {
            case .spotlight: "Spotlight"
            case .circle: "Circle highlight"
            case .ripple: "Ripple"
            }
        }
    }

    public var enabled = true
    @NullCodable public var shortcut: Shortcut? = Shortcut(kVK_ANSI_H, [.control, .option])
    public var autoActivate = false
    public var mode: Mode = .ripple
    public var primaryColor = RGBA(hex: "#BFFF00A6") ?? .accent
    public var secondaryColor = RGBA(hex: "#00BFFFA6") ?? .accent
    /// Persistent highlight around the pointer (Spotlight and Circle). Transparent = off;
    /// Spotlight uses it for the dimmed area.
    public var alwaysColor = RGBA(hex: "#FF000000") ?? .black
    public var radius: Double = 20
    /// Milliseconds before a click circle starts to fade.
    public var fadeDelay: Double = 500
    public var fadeDuration: Double = 250
    public var rippleSize: Double = 60
    public var rippleIntensity: Double = 0.7
    public var rippleDuration: Double = 480
    public var followCursorWhileHeld = true
    public var rightReleasePulse = true
    public init() {}
}

public struct MouseJumpSettings: Codable, Equatable, Sendable {
    public enum Style: String, Codable, CaseIterable, Sendable {
        case compact, bezelled, custom
        public var title: String { rawValue.capitalized }
    }

    public var enabled = true
    @NullCodable public var shortcut: Shortcut? = Shortcut(kVK_ANSI_J, [.control, .option])
    public var maxWidth: Double = 1600
    public var maxHeight: Double = 1200
    public var style: Style = .bezelled
    /// Live display previews (Screen Recording); otherwise the desktop pictures.
    public var liveThumbnails = true
    public var customBackground = RGBA(hex: "#1C1C1EE6") ?? .black
    public var customBorderColor = RGBA(hex: "#FFFFFF33") ?? .white
    public var customBorderWidth: Double = 1
    public var customBezel: Double = 6
    public var customMargin: Double = 6
    public var customCornerRadius: Double = 8
    public init() {}
}

public struct CrosshairsSettings: Codable, Equatable, Sendable {
    public enum Orientation: String, Codable, CaseIterable, Sendable {
        case both, horizontal, vertical
        public var title: String {
            switch self {
            case .both: "Vertical and horizontal"
            case .horizontal: "Horizontal"
            case .vertical: "Vertical"
            }
        }
    }

    public var enabled = true
    @NullCodable public var shortcut: Shortcut? = Shortcut(kVK_ANSI_X, [.control, .option])
    public var autoActivate = false
    public var color = RGBA(hex: "#FF0000") ?? .accent
    public var opacity: Double = 0.75
    public var centerRadius: Double = 20
    public var thickness: Double = 5
    public var borderColor = RGBA.white
    public var borderSize: Double = 1
    public var orientation: Orientation = .both
    /// Hide while Auto Hide Cursor has hidden the pointer.
    public var hideWhenPointerHidden = true
    public var fixedLength = false
    public var length: Double = 100
    @NullCodable public var glideShortcut: Shortcut? = Shortcut(kVK_ANSI_Period, [.control, .option])
    /// Pixels per frame of the fast sweep.
    public var glideTravelSpeed: Double = 25
    /// Pixels per frame of the slow (fine) sweep.
    public var glideDelaySpeed: Double = 5
    public init() {}
}

public struct CursorWrapSettings: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable {
        case both, vertical, horizontal
        public var title: String {
            switch self {
            case .both: "Vertical and horizontal"
            case .vertical: "Vertical only"
            case .horizontal: "Horizontal only"
            }
        }
    }

    public enum Activation: String, Codable, CaseIterable, Sendable {
        case always, holdingControl, holdingShift
        public var title: String {
            switch self {
            case .always: "Always"
            case .holdingControl: "While holding ⌃"
            case .holdingShift: "While holding ⇧"
            }
        }
    }

    public var enabled = false
    @NullCodable public var shortcut: Shortcut? = Shortcut(kVK_ANSI_W, [.control, .option, .shift])
    public var autoActivate = true
    public var disableWhileDragging = true
    public var mode: Mode = .both
    public var activation: Activation = .always
    public var disableOnSingleMonitor = false
    public init() {}
}

public struct AutoHideSettings: Codable, Equatable, Sendable {
    public var enabled = false
    public var hideWhileTyping = true
    public var hideWhenIdle = false
    /// Seconds without movement before hiding.
    public var idleDelay: Double = 5
    /// Movement below this many points doesn't bring the pointer back.
    public var movementThreshold: Double = 4
    public init() {}
}

public struct ButtonLockSettings: Codable, Equatable, Sendable {
    public var enabled = false
    public var left = false
    public var right = true
    public var middle = false
    /// Milliseconds the button must be held still before it locks.
    public var holdDuration: Double = 1200
    /// Moving farther than this while holding makes it a normal drag.
    public var dragThreshold: Double = 5
    public init() {}
}
