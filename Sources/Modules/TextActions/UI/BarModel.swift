import AppKit
import MacToysCore
import Observation
import SwiftUI

/// A result shown next to the selection instead of the bar.
struct ResultCard: Equatable {
    enum Content: Equatable {
        case stats(TextStats)
        case calculation(expression: String, value: Double)
        case translation(Translation)
        case definition(word: String, text: String)
        case output(String)
        case message(String)
    }

    enum Translation: Equatable {
        case working(target: String)
        case done(OnDeviceTranslator.Output)
        case failed(String, offerSettings: Bool)
    }

    var title: String
    var symbol: String
    var tint: Tint
    var content: Content
    /// The selection can be replaced (offers Replace).
    var canReplace: Bool
    var isError = false

    /// The text the Copy button copies, if any.
    var copyText: String? {
        switch content {
        case .calculation(_, let value): ArithmeticEvaluator.canonical(value)
        case .translation(.done(let output)): output.text
        case .definition(_, let text): text
        case .output(let text): text.isEmpty ? nil : text
        case .stats, .translation, .message: nil
        }
    }
}

/// What a card button asks for.
enum CardAction: Equatable {
    case copy(String)
    case replace(String)
    case openDictionary(String)
    case openLanguageSettings
    case close
}

/// State of the bar (or card) on screen.
@MainActor
@Observable
final class BarModel {
    /// Every action that fits the selection, in order.
    var items: [BarItem] = []
    var page: BarPage = .main
    var visibleCount = 7
    var style: TextActionsSettings.LabelStyle = .icons
    var scale: CGFloat = 1
    /// Opened with the shortcut: arrows, Return and Esc drive the bar.
    var keyboardMode = false
    /// Keyboard selection, an index into `current`.
    var highlighted: Int?
    /// Pointer hover, an index into `current`.
    var hovered: Int?
    /// A custom action running.
    var busyID: String?
    /// A button showing a checkmark before the bar closes, and the caption that goes with it.
    var doneID: String?
    var doneCaption: String?
    var card: ResultCard?
    /// The card's Copy button confirmed.
    var cardCopied = false
    /// Drives the appear and disappear animation.
    var isShown = false
    /// The bar sits below its selection: the caption goes underneath and it grows downward.
    var below = false
    /// Reserve room for the caption (off in the settings preview).
    var showsCaption = true

    @ObservationIgnored var onActivate: ((BarItem) -> Void)?
    @ObservationIgnored var onCardAction: ((CardAction) -> Void)?
    /// Button frames in the panel's top-left coordinates, for hover tracking.
    @ObservationIgnored var itemFrames: [Int: CGRect] = [:]

    var current: [BarItem] { BarItems.page(page, of: items, visibleCount: visibleCount) }

    /// The item named by the caption: the keyboard selection, else the hovered one.
    var captionItem: BarItem? {
        let list = current
        guard let i = keyboardMode ? (highlighted ?? hovered) : hovered, list.indices.contains(i) else { return nil }
        return list[i]
    }

    /// Whether a caption band is laid out next to the capsule.
    var hasCaptionBand: Bool { showsCaption && (style == .icons || current.contains { $0.face != nil }) }

    func pointerMoved(to point: CGPoint) {
        let hit = itemFrames.first { $0.value.insetBy(dx: -1, dy: -3).contains(point) }?.key
        if hit != hovered { hovered = hit }
    }

    func pointerExited() {
        if hovered != nil { hovered = nil }
    }

    func reset(items: [BarItem], settings: TextActionsSettings, keyboard: Bool) {
        self.items = items
        page = .main
        visibleCount = settings.visibleCount
        style = settings.labelStyle
        scale = settings.size.scale
        keyboardMode = keyboard
        highlighted = keyboard ? 0 : nil
        hovered = nil
        busyID = nil
        doneID = nil
        doneCaption = nil
        card = nil
        cardCopied = false
        itemFrames = [:]
    }

    func setPage(_ page: BarPage) {
        self.page = page
        itemFrames = [:]
        hovered = nil
        highlighted = keyboardMode ? (page == .main ? 0 : min(1, current.count - 1)) : nil
    }

    /// Moves the keyboard selection, wrapping around.
    func move(_ delta: Int) {
        let count = current.count
        guard count > 0 else { return }
        let start = highlighted ?? (delta > 0 ? -1 : count)
        highlighted = ((start + delta) % count + count) % count
    }
}

/// Sizes shared by the bar's views.
enum BarMetrics {
    /// Transparent room around the capsule for its shadow.
    static let margin: CGFloat = 12
    static let captionHeight: CGFloat = 22
    static let captionSpacing: CGFloat = 5
    static let buttonHeight: CGFloat = 30
    static let iconWidth: CGFloat = 34
    static let chevronWidth: CGFloat = 24
    static let cardWidth: CGFloat = 320
}
