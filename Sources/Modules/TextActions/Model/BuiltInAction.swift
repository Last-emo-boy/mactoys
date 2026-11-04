import Foundation
import MacToysCore

/// The actions Text Actions ships with, in their default bar order.
public enum BuiltInAction: String, CaseIterable, Codable, Sendable {
    case cut, copy, paste
    case openLink, email, map, call, revealPath
    case spelling, search, lookUp, translate
    case calculate, formatJSON, minifyJSON, markdownLink
    case changeCase, count, speak

    /// Name shown in labels, captions and the settings list.
    public var title: String {
        switch self {
        case .cut: String(localized: "Cut", comment: "Text action: cut the selected text")
        case .copy: String(localized: "Copy", comment: "Text action: copy the selected text")
        case .paste: String(localized: "Paste", comment: "Text action: paste over the selection")
        case .openLink: String(localized: "Open Link", comment: "Text action: open the web address in the selection")
        case .email: String(localized: "Email", comment: "Text action: write an email to the address in the selection")
        case .map: String(localized: "Map", comment: "Text action: show the street address in the selection in Maps")
        case .call: String(localized: "Call", comment: "Text action: call the phone number in the selection")
        case .revealPath: String(localized: "Reveal", comment: "Text action: show the file path in the selection in Finder")
        case .spelling: String(localized: "Spelling", comment: "Text action: spelling suggestions for the selected word")
        case .search: String(localized: "Search", comment: "Text action: search the web for the selection")
        case .lookUp: String(localized: "Look Up", comment: "Text action: look the selected word up in the dictionary")
        case .translate: String(localized: "Translate", comment: "Text action: translate the selection")
        case .calculate: String(localized: "Calculate", comment: "Text action: evaluate the selected arithmetic expression")
        case .formatJSON: String(localized: "Format JSON", comment: "Text action: indent the selected JSON")
        case .minifyJSON: String(localized: "Minify JSON", comment: "Text action: remove whitespace from the selected JSON")
        case .markdownLink: String(localized: "Markdown Link", comment: "Text action: turn the selection into a Markdown link")
        case .changeCase: String(localized: "Change Case", comment: "Text action: uppercase, lowercase, title case…")
        case .count: String(localized: "Count", comment: "Text action: count characters, words and lines")
        case .speak: String(localized: "Speak", comment: "Text action: read the selection aloud")
        }
    }

    /// When the action shows up, for the settings list.
    public var condition: String {
        switch self {
        case .cut: String(localized: "In text you can edit")
        case .copy: String(localized: "Whenever text is selected")
        case .paste: String(localized: "In text you can edit, when the clipboard holds text")
        case .openLink: String(localized: "When the selection contains a web address")
        case .email: String(localized: "When the selection contains an email address")
        case .map: String(localized: "When the selection contains a street address")
        case .call: String(localized: "When the selection contains a phone number")
        case .revealPath: String(localized: "When the selection is the path of a file or folder")
        case .spelling: String(localized: "When a single word is misspelled")
        case .search: String(localized: "For selections up to 500 characters")
        case .lookUp: String(localized: "When the dictionary knows the word")
        case .translate: String(localized: "When the text is in another language, on this Mac")
        case .calculate: String(localized: "When the selection is an arithmetic expression")
        case .formatJSON: String(localized: "When the selection is compact JSON")
        case .minifyJSON: String(localized: "When the selection is indented JSON")
        case .markdownLink: String(localized: "On a web address, or on text while a link is on the clipboard")
        case .changeCase: String(localized: "When the text has letters with case")
        case .count: String(localized: "Whenever text is selected")
        case .speak: String(localized: "Whenever text is selected; click again to stop")
        }
    }

    public var symbol: String {
        switch self {
        case .cut: "scissors"
        case .copy: "doc.on.doc"
        case .paste: "doc.on.clipboard"
        case .openLink: "link"
        case .email: "envelope"
        case .map: "map"
        case .call: "phone"
        case .revealPath: "folder"
        case .spelling: "textformat.abc.dottedunderline"
        case .search: "magnifyingglass"
        case .lookUp: "character.book.closed"
        case .translate: "translate"
        case .calculate: "plus.forwardslash.minus"
        case .formatJSON: "curlybraces.square"
        case .minifyJSON: "arrow.down.right.and.arrow.up.left"
        case .markdownLink: "link.badge.plus"
        case .changeCase: "textformat"
        case .count: "number"
        case .speak: "speaker.wave.2"
        }
    }

    /// Icon tile color in the settings list, by family.
    public var tint: Tint {
        switch self {
        case .cut, .copy, .paste: .blue
        case .openLink, .email, .map, .call, .revealPath: .teal
        case .spelling, .search, .lookUp, .translate, .speak: .indigo
        case .calculate, .formatJSON, .minifyJSON, .markdownLink, .changeCase, .count: .orange
        }
    }

    /// Slot id in `TextActionsSettings.actions`.
    public var slotID: String { rawValue }
}
