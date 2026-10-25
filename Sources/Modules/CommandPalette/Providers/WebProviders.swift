import AppKit
import MacToysCore

/// Recognizes URLs typed into the launcher.
enum URLDetection {
    static let topLevelDomains: Set<String> = [
        "com", "org", "net", "edu", "gov", "mil", "int", "io", "dev", "app", "ai", "co", "me", "xyz", "info", "biz",
        "tech", "site", "online", "store", "blog", "cloud", "page", "link", "news", "wiki", "design", "studio", "art",
        "tv", "fm", "gg", "so", "sh", "to", "ly", "cc", "us", "uk", "de", "fr", "jp", "cn", "kr", "ru", "nl", "it", "es",
        "se", "no", "fi", "dk", "ch", "at", "be", "pl", "cz", "pt", "br", "ca", "au", "nz", "in", "eu", "hk", "tw", "sg",
        "ie", "mx", "ar", "za", "tr", "il", "gr", "hu", "ro", "ua", "id", "th", "vn", "my", "ph", "is", "lu", "li",
        "local", "localhost", "test", "zone", "network", "systems", "tools", "software", "codes", "email", "space",
    ]

    /// Known schemes that open apps or pages (`mailto:`, `x-apple.systempreferences:`).
    static let schemes: Set<String> = ["http", "https", "ftp", "sftp", "ssh", "mailto", "tel", "sms", "facetime", "file",
                                       "x-apple.systempreferences", "shortcuts", "music", "maps", "itms-apps", "macappstore",
                                       "vscode", "slack", "zoommtg", "obsidian", "raycast", "spotify", "mactoys", "message"]

    static func url(from raw: String) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        if let colon = text.firstIndex(of: ":") {
            let scheme = text[..<colon].lowercased()
            if schemes.contains(scheme) || text.contains("://") {
                guard let url = URL(string: text), url.scheme != nil else { return nil }
                if scheme == "http" || scheme == "https" { return url.host == nil ? nil : url }
                return url
            }
        }
        let lower = text.lowercased()
        let hostPart = String(lower.split(separator: "/", maxSplits: 1).first ?? "")
        let host = String(hostPart.split(separator: ":").first ?? "")
        if host == "localhost" || isIPv4(host) {
            return URL(string: "http://" + text)
        }
        let labels = host.split(separator: ".")
        guard labels.count >= 2, let tld = labels.last, topLevelDomains.contains(String(tld)),
              labels.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } }) else { return nil }
        return URL(string: "https://" + text)
    }

    static func isIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }
}

/// URI handler (`//`): opens URLs and app links.
@MainActor
final class URLProvider: SearchProvider {
    let id = "url"
    let name = String(localized: "URLs", comment: "Provider name: web addresses and app links")
    let summary = String(localized: "Open web addresses and app links like \("mailto:") or \("x-apple.systempreferences:")",
                         comment: "Both %@ are URL schemes")
    let icon = ItemIcon.symbol("link", .blue)
    let defaultKeyword = "//"
    var examples: [String] {
        ["apple.com", "https://github.com/microsoft/PowerToys", "mailto:someone@example.com",
         String(localized: "\("//")  (open the browser)", comment: "Run help example: %@ is what to type, the parentheses explain it")]
    }

    private let engine: LauncherEngine
    init(engine: LauncherEngine) { self.engine = engine }

    func search(_ query: SearchQuery) async -> [PaletteItem] {
        let text = query.text.trimmingCharacters(in: .whitespaces)
        let browser = engine.options.value.browserBundleID
        if text.isEmpty {
            guard query.scoped, let probe = URL(string: "https://example.com"),
                  let app = browser.isEmpty ? NSWorkspace.shared.urlForApplication(toOpen: probe)
                    : NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser) else { return [] }
            let appName = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
            return [PaletteItem(id: "url:browser", title: String(localized: "Open \(appName)", comment: "Action: open something; %@ is an app, utility, website or address"),
                                subtitle: String(localized: "Your web browser"), icon: .file(app.path),
                                providerID: id, accessory: Labels.app, score: 900,
                                primary: PaletteAction(id: "open", title: Labels.open, symbol: "safari") {
                                    Launch.open(app)
                                    return .dismiss
                                })]
        }
        var url = URLDetection.url(from: text)
        if url == nil, query.scoped, !text.contains(" ") { url = URL(string: "https://" + text) }
        guard let url else { return [] }
        return [item(for: url, score: 960)]
    }

    func resolve(_ id: String) -> PaletteItem? {
        if id == "url:browser" { return nil }
        guard id.hasPrefix("url:"), let url = URL(string: String(id.dropFirst(4))) else { return nil }
        return item(for: url, score: 0)
    }

    func item(for url: URL, score: Double) -> PaletteItem {
        let browser = engine.options.value.browserBundleID
        let web = url.scheme == "http" || url.scheme == "https"
        let handler = NSWorkspace.shared.urlForApplication(toOpen: url)
        return PaletteItem(
            id: "url:\(url.absoluteString)", title: String(localized: "Open \(url.absoluteString)", comment: "Action: open something; %@ is an app, utility, website or address"),
            subtitle: web ? String(localized: "Web page")
                : handler.map { String(localized: "Opens in \(FileManager.default.displayName(atPath: $0.path))", comment: "%@ is an app name") }
                    ?? String(localized: "Opens in its app"),
            icon: web ? icon : handler.map { .file($0.path) } ?? icon, providerID: id,
            accessory: String(localized: "URL", comment: "A web address (row label, Run keyword chip)"), score: score,
            primary: PaletteAction(id: "open", title: Labels.open, symbol: "safari") {
                Launch.open(url, bundleID: web ? browser : nil)
                return .dismiss
            },
            actions: [
                PaletteAction(id: "copy", title: Labels.copyURL, symbol: "doc.on.doc", shortcut: ActionKeys.copy) {
                    Launch.copy(url.absoluteString)
                    return .dismiss
                },
            ])
    }
}

/// Web search (`??`): the catch-all at the end of every list.
@MainActor
final class WebSearchProvider: SearchProvider {
    let id = "web"
    let name = String(localized: "Web", comment: "Provider name: web search")
    let summary = String(localized: "Search the web with your chosen engine")
    let icon = ItemIcon.symbol("magnifyingglass", .cyan)
    let defaultKeyword = "??"
    var examples: [String] {
        ["?? what is the answer to life",
         String(localized: "\("??")  (open the search page)", comment: "Run help example: %@ is what to type, the parentheses explain it")]
    }

