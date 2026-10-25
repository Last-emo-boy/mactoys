import Darwin
import Foundation

/// A file or folder in the PowerRename list.
public struct RenameItem: Identifiable, Hashable, Sendable {
    /// Position in the list; also seeds the item's random values.
    public let id: Int
    public let url: URL
    /// A real folder. Packages (`.app`, `.rtfd`) count as files and keep their extension.
    public let isFolder: Bool
    /// 0 for selected items, 1 for their children, and so on.
    public let depth: Int
    public let created: Date?
    public let modified: Date?
    public let accessed: Date?

    public init(id: Int, url: URL, isFolder: Bool = false, depth: Int = 0, created: Date? = nil,
                modified: Date? = nil, accessed: Date? = nil) {
        self.id = id
        self.url = url
        self.isFolder = isFolder
        self.depth = depth
        self.created = created
        self.modified = modified
        self.accessed = accessed
    }

    public var name: String { url.lastPathComponent }

    func date(_ source: RenameDateSource) -> Date? {
        switch source {
        case .created: created
        case .modified: modified
        case .accessed: accessed
        }
    }
}

/// One row of the preview.
public struct RenamePreview: Identifiable, Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        /// No match, or the result equals the current name.
        case unchanged
        /// Left out by the include and exclude options.
        case skipped
        /// The user cleared the row's checkbox.
        case unchecked
        case rename
        /// The wanted name (`proposedName`) is taken; `newName` adds a number.
        case conflict
        /// The result can't be a file name; the reason is given.
        case invalid(String)
    }

    public let item: RenameItem
    /// The name the search and replace produced, before resolving conflicts.
    public let proposedName: String?
    /// The name Apply will write; nil when the item is left alone.
    public let newName: String?
    public let status: Status

    public var id: Int { item.id }
    public var willRename: Bool { newName != nil }
}

/// What the planner needs from the file system; injectable for tests.
public struct RenameEnvironment {
    /// Names currently in a folder.
    public var existingNames: (URL) -> [String]
    /// Whether names in a folder are case-sensitive (APFS is usually not).
    public var isCaseSensitive: (URL) -> Bool
    /// Photo metadata variables of a file (`PhotoMetadata.read`).
    public var metadata: (URL) -> [String: String]

    public init(existingNames: @escaping (URL) -> [String] = { _ in [] },
                isCaseSensitive: @escaping (URL) -> Bool = { _ in false },
                metadata: @escaping (URL) -> [String: String] = { _ in [:] }) {
        self.existingNames = existingNames
        self.isCaseSensitive = isCaseSensitive
        self.metadata = metadata
    }

    /// Reads the real file system.
    public static var live: RenameEnvironment {
        RenameEnvironment(
            existingNames: { (try? FileManager.default.contentsOfDirectory(atPath: $0.path)) ?? [] },
            isCaseSensitive: { (try? $0.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?
                .volumeSupportsCaseSensitiveNames ?? false },
            metadata: PhotoMetadata.read)
    }
}

/// Computes new names. Pure apart from the `RenameEnvironment` it is given.
public struct RenameEngine {
    public struct InvalidPattern: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    public var options: RenameOptions
    public var flavor: RegexFlavor
    /// Seeds random values; keep it for a window's lifetime so the preview matches what Apply writes.
    public var seed: UInt64

    public init(options: RenameOptions, flavor: RegexFlavor = .standard, seed: UInt64 = 0) {
        self.options = options
        self.flavor = flavor
        self.seed = seed
    }

    // MARK: Planning

