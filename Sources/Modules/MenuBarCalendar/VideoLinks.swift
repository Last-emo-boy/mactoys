import Foundation

/// A video call service a meeting link can belong to.
enum VideoService: String, Codable, CaseIterable, Sendable {
    case zoom, meet, teams, webex, facetime

    /// Service names are brands: the same in every language.
    var name: String {
        switch self {
        case .zoom: "Zoom"
        case .meet: "Google Meet"
        case .teams: "Microsoft Teams"
        case .webex: "Webex"
        case .facetime: "FaceTime"
        }
    }

    var symbol: String { "video.fill" }

    /// Which service a web link belongs to, or nil.
    static func match(_ url: URL) -> VideoService? {
        guard let host = url.host()?.lowercased() else {
            if url.scheme?.lowercased() == "zoommtg" { return .zoom }
            if url.scheme?.lowercased() == "msteams" { return .teams }
            return nil
        }
        let path = url.path().lowercased()
        func on(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        switch url.scheme?.lowercased() {
        case "zoommtg", "zoomus": return .zoom
        case "msteams": return .teams
        case "https", "http": break
        default: return nil
        }
        if on("zoom.us") || on("zoom.com") || on("zoomgov.com") {
            return path.hasPrefix("/j/") || path.hasPrefix("/my/") || path.hasPrefix("/w/") || path.hasPrefix("/s/")
                || path.contains("/wc/join/") ? .zoom : nil
        }
        if host == "meet.google.com" { return path.count > 3 ? .meet : nil }
        if on("teams.microsoft.com") || on("teams.live.com") || on("teams.cloud.microsoft") {
            return path.contains("meetup-join") || path.hasPrefix("/meet/") || path.hasPrefix("/l/meet") ? .teams : nil
        }
        if on("webex.com") {
            return path.contains("/meet/") || path.contains("/join/") || path.contains("j.php") || path.contains("/wbxmjs/") ? .webex : nil
        }
        if host == "facetime.apple.com" { return path.hasPrefix("/join") ? .facetime : nil }
        return nil
    }
}

/// A link that joins a call.
struct VideoLink: Hashable, Sendable {
    let service: VideoService
    let url: URL

    /// The link to open: Zoom web links go straight to the Zoom app when it is installed.
    func joinURL(zoomAppInstalled: Bool) -> URL {
        guard service == .zoom, zoomAppInstalled, url.scheme?.hasPrefix("http") == true,
              let native = VideoLinks.zoomAppURL(for: url) else { return url }
        return native
    }
}

/// Finds call links in an event's URL, location and notes.
enum VideoLinks {
    /// The first call link: the event's URL first, then its location, then its notes.
    static func find(url: URL?, location: String?, notes: String?) -> VideoLink? {
        if let url, let link = classify(url) { return link }
        for text in [location, notes] {
            guard let text, !text.isEmpty else { continue }
            if let link = links(in: text).first { return link }
        }
        return nil
    }

    /// Every call link in a piece of text (plain or HTML notes), in order.
    static func links(in text: String) -> [VideoLink] {
        var found: [VideoLink] = []
        for candidate in candidateURLs(in: text) {
            if let link = classify(candidate), !found.contains(link) { found.append(link) }
        }
        return found
    }

    /// A link as a call link, unwrapping mail-security and search redirects.
    static func classify(_ url: URL) -> VideoLink? {
        let unwrapped = unwrap(url)
        guard let service = VideoService.match(unwrapped) else { return nil }
        return VideoLink(service: service, url: unwrapped)
    }

    /// Safe Links (`…safelinks.protection.outlook.com/?url=`), Google (`google.com/url?q=`) and
    /// similar wrappers carry the real link in a query parameter.
    static func unwrap(_ url: URL) -> URL {
        guard let host = url.host()?.lowercased(),
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return url }
        let key: String?
        if host.hasSuffix("safelinks.protection.outlook.com") { key = "url" }
        else if (host == "www.google.com" || host == "google.com") && url.path() == "/url" { key = "q" }
        else if host.hasSuffix("urldefense.com") || host.hasSuffix("urldefense.proofpoint.com") { key = "u" }
        else { key = nil }
        guard let key, let value = items.first(where: { $0.name == key })?.value,
              let inner = URL(string: value), inner.scheme != nil else { return url }
        return unwrap(inner)
    }

    /// URLs in text: whatever the link detector finds, plus app links (zoommtg:, msteams:) it ignores.
    static func candidateURLs(in text: String) -> [URL] {
        // HTML notes: hrefs often hold the link while the visible text is "Join meeting".
        let cleaned = text.replacingOccurrences(of: "&amp;", with: "&")
        var urls: [(Int, URL)] = []
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let range = NSRange(cleaned.startIndex..., in: cleaned)
            for match in detector.matches(in: cleaned, range: range) {
                if let url = match.url { urls.append((match.range.location, trimmed(url))) }
            }
        }
        if let regex = try? NSRegularExpression(pattern: #"(?i)\b(zoommtg|msteams)://[^\s"'<>]+"#) {
            let range = NSRange(cleaned.startIndex..., in: cleaned)
            for match in regex.matches(in: cleaned, range: range) {
                if let r = Range(match.range, in: cleaned), let url = URL(string: String(cleaned[r])) {
                    urls.append((match.range.location, url))
                }
            }
        }
        return urls.sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// Drops punctuation the detector sometimes keeps at the end of a link.
    private static func trimmed(_ url: URL) -> URL {
        var s = url.absoluteString
        while let last = s.last, ")].,;>\"'".contains(last) { s.removeLast() }
        return URL(string: s) ?? url
    }

    /// `https://acme.zoom.us/j/123456789?pwd=abc` → `zoommtg://acme.zoom.us/join?action=join&confno=123456789&pwd=abc`.
    static func zoomAppURL(for url: URL) -> URL? {
        guard let host = url.host() else { return nil }
        let parts = url.path().split(separator: "/")
        guard parts.count >= 2, parts[0] == "j", let number = Int(parts[1]) else { return nil }
        var c = URLComponents()
        c.scheme = "zoommtg"
        c.host = host
        c.path = "/join"
        var items = [URLQueryItem(name: "action", value: "join"), URLQueryItem(name: "confno", value: String(number))]
        if let pwd = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "pwd" })?.value {
            items.append(URLQueryItem(name: "pwd", value: pwd))
        }
        c.queryItems = items
        return c.url
    }
}
