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
            case .controlCommand: "⌃⌘  Control-Command"
            case .option: "⌥  Option"
            case .controlOption: "⌃⌥  Control-Option"
            case .commandOption: "⌥⌘  Option-Command"
            case .function: "fn  Function"
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
