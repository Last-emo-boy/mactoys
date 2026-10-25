import Foundation
import MacToysCore

public struct GrabAndMoveSettings: Codable, Equatable, Sendable {
    /// The modifier held while dragging.
    public enum Activation: String, Codable, CaseIterable, Sendable {
        case controlCommand, option, controlOption, commandOption, function

        public var modifiers: Modifiers {
            switch self {
            case .controlCommand: [.control, .command]
            case .option: [.option]
            case .controlOption: [.control, .option]
            case .commandOption: [.command, .option]
            case .function: [.function]
            }
        }

        public var keys: [String] { modifiers.symbols }

        public var title: String {
            switch self {
            case .controlCommand: String(localized: "⌃⌘  Control-Command", comment: "Modifier keys; keep the key symbols")
            case .option: String(localized: "⌥  Option", comment: "Modifier key; keep the key symbol")
            case .controlOption: String(localized: "⌃⌥  Control-Option", comment: "Modifier keys; keep the key symbols")
            case .commandOption: String(localized: "⌥⌘  Option-Command", comment: "Modifier keys; keep the key symbols")
            case .function: String(localized: "fn  Function", comment: "Modifier key; keep “fn”, the key's label")
            }
        }
    }

    public var activation: Activation = .controlCommand
    public var resizeWithRightDrag = true
    public var showGeometry = true
    public var bringToFront = true
    /// Apps whose windows are never moved or resized.
    public var excludedApps: [String] = []
    /// Apps that get the modifier as usual while they are frontmost (Grab And Move stays out of the way).
    public var excludedForModifierApps: [String] = []

    public init() {}
}
