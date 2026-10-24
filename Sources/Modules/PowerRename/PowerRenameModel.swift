import Foundation
import MacToysCore
import Observation

/// State of one PowerRename window.
@MainActor
@Observable
final class PowerRenameModel {
    var items: [RenameItem] { didSet { cache.reset(); recompute(); onItemsChanged?() } }
    var options: RenameOptions { didSet { if options != oldValue { recompute() } } }
    var unchecked: Set<Int> = [] { didSet { recompute() } }
    var flavor: RegexFlavor { didSet { if flavor != oldValue { recompute() } } }
    /// Show only the rows that will be renamed (PowerToys' click on the *Renamed* header).
    var onlyShowRenamed = false
    private(set) var previews: [RenamePreview] = []
    private(set) var patternError: String?
    /// Message shown in the footer after Apply or Undo.
    private(set) var resultMessage: String?
    private(set) var failures: [RenameExecutor.Failure] = []
    var canUndo: Bool

    /// Called when the list changes (the window title shows the count).
    @ObservationIgnored var onItemsChanged: (() -> Void)?
    /// Called with what was renamed, so the module can keep the undo journal and history.
    @ObservationIgnored var onApplied: ((RenameExecutor.Outcome, RenameOptions) -> Void)?
    /// Undoes the last batch; returns the outcome, or nil when there is nothing to undo.
    @ObservationIgnored var onUndo: (() -> RenameExecutor.Outcome?)?

    @ObservationIgnored private let seed = UInt64.random(in: 1...UInt64.max)
    @ObservationIgnored private let cache: EnvironmentCache
    @ObservationIgnored private let live: Bool

    /// - Parameter live: false for previews: no file system access.
    init(items: [RenameItem], options: RenameOptions, flavor: RegexFlavor, canUndo: Bool, live: Bool = true) {
        self.items = items
        self.options = options
        self.flavor = flavor
        self.canUndo = canUndo
        self.live = live
        cache = EnvironmentCache(live ? .live : RenameEnvironment())
        recompute()
    }

    var title: String { "PowerRename · \(items.count) item\(items.count == 1 ? "" : "s")" }

    var visibleRows: [RenamePreview] { onlyShowRenamed ? previews.filter(\.willRename) : previews }
    var renameCount: Int { previews.filter(\.willRename).count }
    var conflictCount: Int { previews.filter { $0.status == .conflict }.count }
    var invalidCount: Int { previews.filter { if case .invalid = $0.status { true } else { false } }.count }

    func isChecked(_ row: RenamePreview) -> Bool { !unchecked.contains(row.id) }

    func setChecked(_ row: RenamePreview, _ on: Bool) {
        if on { unchecked.remove(row.id) } else { unchecked.insert(row.id) }
    }

    func setAllChecked(_ on: Bool) {
        unchecked = on ? [] : Set(items.map(\.id))
    }

    func add(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let roots = items.filter { $0.depth == 0 }.map(\.url)
        items = RenameItemLoader.load(roots + urls)
    }

    func recompute() {
        let engine = RenameEngine(options: options, flavor: flavor, seed: seed)
        do {
            previews = try engine.plan(items, unchecked: unchecked, environment: cache.environment)
            patternError = nil
        } catch {
            previews = items.map { RenamePreview(item: $0, proposedName: nil, newName: nil, status: .unchanged) }
            patternError = error.localizedDescription
        }
    }

    func apply() {
        let operations = RenameExecutor.operations(for: previews)
        guard !operations.isEmpty, live else { return }
        let outcome = RenameExecutor.apply(operations)
        onApplied?(outcome, options)
        failures = outcome.failures
        canUndo = !outcome.done.isEmpty || canUndo
        let n = outcome.done.count
        resultMessage = outcome.failures.isEmpty
            ? "Renamed \(n) item\(n == 1 ? "" : "s")"
            : "Renamed \(n) of \(operations.count) · \(outcome.failures.count) failed"
        reload(mapping: outcome.done)
    }

    func undo() {
        guard let outcome = onUndo?() else { return }
        failures = outcome.failures
        canUndo = false
        let n = outcome.done.count
        resultMessage = outcome.failures.isEmpty
            ? "Restored \(n) name\(n == 1 ? "" : "s")"
            : "Restored \(n) · \(outcome.failures.count) could not be restored"
        reload(mapping: outcome.done)
    }

    /// Reloads the list after renames, following the selected items to their new names.
    private func reload(mapping done: [RenameOperation]) {
        let moved = Dictionary(done.map { ($0.from.standardizedFileURL.path, $0.to) }, uniquingKeysWith: { a, _ in a })
        let roots = items.filter { $0.depth == 0 }.map { moved[$0.url.standardizedFileURL.path] ?? $0.url }
        unchecked = []
        items = RenameItemLoader.load(roots)
    }
}

/// Memoizes directory listings and metadata while a window is open.
private final class EnvironmentCache {
    private let base: RenameEnvironment
    private var names: [String: [String]] = [:]
    private var caseSensitive: [String: Bool] = [:]
    private var metadata: [String: [String: String]] = [:]

    init(_ base: RenameEnvironment) { self.base = base }

    func reset() {
        names = [:]
        caseSensitive = [:]
    }

    var environment: RenameEnvironment {
        RenameEnvironment(
            existingNames: { [self] url in
                if let n = names[url.path] { return n }
                let n = base.existingNames(url)
                names[url.path] = n
                return n
            },
            isCaseSensitive: { [self] url in
                if let c = caseSensitive[url.path] { return c }
                let c = base.isCaseSensitive(url)
                caseSensitive[url.path] = c
                return c
            },
            metadata: { [self] url in
                if let m = metadata[url.path] { return m }
                let m = base.metadata(url)
                metadata[url.path] = m
                return m
            })
    }
}
