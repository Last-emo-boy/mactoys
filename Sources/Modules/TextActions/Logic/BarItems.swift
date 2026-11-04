import Foundation

/// One button in the bar.
public struct BarItem: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case builtIn(BuiltInAction)
        case custom(UUID)
        case caseOption(CaseTransform)
        case suggestion(String)
        /// The overflow chevron.
        case more
        /// Back from the overflow or a sub-bar.
        case back
    }

    public let id: String
    public let kind: Kind
    /// Localized name: label, caption and accessibility.
    public let title: String
    public let symbol: String?
    /// A text face instead of an icon (case samples, spelling suggestions).
    public let face: String?
    public let monospaced: Bool

    public init(id: String, kind: Kind, title: String, symbol: String?, face: String? = nil, monospaced: Bool = false) {
        self.id = id
        self.kind = kind
        self.title = title
        self.symbol = symbol
        self.face = face
        self.monospaced = monospaced
    }

    public static func builtIn(_ action: BuiltInAction) -> BarItem {
        BarItem(id: action.slotID, kind: .builtIn(action), title: action.title, symbol: action.symbol)
    }

    public static func custom(_ action: CustomAction) -> BarItem {
        BarItem(id: action.slotID, kind: .custom(action.id), title: action.name, symbol: action.symbol)
    }

    public static var more: BarItem {
        BarItem(id: "more", kind: .more, title: String(localized: "More actions", comment: "Text Actions bar: show the actions that didn't fit"),
                symbol: "chevron.right")
    }

    public static var back: BarItem {
        BarItem(id: "back", kind: .back, title: String(localized: "Back", comment: "Text Actions bar: return to the main actions"),
                symbol: "chevron.left")
    }

    public static func caseOption(_ t: CaseTransform) -> BarItem {
        BarItem(id: "case." + t.rawValue, kind: .caseOption(t), title: t.title, symbol: nil, face: t.sample, monospaced: t.isIdentifierStyle)
    }

    public static func suggestion(_ word: String) -> BarItem {
        BarItem(id: "suggestion." + word, kind: .suggestion(word), title: word, symbol: nil, face: word)
    }
}

/// What the bar is showing.
public enum BarPage: Equatable, Sendable {
    case main, overflow, cases
    case spelling([String])
}

public enum BarItems {
    /// The enabled actions that fit the selection, in the user's order.
    public static func actions(settings: TextActionsSettings, analysis: SelectionAnalysis, context: SelectionContext) -> [BarItem] {
        settings.slots.compactMap { slot -> BarItem? in
            guard slot.enabled else { return nil }
            if let builtIn = BuiltInAction(rawValue: slot.id) {
                return ActionRelevance.applies(builtIn, analysis, context) ? .builtIn(builtIn) : nil
            }
            guard let custom = settings.custom(slotID: slot.id), ActionRelevance.applies(custom, analysis, context) else { return nil }
            return .custom(custom)
        }
    }

    /// The buttons on a page. The main page shows `visibleCount` actions and a chevron for the
    /// rest — unless only one would be left over, which then takes the chevron's place.
    public static func page(_ page: BarPage, of items: [BarItem], visibleCount: Int) -> [BarItem] {
        let count = max(1, visibleCount)
        switch page {
        case .main:
            return items.count > count + 1 ? Array(items.prefix(count)) + [.more] : items
        case .overflow:
            return [.back] + items.dropFirst(count)
        case .cases:
            return [.back] + CaseTransform.allCases.map(BarItem.caseOption)
        case .spelling(let words):
            return [.back] + words.prefix(6).map(BarItem.suggestion)
        }
    }
}
