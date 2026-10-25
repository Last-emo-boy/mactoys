import AppKit
import MacToysCore

/// A source of results shared by Command Palette and Run (a PowerToys "plugin" or "extension").
@MainActor
protocol SearchProvider: AnyObject {
    /// Stable id; also the prefix of every item id it produces (`apps:…`).
    var id: String { get }
    var name: String { get }
    var summary: String { get }
    var icon: ItemIcon { get }
    /// Run's default direct activation command (`=`, `>`, `//`); empty for none.
    var defaultKeyword: String { get }
    /// Whether results appear in global (keyword-less) searches by default.
    var globalByDefault: Bool { get }
    var enabledByDefault: Bool { get }
    /// Example queries for Run's `?` help.
    var examples: [String] { get }

    /// Results for a query. Called on the main actor; heavy work must hop off it and return quickly
    /// when cancelled.
    func search(_ query: SearchQuery) async -> [PaletteItem]
    /// Rebuilds an item from its id (pins, hotkeys, aliases, history, command links).
    func resolve(_ id: String) -> PaletteItem?
    /// Top-level commands for the palette home and its command search ("Clipboard History").
    var commands: [PaletteItem] { get }
    /// Called when the first launcher using the engine starts / the last one stops.
    func activate()
    func deactivate()
    /// Called each time a launcher opens (refresh caches cheaply).
    func launcherWillShow()
    /// Called after the shared provider options changed, while the engine is active.
    func optionsChanged()
}

extension SearchProvider {
    var globalByDefault: Bool { true }
    var enabledByDefault: Bool { true }
    var examples: [String] { [] }
    func resolve(_ id: String) -> PaletteItem? { commands.first { $0.id == id } }
    var commands: [PaletteItem] { [] }
    func activate() {}
    func deactivate() {}
    func launcherWillShow() {}
    func optionsChanged() {}

    /// The page that searches only this provider (for commands, filters and aliases).
    var page: ListPage {
        ListPage(id: "\(id):page", title: name, placeholder: String(localized: "Search \(name)…", comment: "Search field placeholder; %@ is a provider name such as “Calculator”"),
                 icon: icon) { [weak self] text in
            guard let self else { return [] }
            return await self.search(SearchQuery(text: text, scoped: true, frontEnd: .palette))
        }
    }

    /// A top-level command that opens this provider's page. The title's English text stays searchable.
    func pageCommand(title: Phrase, subtitle: String? = nil, keywords: [String] = [],
                     page: ListPage? = nil) -> PaletteItem {
        let target = page ?? self.page
        return PaletteItem(
            id: target.id, title: title.text, subtitle: subtitle ?? summary, icon: icon, providerID: id,
            section: Labels.commands, accessory: Labels.command,
            primary: PaletteAction(id: "open", title: Labels.open, symbol: "arrow.right.circle") { .push(target) },
            keywords: title.englishTerms + keywords)
    }
}

/// A built-in title in the UI language, with its English source kept so that searches typed in
/// English still match after it is translated. String literals are extracted into the catalog.
struct Phrase: Hashable, Sendable {
    let text: String
    let english: String

    init(_ resource: LocalizedStringResource) {
        text = String(localized: resource)
        // No table has this name, so the lookup falls back to the source (English) text.
        english = String(localized: resource.defaultValue, table: "EnglishSource")
    }

    /// The English text when it differs from the shown one: extra search keywords.
    var englishTerms: [String] { english == text ? [] : [english] }
}

/// Fuzzy-filters items by title, subtitle and keywords; for providers with a fixed list.
@MainActor
func fuzzyFilter(_ items: [PaletteItem], _ text: String, includeSubtitle: Bool = false) -> [PaletteItem] {
    let q = text.trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty else { return items }
    return items.compactMap { item in
        let extra = item.keywords + (includeSubtitle ? [item.subtitle] : [])
        guard let s = FuzzyMatcher.best(q, title: item.title, keywords: extra) else { return nil }
        var copy = item
        copy.score = s
        return copy
    }
    .sorted { $0.score > $1.score }
}

/// Runs blocking work off the main actor.
func background<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await Task.detached(priority: .userInitiated) { work() }.value
}
