import AppKit
import MacToysCore

/// Clipboard history: browse, paste, pin and delete recent clipboard entries.
@MainActor
final class ClipboardProvider: SearchProvider {
    let id = "clipboard"
    let name = "Clipboard History"
    let summary = "Browse and paste recent clipboard entries"
    let icon = ItemIcon.symbol("doc.on.clipboard.fill", .purple)
    let defaultKeyword = "cb"
    let globalByDefault = false
    let examples = ["cb", "cb invoice"]

    private let engine: LauncherEngine
    private var history: ClipboardHistory { ClipboardHistory.shared }

    init(engine: LauncherEngine) { self.engine = engine }

    var commands: [PaletteItem] {
        [pageCommand(title: "Clipboard History", subtitle: "Paste something you copied earlier",
                     keywords: ["clipboard", "paste", "copy history", "pasteboard"])]
    }

    func search(_ query: SearchQuery) async -> [PaletteItem] {
        let text = query.text.trimmingCharacters(in: .whitespaces)
        if !query.scoped {
            guard engine.options.value.clipboardInGlobalResults, text.count >= 3 else { return [] }
        }
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
        case .text: (kindName, symbol) = ("Text", "doc.text")
        case .richText: (kindName, symbol) = ("Rich text", "doc.richtext")
        case .html: (kindName, symbol) = ("HTML", "chevron.left.forwardslash.chevron.right")
        case .image: (kindName, symbol) = ("Image", "photo")
        case .files: (kindName, symbol) = (clip.files.count == 1 ? "File" : "Files", "doc.on.doc")
        }
        var subtitleParts = [kindName, Self.relative.localizedString(for: clip.date, relativeTo: Date())]
        if let app = clip.sourceApp { subtitleParts.append(app) }
        if clip.pinned { subtitleParts.insert("Pinned", at: 0) }
        let icon: ItemIcon = clip.kind == .files && clip.files.count == 1 ? .file(clip.files[0].path) : .symbol(symbol, .purple)
        let pasteOnEnter = engine.options.value.clipboardPasteOnEnter
        let paste = PaletteAction(id: "paste", title: "Paste", symbol: "doc.on.clipboard") {
            self.history.restore(clip)
            return Launch.pasteCurrentClipboard()
        }
        let copy = PaletteAction(id: "copy", title: "Copy to Clipboard", symbol: "doc.on.doc", shortcut: ActionKeys.copy) {
            self.history.restore(clip)
            HUD.show("Copied", symbol: "doc.on.doc")
            return .dismiss
        }
        var actions = [pasteOnEnter ? copy : paste]
        if let text = clip.text, clip.kind != .text {
            actions.append(PaletteAction(id: "plain", title: "Paste as Plain Text", symbol: "textformat", shortcut: ActionKeys.paste) {
                Launch.pasteOutcome(text)
            })
        }
        actions.append(PaletteAction(id: "pin", title: clip.pinned ? "Unpin Entry" : "Pin Entry", symbol: clip.pinned ? "pin.slash" : "pin",
                                     recordsUsage: false) {
            self.history.togglePin(clip)
            return .refresh
        })
        actions.append(PaletteAction(id: "delete", title: "Delete Entry", symbol: "trash", shortcut: ActionKeys.trash,
                                     destructive: true, recordsUsage: false) {
            self.history.delete(clip)
            return .refresh
        })
        actions.append(PaletteAction(id: "clear", title: "Clear History…", symbol: "trash.slash", destructive: true, recordsUsage: false) {
            .confirm(Confirmation(title: "Clear clipboard history?", message: "Pinned entries are kept.", confirmTitle: "Clear") {
                self.history.clear()
                return .refresh
            })
        })

        var details = ItemDetails(icon: icon, title: kindName, subtitle: subtitleParts.dropFirst(clip.pinned ? 2 : 1).joined(separator: " · "))
        switch clip.kind {
        case .image:
            details.image = clip.image.flatMap(NSImage.init(data:))
            if let img = details.image {
                details.rows = [DetailRow(label: "Size", value: "\(Int(img.size.width)) × \(Int(img.size.height))")]
            }
        case .files:
            details.rows = clip.files.prefix(12).map { DetailRow(label: $0.lastPathComponent, value: $0.deletingLastPathComponent().path, monospaced: false) }
            if clip.files.count == 1 { details.previewFile = clip.files[0] }
        default:
            let text = clip.text ?? ""
            details.body = String(text.prefix(20_000))
            details.rows = [DetailRow(label: "Characters", value: String(text.count)),
                            DetailRow(label: "Words", value: String(text.split(whereSeparator: \.isWhitespace).count)),
                            DetailRow(label: "Lines", value: String(text.split(separator: "\n", omittingEmptySubsequences: false).count))]
        }
        let title = clip.kind == .image ? "Image" : String(clip.title.prefix(200))
        return PaletteItem(
            id: "clipboard:\(clip.id.uuidString)", title: title.isEmpty ? "(empty)" : title,
            subtitle: subtitleParts.joined(separator: " · "), icon: icon, providerID: id,
            section: clip.pinned ? "Pinned" : "Recent", accessory: pasteOnEnter ? "Paste" : "Copy", score: score,
            primary: pasteOnEnter ? paste : copy, actions: actions, details: details, isPinnable: false)
    }
}
