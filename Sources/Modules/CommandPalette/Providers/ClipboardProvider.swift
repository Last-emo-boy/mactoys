import AppKit
import MacToysCore

/// Clipboard history: browse, paste, pin and delete recent clipboard entries.
@MainActor
final class ClipboardProvider: SearchProvider {
    let id = "clipboard"
    let name = String(localized: "Clipboard History")
    let summary = String(localized: "Browse and paste recent clipboard entries")
    let icon = ItemIcon.symbol("doc.on.clipboard.fill", .purple)
    let defaultKeyword = "cb"
    let globalByDefault = false
    let examples = ["cb", "cb invoice"]

    private let engine: LauncherEngine
    private var history: ClipboardHistory { ClipboardHistory.shared }

    init(engine: LauncherEngine) { self.engine = engine }

    var commands: [PaletteItem] {
        [pageCommand(title: Phrase("Clipboard History"), subtitle: String(localized: "Paste something you copied earlier"),
                     keywords: ["clipboard", "paste", "copy history", "pasteboard"])]
    }

    func search(_ query: SearchQuery) async -> [PaletteItem] {
        let text = query.text.trimmingCharacters(in: .whitespaces)
        if !query.scoped { guard text.count >= 3 else { return [] } }
        let items = history.items
        if text.isEmpty {
            return items.enumerated().map { i, clip in item(clip, score: 1000 - Double(i)) }
        }
        return items.enumerated().compactMap { i, clip in
            let haystack = clip.title
            guard let s = FuzzyMatcher.score(text, String(haystack.prefix(300))) ?? (haystack.localizedCaseInsensitiveContains(text) ? 500 : nil)
            else { return nil }
            return item(clip, score: (query.scoped ? s : s * 0.7) - Double(i) * 0.01)
        }
    }

    func resolve(_ id: String) -> PaletteItem? {
        commands.first { $0.id == id }
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    func item(_ clip: ClipItem, score: Double) -> PaletteItem {
        let kindName: String
        let symbol: String
        switch clip.kind {
        case .text: (kindName, symbol) = (String(localized: "Text", comment: "Clipboard entry kind"), "doc.text")
        case .richText: (kindName, symbol) = (String(localized: "Rich text", comment: "Clipboard entry kind"), "doc.richtext")
        case .html: (kindName, symbol) = ("HTML", "chevron.left.forwardslash.chevron.right")
        case .image: (kindName, symbol) = (String(localized: "Image", comment: "Clipboard entry kind"), "photo")
        case .files:
            (kindName, symbol) = (clip.files.count == 1 ? Labels.file : String(localized: "Files", comment: "Provider name: file search; also the kind of a clipboard entry with several files"),
                                  "doc.on.doc")
        }
        var subtitleParts = [kindName, Self.relative.localizedString(for: clip.date, relativeTo: Date())]
        if let app = clip.sourceApp { subtitleParts.append(app) }
        if clip.pinned { subtitleParts.insert(Labels.pinned, at: 0) }
        let icon: ItemIcon = clip.kind == .files && clip.files.count == 1 ? .file(clip.files[0].path) : .symbol(symbol, .purple)
        let pasteOnEnter = engine.options.value.clipboardPasteOnEnter
        let paste = PaletteAction(id: "paste", title: Labels.paste, symbol: "doc.on.clipboard") {
            self.history.restore(clip)
            return Launch.pasteCurrentClipboard()
        }
        let copy = PaletteAction(id: "copy", title: String(localized: "Copy to Clipboard"), symbol: "doc.on.doc", shortcut: ActionKeys.copy) {
            self.history.restore(clip)
            HUD.show("Copied", symbol: "doc.on.doc")
            return .dismiss
        }
        var actions = [pasteOnEnter ? copy : paste]
        if let text = clip.text, clip.kind != .text {
            actions.append(PaletteAction(id: "plain", title: String(localized: "Paste as Plain Text"), symbol: "textformat",
                                         shortcut: ActionKeys.paste) {
                Launch.pasteOutcome(text)
            })
        }
        actions.append(PaletteAction(id: "pin", title: clip.pinned ? String(localized: "Unpin Entry") : String(localized: "Pin Entry"),
                                     symbol: clip.pinned ? "pin.slash" : "pin",
                                     recordsUsage: false) {
            self.history.togglePin(clip)
            return .refresh
        })
        actions.append(PaletteAction(id: "delete", title: String(localized: "Delete Entry"), symbol: "trash", shortcut: ActionKeys.trash,
                                     destructive: true, recordsUsage: false) {
            self.history.delete(clip)
            return .refresh
        })
        actions.append(PaletteAction(id: "clear", title: String(localized: "Clear History…"), symbol: "trash.slash", destructive: true,
                                     recordsUsage: false) {
            .confirm(Confirmation(title: String(localized: "Clear clipboard history?"), message: String(localized: "Pinned entries are kept."),
                                  confirmTitle: String(localized: "Clear", comment: "Confirmation button: delete the clipboard history")) {
                self.history.clear()
                return .refresh
            })
        })

        var details = ItemDetails(icon: icon, title: kindName, subtitle: subtitleParts.dropFirst(clip.pinned ? 2 : 1).joined(separator: " · "))
        switch clip.kind {
        case .image:
            details.image = clip.image.flatMap(NSImage.init(data:))
            if let img = details.image {
                details.rows = [DetailRow(label: Labels.size, value: "\(Int(img.size.width)) × \(Int(img.size.height))")]
            }
        case .files:
            details.rows = clip.files.prefix(12).map { DetailRow(label: $0.lastPathComponent, value: $0.deletingLastPathComponent().path, monospaced: false) }
            if clip.files.count == 1 { details.previewFile = clip.files[0] }
        default:
            let text = clip.text ?? ""
            details.body = String(text.prefix(20_000))
            details.rows = [DetailRow(label: String(localized: "Characters", comment: "Detail row: character count"), value: text.count.formatted()),
                            DetailRow(label: String(localized: "Words", comment: "Detail row: word count"),
                                      value: text.split(whereSeparator: \.isWhitespace).count.formatted()),
                            DetailRow(label: String(localized: "Lines", comment: "Detail row: line count"),
                                      value: text.split(separator: "\n", omittingEmptySubsequences: false).count.formatted())]
        }
        let title = clip.kind == .image ? kindName : String(clip.title.prefix(200))
        return PaletteItem(
            id: "clipboard:\(clip.id.uuidString)",
            title: title.isEmpty ? String(localized: "(empty)", comment: "A clipboard entry without text") : title,
            subtitle: subtitleParts.joined(separator: " · "), icon: icon, providerID: id,
            section: clip.pinned ? Labels.pinned : Labels.recent, accessory: pasteOnEnter ? Labels.paste : Labels.copy, score: score,
            primary: pasteOnEnter ? paste : copy, actions: actions, details: details, isPinnable: false)
    }
}
