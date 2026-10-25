import Foundation

/// The metadata header of a Script Command: comment lines near the top of an executable file.
///
///     #!/bin/zsh
///     # @mactoys.title Say Hello
///     # @mactoys.subtitle Greets someone by name
///     # @mactoys.icon hand.wave            (SF Symbol name or an emoji)
///     # @mactoys.mode output               (silent | output | inline | terminal)
///     # @mactoys.argument Name             (placeholder; the script then takes one argument)
///     # @mactoys.keywords greet hi
///
/// Raycast script commands (`@raycast.title`, `@raycast.mode fullOutput`, `@raycast.argument1 {…}`)
/// are understood too, so existing scripts work unchanged.
struct ScriptMetadata: Hashable, Sendable {
    enum Mode: String, Codable, CaseIterable, Sendable {
        /// Runs in the background; the last output line is shown as a HUD.
        case silent
        /// Shows the full output in the palette.
        case output
        /// Shows the first output line as the command's subtitle, refreshed periodically.
        case inline
        /// Runs in a Terminal window.
        case terminal

        var title: String {
            switch self {
            case .silent: String(localized: "Silent", comment: "Script mode: runs in the background, a HUD shows the last line")
            case .output: String(localized: "Show output", comment: "Script mode: shows the full output")
            case .inline: String(localized: "Inline", comment: "Script mode: the first output line becomes the command's subtitle")
            case .terminal: TerminalApp.terminal.title
            }
        }
    }

    var title: String
    var subtitle: String?
    var icon: String?
    var mode: Mode = .output
    /// Placeholder of the argument; nil when the script takes none.
    var argument: String?
    var argumentOptional = false
    var keywords: [String] = []
    /// For inline scripts: how often the output is refreshed, in seconds.
    var refreshInterval: TimeInterval?
    var needsConfirmation = false
    /// Whether any metadata key was found (otherwise only the file name is known).
    var hasHeader = false

    /// How many lines from the top are scanned for metadata.
    static let scannedLines = 60

    static func parse(_ text: String, fileName: String) -> ScriptMetadata {
        var meta = ScriptMetadata(title: humanize(fileName))
        var argumentFound = false
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false).prefix(scannedLines) {
            guard let (key, value) = keyValue(String(rawLine)) else { continue }
            meta.hasHeader = true
            switch key {
            case "title":
                if !value.isEmpty { meta.title = value }
            case "subtitle", "description", "packagename":
                if !value.isEmpty, meta.subtitle == nil || key == "subtitle" { meta.subtitle = value }
            case "icon":
                if !value.isEmpty { meta.icon = value }
            case "mode":
                meta.mode = mode(value) ?? meta.mode
            case "argument", "argument1":
                guard !argumentFound else { break }
                argumentFound = true
                if value.hasPrefix("{"), let data = value.data(using: .utf8),
                   let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    meta.argument = (obj["placeholder"] as? String) ?? defaultArgument
                    meta.argumentOptional = (obj["optional"] as? Bool) ?? false
                } else {
                    var placeholder = value
                    if placeholder.lowercased().hasSuffix("(optional)") {
                        meta.argumentOptional = true
                        placeholder = String(placeholder.dropLast("(optional)".count)).trimmingCharacters(in: .whitespaces)
                    }
                    meta.argument = placeholder.isEmpty ? defaultArgument : placeholder
                }
            case "optional":
                meta.argumentOptional = ["true", "yes", "1"].contains(value.lowercased())
            case "keywords", "keyword", "aliases":
                meta.keywords += value.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
            case "refresh", "refreshtime":
                meta.refreshInterval = interval(value)
            case "needsconfirmation", "confirm":
                meta.needsConfirmation = ["true", "yes", "1"].contains(value.lowercased())
            default:
                break
            }
        }
        if meta.mode == .inline, meta.refreshInterval == nil { meta.refreshInterval = 60 }
        return meta
    }

    /// `# @mactoys.title Foo` → ("title", "Foo").
    static func keyValue(_ line: String) -> (String, String)? {
        var s = line.trimmingCharacters(in: .whitespaces)
        guard !s.hasPrefix("#!") else { return nil }
        var stripped = false
        for marker in ["#", "//", "--", ";", "%", "'", "REM "] where s.hasPrefix(marker) {
            s.removeFirst(marker.count)
            stripped = true
            break
        }
        guard stripped else { return nil }
        s = s.trimmingCharacters(in: .whitespaces)
        for prefix in ["@mactoys.", "@raycast."] where s.lowercased().hasPrefix(prefix) {
            let rest = s.dropFirst(prefix.count)
            let key = rest.prefix { !$0.isWhitespace }.lowercased()
            let value = rest.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
            return key.isEmpty ? nil : (key, value)
        }
        return nil
    }

    static func mode(_ value: String) -> Mode? {
        switch value.lowercased() {
        case "silent", "compact": .silent
        case "output", "fulloutput", "full": .output
        case "inline": .inline
        case "terminal": .terminal
        default: nil
        }
    }

    /// "10s", "5m", "1h", "1d", or plain seconds.
    static func interval(_ value: String) -> TimeInterval? {
        let v = value.trimmingCharacters(in: .whitespaces).lowercased()
        guard let unit = v.last else { return nil }
        let multipliers: [Character: Double] = ["s": 1, "m": 60, "h": 3600, "d": 86400]
        if let m = multipliers[unit], let n = Double(v.dropLast()) { return max(n * m, 1) }
        return Double(v).map { max($0, 1) }
    }

    static var defaultArgument: String { String(localized: "Argument", comment: "A script's argument: its placeholder, a detail row or a row label") }

    /// "say-hello.sh" → "Say Hello".
    static func humanize(_ fileName: String) -> String {
        let base = (fileName as NSString).deletingPathExtension
        let words = base.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " || $0 == "." })
        let title = words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        return title.isEmpty ? fileName : title
    }
}
