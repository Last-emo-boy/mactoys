import Carbon.HIToolbox
import CoreGraphics
import Foundation
import MacToysCore

/// Persisted options of Keystroke Overlay (`keystrokes.json`).
public struct KeystrokeSettings: Codable, Equatable, Sendable {
    /// Which presses appear.
    public enum Mode: String, Codable, CaseIterable, Sendable {
        case shortcuts, allKeys, text

        public var title: String {
            switch self {
            case .shortcuts: String(localized: "Shortcuts only", comment: "Keystroke Overlay mode")
            case .allKeys: String(localized: "Every key", comment: "Keystroke Overlay mode")
            case .text: String(localized: "Typed text", comment: "Keystroke Overlay mode")
            }
        }

        public var summary: String {
            switch self {
            case .shortcuts: String(localized: "Keys pressed with ⌘, ⌃ or ⌥. What you type stays private.")
            case .allKeys: String(localized: "Each key as a keycap, including letters and numbers.")
            case .text: String(localized: "What you type as a running line of text, with shortcuts as keycaps.")
            }
        }
    }

    public enum Position: String, Codable, CaseIterable, Sendable {
        case bottomCenter, topCenter, bottomLeading, bottomTrailing, topLeading, topTrailing, custom

        public var title: String {
            switch self {
            case .bottomCenter: String(localized: "Bottom center", comment: "Overlay position on screen")
            case .topCenter: String(localized: "Top center", comment: "Overlay position on screen")
            case .bottomLeading: String(localized: "Bottom left", comment: "Overlay position on screen")
            case .bottomTrailing: String(localized: "Bottom right", comment: "Overlay position on screen")
            case .topLeading: String(localized: "Top left", comment: "Overlay position on screen")
            case .topTrailing: String(localized: "Top right", comment: "Overlay position on screen")
            case .custom: String(localized: "Custom", comment: "Overlay position on screen: where the user dragged it")
            }
        }
    }

    public enum Size: String, Codable, CaseIterable, Sendable {
        case small, medium, large, extraLarge

        public var title: String {
            switch self {
            case .small: String(localized: "Small", comment: "Overlay size")
            case .medium: String(localized: "Medium", comment: "Overlay size")
            case .large: String(localized: "Large", comment: "Overlay size")
            case .extraLarge: String(localized: "Extra large", comment: "Overlay size")
            }
        }

        /// Point size of key legends.
        public var fontSize: CGFloat {
            switch self {
            case .small: 15
            case .medium: 20
            case .large: 28
            case .extraLarge: 40
            }
        }

        /// How many recent presses stay in the pill.
        public var maxItems: Int {
            switch self {
            case .small: 5
            case .medium: 4
            case .large: 3
            case .extraLarge: 2
            }
        }

        /// Characters of typed text kept in view.
        public var maxText: Int {
            switch self {
            case .small: 48
            case .medium: 40
            case .large: 30
            case .extraLarge: 22
            }
        }
    }

    public enum Theme: String, Codable, CaseIterable, Sendable {
        case glass, dark, light

        public var title: String {
            switch self {
            case .glass: String(localized: "Glass", comment: "Overlay theme: translucent Liquid Glass")
            case .dark: String(localized: "Dark", comment: "Theme: dark appearance")
            case .light: String(localized: "Light", comment: "Theme: light appearance")
            }
        }
    }

    /// The display the overlay appears on.
    public enum Screen: String, Codable, CaseIterable, Sendable {
        case pointer, main

        public var title: String {
            switch self {
            case .pointer: String(localized: "The display with the pointer")
            case .main: String(localized: "The display with the menu bar")
            }
        }
    }

    /// Overlay on or off (the toggle shortcut and the quick action switch flip it).
    public var showing = true
    public var toggle: Shortcut? = Shortcut(kVK_ANSI_J, [.control, .option, .shift])
    public var mode = Mode.shortcuts
    /// Name shortcuts after the active app's menu items: "⌘S Save".
    public var showNames = true
    /// In shortcuts mode, also show esc, return, tab, delete, arrows and function keys.
    public var specialKeys = false
    public var modifierOnly = false
    public var mouseClicks = false
    /// Letters and digits show as dots.
    public var maskText = false
    public var position = Position.bottomCenter
    /// Center of the overlay for the custom position, as fractions of the screen (top-left origin).
    public var customX: Double = 0.5
    public var customY: Double = 0.8
    public var screen = Screen.pointer
    public var size = Size.medium
    public var theme = Theme.glass
    /// Seconds the overlay stays after the last press.
    public var duration: Double = 2
    /// Never shown while one of these apps is active.
    public var excludedApps = ["1Password", "Bitwarden", "Keychain Access", "Passwords"]

    public init() {}
}