    /// The preview for every item, in order. Throws for an invalid regular expression.
    public func plan(_ items: [RenameItem], unchecked: Set<Int> = [],
                     environment: RenameEnvironment = RenameEnvironment()) throws -> [RenamePreview] {
        let regex = try makeRegex()
        let template = RenameTemplate(options.replace, regex: options.useRegex, flavor: flavor,
                                      enumerate: options.enumerate, randomize: options.randomize)
        let excludes = Self.patterns(options.exclude)
        var counter = 0
        var rows: [(item: RenameItem, proposed: String?, status: RenamePreview.Status)] = []
        rows.reserveCapacity(items.count)

        for item in items {
            if !isIncluded(item) || Self.isExcluded(item.name, by: excludes) {
                rows.append((item, nil, .skipped)); continue
            }
            if unchecked.contains(item.id) { rows.append((item, nil, .unchecked)); continue }
            var context = RenameTemplate.Context(counterIndex: counter, date: item.date(options.dateSource),
                                                 metadata: template.usesMetadata ? environment.metadata(item.url) : [:],
                                                 random: RandomSource(seed: seed ^ (UInt64(item.id) &* 0x2545_F491_4F6C_DD1D)))
            guard let result = newName(for: item.name, isFolder: item.isFolder, regex: regex,
                                       template: template, context: &context) else {
                rows.append((item, nil, .unchanged)); continue
            }
            if result.matched { counter += 1 }
            if result.name == item.name {
                rows.append((item, nil, .unchanged))
            } else if let problem = Self.validate(result.name) {
                rows.append((item, result.name, .invalid(problem)))
            } else {
                rows.append((item, result.name, .rename))
            }
        }
        return resolveConflicts(rows, environment: environment)
    }

    /// The new name of a single item, or nil when nothing applies. Used by `plan` and handy in tests.
    public func newName(for name: String, isFolder: Bool = false, counterIndex: Int = 0, date: Date? = nil,
                        metadata: [String: String] = [:]) throws -> String? {
        let regex = try makeRegex()
        let template = RenameTemplate(options.replace, regex: options.useRegex, flavor: flavor,
                                      enumerate: options.enumerate, randomize: options.randomize)
        var context = RenameTemplate.Context(counterIndex: counterIndex, date: date, metadata: metadata,
                                             random: RandomSource(seed: seed))
        return newName(for: name, isFolder: isFolder, regex: regex, template: template, context: &context)?.name
    }

    private func newName(for name: String, isFolder: Bool, regex: NSRegularExpression?, template: RenameTemplate,
                         context: inout RenameTemplate.Context) -> (name: String, matched: Bool)? {
        let parts = Self.split(name, isFolder: isFolder)
        let target: String
        switch options.scope {
        case .name: target = parts.stem
        case .extension:
            guard let ext = parts.ext else { return nil }
            target = ext
        case .both: target = name
        }
        var replaced: String?
        if let regex { replaced = Self.replace(target, regex: regex, matchAll: options.matchAll, template: template, context: &context) }
        guard replaced != nil || options.textFormat != .none else { return nil }
        let matched = replaced != nil
        var value = replaced ?? target

        let format = options.textFormat
        let result: String
        switch options.scope {
        case .name:
            result = format.apply(value) + (parts.ext.map { "." + $0 } ?? "")
        case .extension:
            value = format.apply(value)
            result = value.isEmpty ? parts.stem : parts.stem + "." + value
        case .both:
            if format == .lowercase || format == .uppercase || format == .none {
                result = format.apply(value)
            } else {
                // Title-casing an extension reads oddly, so only the stem gets it.
                let p = Self.split(value, isFolder: isFolder)
                result = format.apply(p.stem) + (p.ext.map { "." + $0 } ?? "")
            }
        }
        return (result, matched)
    }

    private func makeRegex() throws -> NSRegularExpression? {
        guard !options.search.isEmpty else { return nil }
        let pattern = options.useRegex ? options.search : NSRegularExpression.escapedPattern(for: options.search)
        do {
            return try NSRegularExpression(pattern: pattern, options: options.caseSensitive ? [] : [.caseInsensitive])
        } catch {
            throw InvalidPattern(message: String(localized: "The regular expression is not valid."))
        }
    }

