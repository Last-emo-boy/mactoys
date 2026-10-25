import AppKit
import MacToysCore

/// One installed application.
struct AppEntry: Sendable, Hashable {
    let path: String
    let name: String
    let bundleID: String?
    /// Other names it answers to: bundle name, executable, English file name.
    let keywords: [String]
}

/// Finds .app bundles in the usual folders and their nested folders.
enum AppIndexer {
    static func folders(extra: [String], coreServices: Bool) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var list = ["/Applications", "/System/Applications", home.appendingPathComponent("Applications").path,
                    "/System/Volumes/Preboot/Cryptexes/App/System/Applications"]
        if coreServices { list.append("/System/Library/CoreServices/Applications") }
        list += extra.map { ($0 as NSString).expandingTildeInPath }
        return list.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Apps that live outside the scanned folders but should always be found.
    static let extras = ["/System/Library/CoreServices/Finder.app", "/System/Library/CoreServices/ScreenSaverEngine.app"]

    static func scan(_ folders: [URL]) -> [AppEntry] {
        var seenPaths = Set<String>()
        var seenBundles = Set<String>()
        var result: [AppEntry] = []
        func add(_ url: URL) {
            let resolved = url.resolvingSymlinksInPath().path
            guard seenPaths.insert(resolved).inserted, let entry = entry(for: url) else { return }
            if let bid = entry.bundleID, !seenBundles.insert(bid).inserted { return }
            result.append(entry)
        }
        func walk(_ dir: URL, depth: Int) {
            guard let items = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey], options: [.skipsHiddenFiles]) else { return }
            for url in items {
                if url.pathExtension == "app" {
                    add(url)
                } else if depth < 3, (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                          (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) != true {
                    walk(url, depth: depth + 1)
                }
            }
        }
        for folder in folders { walk(folder, depth: 0) }
        for path in extras where FileManager.default.fileExists(atPath: path) { add(URL(fileURLWithPath: path)) }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func entry(for url: URL) -> AppEntry? {
        let plist = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
        // Skip helper apps that hide themselves (LSUIElement background agents are still launchable, keep them).
        if (plist?["LSBackgroundOnly"] as? Bool) == true { return nil }
        var name = FileManager.default.displayName(atPath: url.path)
        if name.hasSuffix(".app") { name.removeLast(4) }
        let fileName = url.deletingPathExtension().lastPathComponent
        var keywords: [String] = []
        for key in ["CFBundleDisplayName", "CFBundleName", "CFBundleExecutable"] {
            if let v = plist?[key] as? String, !v.isEmpty, v != name, !keywords.contains(v) { keywords.append(v) }
        }
        if fileName != name, !keywords.contains(fileName) { keywords.append(fileName) }
        return AppEntry(path: url.path, name: name, bundleID: plist?["CFBundleIdentifier"] as? String, keywords: keywords)
    }

    /// `Visual Studio Code -- ~/src` → ("Visual Studio Code", ["~/src"]); the first word starting with
    /// `-`, `--` or `/` begins the arguments, as in PowerToys Run.
    static func splitArguments(_ text: String) -> (name: String, arguments: [String])? {
        let words = text.split(separator: " ").map(String.init)
        guard words.count >= 2 else { return nil }
        for i in 1..<words.count where words[i].hasPrefix("-") || words[i].hasPrefix("/") {
            var args = Array(words[i...])
            if args.first == "--" { args.removeFirst() }
            return (words[..<i].joined(separator: " "), args.map { ($0 as NSString).expandingTildeInPath })
        }
        return nil
    }
}

/// Apps: launches applications (PowerToys "Program" plugin).
@MainActor
final class AppsProvider: SearchProvider {
    let id = "apps"
    let name = String(localized: "Apps", comment: "Provider name: installed applications")
    let summary = String(localized: "Search and launch installed applications")
    let icon = ItemIcon.symbol("square.grid.3x3.fill", .blue)
    let defaultKeyword = "."
    var examples: [String] {
        ["safari",
         String(localized: "\("vsc")  (acronyms)", comment: "Run help example: %@ is what to type, the parentheses explain it"),
         String(localized: "\("code -- ~/src")  (launch with arguments)", comment: "Run help example: %@ is what to type, the parentheses explain it")]
    }

    private let engine: LauncherEngine
    private var entries: [AppEntry] = []
    private var indexTask: Task<Void, Never>?
    private var lastIndex: Date?
    private var observer: NSObjectProtocol?
    private var indexedConfig: [String] = []

