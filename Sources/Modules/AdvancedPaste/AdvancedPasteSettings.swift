import Carbon.HIToolbox
import Foundation
import MacToysCore

/// On/off and direct shortcut of one built-in action.
public struct ActionPrefs: Codable, Equatable, Sendable {
    public var enabled = true
    public var shortcut: Shortcut?

    public init(enabled: Bool = true, shortcut: Shortcut? = nil) {
        self.enabled = enabled
        self.shortcut = shortcut
    }
}

/// A saved AI prompt shown in the window and runnable by its own shortcut.
public struct CustomAction: Codable, Equatable, Sendable, Identifiable {
    public var id = UUID()
    public var name: String
    public var prompt: String
    public var shortcut: Shortcut?
    /// Shown in the Advanced Paste window.
    public var isEnabled = true

    public init(name: String, prompt: String, shortcut: Shortcut? = nil, isEnabled: Bool = true) {
        self.name = name
        self.prompt = prompt
        self.shortcut = shortcut
        self.isEnabled = isEnabled
    }

    public static let defaults = [
        CustomAction(name: "Fix spelling and grammar",
                     prompt: "Fix spelling and grammar. Keep the original language, meaning, tone and formatting."),
        CustomAction(name: "Summarize in 3 bullets", prompt: "Summarize the text in three short Markdown bullet points."),
        CustomAction(name: "Translate to English", prompt: "Translate the text to English. Keep the formatting.", isEnabled: false),
    ]
}

public struct AdvancedPasteSettings: Codable, Equatable, Sendable {
    public enum WindowPosition: String, Codable, CaseIterable, Sendable {
        case caret, pointer, center
        public var title: String {
            switch self {
            case .caret: "Near the text cursor"
            case .pointer: "Near the pointer"
            case .center: "Center of the screen"
            }
        }
    }

    // Activation & behavior
    public var openShortcut: Shortcut? = Shortcut(kVK_ANSI_V, [.control, .option])
    public var windowPosition = WindowPosition.caret
    public var showPreview = true
    public var historyEnabled = true
    public var closeOnFocusLoss = false
    /// Show AI and OCR results before pasting them.
    public var customFormatPreview = true
    /// Copy the current selection (⌘C) before running a direct shortcut.
    public var useSelectedText = false
    /// Put the original clipboard back after pasting a transformed result.
    public var restoreClipboard = true

    // Actions, keyed by `AdvancedPasteTransforms.Action.name`.
    public var actions: [String: ActionPrefs] = AdvancedPasteSettings.defaultActions

    // Paste with AI
    public var aiEnabled = false
    public var showPromptBox = true
    public var provider = AIProvider.preset(.openAI)
    public var customActions = CustomAction.defaults

    public init() {}

    public static let defaultActions: [String: ActionPrefs] = {
        var d: [String: ActionPrefs] = [:]
        for action in AdvancedPasteTransforms.Action.builtIns { d[action.name] = ActionPrefs() }
        d[AdvancedPasteTransforms.Action.plainText.name]?.shortcut = Shortcut(kVK_ANSI_V, [.control, .option, .shift])
        return d
    }()

    public func prefs(_ action: AdvancedPasteTransforms.Action) -> ActionPrefs {
        actions[action.name] ?? ActionPrefs()
    }

    /// Built-in actions turned on in settings.
    public var enabledActions: [AdvancedPasteTransforms.Action] {
        AdvancedPasteTransforms.Action.builtIns.filter { prefs($0).enabled }
    }

    /// Custom actions available in the window (AI on, action on).
    public var visibleCustomActions: [CustomAction] {
        aiEnabled ? customActions.filter { $0.isEnabled && !$0.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } : []
    }
}
