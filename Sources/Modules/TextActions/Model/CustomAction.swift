import Carbon.HIToolbox
import Foundation
import MacToysCore

/// An action the user defines: open a URL, run a shell script, AppleScript or Shortcut, or press keys.
public struct CustomAction: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case url, shell, appleScript = "applescript", shortcut, keyPress = "keys"

        public var title: String {
            switch self {
            case .url: String(localized: "URL", comment: "Custom text action type: open a web address")
            case .shell: String(localized: "Shell Script", comment: "Custom text action type")
            case .appleScript: String(localized: "AppleScript", comment: "Custom text action type")
            case .shortcut: String(localized: "textactions.type.shortcut", defaultValue: "Shortcut", comment: "Custom text action type: run one of the user's Shortcuts from the Shortcuts app (not a keyboard shortcut)")
            case .keyPress: String(localized: "Key Press", comment: "Custom text action type: press a key combination")
            }
        }

        /// Short segmented-control label.
        public var shortTitle: String {
            switch self {
            case .url: String(localized: "URL", comment: "Custom text action type: open a web address")
            case .shell: String(localized: "Shell", comment: "Custom text action type, short: shell script")
            case .appleScript: String(localized: "AppleScript", comment: "Custom text action type")
            case .shortcut: String(localized: "textactions.type.shortcut", defaultValue: "Shortcut", comment: "Custom text action type: run one of the user's Shortcuts from the Shortcuts app (not a keyboard shortcut)")
            case .keyPress: String(localized: "Keys", comment: "Custom text action type, short: press a key combination")
            }
        }

        public var symbol: String {
            switch self {
            case .url: "link"
            case .shell: "terminal"
            case .appleScript: "applescript"
            case .shortcut: "square.2.layers.3d"
            case .keyPress: "keyboard"
            }
        }

        /// Whether the action produces text that `output` decides about.
        public var producesOutput: Bool { self == .shell || self == .appleScript || self == .shortcut }
    }

    /// What happens with a script's output.
    public enum Output: String, Codable, CaseIterable, Sendable {
        case replace, copy, show, ignore

        public var title: String {
            switch self {
            case .replace: String(localized: "Replace the selection", comment: "Custom action result: paste the output over the selection")
            case .copy: String(localized: "Copy to the clipboard", comment: "Custom action result")
            case .show: String(localized: "Show in a card", comment: "Custom action result: show the output next to the selection")
            case .ignore: String(localized: "Ignore", comment: "Custom action result: do nothing with the output")
            }
        }
    }

    /// When the action appears in the bar.
    public enum Condition: String, Codable, CaseIterable, Sendable {
        case any, link, email, path, number, regex

        public var title: String {
            switch self {
            case .any: String(localized: "Any text", comment: "Custom action condition")
            case .link: String(localized: "Text with a web address", comment: "Custom action condition")
            case .email: String(localized: "Text with an email address", comment: "Custom action condition")
            case .path: String(localized: "A file or folder path", comment: "Custom action condition")
            case .number: String(localized: "A number or calculation", comment: "Custom action condition")
            case .regex: String(localized: "Text matching a pattern", comment: "Custom action condition: a regular expression")
            }
        }
    }

    public var id = UUID()
    public var name: String
    /// SF Symbol shown in the bar.
    public var symbol: String
    public var kind: Kind
    /// `.url`: the template, `{text}` is the URL-encoded selection.
    public var template: String
    /// `.shell` (zsh) and `.appleScript` source.
    public var script: String
    /// `.shortcut`: the Shortcut's name.
    public var shortcutName: String
    /// `.keyPress`: the keys to press.
    public var keys: Shortcut?
    public var output: Output
    public var condition: Condition
    /// `.regex` condition.
    public var pattern: String

    public init(id: UUID = UUID(), name: String, symbol: String? = nil, kind: Kind, template: String = "", script: String = "",
                shortcutName: String = "", keys: Shortcut? = nil, output: Output = .show, condition: Condition = .any,
                pattern: String = "") {
        self.id = id
        self.name = name
        self.symbol = symbol ?? kind.symbol
        self.kind = kind
        self.template = template
        self.script = script
        self.shortcutName = shortcutName
        self.keys = keys
        self.output = output
        self.condition = condition
        self.pattern = pattern
    }

    /// Slot id in `TextActionsSettings.actions`.
    public var slotID: String { CustomAction.slotPrefix + id.uuidString }
    public static let slotPrefix = "custom."

    /// Whether the action has what it needs to run.
    public var isComplete: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch kind {
        case .url: return URLTemplate.isValid(template)
        case .shell, .appleScript: return !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .shortcut: return !shortcutName.trimmingCharacters(in: .whitespaces).isEmpty
        case .keyPress: return keys != nil
        }
    }

    // MARK: Codable — the export format: only the fields the type uses, readable names.

    private enum CodingKeys: String, CodingKey {
        case id, name, icon, type, url, script, shortcut, keys, result, when, pattern
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .type)
        self.init(id: (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID(),
                  name: try c.decodeIfPresent(String.self, forKey: .name) ?? "",
                  symbol: try c.decodeIfPresent(String.self, forKey: .icon),
                  kind: kind,
                  template: try c.decodeIfPresent(String.self, forKey: .url) ?? "",
                  script: try c.decodeIfPresent(String.self, forKey: .script) ?? "",
                  shortcutName: try c.decodeIfPresent(String.self, forKey: .shortcut) ?? "",
                  keys: try? c.decodeIfPresent(Shortcut.self, forKey: .keys),
                  output: (try? c.decodeIfPresent(Output.self, forKey: .result)) ?? .show,
                  condition: (try? c.decodeIfPresent(Condition.self, forKey: .when)) ?? .any,
                  pattern: try c.decodeIfPresent(String.self, forKey: .pattern) ?? "")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(symbol, forKey: .icon)
        try c.encode(kind, forKey: .type)
        switch kind {
        case .url: try c.encode(template, forKey: .url)
        case .shell, .appleScript: try c.encode(script, forKey: .script)
        case .shortcut: try c.encode(shortcutName, forKey: .shortcut)
        case .keyPress: try c.encodeIfPresent(keys, forKey: .keys)
        }
        if kind.producesOutput { try c.encode(output, forKey: .result) }
        try c.encode(condition, forKey: .when)
        if condition == .regex { try c.encode(pattern, forKey: .pattern) }
    }
}

