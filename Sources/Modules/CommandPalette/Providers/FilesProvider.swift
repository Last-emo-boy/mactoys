import AppKit
import MacToysCore

/// One NSMetadataQuery run that resolves once results are gathered, enough results arrived,
/// a time limit passes, or the calling task is cancelled.
@MainActor
final class SpotlightRequest {
    struct Hit: Sendable {
        let url: URL
        let lastUsed: Date?
    }

    private let query = NSMetadataQuery()
    private var continuation: CheckedContinuation<[Hit], Never>?
    private var observers: [NSObjectProtocol] = []
    private let limit: Int

    init(predicate: NSPredicate, scopes: [Any], limit: Int) {
        self.limit = limit
        query.predicate = predicate
        query.searchScopes = scopes
        query.notificationBatchingInterval = 0.08
    }

    static func run(predicate: NSPredicate, scopes: [Any], limit: Int, timeout: TimeInterval = 1.5) async -> [Hit] {
        let request = SpotlightRequest(predicate: predicate, scopes: scopes, limit: limit)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                request.start(cont, timeout: timeout)
            }
        } onCancel: {
            Task { @MainActor in request.finish() }
        }
    }

    private func start(_ cont: CheckedContinuation<[Hit], Never>, timeout: TimeInterval) {
        continuation = cont
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish() }
        })
        observers.append(center.addObserver(forName: .NSMetadataQueryGatheringProgress, object: query, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.query.resultCount >= self.limit * 4 else { return }
                self.finish()
            }
        })
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            MainActor.assumeIsolated { self?.finish() }
        }
        if !query.start() { finish() }
    }

    func finish() {
        guard let cont = continuation else { return }
        continuation = nil
        query.disableUpdates()
        var hits: [Hit] = []
        let count = min(query.resultCount, limit * 4)
        for i in 0..<count {
            guard let item = query.result(at: i) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            hits.append(Hit(url: URL(fileURLWithPath: path), lastUsed: item.value(forAttribute: "kMDItemLastUsedDate") as? Date))
        }
        query.stop()
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        cont.resume(returning: hits)
    }
}

