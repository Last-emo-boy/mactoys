import AppKit
import MacToysCore

/// Browsers whose bookmarks can be read.
enum BrowserKind: String, CaseIterable, Sendable, Identifiable {
    case safari, chrome, edge, brave, vivaldi, chromium, arc
    var id: String { rawValue }

    var title: String {
        switch self {
        case .safari: "Safari"
        case .chrome: "Google Chrome"
        case .edge: "Microsoft Edge"
        case .brave: "Brave"
        case .vivaldi: "Vivaldi"
        case .chromium: "Chromium"
        case .arc: "Arc"
        }
    }

    var bundleID: String {
        switch self {
        case .safari: "com.apple.Safari"
        case .chrome: "com.google.Chrome"
        case .edge: "com.microsoft.edgemac"
        case .brave: "com.brave.Browser"
        case .vivaldi: "com.vivaldi.Vivaldi"
        case .chromium: "org.chromium.Chromium"
        case .arc: "company.thebrowser.Browser"
        }
    }

    /// Chromium-family profile root under Application Support.
    var chromiumRoot: String? {
        switch self {
        case .chrome: "Google/Chrome"
        case .edge: "Microsoft Edge"
        case .brave: "BraveSoftware/Brave-Browser"
        case .vivaldi: "Vivaldi"
        case .chromium: "Chromium"
        case .arc: "Arc/User Data"
        case .safari: nil
        }
    }
}

struct Bookmark: Sendable, Hashable {
    let title: String
    let url: String
    let folder: String
    let browser: BrowserKind
}

/// Reads bookmark files of installed browsers.
enum BookmarkReader {
    enum Outcome: Sendable {
        case bookmarks([Bookmark])
        case noAccess
        case missing
    }

    static func read(_ browser: BrowserKind) -> Outcome {
        let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        if browser == .safari {
            let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Safari/Bookmarks.plist")
            guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
            do {
                let data = try Data(contentsOf: url)
                let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
                var out: [Bookmark] = []
                walkSafari(plist, folder: "", into: &out)
                return .bookmarks(out)
            } catch {
                // ~/Library/Safari is protected: without Full Disk Access the read fails with EPERM.
                return .noAccess
            }
        }
        guard let rootName = browser.chromiumRoot else { return .missing }
        let root = support.appendingPathComponent(rootName)
        guard let profiles = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return .missing }
        var out: [Bookmark] = []
        var found = false
        for profile in profiles where profile == "Default" || profile.hasPrefix("Profile ") {
            let file = root.appendingPathComponent(profile).appendingPathComponent("Bookmarks")
            guard let data = try? Data(contentsOf: file),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let roots = json["roots"] as? [String: Any] else { continue }
            found = true
            for (_, node) in roots.sorted(by: { $0.key < $1.key }) { walkChromium(node, folder: "", browser: browser, into: &out) }
        }
        return found ? .bookmarks(out) : .missing
    }

    static func walkChromium(_ node: Any, folder: String, browser: BrowserKind, into out: inout [Bookmark]) {
        guard let dict = node as? [String: Any] else { return }
        let name = dict["name"] as? String ?? ""
        if dict["type"] as? String == "url", let url = dict["url"] as? String {
            out.append(Bookmark(title: name.isEmpty ? url : name, url: url, folder: folder, browser: browser))
            return
        }
        let path = folder.isEmpty ? name : (name.isEmpty ? folder : "\(folder) › \(name)")
        for child in dict["children"] as? [Any] ?? [] { walkChromium(child, folder: path, browser: browser, into: &out) }
    }

    static func walkSafari(_ node: Any, folder: String, into out: inout [Bookmark]) {
        guard let dict = node as? [String: Any] else { return }
        let type = dict["WebBookmarkType"] as? String
        if type == "WebBookmarkTypeLeaf", let url = dict["URLString"] as? String {
            let title = (dict["URIDictionary"] as? [String: Any])?["title"] as? String ?? url
            out.append(Bookmark(title: title, url: url, folder: folder, browser: .safari))
            return
        }
        var name = dict["Title"] as? String ?? ""
        if name == "com.apple.ReadingList" { name = "Reading List" }
        if name == "BookmarksBar" { name = "Favorites" }
        if name == "BookmarksMenu" { name = "Bookmarks Menu" }
        let path = folder.isEmpty ? name : (name.isEmpty ? folder : "\(folder) › \(name)")
        for child in dict["Children"] as? [Any] ?? [] { walkSafari(child, folder: path, into: &out) }
    }
}

/// Bookmarks of Safari and Chromium-family browsers.
@MainActor
final class BookmarksProvider: SearchProvider {
    let id = "bookmarks"
    let name = "Bookmarks"
    let summary = "Open bookmarks from Safari, Chrome, Edge, Brave, Vivaldi and Arc"
    let icon = ItemIcon.symbol("bookmark.fill", .orange)
    let defaultKeyword = "bm"
    let examples = ["bm github", "bm  (all bookmarks)"]

    private let engine: LauncherEngine
    private var bookmarks: [Bookmark] = []
    private var safariBlocked = false
    private var loadedAt: Date?
    private var loadTask: Task<Void, Never>?

    init(engine: LauncherEngine) { self.engine = engine }

