import CoreGraphics
import Foundation

/// A display that exists now (global top-left coordinates).
struct DisplayGeometry: Equatable {
    var id: String
    var frame: CGRect
    var visibleFrame: CGRect
    var isMain: Bool
}

/// Maps saved window frames onto the displays connected now.
enum DisplayMapper {
    /// The display a saved window should go to: the same display when it's connected,
    /// otherwise the main display.
    static func target(for savedID: String, among displays: [DisplayGeometry]) -> DisplayGeometry? {
        displays.first { $0.id == savedID } ?? displays.first { $0.isMain } ?? displays.first
    }

    /// Where a window saved at `frame` on `saved` goes on `target`.
    ///
    /// Same-sized visible areas keep the exact frame (moved along if the display was rearranged);
    /// otherwise the frame is scaled proportionally to the new visible area. The result always
    /// fits inside the target's visible frame.
    static func map(_ frame: CGRect, from saved: SavedDisplay?, to target: DisplayGeometry) -> CGRect {
        let tv = target.visibleFrame
        guard let sv = saved?.visibleFrame, sv.width > 0, sv.height > 0 else { return clamp(frame, into: tv) }
        let mapped: CGRect
        if abs(sv.width - tv.width) < 1 && abs(sv.height - tv.height) < 1 {
            mapped = frame.offsetBy(dx: tv.minX - sv.minX, dy: tv.minY - sv.minY)
        } else {
            let sx = tv.width / sv.width, sy = tv.height / sv.height
            mapped = CGRect(x: tv.minX + (frame.minX - sv.minX) * sx, y: tv.minY + (frame.minY - sv.minY) * sy,
                            width: frame.width * sx, height: frame.height * sy)
        }
        return clamp(mapped, into: tv)
    }

    /// Shrinks `r` to fit `bounds` and moves it inside; values are rounded to whole points.
    static func clamp(_ r: CGRect, into bounds: CGRect) -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else { return r }
        let w = min(r.width, bounds.width).rounded(), h = min(r.height, bounds.height).rounded()
        let x = min(max(r.minX, bounds.minX), bounds.maxX - w).rounded()
        let y = min(max(r.minY, bounds.minY), bounds.maxY - h).rounded()
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// The saved display that shows most of `frame` (for re-homing a window dragged in the editor).
    static func display(for frame: CGRect, among displays: [SavedDisplay]) -> SavedDisplay? {
        displays.max { a, b in a.frame.intersection(frame).area < b.frame.intersection(frame).area }
    }
}

/// Converts between global coordinates and the editor's display canvas.
struct CanvasMapping {
    let origin: CGPoint
    let scale: CGFloat
    let inset: CGPoint

    init(displays: [CGRect], canvas: CGSize, padding: CGFloat) {
        let union = displays.reduce(CGRect.null) { $0.union($1) }
        guard !union.isNull, union.width > 0, union.height > 0 else {
            origin = .zero
            scale = 1
            inset = CGPoint(x: padding, y: padding)
            return
        }
        let availW = max(canvas.width - padding * 2, 1), availH = max(canvas.height - padding * 2, 1)
        scale = min(availW / union.width, availH / union.height)
        origin = union.origin
        inset = CGPoint(x: (canvas.width - union.width * scale) / 2, y: (canvas.height - union.height * scale) / 2)
    }

    func toCanvas(_ r: CGRect) -> CGRect {
        CGRect(x: inset.x + (r.minX - origin.x) * scale, y: inset.y + (r.minY - origin.y) * scale,
               width: r.width * scale, height: r.height * scale)
    }

    func toGlobal(_ r: CGRect) -> CGRect {
        CGRect(x: origin.x + (r.minX - inset.x) / scale, y: origin.y + (r.minY - inset.y) / scale,
               width: r.width / scale, height: r.height / scale)
    }

    /// A canvas drag distance in global points.
    func toGlobal(_ d: CGSize) -> CGSize { CGSize(width: d.width / scale, height: d.height / scale) }
}

/// Words for where a window sits on its display: "left two thirds", "top right", "full screen".
enum PositionDescriber {
    private static let fractions: [(Double, String)] = [(1.0 / 4, "quarter"), (1.0 / 3, "third"), (1.0 / 2, "half"),
                                                         (2.0 / 3, "two thirds"), (3.0 / 4, "three quarters")]

