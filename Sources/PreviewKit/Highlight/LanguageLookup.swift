import Foundation

extension Language {
    private static let byName: [String: Language] = {
        var map: [String: Language] = [:]
        for l in all {
            for key in [l.id, l.name.lowercased()] + l.aliases where map[key] == nil { map[key] = l }
        }
        for l in all { for e in l.extensions where map[e] == nil { map[e] = l } }
        return map
    }()

    private static let byExtension: [String: Language] = {
        var map: [String: Language] = [:]
        for l in all { for e in l.extensions where map[e] == nil { map[e] = l } }
        return map
    }()

    private static let byFileName: [String: Language] = {
        var map: [String: Language] = [:]
        for l in all { for f in l.fileNames where map[f] == nil { map[f] = l } }
        return map
    }()

    /// A language by fence name, id, alias or extension (`"js"`, `"c++"`, `"Swift"`), case-insensitive.
    public static func named(_ name: String) -> Language? {
        let key = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard !key.isEmpty else { return nil }
        if let l = byName[key] { return l }
        // "language-python", "{.python}", "python title=x"
        let cleaned = key.replacingOccurrences(of: "language-", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "{}."))
        return cleaned == key ? nil : byName[cleaned]
    }

    /// The language for a file name, or nil when nothing matches.
    public static func forFileName(_ fileName: String) -> Language? {
        if let l = byFileName[fileName] { return l }
        let lower = fileName.lowercased()
        if lower.hasPrefix("dockerfile") || lower.hasSuffix(".dockerfile") { return dockerfile }
        if lower.hasPrefix("makefile") { return makefile }
        if lower.hasPrefix(".env") { return ini }
        let ext = (lower as NSString).pathExtension
        return ext.isEmpty ? nil : byExtension[ext]
    }

    /// The interpreter named by a `#!` first line: `#!/usr/bin/env python3` → Python.
    public static func forShebang(_ firstLine: Substring) -> Language? {
        guard firstLine.hasPrefix("#!") else { return nil }
        let parts = firstLine.dropFirst(2).split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard var program = parts.first.map({ String($0.split(separator: "/").last ?? $0) }) else { return nil }
        if program == "env" {
            guard let next = parts.dropFirst().first(where: { !$0.hasPrefix("-") }) else { return nil }
            program = String(next)
        }
        let base = program.trimmingCharacters(in: CharacterSet.decimalDigits.union(CharacterSet(charactersIn: ".")))
        return all.first { $0.interpreters.contains(program) || $0.interpreters.contains(base) }
    }

    /// File name first, then the shebang line of `text`.
    public static func detect(fileName: String, text: String?) -> Language? {
        if let l = forFileName(fileName) { return l }
        if let text, let first = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first {
            return forShebang(first)
        }
        return nil
    }
}