    /// Replaces the first or every match. An empty match right where the previous one ended is skipped,
    /// so `(.*)` → `$1.txt` appends `.txt` once.
    static func replace(_ text: String, regex: NSRegularExpression, matchAll: Bool, template: RenameTemplate,
                        context: inout RenameTemplate.Context) -> String? {
        let ns = text as NSString
        var used: [NSTextCheckingResult] = []
        var lastEnd = -1
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, stop in
            guard let match else { return }
            if match.range.length == 0 && match.range.location == lastEnd { return }
            used.append(match)
            lastEnd = NSMaxRange(match.range)
            if !matchAll { stop.pointee = true }
        }
        guard !used.isEmpty else { return nil }
        var out = ""
        var cursor = 0
        for m in used {
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            out += template.render(match: m, in: ns, context: &context)
            cursor = NSMaxRange(m.range)
        }
        out += ns.substring(from: cursor)
        return out
    }

    private func isIncluded(_ item: RenameItem) -> Bool {
        if item.isFolder && !options.includeFolders { return false }
        if !item.isFolder && !options.includeFiles { return false }
        if item.depth > 0 && !options.includeSubfolders { return false }
        return true
    }

    // MARK: Conflicts

    private func resolveConflicts(_ rows: [(item: RenameItem, proposed: String?, status: RenamePreview.Status)],
                                  environment: RenameEnvironment) -> [RenamePreview] {
        var byFolder: [String: [Int]] = [:]
        for (i, row) in rows.enumerated() where row.status == .rename {
            byFolder[row.item.url.deletingLastPathComponent().path, default: []].append(i)
        }
        var final: [Int: (String, RenamePreview.Status)] = [:]
        for (folderPath, indexes) in byFolder {
            let folder = URL(fileURLWithPath: folderPath, isDirectory: true)
            let caseSensitive = environment.isCaseSensitive(folder)
            func key(_ s: String) -> String {
                let n = s.precomposedStringWithCanonicalMapping
                return caseSensitive ? n : n.lowercased()
            }
            var taken = Set(environment.existingNames(folder).map(key))
            for i in indexes { taken.remove(key(rows[i].item.name)) }
            for i in indexes {
                let wanted = rows[i].proposed ?? ""
                guard taken.contains(key(wanted)) else {
                    taken.insert(key(wanted))
                    final[i] = (wanted, .rename)
                    continue
                }
                let parts = Self.split(wanted, isFolder: rows[i].item.isFolder)
                var n = 2
                var candidate: String
                repeat {
                    candidate = parts.stem + " (\(n))" + (parts.ext.map { "." + $0 } ?? "")
                    n += 1
                } while taken.contains(key(candidate))
                taken.insert(key(candidate))
                final[i] = (candidate, .conflict)
            }
        }
        return rows.enumerated().map { i, row in
            if let (name, status) = final[i] {
                return RenamePreview(item: row.item, proposedName: row.proposed, newName: name, status: status)
            }
            return RenamePreview(item: row.item, proposedName: row.proposed, newName: nil, status: row.status)
        }
    }

    // MARK: Names

    /// Splits off the extension. Folders and dot files (`.zshrc`) have none.
    public static func split(_ name: String, isFolder: Bool) -> (stem: String, ext: String?) {
        guard !isFolder, let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, nil) }
        return (String(name[..<dot]), String(name[name.index(after: dot)...]))
    }

    /// Why a name can't be used on macOS, or nil when it can.
    public static func validate(_ name: String) -> String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return String(localized: "The name is empty") }
        if name == "." || name == ".." { return String(localized: "“\(name)” is reserved", comment: "PowerRename: the new name is . or .., which macOS reserves") }
        if name.contains("/") { return String(localized: "Names can’t contain “/”") }
        if name.contains(":") { return String(localized: "Names can’t contain “:”") }
        if name.contains("\0") { return String(localized: "Names can’t contain null characters") }
        if name.utf8.count > 255 { return String(localized: "The name is longer than 255 bytes") }
        return nil
    }

    static func patterns(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func isExcluded(_ name: String, by patterns: [String]) -> Bool {
        patterns.contains { fnmatch($0, name, FNM_CASEFOLD) == 0 }
    }
}
