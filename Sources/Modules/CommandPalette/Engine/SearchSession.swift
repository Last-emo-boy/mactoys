import AppKit
import MacToysCore

/// A titled group of results.
struct ResultSection: Identifiable {
    let id: String
    let title: String
    var items: [PaletteItem]
}

/// Runs one search across several providers and merges their results as they arrive.
///
/// Results of the previous query stay on screen until each provider answers the new one (or a
/// short grace period passes), so fast typing doesn't make the list flicker; slow providers
/// (Spotlight, windows, Homebrew) append when ready. Duplicates (same id from two sources) keep
/// the higher score; usage boosts frequently picked items.
@MainActor
final class SearchSession {
    struct Source {
        let provider: any SearchProvider
        let query: SearchQuery
    }

    enum Layout {
        /// Command Palette: sections by provider, ordered by their best match.
        case sections(maxPerSection: Int)
        /// Run: one list ordered by score.
        case flat(limit: Int)
    }

    var layout: Layout
    /// Multiplier for usage boosts (0 disables, for pages with their own order).
    var boostWeight: Double = 1
    /// Section title for an item without its own (`item.section`).
    var sectionTitle: (PaletteItem) -> String = { _ in "" }
    /// Called with the merged sections and whether some providers are still working.
    var onUpdate: (([ResultSection], Bool) -> Void)?

    private let usage: UsageStore
    private var results: [String: [PaletteItem]] = [:]
    private var answered: Set<String> = []
    private var order: [String] = []
    private var tasks: [Task<Void, Never>] = []
    private var generation = 0
    private var rebuildScheduled = false
    private var staleWork: DispatchWorkItem?

    init(layout: Layout, usage: UsageStore) {
        self.layout = layout
        self.usage = usage
    }

    /// Starts a search; cancels the previous one.
    func run(_ sources: [Source]) {
        generation += 1
        let gen = generation
        for t in tasks { t.cancel() }
        tasks.removeAll()
        order = sources.map(\.provider.id)
        answered.removeAll()
        let wanted = Set(order)
        results = results.filter { wanted.contains($0.key) }
        if sources.isEmpty {
            rebuild()
            return
        }
        for s in sources {
            let id = s.provider.id
            let provider = s.provider
            let query = s.query
            tasks.append(Task { [weak self] in
                let items = await provider.search(query)
                guard let self, !Task.isCancelled, gen == self.generation else { return }
                self.results[id] = items
                self.answered.insert(id)
                self.scheduleRebuild()
            })
        }
        staleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, gen == self.generation else { return }
                // Providers still working after the grace period drop their old results.
                let keep = self.answered
                self.results = self.results.filter { keep.contains($0.key) }
                self.rebuild()
            }
        }
        staleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func cancel() {
        generation += 1
        for t in tasks { t.cancel() }
        tasks.removeAll()
        staleWork?.cancel()
    }

    /// Forgets everything (when the launcher closes).
    func reset() {
        cancel()
        results.removeAll()
        answered.removeAll()
        order.removeAll()
    }

    private func scheduleRebuild() {
        guard !rebuildScheduled else { return }
        rebuildScheduled = true
        // Coalesce providers that answer in the same run loop turn into one update.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.rebuild() }
        }
    }

    private func rebuild() {
        rebuildScheduled = false
        var index: [String: Int] = [:]
        var all: [PaletteItem] = []
        for pid in order {
            for item in results[pid] ?? [] {
                var it = item
                if !it.isFallback, boostWeight > 0 { it.score += usage.boost(it.id) * boostWeight }
                if let i = index[it.id] {
                    if it.score > all[i].score { all[i] = it }
                    continue
                }
                index[it.id] = all.count
                all.append(it)
            }
        }
        let normal = all.filter { !$0.isFallback }.sorted { $0.score > $1.score }
        let fallback = all.filter(\.isFallback)
        var sections: [ResultSection] = []
        switch layout {
        case .flat(let limit):
            let items = Array(normal.prefix(limit)) + fallback
            if !items.isEmpty { sections = [ResultSection(id: "results", title: "", items: items)] }
        case .sections(let maxPer):
            var grouped: [String: [PaletteItem]] = [:]
            var titles: [String] = []
            for it in normal {
                let title = it.section ?? sectionTitle(it)
                if grouped[title] == nil { titles.append(title) }
                grouped[title, default: []].append(it)
            }
            // `normal` is sorted, so titles come in order of each section's best match.
            sections = titles.map { ResultSection(id: "s:\($0)", title: $0, items: Array((grouped[$0] ?? []).prefix(maxPer))) }
            if !fallback.isEmpty {
                let title = fallback[0].section ?? sectionTitle(fallback[0])
                sections.append(ResultSection(id: "s:fallback:\(title)", title: title, items: fallback))
            }
        }
        onUpdate?(sections, answered.count < order.count)
    }
}

/// Wraps a page so the session can search it like a provider.
@MainActor
final class PageSource: SearchProvider {
    let page: ListPage
    var id: String { page.id }
    var name: String { page.title }
    var summary: String { page.title }
    var icon: ItemIcon { page.icon }
    let defaultKeyword = ""

    init(_ page: ListPage) { self.page = page }

    func search(_ query: SearchQuery) async -> [PaletteItem] { await page.search(query.text) }
}

/// The palette's top-level commands ("Clipboard History", "Search Files", script commands) matched by name.
@MainActor
final class CommandsSource: SearchProvider {
    let id = "commands"
    let name = "Commands"
    let summary = "Top-level commands"
    let icon = ItemIcon.symbol("command", .blue)
    let defaultKeyword = ""
    private let items: () -> [PaletteItem]

    init(_ items: @escaping () -> [PaletteItem]) { self.items = items }

    func search(_ query: SearchQuery) async -> [PaletteItem] {
        let text = query.text.trimmingCharacters(in: .whitespaces)
        guard text.count >= 1 else { return [] }
        return items().compactMap { item in
            guard let s = FuzzyMatcher.best(text, title: item.title, keywords: item.keywords) else { return nil }
            var it = item
            it.score = s * 0.98
            return it
        }
    }
}

/// Fixed items (an alias's target) merged into a search.
@MainActor
final class FixedSource: SearchProvider {
    let id: String
    let name = "Alias"
    let summary = "Alias"
    let icon = ItemIcon.symbol("character.cursor.ibeam", .blue)
    let defaultKeyword = ""
    private let items: [PaletteItem]

    init(id: String, items: [PaletteItem]) {
        self.id = id
        self.items = items
    }

    func search(_ query: SearchQuery) async -> [PaletteItem] { items }
}
