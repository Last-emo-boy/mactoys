import Foundation

/// Output names from the file name format (`%1 (%2)`):
/// `%1` original name, `%2` size name, `%3` selected width, `%4` selected height,
/// `%5` actual width, `%6` actual height. `/` in the format makes subfolders.
public enum ResizeFileNamer {
    public struct Values: Sendable {
        public var original: String
        public var sizeName: String
        public var selectedWidth: Double
        public var selectedHeight: Double
        public var actualWidth: Int
        public var actualHeight: Int

        public init(original: String, sizeName: String, selectedWidth: Double, selectedHeight: Double,
                    actualWidth: Int, actualHeight: Int) {
            self.original = original
            self.sizeName = sizeName
            self.selectedWidth = selectedWidth
            self.selectedHeight = selectedHeight
            self.actualWidth = actualWidth
            self.actualHeight = actualHeight
        }
    }

    /// The relative path (without extension) the format produces, as path components.
    /// Characters that can't be in a file name become `_`; empty, `.` and `..` parts are dropped.
    public static func components(format: String, values v: Values) -> [String] {
        let tokens: [Character: String] = [
            "1": v.original, "2": v.sizeName,
            "3": v.selectedWidth > 0 ? Self.format(v.selectedWidth) : "",
            "4": v.selectedHeight > 0 ? Self.format(v.selectedHeight) : "",
            "5": String(v.actualWidth), "6": String(v.actualHeight),
        ]
        var parts: [String] = []
        var current = ""
        var i = format.startIndex
        while i < format.endIndex {
            let c = format[i]
            let next = format.index(after: i)
            if c == "%", next < format.endIndex, let value = tokens[format[next]] {
                current += sanitize(value)
                i = format.index(after: next)
                continue
            }
            if c == "/" || c == "\\" {
                parts.append(current)
                current = ""
            } else {
                current.append(c)
            }
            i = next
        }
        parts.append(current)
        let cleaned = parts.map { sanitize($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        return cleaned.isEmpty ? [sanitize(v.original)] : cleaned
    }

    /// Replaces characters macOS doesn't allow in names.
    static func sanitize(_ s: String) -> String {
        String(s.map { $0 == "/" || $0 == ":" || $0 == "\0" ? "_" : $0 })
    }

    /// `50` → "50", `2.5` → "2.5", `2.54` → "2.54".
    public static func format(_ value: Double) -> String {
        if value.rounded() == value, abs(value) < 1e12 { return String(Int(value)) }
        var s = String(format: "%.2f", value)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    /// `base/<components>.<ext>`, adding " (2)", " (3)", … while the name is taken.
    public static func uniqueURL(in base: URL, components: [String], pathExtension: String,
                                 exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        var folder = base
        for c in components.dropLast() { folder.appendPathComponent(c, isDirectory: true) }
        let stem = components.last ?? "image"
        func candidate(_ n: Int) -> URL {
            let name = n == 1 ? stem : "\(stem) (\(n))"
            return folder.appendingPathComponent(pathExtension.isEmpty ? name : "\(name).\(pathExtension)")
        }
        var n = 1
        while exists(candidate(n)) { n += 1 }
        return candidate(n)
    }
}
