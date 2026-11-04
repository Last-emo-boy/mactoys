import Carbon.HIToolbox
import Foundation
import MacToysCore

/// A position in the bar: a built-in action (`BuiltInAction.rawValue`) or a custom one
/// (`custom.<uuid>`), switched on or off.
public struct ActionSlot: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var enabled: Bool

    public init(_ id: String, enabled: Bool = true) {
        self.id = id
        self.enabled = enabled
    }

    public static var defaults: [ActionSlot] { BuiltInAction.allCases.map { ActionSlot($0.slotID) } }

    /// The stored order made whole: unknown and duplicate ids dropped, built-ins added in a
    /// later version inserted after their default predecessor, new custom actions appended.
    public static func reconcile(_ slots: [ActionSlot], custom: [CustomAction]) -> [ActionSlot] {
        let customIDs = Set(custom.map(\.slotID))
        let builtInIDs = Set(BuiltInAction.allCases.map(\.slotID))
        var seen = Set<String>()
        var result = slots.filter { slot in
            (builtInIDs.contains(slot.id) || customIDs.contains(slot.id)) && seen.insert(slot.id).inserted
        }
        let order = BuiltInAction.allCases
        for (index, action) in order.enumerated() where !seen.contains(action.slotID) {
            let predecessors = order[..<index].map(\.slotID)
            let position = result.lastIndex { predecessors.contains($0.id) }.map { $0 + 1 } ?? 0
            result.insert(ActionSlot(action.slotID), at: position)
            seen.insert(action.slotID)
        }
        for action in custom where !seen.contains(action.slotID) {
            result.append(ActionSlot(action.slotID))
            seen.insert(action.slotID)
        }
        return result
    }
}

/// Web search engines for the Search action; `{text}` is the URL-encoded selection.
public enum SearchEngine: String, Codable, CaseIterable, Sendable {
    case google, bing, duckDuckGo, ecosia, brave, startpage, kagi, baidu, yandex, naver, custom

    /// Engine names are brands and stay as they are; only "Custom" is localized.
    public var title: String {
        switch self {
        case .google: "Google"
        case .bing: "Bing"
        case .duckDuckGo: "DuckDuckGo"
        case .ecosia: "Ecosia"
        case .brave: "Brave Search"
        case .startpage: "Startpage"
        case .kagi: "Kagi"
        case .baidu: "Baidu"
        case .yandex: "Yandex"
        case .naver: "NAVER"
        case .custom: String(localized: "Custom URL", comment: "Search engine choice: a web address the user enters")
        }
    }

    public var template: String? {
        switch self {
        case .google: "https://www.google.com/search?q={text}"
        case .bing: "https://www.bing.com/search?q={text}"
        case .duckDuckGo: "https://duckduckgo.com/?q={text}"
        case .ecosia: "https://www.ecosia.org/search?q={text}"
        case .brave: "https://search.brave.com/search?q={text}"
        case .startpage: "https://www.startpage.com/do/search?q={text}"
        case .kagi: "https://kagi.com/search?q={text}"
        case .baidu: "https://www.baidu.com/s?wd={text}"
        case .yandex: "https://yandex.com/search/?text={text}"
        case .naver: "https://search.naver.com/search.naver?query={text}"
        case .custom: nil
        }
    }
}

public struct TextActionsSettings: Codable, Equatable, Sendable {
    /// A modifier that must be held while selecting for the bar to appear.
    public enum RequiredModifier: String, Codable, CaseIterable, Sendable {
        case none, option, control, command

        public var title: String {
            switch self {
            case .none: String(localized: "None", comment: "Required modifier key: no key needs to be held")
            case .option: String(localized: "⌥ Option", comment: "Modifier key name")
            case .control: String(localized: "⌃ Control", comment: "Modifier key name")
            case .command: String(localized: "⌘ Command", comment: "Modifier key name")
            }
        }

        public var modifiers: Modifiers {
            switch self {
            case .none: []
            case .option: .option
            case .control: .control
            case .command: .command
            }
        }
    }

    /// What each bar button shows.
    public enum LabelStyle: String, Codable, CaseIterable, Sendable {
        case icons, iconsAndLabels, labels

        public var title: String {
            switch self {
            case .icons: String(localized: "Icons", comment: "Text Actions bar style: icons only")
            case .iconsAndLabels: String(localized: "Icons and names", comment: "Text Actions bar style")
            case .labels: String(localized: "Names", comment: "Text Actions bar style: action names only, no icons")
            }
        }

        var showsIcon: Bool { self != .labels }
        var showsLabel: Bool { self != .icons }
    }

    public enum BarSize: String, Codable, CaseIterable, Sendable {
        case small, regular, large

        public var title: String {
            switch self {
            case .small: String(localized: "Small", comment: "Text Actions bar size")
            case .regular: String(localized: "Medium", comment: "Text Actions bar size")
            case .large: String(localized: "Large", comment: "Text Actions bar size")
            }
        }

        public var scale: CGFloat {
            switch self {
            case .small: 0.86
            case .regular: 1
            case .large: 1.18
            }
        }
    }

    /// Where the bar goes relative to a single-line selection.
    public enum Placement: String, Codable, CaseIterable, Sendable {
        case above, below

        public var title: String {
            switch self {
            case .above: String(localized: "Above the selection")
            case .below: String(localized: "Below the selection")
            }
        }
    }

    /// Which selection gestures show the bar.
    public struct Triggers: Codable, Equatable, Sendable {
        public var drag = true
        public var multiClick = true
        public var shiftClick = true
        public var keyboard = true
        public var longPress = false

        public init() {}
    }

    public var autoShow = true
    public var triggers = Triggers()
    public var requiredModifier = RequiredModifier.none
    /// Milliseconds between the end of a selection and reading it.
    public var delay: Double = 150
    public var showShortcut: Shortcut? = Shortcut(kVK_ANSI_A, [.control, .option, .shift])
    /// Press ⌘C (and put the clipboard back) when an app doesn't share its selection.
    public var copyFallback = false
    /// Always replace text by pasting instead of through Accessibility.
    public var pasteToReplace = false
    public var labelStyle = LabelStyle.icons
    public var size = BarSize.regular
    public var placement = Placement.above
    public var hideWhenPointerLeaves = true
    /// Actions shown before the overflow chevron.
    public var visibleCount = 7
    public var actions: [ActionSlot] = ActionSlot.defaults
    public var customActions: [CustomAction] = []
    public var searchEngine = SearchEngine.google
    public var customSearchURL = "https://www.google.com/search?q={text}"
    /// BCP 47 language for Translate; empty follows the system language.
    public var translateTarget = ""
    public var excludedApps: [String] = []

    public init() {}

    /// `actions` reconciled with the built-ins and custom actions that exist.
    public var slots: [ActionSlot] { ActionSlot.reconcile(actions, custom: customActions) }

    /// The search URL template in use.
    public var searchTemplate: String {
        searchEngine.template ?? (URLTemplate.isValid(customSearchURL) ? customSearchURL : SearchEngine.google.template ?? "")
    }

    public func custom(slotID: String) -> CustomAction? {
        customActions.first { $0.slotID == slotID }
    }

    /// Adds a custom action at the end of the bar.
    public mutating func add(_ action: CustomAction) {
        actions = slots
        customActions.append(action)
        actions.append(ActionSlot(action.slotID))
    }

    public mutating func remove(customID id: UUID) {
        customActions.removeAll { $0.id == id }
        actions = slots
    }
}