    private let engine: LauncherEngine
    init(engine: LauncherEngine) { self.engine = engine }

    var commands: [PaletteItem] {
        [pageCommand(title: Phrase("Web Search"), subtitle: String(localized: "Search with \(engineName)", comment: "%@ is a search engine such as Google"),
                     keywords: ["google", "search", "internet"])]
    }

    var engineName: String {
        let o = engine.options.value
        if o.searchEngine == .custom {
            return URL(string: o.customSearchURL)?.host ?? String(localized: "custom engine", comment: "Stands in for the search engine's name")
        }
        return o.searchEngine.title
    }

    func search(_ query: SearchQuery) async -> [PaletteItem] {
        let text = query.text.trimmingCharacters(in: .whitespaces)
        let o = engine.options.value
        if text.isEmpty {
            guard query.scoped, let url = Launch.searchURL("", template: o.searchTemplate).flatMap(homepage) else { return [] }
            return [PaletteItem(id: "web:home", title: String(localized: "Open \(engineName)", comment: "Action: open something; %@ is an app, utility, website or address"),
                                subtitle: url.absoluteString, icon: icon,
                                providerID: id, accessory: name, score: 900,
                                primary: PaletteAction(id: "open", title: Labels.open, symbol: "safari") {
                                    Launch.open(url, bundleID: o.browserBundleID)
                                    return .dismiss
                                }, isPinnable: false)]
        }
        guard let item = item(text) else { return [] }
        return [item]
    }

    func resolve(_ id: String) -> PaletteItem? {
        if let c = commands.first(where: { $0.id == id }) { return c }
        guard id.hasPrefix("web:search:") else { return nil }
        return item(String(id.dropFirst(11)))
    }

    func item(_ text: String) -> PaletteItem? {
        let o = engine.options.value
        guard let url = Launch.searchURL(text, template: o.searchTemplate) else { return nil }
        var item = PaletteItem(
            id: "web:search:\(text)",
            title: String(localized: "Search “\(text)” on \(engineName)", comment: "%1$@ is the search text, %2$@ a search engine such as Google"),
            subtitle: o.searchEngine == .google && o.browserBundleID.isEmpty ? String(localized: "Web search · default engine")
                : String(localized: "Web search"),
            icon: icon, providerID: id, accessory: name, score: 1,
            primary: PaletteAction(id: "open", title: String(localized: "Search", comment: "Action: search the web"), symbol: "magnifyingglass") {
                Launch.open(url, bundleID: o.browserBundleID)
                return .dismiss
            },
            actions: [PaletteAction(id: "copy", title: String(localized: "Copy Search URL"), symbol: "link", shortcut: ActionKeys.copyPath) {
                Launch.copy(url.absoluteString)
                return .dismiss
            }],
            isFallback: true, isPinnable: false)
        item.section = name
        return item
    }

    private func homepage(_ url: URL) -> URL? {
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        c?.path = "/"
        c?.query = nil
        return c?.url
    }
}