/// Files: Spotlight file search plus path browsing (`~/Documents/` lists the folder).
@MainActor
final class FilesProvider: SearchProvider {
    let id = "files"
    let name = String(localized: "Files", comment: "Provider name: file search; also the kind of a clipboard entry with several files")
    let summary = String(localized: "Find files and folders with Spotlight, or browse a path")
    let icon = ItemIcon.symbol("doc.text.magnifyingglass", .orange)
    let defaultKeyword = "("
    var examples: [String] {
        ["report.pdf",
         String(localized: "\("~/Documents/")  (browse a folder)", comment: "Run help example: %@ is what to type, the parentheses explain it"),
         String(localized: "\("/Applications/*.app")  (mask)", comment: "Run help example: %@ is a file name pattern with wildcards")]
    }

    private let engine: LauncherEngine
    init(engine: LauncherEngine) { self.engine = engine }

    var commands: [PaletteItem] {
        [pageCommand(title: Phrase("Search Files"), subtitle: String(localized: "Find files and folders with Spotlight"),
                     keywords: ["find", "spotlight", "file"])]
    }

    func search(_ query: SearchQuery) async -> [PaletteItem] {
        let text = query.text.trimmingCharacters(in: .whitespaces)
        let o = engine.options.value
        if text.hasPrefix("/") || text.hasPrefix("~") {
            return browse(text, showHidden: o.fileShowHidden)
        }
        if text.isEmpty {
            guard query.scoped else { return [] }
            return await recent(limit: o.fileMaxResults)
        }
        guard query.scoped || text.count >= 3 else { return [] }
        let limit = query.scoped ? o.fileMaxResults : min(o.fileMaxResults, 6)
        // Debounce: a newer keystroke cancels this task before Spotlight starts.
        try? await Task.sleep(nanoseconds: 120_000_000)
        guard !Task.isCancelled else { return [] }
        let hits = await SpotlightRequest.run(predicate: Self.predicate(text, contents: o.fileMatchContents),
                                              scopes: [o.fileScope == .home ? NSMetadataQueryUserHomeScope
                                                       : NSMetadataQueryLocalComputerScope], limit: limit)
        guard !Task.isCancelled else { return [] }
        let now = Date()
        let ranked = hits.filter { !Self.isNoise($0.url.path) }.compactMap { hit -> (SpotlightRequest.Hit, Double)? in
            let base = FuzzyMatcher.score(text, hit.url.lastPathComponent) ?? (o.fileMatchContents ? 150 : nil)
            guard let base else { return nil }
            var recency = 0.0
            if let used = hit.lastUsed {
                let days = now.timeIntervalSince(used) / 86400
                recency = days < 1 ? 60 : days < 7 ? 35 : days < 30 ? 15 : 0
            }
            // Spotlight hits rank below apps and commands with the same name.
            return (hit, base * 0.85 + recency)
        }
        .sorted { $0.1 > $1.1 }
        .prefix(limit)
        return ranked.map { item(for: $0.0.url, score: $0.1) }
    }

    func resolve(_ id: String) -> PaletteItem? {
        if let c = commands.first(where: { $0.id == id }) { return c }
        guard id.hasPrefix("files:") else { return nil }
        let path = String(id.dropFirst(6))
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return item(for: URL(fileURLWithPath: path), score: 0)
    }

    /// Name match on every word (`kMDItemFSName LIKE[cd] "*word*"`), optionally file contents too.
    static func predicate(_ text: String, contents: Bool) -> NSPredicate {
        let words = text.split(separator: " ").map { w in
            w.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "*", with: "\\*")
                .replacingOccurrences(of: "?", with: "\\?")
        }
        let name = NSCompoundPredicate(andPredicateWithSubpredicates: words.map {
            NSPredicate(format: "%K LIKE[cd] %@", NSMetadataItemFSNameKey, "*\($0)*")
        })
        guard contents else { return name }
        return NSCompoundPredicate(orPredicateWithSubpredicates: [name, NSPredicate(format: "kMDItemTextContent CONTAINS[cd] %@", text)])
    }

    static func isNoise(_ path: String) -> Bool {
        ["/Library/Caches/", "/node_modules/", "/.git/", "/.Trash/", "/DerivedData/", "/.build/"].contains { path.contains($0) }
    }

    /// Recently used documents (empty Files page).
    private func recent(limit: Int) async -> [PaletteItem] {
        let since = Date().addingTimeInterval(-14 * 86400)
        let predicate = NSPredicate(format: "kMDItemLastUsedDate >= %@ && kMDItemContentType != 'com.apple.application-bundle'",
                                    since as NSDate)
        let hits = await SpotlightRequest.run(predicate: predicate, scopes: [NSMetadataQueryUserHomeScope], limit: limit * 3)
        return hits.filter { !Self.isNoise($0.url.path) && !$0.url.path.contains("/Library/") }
            .sorted { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }
            .prefix(limit)
            .enumerated().map { i, hit in
                var it = item(for: hit.url, score: Double(limit - i))
                it.section = String(localized: "Recent Files", comment: "Section heading: recently used documents")
                return it
            }
    }

    /// Lists a folder: `~/Documents/` everything, `~/Documents/rep` entries matching "rep",
    /// `~/Downloads/*.pdf` a mask, `~/Documents/>notes` a recursive search inside the folder.
    func browse(_ text: String, showHidden: Bool) -> [PaletteItem] {
        let expanded = (text as NSString).expandingTildeInPath
        var dirPath: String
        var partial: String
        if expanded.hasSuffix("/") {
            dirPath = expanded
            partial = ""
        } else {
            dirPath = (expanded as NSString).deletingLastPathComponent
            partial = (expanded as NSString).lastPathComponent
        }
        var recursive = false
        if partial.hasPrefix(">") { recursive = true; partial.removeFirst() }
        if dirPath.hasSuffix("/>") { recursive = true; dirPath.removeLast(2) }
        let dir = URL(fileURLWithPath: dirPath.isEmpty ? "/" : dirPath, isDirectory: true)
        let fm = FileManager.default
        var urls: [URL] = []
        let opts: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
        if recursive {
            if let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: opts.union(.skipsPackageDescendants)) {
                for case let url as URL in e {
                    urls.append(url)
                    if urls.count > 4000 { break }
                }
            }
        } else {
            urls = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: opts)) ?? []
        }
        let mask = partial.contains("*") || partial.contains("?")
        let maskPredicate = mask ? NSPredicate(format: "SELF LIKE[cd] %@", partial) : nil
        var results: [(url: URL, score: Double, isDir: Bool)] = []
        for url in urls {
            let name = url.lastPathComponent
            let score: Double?
            if let maskPredicate {
                score = maskPredicate.evaluate(with: name) ? 500 : nil
            } else if partial.isEmpty {
                score = 0
            } else {
                score = FuzzyMatcher.score(partial, name)
            }
            guard let score else { continue }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            results.append((url, score, isDir))
        }
        results.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.isDir != b.isDir { return a.isDir }
            return a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent) == .orderedAscending
        }
        var items = results.prefix(200).map { url, score, _ -> PaletteItem in
            var it = item(for: url, score: 900 + score / 10)
            it.section = (dir.path as NSString).abbreviatingWithTildeInPath
            return it
        }
        if partial.isEmpty, !recursive, fm.fileExists(atPath: dir.path) {
            var folder = item(for: dir, score: 1000)
            folder.section = items.first?.section
            let folderName = dir.lastPathComponent.isEmpty ? "/" : dir.lastPathComponent
            folder.title = String(localized: "Open “\(folderName)”", comment: "%@ is a folder name")
            items.insert(folder, at: 0)
        }
        return items
    }

    func item(for url: URL, score: Double) -> PaletteItem {
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && url.pathExtension != "app"
        let terminal = engine.options.value.terminal
        var item = PaletteItem(
            id: "files:\(url.path)", title: url.lastPathComponent,
            subtitle: (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath,
            icon: .file(url.path), providerID: id, accessory: isDir ? Labels.folder : Labels.file, score: score,
            primary: PaletteAction(id: "open", title: Labels.open, symbol: "arrow.up.forward.app") {
                Launch.open(url)
                return .dismiss
            },
            moreActions: { FileActions.actions(for: url, terminal: terminal) },
            loadDetails: { await FileActions.details(for: url) })
        if isDir {
            let path = (url.path as NSString).abbreviatingWithTildeInPath + "/"
            item.autocomplete = path
            item.actions.insert(PaletteAction(id: "browse", title: String(localized: "Browse Folder"), symbol: "folder.badge.gearshape") {
                .setQuery(path)
            }, at: 0)
        }
        return item
    }
}
