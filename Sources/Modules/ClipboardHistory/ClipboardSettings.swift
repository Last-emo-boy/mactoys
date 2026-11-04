import Carbon.HIToolbox
import Foundation
import MacToysCore

public struct ClipboardSettings: Codable, Equatable, Sendable {
    public enum PanelStyle: String, Codable, CaseIterable, Sendable, Identifiable {
        /// A floating panel with a list and a preview, at the pointer's display.
        case panel
        /// A horizontal strip of cards along the bottom of the screen.
        case bar

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .panel: String(localized: "Panel", comment: "Clipboard History window style: floating panel with a list")
            case .bar: String(localized: "Paste bar", comment: "Clipboard History window style: a strip of cards along the bottom of the screen")
            }
        }
    }

    public enum ReturnAction: String, Codable, CaseIterable, Sendable, Identifiable {
        case paste, copy

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .paste: String(localized: "Paste into the previous app", comment: "What Return does in the clipboard panel")
            case .copy: String(localized: "Copy to the clipboard", comment: "What Return does in the clipboard panel")
            }
        }
    }

    /// How long unpinned entries are kept.
    public enum Retention: String, Codable, CaseIterable, Sendable, Identifiable {
        case day, week, month, quarter, year, forever

        public var id: String { rawValue }

        public var interval: TimeInterval? {
            switch self {
            case .day: 86_400
            case .week: 7 * 86_400
            case .month: 30 * 86_400
            case .quarter: 90 * 86_400
            case .year: 365 * 86_400
            case .forever: nil
            }
        }

        public var title: String {
            switch self {
            case .day: String(localized: "1 day", comment: "Clipboard history retention")
            case .week: String(localized: "1 week", comment: "Clipboard history retention")
            case .month: String(localized: "1 month", comment: "Clipboard history retention")
            case .quarter: String(localized: "3 months", comment: "Clipboard history retention")
            case .year: String(localized: "1 year", comment: "Clipboard history retention")
            case .forever: String(localized: "Forever", comment: "Clipboard history retention: until the item limit pushes them out")
            }
        }
    }

    public enum MergeSeparator: String, Codable, CaseIterable, Sendable, Identifiable {
        case newline, blankLine, space, comma

        public var id: String { rawValue }

        public var string: String {
            switch self {
            case .newline: "\n"
            case .blankLine: "\n\n"
            case .space: " "
            case .comma: ", "
            }
        }

        public var title: String {
            switch self {
            case .newline: String(localized: "New line", comment: "Separator between merged clipboard items")
            case .blankLine: String(localized: "Blank line", comment: "Separator between merged clipboard items")
            case .space: String(localized: "Space", comment: "Separator between merged clipboard items")
            case .comma: String(localized: "Comma", comment: "Separator between merged clipboard items")
            }
        }
    }

    /// Item limits offered in Settings.
    public static let limits = [50, 100, 200, 500, 1000, 2000]

    /// Password managers whose copies are never recorded (bundle ids for Apple's localized app names).
    public static let defaultExcludedApps = [
        "com.apple.Passwords", "com.apple.keychainaccess", "1Password", "Bitwarden", "Dashlane", "LastPass",
        "KeePassXC", "Enpass", "Proton Pass", "Strongbox",
    ]

    // Activation
    @NullCodable public var openShortcut: Shortcut? = Shortcut(kVK_ANSI_C, [.control, .option, .shift])
    public var style: PanelStyle = .panel
    public var returnAction: ReturnAction = .paste
    public var showPreview = true
    public var moveToTopOnPaste = true
    public var mergeSeparator: MergeSeparator = .newline

    // Paste stack
    @NullCodable public var stackShortcut: Shortcut? = nil
    public var stackOrder: PasteStack.Order = .copyOrder
    public var restoreClipboardAfterStack = true

    // Snippets
    public var restoreClipboardAfterSnippet = true

    // Privacy & history
    @NullCodable public var pauseShortcut: Shortcut? = nil
    public var paused = false
    public var excludedApps: [String] = ClipboardSettings.defaultExcludedApps
    public var maxItems = 500
    public var retention: Retention = .month

    public init() {}
}