    var commands: [PaletteItem] {
        [pageCommand(title: "Search Bookmarks", subtitle: "Browser bookmarks", keywords: ["bookmarks", "favorites"])]
    }

    func isEnabled(_ b: BrowserKind) -> Bool { engine.options.value.bookmarkBrowsers[b.rawValue] ?? true }

    func activate() { reload() }
    func deactivate() {
        loadTask?.cancel()
        loadTask = nil
    }

    func launcherWillShow() {
        if let at = loadedAt, Date().timeIntervalSince(at) < 60 { return }
        reload()
    }

    func reload() {
        guard loadTask == nil else { return }
        let browsers = BrowserKind.allCases.filter(isEnabled)
        loadTask = Task { [weak self] in
            let result = await background { () -> ([Bookmark], Bool) in
                var all: [Bookmark] = []
                var blocked = false
                for b in browsers {
                    switch BookmarkReader.read(b) {
                    case .bookmarks(let list): all += list
                    case .noAccess: blocked = true
                    case .missing: break
                    }
                }
                return (all, blocked)
            }
            guard let self, !Task.isCancelled else { return }
            self.bookmarks = result.0
            self.safariBlocked = result.1
            self.loadedAt = Date()
            self.loadTask = nil
            self.engine.notifyChange(self.id)
        }
    }

    func search(_ query: SearchQuery) async -> [PaletteItem] {
        if bookmarks.isEmpty, let t = loadTask { await t.value }
        let text = query.text.trimmingCharacters(in: .whitespaces)
        var out: [PaletteItem] = []
        if query.scoped, safariBlocked, isEnabled(.safari) {
            out.append(PaletteItem(id: "bookmarks:access", title: "Allow Full Disk Access to read Safari bookmarks",
                                   subtitle: "Privacy & Security › Full Disk Access › MacToys",
                                   icon: .symbol("lock.shield.fill", .orange), providerID: id, section: "Safari", score: 2000,
                                   primary: PaletteAction(id: "open", title: "Open Settings", symbol: "gearshape") {
                                       PermissionCenter.shared.openSettings(.fullDiskAccess)
                                       return .dismiss
                                   }, isPinnable: false))
        }
        if text.isEmpty {
            guard query.scoped else { return out }
            return out + bookmarks.prefix(1000).enumerated().map { i, b in item(b, score: 500 - Double(i) / 10) }
        }
        guard query.scoped || text.count >= 2 else { return [] }
        let hits = bookmarks.compactMap { b -> PaletteItem? in
            let host = URL(string: b.url)?.host ?? ""
            guard let s = FuzzyMatcher.best(text, title: b.title, keywords: [host, b.folder]) else { return nil }
            return item(b, score: query.scoped ? s : s * 0.85)
        }
        return out + hits
    }

    func resolve(_ id: String) -> PaletteItem? {
        if let c = commands.first(where: { $0.id == id }) { return c }
        guard id.hasPrefix("bookmarks:") else { return nil }
        let rest = id.dropFirst(10)
        guard let colon = rest.firstIndex(of: ":"), let browser = BrowserKind(rawValue: String(rest[..<colon])) else { return nil }
        let url = String(rest[rest.index(after: colon)...])
        let b = bookmarks.first { $0.browser == browser && $0.url == url } ?? Bookmark(title: url, url: url, folder: "", browser: browser)
        return item(b, score: 0)
    }

    func item(_ b: Bookmark, score: Double) -> PaletteItem {
        let appPath = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b.browser.bundleID)?.path
        let url = URL(string: b.url)
        let place = b.folder.isEmpty ? b.browser.title : "\(b.browser.title) › \(b.folder)"
        return PaletteItem(
            id: "bookmarks:\(b.browser.rawValue):\(b.url)", title: b.title, subtitle: "\(url?.host ?? b.url) · \(place)",
            icon: appPath.map { .file($0) } ?? icon, providerID: id, accessory: "Bookmark", score: score,
            primary: PaletteAction(id: "open", title: "Open in \(b.browser.title)", symbol: "safari") {
                if let url { Launch.open(url, bundleID: appPath == nil ? nil : b.browser.bundleID) }
                return .dismiss
            },
            actions: [
                PaletteAction(id: "opendefault", title: "Open in Default Browser", symbol: "globe", shortcut: ActionKeys.secondary) {
                    if let url { Launch.open(url) }
                    return .dismiss
                },
                PaletteAction(id: "copy", title: "Copy URL", symbol: "doc.on.doc", shortcut: ActionKeys.copy) {
                    Launch.copy(b.url)
                    HUD.show("URL copied", symbol: "link")
                    return .dismiss
                },
                PaletteAction(id: "copytitle", title: "Copy Title", symbol: "textformat") {
                    Launch.copy(b.title)
                    return .dismiss
                },
                PaletteAction(id: "markdown", title: "Copy as Markdown Link", symbol: "link") {
                    Launch.copy("[\(b.title)](\(b.url))")
                    return .dismiss
                },
            ],
            details: ItemDetails(icon: appPath.map { .file($0) } ?? icon, title: b.title, subtitle: place,
                                 rows: [DetailRow(label: "URL", value: b.url), DetailRow(label: "Browser", value: b.browser.title, monospaced: false)]
                                     + (b.folder.isEmpty ? [] : [DetailRow(label: "Folder", value: b.folder, monospaced: false)])))
    }
}
