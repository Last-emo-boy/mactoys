import AppKit
import MacToysCore
import Observation

/// The history the panel works on: the live `ClipboardHistory`, or sample entries in previews.
@MainActor
protocol ClipHistoryStore: AnyObject {
    var items: [ClipItem] { get }
    var isPaused: Bool { get }
    func delete(ids: Set<UUID>)
    func update(_ item: ClipItem)
    func add(_ item: ClipItem)
    func togglePin(_ item: ClipItem)
    func clear()
}

extension ClipboardHistory: ClipHistoryStore {}

/// In-memory history for preview scenes and tests.
@MainActor
@Observable
final class SampleHistory: ClipHistoryStore {
    var items: [ClipItem]
    var isPaused = false

    init(_ items: [ClipItem]) { self.items = items }

    func delete(ids: Set<UUID>) { items.removeAll { ids.contains($0.id) } }
    func update(_ item: ClipItem) {
        if let i = items.firstIndex(where: { $0.id == item.id }) { items[i] = item }
    }
    func add(_ item: ClipItem) {
        items.removeAll { $0.id == item.id }
        items.insert(item, at: 0)
    }
    func togglePin(_ item: ClipItem) {
        if let i = items.firstIndex(where: { $0.id == item.id }) { items[i].pinned.toggle() }
    }
    func clear() { items.removeAll { !$0.pinned } }
}

/// What the panel asks of the app: pasting, copying, the paste stack, settings.
@MainActor
protocol ClipboardPanelHost: AnyObject {
    func paste(_ item: ClipItem, plain: Bool, original: ClipItem?)
    func copy(_ item: ClipItem, plain: Bool)
    func pasteSnippet(_ snippet: Snippet, plain: Bool, copyOnly: Bool)
    func addToStack(_ items: [ClipItem])
    func open(_ url: URL)
    func reveal(_ urls: [URL])
    func closePanel()
    func openSettings()
}

/// Joins several entries into one: texts with a separator, or the files of file entries.
enum ClipMerge {
    static func merge(_ items: [ClipItem], separator: String) -> ClipItem? {
        guard items.count >= 2 else { return nil }
        if items.allSatisfy({ $0.kind == .files }) {
            var seen = Set<URL>()
            let files = items.flatMap(\.files).filter { seen.insert($0).inserted }
            return ClipItem(kind: .files, text: files.map(\.path).joined(separator: "\n"), files: files)
        }
        let texts = items.compactMap(\.plainText).filter { !$0.isEmpty }
        guard texts.count >= 2 else { return nil }
        return ClipItem(kind: .text, text: texts.joined(separator: separator))
    }
}

/// State of the clipboard panel or paste bar while it is open.
@MainActor
@Observable
final class ClipboardPanelModel {
    enum Source: Hashable {
        case history
        case pinboard(UUID)
        case snippets
    }

    struct Row: Identifiable, Equatable {
        enum Content: Equatable {
            case clip(ClipItem)
            case snippet(Snippet)
        }

        let content: Content
        /// ⌘1…⌘9.
        var number: Int?

        var id: String {
            switch content {
            case .clip(let c): "clip:\(c.id.uuidString)"
            case .snippet(let s): "snippet:\(s.id.uuidString)"
            }
        }

        var clip: ClipItem? { if case .clip(let c) = content { c } else { nil } }
        var snippet: Snippet? { if case .snippet(let s) = content { s } else { nil } }
    }

    /// Overlays that take the keyboard from the list.
    enum Mode: Equatable {
        case browse
        case actions
        case editing(UUID, String)
        case renaming(UUID, String)
        case newPinboard(String, Tint)
        case confirmClear
    }

    struct Command: Identifiable {
        enum Kind: Equatable {
            case paste, pastePlain, copy, togglePin, edit, rename, merge, addToStack, saveAsSnippet
            case addToPinboard(UUID), addToNewPinboard, removeFromPinboard
            case openLink, reveal, delete, clearHistory, settings
        }

        let kind: Kind
        let title: String
        let symbol: String
        var keys: [String] = []
        var destructive = false
        var id: String { "\(kind)" }
    }

    let history: any ClipHistoryStore
    let library: ClipLibrary
    var settings: ClipboardSettings
    weak var host: ClipboardPanelHost?
    var now: () -> Date = Date.init
    /// Items waiting in the paste stack (footer).
    var stackCount = 0

    var query = "" {
        didSet { if query != oldValue { refresh(resetSelection: true) } }
    }
    var source: Source = .history {
        didSet {
            guard source != oldValue else { return }
            marked = []
            refresh(resetSelection: true)
        }
    }
    var filter = ClipFilter() {
        didSet { if filter != oldValue { refresh(resetSelection: true) } }
    }

