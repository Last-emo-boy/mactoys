import AppKit
import MacToysCore

/// History (`!!`): everything selected before, from any provider, searchable by any part.
@MainActor
final class HistoryProvider: SearchProvider {
    let id = "history"
    let name = "History"
    let summary = "Results you selected before, from any provider"
    let icon = ItemIcon.symbol("clock.arrow.circlepath", .graphite)
    let defaultKeyword = "!!"
    let globalByDefault = false
    let examples = ["!! 333  (part of a URL you opened)", "!!  (everything)"]

    private let engine: LauncherEngine
    init(engine: LauncherEngine) { self.engine = engine }

    var commands: [PaletteItem] {
        [pageCommand(title: "Search History", subtitle: "Everything you ran from the palette and Run", keywords: ["recent", "history"])]
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    func search(_ query: SearchQuery) async -> [PaletteItem] {
        let text = query.text.trimmingCharacters(in: .whitespaces)
        let entries = engine.usage.history
        if text.isEmpty {
            guard query.scoped else { return [] }
            return entries.prefix(200).enumerated().map { i, e in item(e, score: 1000 - Double(i)) }
        }
        return entries.enumerated().compactMap { i, e in
            let s = FuzzyMatcher.best(text, title: e.title, keywords: [e.subtitle, e.query])
                ?? ([e.title, e.subtitle, e.query].contains { $0.localizedCaseInsensitiveContains(text) } ? 500 : nil)
            return s.map { item(e, score: $0 - Double(i) * 0.01) }
        }
    }

    func item(_ e: UsageStore.HistoryEntry, score: Double) -> PaletteItem {
        let usage = engine.usage
        let primary = PaletteAction(id: "run", title: "Run Again", symbol: "arrow.uturn.backward", recordsUsage: false) {
            if let item = self.engine.resolve(e.id) {
                usage.record(item, query: e.query)
                return item.primary.perform()
            }
            return .setQuery(e.query)
        }
        return PaletteItem(
            id: "history:\(e.id)", title: e.title,
            subtitle: [e.subtitle, Self.relative.localizedString(for: e.date, relativeTo: Date())].filter { !$0.isEmpty }.joined(separator: " · "),
            icon: e.icon, providerID: id, accessory: "History", score: score, primary: primary,
            actions: [
                PaletteAction(id: "query", title: "Search “\(e.query)” Again", symbol: "magnifyingglass", recordsUsage: false) {
                    .setQuery(e.query)
                },
                PaletteAction(id: "remove", title: "Remove from History", symbol: "trash", shortcut: ActionKeys.trash,
                              recordsUsage: false) {
                    usage.remove(e.id)
                    return .refresh
                },
            ],
            loadDetails: { [engine] in engine.resolve(e.id)?.details }, isPinnable: false)
    }
}