    init(engine: LauncherEngine) { self.engine = engine }

    var commands: [PaletteItem] {
        [pageCommand(title: Phrase("All Apps"), subtitle: String(localized: "Browse every installed application"), keywords: ["applications", "programs"])]
    }

    func activate() {
        reindex()
        // Re-index when apps are installed or removed (they usually launch afterwards).
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let url = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleURL
            MainActor.assumeIsolated {
                guard let self, let url, !self.entries.contains(where: { $0.path == url.path }) else { return }
                self.reindex()
            }
        }
    }

    func deactivate() {
        indexTask?.cancel()
        indexTask = nil
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
    }

    func launcherWillShow() {
        if let last = lastIndex, Date().timeIntervalSince(last) < 120 { return }
        reindex()
    }

    func optionsChanged() {
        let o = engine.options.value
        if o.appExtraFolders + [String(o.appIncludeCoreServices)] != indexedConfig { reindex() }
    }

    func reindex() {
        guard indexTask == nil else { return }
        let o = engine.options.value
        indexedConfig = o.appExtraFolders + [String(o.appIncludeCoreServices)]
        let folders = AppIndexer.folders(extra: o.appExtraFolders, coreServices: o.appIncludeCoreServices)
        indexTask = Task { [weak self] in
            let list = await background { AppIndexer.scan(folders) }
            guard let self, !Task.isCancelled else { return }
            self.entries = list
            self.lastIndex = Date()
            self.indexTask = nil
            self.engine.notifyChange(self.id)
        }
    }

    func search(_ query: SearchQuery) async -> [PaletteItem] {
        if entries.isEmpty, let task = indexTask { await task.value }
        var text = query.text.trimmingCharacters(in: .whitespaces)
        var arguments: [String] = []
        if let split = AppIndexer.splitArguments(text) {
            text = split.name
            arguments = split.arguments
        }
        let running = runningBundleIDs()
        if text.isEmpty {
            guard query.scoped else { return [] }
            return entries.map { item(for: $0, score: 0, running: running) }
        }
        return entries.compactMap { e in
            guard let s = FuzzyMatcher.best(text, title: e.name, keywords: e.keywords) else { return nil }
            return item(for: e, score: s, arguments: arguments, running: running)
        }
    }

    func resolve(_ id: String) -> PaletteItem? {
        if let c = commands.first(where: { $0.id == id }) { return c }
        guard id.hasPrefix("apps:") else { return nil }
        let path = String(id.dropFirst(5))
        if let e = entries.first(where: { $0.path == path }) { return item(for: e, score: 0, running: runningBundleIDs()) }
        guard FileManager.default.fileExists(atPath: path), let e = AppIndexer.entry(for: URL(fileURLWithPath: path)) else { return nil }
        return item(for: e, score: 0, running: runningBundleIDs())
    }

    private func runningBundleIDs() -> Set<String> {
        guard engine.options.value.appShowRunningIndicator else { return [] }
        return Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    func item(for e: AppEntry, score: Double, arguments: [String] = [], running runningIDs: Set<String> = []) -> PaletteItem {
        let url = URL(fileURLWithPath: e.path)
        let running = e.bundleID.map { runningIDs.contains($0) } ?? false
        let open = PaletteAction(id: "open", title: arguments.isEmpty ? Labels.open : String(localized: "Open with Arguments"),
                                 symbol: "arrow.up.forward.app") {
            Launch.open(url, arguments: arguments)
            return .dismiss
        }
        var subtitle = (e.path as NSString).abbreviatingWithTildeInPath
        if !arguments.isEmpty {
            subtitle = String(localized: "Arguments: \(arguments.joined(separator: " "))", comment: "%@ is the command-line arguments typed")
        }
        return PaletteItem(
            id: "apps:\(e.path)", title: e.name, subtitle: subtitle, icon: .file(e.path), providerID: id,
            accessory: running ? String(localized: "Running", comment: "Result row label: the app is running") : Labels.app,
            score: score, primary: open,
            moreActions: { [engine] in FileActions.actions(for: url, terminal: engine.options.value.terminal) },
            loadDetails: { await FileActions.details(for: url) }, keywords: e.keywords)
    }

    /// For previews: an item for an app path without indexing.
    func previewItem(path: String) -> PaletteItem? {
        AppIndexer.entry(for: URL(fileURLWithPath: path)).map { item(for: $0, score: 0) }
    }
}