    private(set) var rows: [Row] = []
    var selection = 0
    /// Rows picked with ⇧ or ⌘ for merge, delete, pinboards and the paste stack.
    var marked: Set<String> = []
    var mode: Mode = .browse
    var actionSelection = 0
    /// Bumped to move the keyboard back to the search field.
    var focusRequest = 0
    /// The entry being dragged, so a pinboard chip knows what was dropped on it.
    @ObservationIgnored var dragging: ClipItem?
    @ObservationIgnored private var observing = false

    init(history: any ClipHistoryStore, library: ClipLibrary, settings: ClipboardSettings) {
        self.history = history
        self.library = library
        self.settings = settings
        refresh(resetSelection: true)
    }

    // MARK: Data

    /// Re-reads the history and library whenever they change, while the panel is open.
    func startObserving() {
        guard !observing else { return }
        observing = true
        track()
    }

    func stopObserving() { observing = false }

    private func track() {
        withObservationTracking {
            _ = history.items
            _ = library.pinboards
            _ = library.snippets
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.observing else { return }
                    self.refresh()
                    self.track()
                }
            }
        }
    }

    /// Every source in strip order: History, the pinboards, Snippets.
    var sources: [Source] { [.history] + library.pinboards.map { .pinboard($0.id) } + [.snippets] }

    func refresh(resetSelection: Bool = false) {
        let keep = resetSelection ? nil : selectedRow?.id
        var list: [Row] = []
        let date = now()
        switch source {
        case .history:
            if !query.trimmingCharacters(in: .whitespaces).isEmpty, !filter.isActive {
                list += ClipSearch.snippets(library.snippets, query: query).prefix(3).map { Row(content: .snippet($0)) }
            }
            list += ClipSearch.results(history.items, query: query, filter: filter, now: date).map { Row(content: .clip($0)) }
        case .pinboard(let id):
            guard let board = library.pinboard(id) else { source = .history; return }
            list = ClipSearch.results(board.items, query: query, filter: filter, now: date).map { Row(content: .clip($0)) }
        case .snippets:
            list = ClipSearch.snippets(library.snippets, query: query).map { Row(content: .snippet($0)) }
        }
        for i in list.indices where i < 9 { list[i].number = i + 1 }
        rows = list
        if let keep, let index = list.firstIndex(where: { $0.id == keep }) {
            selection = index
        } else {
            selection = resetSelection ? 0 : min(selection, max(0, list.count - 1))
        }
        let ids = Set(list.map(\.id))
        marked.formIntersection(ids)
    }

    var selectedRow: Row? { rows.indices.contains(selection) ? rows[selection] : nil }

    /// The marked rows in list order, or the selected one.
    var targetRows: [Row] {
        if marked.count > 1 { return rows.filter { marked.contains($0.id) } }
        return selectedRow.map { [$0] } ?? []
    }

    var targetClips: [ClipItem] { targetRows.compactMap(\.clip) }

    var pinboardID: UUID? { if case .pinboard(let id) = source { id } else { nil } }

    /// Title of the current source, for the bar and empty states.
    func title(of source: Source) -> String {
        switch source {
        case .history: String(localized: "History", comment: "Clipboard panel source: everything copied recently")
        case .pinboard(let id): library.pinboard(id)?.name ?? ""
        case .snippets: String(localized: "Snippets", comment: "Clipboard panel source: saved text snippets")
        }
    }

    // MARK: Selection

    func move(_ delta: Int, extend: Bool = false) {
        guard !rows.isEmpty else { return }
        let from = selection
        let to = min(max(selection + delta, 0), rows.count - 1)
        if extend {
            marked.insert(rows[from].id)
            marked.insert(rows[to].id)
        } else {
            marked = []
        }
        selection = to
    }

    func select(_ index: Int, toggle: Bool = false, extend: Bool = false) {
        guard rows.indices.contains(index) else { return }
        if toggle {
            if marked.isEmpty, let current = selectedRow { marked.insert(current.id) }
            let id = rows[index].id
            if marked.contains(id) { marked.remove(id) } else { marked.insert(id) }
        } else if extend {
            let range = min(selection, index)...max(selection, index)
            marked = Set(range.map { rows[$0].id })
        } else {
            marked = []
        }
        selection = index
    }

    func cycleSource(_ delta: Int) {
        let all = sources
        let i = all.firstIndex(of: source) ?? 0
        source = all[(i + delta + all.count) % all.count]
    }

    // MARK: Commands

    func commands(for row: Row?) -> [Command] {
        guard let row else { return source == .history ? [clearCommand] : [] }
        let pasteTitle = settings.returnAction == .paste ? String(localized: "Paste", comment: "Clipboard panel action")
            : String(localized: "Paste into the previous app", comment: "Clipboard panel action when Return only copies")
        if let snippet = row.snippet {
            return [
                Command(kind: .paste, title: pasteTitle, symbol: "doc.on.clipboard", keys: settings.returnAction == .paste ? ["↩"] : []),
                Command(kind: .pastePlain, title: String(localized: "Paste as Plain Text"), symbol: "textformat", keys: ["⇧", "↩"]),
                Command(kind: .copy, title: String(localized: "Copy", comment: "Clipboard panel action: copy without pasting"),
                        symbol: "doc.on.doc", keys: ["⌘", "C"]),
                Command(kind: .settings, title: String(localized: "Edit Snippets in Settings…"), symbol: "square.and.pencil"),
                Command(kind: .delete, title: String(localized: "Delete Snippet"), symbol: "trash", keys: ["⌘", "⌫"], destructive: true),
            ].filter { $0.kind != .pastePlain || !snippet.text.isEmpty }
        }
        guard let clip = row.clip else { return [] }
        let multiple = targetClips.count > 1
        var list: [Command] = [
            Command(kind: .paste, title: multiple ? String(localized: "Paste Merged") : pasteTitle, symbol: "doc.on.clipboard",
                    keys: settings.returnAction == .paste ? ["↩"] : []),
        ]
        if clip.plainText != nil, clip.kind != .text || multiple {
            list.append(Command(kind: .pastePlain, title: String(localized: "Paste as Plain Text"), symbol: "textformat", keys: ["⇧", "↩"]))
        }
        list.append(Command(kind: .copy, title: String(localized: "Copy", comment: "Clipboard panel action: copy without pasting"),
                            symbol: "doc.on.doc", keys: ["⌘", "C"]))
        if multiple {
            list.append(Command(kind: .merge, title: String(localized: "Merge \(targetClips.count) Items"),
                                symbol: "arrow.triangle.merge", keys: ["⌘", "M"]))
        }
        if source == .history {
            list.append(clip.pinned
                ? Command(kind: .togglePin, title: String(localized: "Unpin"), symbol: "pin.slash", keys: ["⌘", "P"])
                : Command(kind: .togglePin, title: String(localized: "Pin", comment: "Clipboard panel action: keep this entry forever"),
                          symbol: "pin", keys: ["⌘", "P"]))
        }
        if !multiple {
            if clip.hasText {
                list.append(Command(kind: .edit, title: String(localized: "Edit Text…"), symbol: "square.and.pencil", keys: ["⌘", "E"]))
            }
            list.append(Command(kind: .rename, title: String(localized: "Rename…"), symbol: "character.cursor.ibeam", keys: ["⌘", "R"]))
        }
        for board in library.pinboards where board.id != pinboardID {
            list.append(Command(kind: .addToPinboard(board.id), title: String(localized: "Add to “\(board.name)”",
                                                                              comment: "Clipboard panel action; %@ is a pinboard name"),
                                symbol: "pin.square"))
        }
        list.append(Command(kind: .addToNewPinboard, title: String(localized: "Add to New Pinboard…"), symbol: "plus.square.on.square"))
        if pinboardID != nil {
            list.append(Command(kind: .removeFromPinboard, title: String(localized: "Remove from Pinboard"), symbol: "pin.square.fill"))
        }
        list.append(Command(kind: .addToStack, title: String(localized: "Add to Paste Stack"), symbol: "square.stack.3d.up"))
        if !multiple, clip.hasText {
            list.append(Command(kind: .saveAsSnippet, title: String(localized: "Save as Snippet"), symbol: "text.badge.plus"))
        }
        if !multiple, clip.kind != .files, ClipText.link(in: clip.text ?? "") != nil {
            list.append(Command(kind: .openLink, title: String(localized: "Open Link"), symbol: "safari"))
        }
        if clip.kind == .files {
            list.append(Command(kind: .reveal, title: String(localized: "Show in Finder"), symbol: "folder"))
        }
        if pinboardID == nil {
            list.append(Command(kind: .delete, title: multiple ? String(localized: "Delete \(targetClips.count) Items")
                                    : String(localized: "Delete", comment: "Clipboard panel action: remove the entry from the history"),
                                symbol: "trash", keys: ["⌘", "⌫"], destructive: true))
        }
        if source == .history { list.append(clearCommand) }
        return list
    }

    private var clearCommand: Command {
        Command(kind: .clearHistory, title: String(localized: "Clear History…"), symbol: "trash.slash", destructive: true)
    }

    /// Return: the primary action.
    func activate(plain: Bool = false) {
        perform(settings.returnAction == .paste || plain ? (plain ? .pastePlain : .paste) : .copy)
    }

    func perform(_ kind: Command.Kind) {
        if mode == .actions { mode = .browse }
        let rows = targetRows
        let clips = rows.compactMap(\.clip)
        switch kind {
        case .paste, .pastePlain, .copy:
            let plain = kind == .pastePlain
            if let snippet = rows.first?.snippet {
                host?.pasteSnippet(snippet, plain: plain, copyOnly: kind == .copy)
                return
            }
            let content = clips.count > 1 ? ClipMerge.merge(clips, separator: settings.mergeSeparator.string) : clips.first
            guard let content else { return }
            if kind == .copy { host?.copy(content, plain: plain) } else {
                host?.paste(content, plain: plain, original: clips.count == 1 && source == .history ? clips[0] : nil)
            }
        case .togglePin:
            guard source == .history else { return }
            let pin = clips.contains { !$0.pinned }
            for clip in clips where clip.pinned != pin { history.togglePin(clip) }
        case .edit:
            guard let clip = clips.first, clip.hasText else { return }
            mode = .editing(clip.id, clip.text ?? "")
        case .rename:
            guard let clip = clips.first else { return }
            mode = .renaming(clip.id, clip.name ?? "")
        case .merge:
            guard let merged = ClipMerge.merge(clips, separator: settings.mergeSeparator.string) else { return }
            var item = merged
            item.date = now()
            if let board = pinboardID { library.add([item], to: board) } else { history.add(item) }
            marked = []
            refresh()
            if let index = self.rows.firstIndex(where: { $0.clip?.hasSameContent(as: item) == true }) { selection = index }
        case .addToPinboard(let id):
            library.add(clips, to: id)
            HUD.show(String(localized: "Added to “\(library.pinboard(id)?.name ?? "")”",
                            comment: "Notice; %@ is a pinboard name"), symbol: "pin.square.fill")
        case .addToNewPinboard:
            mode = .newPinboard("", Pinboard.tints[library.pinboards.count % Pinboard.tints.count])
        case .removeFromPinboard:
            guard let board = pinboardID else { return }
            library.remove(Set(clips.map(\.id)), from: board)
        case .addToStack:
            host?.addToStack(clips.sorted { $0.date < $1.date })
        case .saveAsSnippet:
            guard let clip = clips.first, let text = clip.text else { return }
            let name = clip.name ?? String(ClipText.firstLine(text, limit: 40))
            library.addSnippet(Snippet(name: name, text: text))
            HUD.show("Saved as a snippet", symbol: "text.badge.plus")
        case .openLink:
            if let text = clips.first?.text, let url = ClipText.link(in: text) { host?.open(url) }
        case .reveal:
            host?.reveal(clips.flatMap(\.files))
        case .delete:
            if source == .snippets || rows.first?.snippet != nil {
                for row in rows { if let s = row.snippet { library.deleteSnippet(s.id) } }
            } else if let board = pinboardID {
                library.remove(Set(clips.map(\.id)), from: board)
            } else {
                history.delete(ids: Set(clips.map(\.id)))
            }
            marked = []
        case .clearHistory:
            mode = .confirmClear
        case .settings:
            host?.openSettings()
        }
    }

    // MARK: Sheets

    func commitSheet() {
        switch mode {
        case .editing(let id, let draft):
            if var item = clip(id) {
                item.text = draft
                if item.kind == .html || item.kind == .richText {
                    item.kind = .text
                    item.html = nil
                    item.rtf = nil
                }
                store(item)
            }
        case .renaming(let id, let draft):
            if var item = clip(id) {
                let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                item.name = name.isEmpty ? nil : name
                store(item)
            }
        case .newPinboard(let draft, let tint):
            let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            let clips = targetClips
            let board = library.createPinboard(name: name, tint: tint)
            if !clips.isEmpty { library.add(clips, to: board.id) }
        case .confirmClear:
            history.clear()
        case .browse, .actions:
            return
        }
        mode = .browse
        focusRequest += 1
    }

    func cancelSheet() {
        mode = .browse
        focusRequest += 1
    }

    private func clip(_ id: UUID) -> ClipItem? {
        rows.lazy.compactMap(\.clip).first { $0.id == id }
    }

    private func store(_ item: ClipItem) {
        if let board = pinboardID { library.update(item, in: board) } else { history.update(item) }
    }

    // MARK: Actions menu

    func toggleActions() {
        if mode == .actions { mode = .browse; return }
        guard mode == .browse, !commands(for: selectedRow).isEmpty else { return }
        actionSelection = 0
        mode = .actions
    }

    func moveAction(_ delta: Int) {
        let count = commands(for: selectedRow).count
        guard count > 0 else { return }
        actionSelection = (actionSelection + delta + count) % count
    }

    func runSelectedAction() {
        let list = commands(for: selectedRow)
        guard list.indices.contains(actionSelection) else { return }
        perform(list[actionSelection].kind)
    }
}