/// The file custom actions are exported to and imported from.
public enum CustomActionsFile {
    public static let format = "mactoys.textactions"

    private struct Envelope: Codable {
        var format: String
        var version: Int
        var actions: [CustomAction]
    }

    /// Pretty JSON with sorted keys.
    public static func export(_ actions: [CustomAction]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Envelope(format: format, version: 1, actions: actions))
    }

    /// Accepts the export envelope, a bare array of actions or a single action. Entries that
    /// can't be read are skipped; actions get fresh ids when `existing` already uses theirs.
    public static func `import`(_ data: Data, existing: Set<UUID> = []) throws -> [CustomAction] {
        let json = try JSONSerialization.jsonObject(with: data)
        let entries: [Any]
        if let dict = json as? [String: Any] {
            entries = (dict["actions"] as? [Any]) ?? [dict]
        } else if let array = json as? [Any] {
            entries = array
        } else {
            throw ImportError.notActions
        }
        var seen = existing
        var result: [CustomAction] = []
        for entry in entries {
            guard JSONSerialization.isValidJSONObject(entry),
                  let itemData = try? JSONSerialization.data(withJSONObject: entry),
                  var action = try? JSONDecoder().decode(CustomAction.self, from: itemData) else { continue }
            if action.name.trimmingCharacters(in: .whitespaces).isEmpty { action.name = action.kind.title }
            if seen.contains(action.id) { action.id = UUID() }
            seen.insert(action.id)
            result.append(action)
        }
        if result.isEmpty { throw ImportError.notActions }
        return result
    }

    public enum ImportError: LocalizedError, Equatable {
        case notActions

        public var errorDescription: String? {
            String(localized: "The file doesn’t contain any text actions.")
        }
    }
}

/// Ready-made custom actions offered in the settings' Add menu.
public enum CustomActionExamples {
    public static var all: [CustomAction] {
        [
            CustomAction(name: String(localized: "Search GitHub", comment: "Example custom text action"),
                         symbol: "chevron.left.forwardslash.chevron.right", kind: .url,
                         template: "https://github.com/search?q={text}&type=code"),
            CustomAction(name: String(localized: "Sort Lines", comment: "Example custom text action"),
                         symbol: "arrow.up.arrow.down", kind: .shell, script: "sort", output: .replace),
            CustomAction(name: String(localized: "Base64 Encode", comment: "Example custom text action"),
                         symbol: "lock", kind: .shell, script: "base64 | tr -d '\\n'", output: .replace),
            CustomAction(name: String(localized: "New Note", comment: "Example custom text action"),
                         symbol: "note.text", kind: .appleScript,
                         script: "tell application \"Notes\" to make new note with properties {body:{text}}", output: .ignore),
            CustomAction(name: String(localized: "Bold", comment: "Example custom text action: press ⌘B"),
                         symbol: "bold", kind: .keyPress, keys: Shortcut(kVK_ANSI_B, [.command])),
        ]
    }
}
