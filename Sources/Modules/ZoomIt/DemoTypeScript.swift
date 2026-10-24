import Foundation

/// A key DemoType presses for a `[enter]`-style control.
public enum DemoTypeKey: String, Sendable {
    case enter, up, down, left, right
}

/// One step of a DemoType segment.
public enum DemoTypeToken: Equatable, Sendable {
    /// Characters typed one by one (newlines press Return, tabs press Tab).
    case text(String)
    case key(DemoTypeKey)
    /// `[pause:n]`: wait n seconds (ignored in user-driven mode).
    case pause(Int)
    /// `[paste]…[/paste]`: put the text on the clipboard and paste it at once.
    case paste(String)
}

/// A DemoType script: segments separated by `[end]`, each typed by one press of the shortcut.
///
/// Normalization follows ZoomIt: line endings become `\n`, unprintable characters are
/// dropped, a leading newline is removed, one newline on each side of `[end]`, after
/// `[paste]` and before `[/paste]` is removed, and whitespace after the last `[end]` is ignored.
/// Unknown `[tags]` are typed literally.
public struct DemoTypeScript: Equatable, Sendable {
    public let segments: [[DemoTypeToken]]

    /// The longest control ZoomIt accepts is `[pause:000]`.
    static let maxControlLength = 11

    public init(_ text: String) {
        segments = Self.parse(Self.normalize(text))
    }

    /// Clipboard text is a script only when it starts with `[start]` (a safety prefix).
    public static func fromClipboard(_ text: String) -> DemoTypeScript? {
        guard text.hasPrefix("[start]") else { return nil }
        let script = DemoTypeScript(String(text.dropFirst("[start]".count)))
        return script.segments.isEmpty ? nil : script
    }

    // MARK: Normalization

    public static func normalize(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        s = String(String.UnicodeScalarView(s.unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\t" || !(CharacterSet.controlCharacters.contains(scalar)
                                                   || CharacterSet.illegalCharacters.contains(scalar))
        }))
        if s.hasPrefix("\n") { s.removeFirst() }
        s = trimNewline(around: "[end]", left: true, right: true, in: s)
        s = trimNewline(around: "[paste]", left: false, right: true, in: s)
        s = trimNewline(around: "[/paste]", left: true, right: false, in: s)
        if let last = s.range(of: "[end]", options: .backwards),
           s[last.upperBound...].allSatisfy({ $0 == " " || $0 == "\n" || $0 == "\t" }) {
            s.removeSubrange(last.upperBound...)
        }
        return s
    }

    private static func trimNewline(around control: String, left: Bool, right: Bool, in text: String) -> String {
        var out = ""
        var rest = Substring(text)
        while let r = rest.range(of: control) {
            var before = rest[..<r.lowerBound]
            if left, before.hasSuffix("\n") { before = before.dropLast() }
            out += before
            out += control
            rest = rest[r.upperBound...]
            if right, rest.hasPrefix("\n") { rest = rest.dropFirst() }
        }
        return out + rest
    }

    // MARK: Parsing

    private static func parse(_ s: String) -> [[DemoTypeToken]] {
        var segments: [[DemoTypeToken]] = []
        var tokens: [DemoTypeToken] = []
        var pending = ""
        let chars = Array(s)
        var i = 0

        func flushText() {
            if !pending.isEmpty { tokens.append(.text(pending)); pending = "" }
        }

        while i < chars.count {
            if chars[i] == "[", let (token, length) = control(in: chars, at: i) {
                flushText()
                if let token { tokens.append(token) } else { segments.append(tokens); tokens = [] }
                i += length
                continue
            }
            pending.append(chars[i])
            i += 1
        }
        flushText()
        if !tokens.isEmpty { segments.append(tokens) }
        return segments.filter { !$0.isEmpty }
    }

    /// A control at `i`: the token (`nil` for `[end]`) and how many characters it spans.
    private static func control(in chars: [Character], at i: Int) -> (DemoTypeToken?, Int)? {
        guard let close = chars[i...].prefix(maxControlLength).firstIndex(of: "]") else { return nil }
        let tag = String(chars[i...close])
        let length = close - i + 1
        switch tag {
        case "[end]": return (nil, length)
        case "[enter]": return (.key(.enter), length)
        case "[up]": return (.key(.up), length)
        case "[down]": return (.key(.down), length)
        case "[left]": return (.key(.left), length)
        case "[right]": return (.key(.right), length)
        case "[paste]":
            let rest = String(chars[(close + 1)...])
            guard let end = rest.range(of: "[/paste]") else { return nil }
            let body = String(rest[..<end.lowerBound])
            return (.paste(body), length + body.count + "[/paste]".count)
        default:
            guard tag.hasPrefix("[pause:"), let n = Int(tag.dropFirst(7).dropLast()), n >= 0 else { return nil }
            return (.pause(n), length)
        }
    }
}

/// Flattens a segment into the individual actions DemoType performs, one per keystroke.
public enum DemoTypeStep: Equatable, Sendable {
    case character(Character)
    case key(DemoTypeKey)
    case pause(Int)
    case paste(String)

    public static func steps(of segment: [DemoTypeToken]) -> [DemoTypeStep] {
        segment.flatMap { token -> [DemoTypeStep] in
            switch token {
            case .text(let s): s.map { .character($0) }
            case .key(let k): [.key(k)]
            case .pause(let n): [.pause(n)]
            case .paste(let s): [.paste(s)]
            }
        }
    }

    /// Delay before each keystroke, in seconds, for a speed of 10 (slow) … 100 (fast), with
    /// ZoomIt's variance: anywhere from almost nothing to twice the base delay.
    public static func delay(speed: Double, random: Double) -> Double {
        let base = 110 - min(max(speed, 10), 100)
        return max(1, base * 2 * min(max(random, 0), 1)) / 1000
    }

    /// Characters typed per key press in user-driven mode: faster speeds type more per press.
    public static func charactersPerPress(speed: Double) -> Int {
        let s = min(max(speed, 10), 100)
        return s < 40 ? 1 : s < 70 ? 2 : 3
    }
}
