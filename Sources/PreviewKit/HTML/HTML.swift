import Foundation

/// HTML escaping and the page wrapper every text preview uses.
public enum HTML {
    /// Escapes text for element content and attribute values.
    public static func escape(_ s: some StringProtocol) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count + 16)
        for c in s.unicodeScalars {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.unicodeScalars.append(c)
            }
        }
        return out
    }

    /// A complete document: scripts are always blocked by the Content Security Policy;
    /// images may come from `data:`/`cid:` URLs, and from the network only when `allowRemoteImages`.
    public static func document(title: String, body: String, theme: PreviewTheme, extraCSS: String = "",
                                allowRemoteImages: Bool = false, fontSize: Double = 13) -> String {
        let img = allowRemoteImages ? "data: cid: https: http:" : "data: cid:"
        let scheme: String
        switch theme {
        case .auto: scheme = "light dark"
        case .light: scheme = "light"
        case .dark: scheme = "dark"
        }
        return """
        <!DOCTYPE html>
        <html class="theme-\(theme.rawValue)"><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src \(img); font-src data:">
        <meta name="color-scheme" content="\(scheme)">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(title))</title>
        <style>
        \(Styles.palette(theme))
        :root { --font-size: \(String(format: "%.1f", fontSize))px; }
        \(Styles.base)
        \(extraCSS)
        </style></head>
        <body>
        \(body)
        </body></html>
        """
    }

    /// Lowercased, punctuation-free anchor slug the way GitHub builds heading ids.
    public static func slug(_ text: String) -> String {
        var out = ""
        for ch in text.lowercased() {
            if ch.isLetter || ch.isNumber || ch == "-" || ch == "_" { out.append(ch) }
            else if ch == " " { out.append("-") }
        }
        return out
    }
}
