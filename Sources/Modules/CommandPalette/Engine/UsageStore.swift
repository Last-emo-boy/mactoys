import Foundation
import MacToysCore

/// What the user ran, shared by Command Palette and Run: usage counts for ranking, the history
/// behind Run's `!!` and the palette's recent items, and shell command history.
@MainActor
final class UsageStore {
    struct Record: Codable, Equatable {
        var count: Int
        var last: Date
    }

    struct HistoryEntry: Codable, Identifiable, Equatable {
        /// The item id.
        var id: String
        var title: String
        var subtitle: String
        var icon: ItemIcon
        /// The query that found it, for items that can't be rebuilt from the id.
        var query: String
        var date: Date
    }

    private struct Stored: Codable {
        var records: [String: Record] = [:]
        var history: [HistoryEntry] = []
        var shell: [String] = []
    }

    private(set) var records: [String: Record] = [:]
    /// Newest first, one entry per item.
    private(set) var history: [HistoryEntry] = []
    /// Newest first.
    private(set) var shellHistory: [String] = []

    static let historyLimit = 300
    private let file: URL?
    private var pendingSave: DispatchWorkItem?
    private let log = Log.for("cmdpal")

    /// `file` nil keeps everything in memory (previews, tests).
    init(file: URL?) {
        self.file = file
        guard let file, let data = try? Data(contentsOf: file) else { return }
        do {
            let stored = try JSONDecoder().decode(Stored.self, from: data)
            records = stored.records
            history = stored.history
            shellHistory = stored.shell
        } catch {
            log.error("Could not read usage: \(error.localizedDescription, privacy: .public)")
        }
    }

    func record(_ item: PaletteItem, query: String, at date: Date = Date()) {
        var r = records[item.id] ?? Record(count: 0, last: date)
        r.count += 1
        r.last = date
        records[item.id] = r
        history.removeAll { $0.id == item.id }
        history.insert(HistoryEntry(id: item.id, title: item.title, subtitle: item.subtitle, icon: item.icon,
                                    query: query, date: date), at: 0)
        if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
        scheduleSave()
    }

    /// Ranking bonus for an item the user picks often or picked recently (0…~160).
    func boost(_ id: String, now: Date = Date()) -> Double {
        guard let r = records[id] else { return 0 }
        let frequency = min(25 * log2(1 + Double(r.count)), 120)
        let age = now.timeIntervalSince(r.last)
        let recency: Double = age < 3600 ? 40 : age < 86400 ? 25 : age < 7 * 86400 ? 10 : 0
        return frequency + recency
    }

    func remove(_ id: String) {
        history.removeAll { $0.id == id }
        records[id] = nil
        scheduleSave()
    }

    func clearHistory() {
        history.removeAll()
        records.removeAll()
        scheduleSave()
    }

    func recordShell(_ command: String) {
        let c = command.trimmingCharacters(in: .whitespaces)
        guard !c.isEmpty else { return }
        shellHistory.removeAll { $0 == c }
        shellHistory.insert(c, at: 0)
        if shellHistory.count > 100 { shellHistory.removeLast(shellHistory.count - 100) }
        scheduleSave()
    }

    func removeShell(_ command: String) {
        shellHistory.removeAll { $0 == command }
        scheduleSave()
    }

    func clearShellHistory() {
        shellHistory.removeAll()
        scheduleSave()
    }

    private func scheduleSave() {
        guard let file else { return }
        pendingSave?.cancel()
        let snapshot = Stored(records: records, history: history, shell: shellHistory)
        let log = self.log
        let work = DispatchWorkItem {
            do {
                try JSONEncoder().encode(snapshot).write(to: file, options: .atomic)
            } catch {
                log.error("Could not save usage: \(error.localizedDescription, privacy: .public)")
            }
        }
        pendingSave = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Writes pending changes now (at stop).
    func flush() {
        guard let work = pendingSave else { return }
        pendingSave = nil
        work.cancel()
        guard let file else { return }
        let snapshot = Stored(records: records, history: history, shell: shellHistory)
        do {
            try JSONEncoder().encode(snapshot).write(to: file, options: .atomic)
        } catch {
            log.error("Could not save usage: \(error.localizedDescription, privacy: .public)")
        }
    }
}