    static func describe(_ frame: CGRect, in visible: CGRect) -> String {
        guard visible.width > 0, visible.height > 0 else { return "custom" }
        let w = frame.width / visible.width, h = frame.height / visible.height
        let x0 = (frame.minX - visible.minX) / visible.width, x1 = (frame.maxX - visible.minX) / visible.width
        let y0 = (frame.minY - visible.minY) / visible.height, y1 = (frame.maxY - visible.minY) / visible.height
        let fullW = w >= 0.9, fullH = h >= 0.9
        if fullW && fullH { return "full screen" }
        let hSide: String? = x0 < 0.05 ? "left" : (x1 > 0.95 ? "right" : nil)
        let vSide: String? = y0 < 0.05 ? "top" : (y1 > 0.95 ? "bottom" : nil)
        if fullH { return [hSide ?? "center", fraction(w)].compactMap { $0 }.joined(separator: " ") }
        if fullW { return [vSide ?? "middle", fraction(h)].compactMap { $0 }.joined(separator: " ") }
        switch (vSide, hSide) {
        case let (v?, h?): return "\(v) \(h)"
        case let (v?, nil): return v
        case let (nil, h?): return h
        default: return "center"
        }
    }

    private static func fraction(_ f: Double) -> String? {
        fractions.first { abs($0.0 - f) < 0.05 }?.1
    }
}

/// Splits a command-line string into arguments like a POSIX shell: whitespace separates,
/// '…' is literal, inside "…" a backslash escapes only the characters " \ $ and `, outside quotes it escapes
/// any character.
enum ArgumentSplitter {
    static func split(_ s: String) -> [String] {
        var args: [String] = []
        var current = ""
        var inArg = false
        var quote: Character?
        var escape = false
        for ch in s {
            if escape {
                if quote == "\"" && !"\"\\$`".contains(ch) { current.append("\\") }
                current.append(ch)
                escape = false
                inArg = true
                continue
            }
            switch quote {
            case "'":
                if ch == "'" { quote = nil } else { current.append(ch) }
            case "\"":
                if ch == "\"" { quote = nil } else if ch == "\\" { escape = true } else { current.append(ch) }
            default:
                if ch == "'" || ch == "\"" {
                    quote = ch
                    inArg = true
                } else if ch == "\\" {
                    escape = true
                } else if ch.isWhitespace {
                    if inArg { args.append(current); current = ""; inArg = false }
                } else {
                    current.append(ch)
                    inArg = true
                }
            }
        }
        if inArg || !current.isEmpty { args.append(current) }
        return args
    }
}

/// Interprets the "URL or file to open" field.
enum OpenTarget {
    /// `/path` and `~/path` are files; `scheme:` strings are URLs; a bare host like
    /// `developer.apple.com` becomes an https URL.
    static func url(_ raw: String, home: String = NSHomeDirectory()) -> URL? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("/") { return URL(fileURLWithPath: s) }
        if s == "~" || s.hasPrefix("~/") { return URL(fileURLWithPath: home + s.dropFirst()) }
        if let colon = s.firstIndex(of: ":"), s[..<colon].count > 1,
           s[..<colon].allSatisfy({ $0.isLetter || $0.isNumber || "+-.".contains($0) }), let u = URL(string: s) {
            return u
        }
        if !s.contains(" "), let host = s.split(separator: "/").first, host.contains("."),
           let u = URL(string: "https://" + s) {
            return u
        }
        return URL(fileURLWithPath: s, relativeTo: URL(fileURLWithPath: home, isDirectory: true)).absoluteURL
    }

    /// Short form for row subtitles: `~/mactoys`, `developer.apple.com`.
    static func display(_ raw: String, home: String = NSHomeDirectory()) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix(home + "/") { return "~" + s.dropFirst(home.count) }
        for prefix in ["https://", "http://"] where s.hasPrefix(prefix) { return String(s.dropFirst(prefix.count)) }
        return s
    }
}

/// Pairs saved windows with windows that appeared: same title first, then similar titles,
/// then whatever is left in order.
enum WindowMatcher {
    /// - Returns: for each saved title, the index of its window in `windows`, or nil.
    static func assign(saved: [String], windows: [String]) -> [Int?] {
        var result = [Int?](repeating: nil, count: saved.count)
        var free = Set(windows.indices)
        func pass(_ match: (String, String) -> Bool) {
            for (i, title) in saved.enumerated() where result[i] == nil {
                if let j = windows.indices.first(where: { free.contains($0) && match(title, windows[$0]) }) {
                    result[i] = j
                    free.remove(j)
                }
            }
        }
        pass { !$0.isEmpty && $0 == $1 }
        pass { a, b in
            let x = a.lowercased(), y = b.lowercased()
            return !x.isEmpty && !y.isEmpty && (x.contains(y) || y.contains(x))
        }
        pass { _, _ in true }
        return result
    }
}
