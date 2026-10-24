import Darwin
import Foundation

/// One mapping line: `address host [host…] [# comment]`, active or commented out.
struct HostsEntry: Identifiable, Equatable, Hashable {
    var id = UUID()
    var active: Bool
    var address: String
    var hosts: [String]
    var comment: String
    /// The line as read from disk; kept until the entry is edited, so unchanged files round-trip byte for byte.
    var original: String?

    init(id: UUID = UUID(), active: Bool = true, address: String, hosts: [String], comment: String = "", original: String? = nil) {
        self.id = id
        self.active = active
        self.address = address
        self.hosts = hosts
        self.comment = comment
        self.original = original
    }

    /// The same mapping with a new id and no original text.
    func duplicated() -> HostsEntry {
        HostsEntry(active: active, address: address, hosts: hosts, comment: comment)
    }

    var hostsText: String { hosts.joined(separator: " ") }

    /// How a new or edited entry is written: disabled entries are commented out with "# ".
    func rendered(lineEnding: String) -> String {
        var s = (active ? "" : "# ") + address + "\t" + hosts.joined(separator: " ")
        if !comment.isEmpty { s += "\t# " + comment }
        return lineEnding == "\r\n" ? s + "\r" : s
    }
}

/// /etc/hosts as an ordered list of lines: comments, blank lines and anything unparsable are kept
/// verbatim; mappings become `HostsEntry` values.
struct HostsDocument: Equatable {
    enum Line: Equatable {
        case raw(String)
        case entry(HostsEntry)
    }

    enum Placement: String, Codable, CaseIterable {
        /// After the header comments, before the first existing entry.
        case top
        case bottom
    }

    var lines: [Line]
    var lineEnding: String
    var hasTrailingNewline: Bool
    var hasBOM: Bool

    static func parse(_ text: String) -> HostsDocument {
        var body = Substring(text)
        let bom = body.hasPrefix("\u{FEFF}")
        if bom { body = body.dropFirst() }
        let ending = body.contains("\r\n") ? "\r\n" : "\n"
        guard !body.isEmpty else { return HostsDocument(lines: [], lineEnding: ending, hasTrailingNewline: false, hasBOM: bom) }
        var parts = body.components(separatedBy: "\n")
        let trailing = parts.last == ""
        if trailing { parts.removeLast() }
        let lines = parts.map { raw -> Line in
            if let e = parseEntry(raw) { return .entry(e) }
            return .raw(raw)
        }
        return HostsDocument(lines: lines, lineEnding: ending, hasTrailingNewline: trailing, hasBOM: bom)
    }

    /// Parses one line. Commented-out lines count as disabled entries when the rest is a valid mapping.
    static func parseEntry(_ raw: String) -> HostsEntry? {
        let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        var active = true
        var content = Substring(trimmed)
        if content.hasPrefix("#") {
            active = false
            content = content.drop { $0 == "#" }
            content = content.drop { $0 == " " || $0 == "\t" }
        }
        var comment = ""
        if let hash = content.firstIndex(of: "#") {
            comment = content[content.index(after: hash)...].trimmingCharacters(in: .whitespaces)
            content = content[..<hash]
        }
        let tokens = content.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard tokens.count >= 2 else { return nil }
        let address = tokens[0], hosts = Array(tokens.dropFirst())
        if !active {
            // A comment only becomes a disabled entry when it really looks like one: a valid address and
            // valid names, at least one dotted or a well-known single label (so "# 10.0.0.1 is the router" stays prose).
            let wellKnown: Set<String> = ["localhost", "broadcasthost", "ip6-localhost", "ip6-loopback"]
            guard HostsValidator.isValidAddress(address), hosts.allSatisfy(HostsValidator.isValidHostname),
                  hosts.contains(where: { $0.contains(".") || wellKnown.contains($0.lowercased()) }) else { return nil }
        } else if !HostsValidator.isValidAddress(address) && !address.contains(where: { $0 == "." || $0 == ":" }) {
            // "Some text without an address" on an uncommented line stays raw.
            return nil
        }
        return HostsEntry(active: active, address: address, hosts: hosts, comment: comment, original: raw)
    }

    func serialize() -> String {
        var out = lines.map { line -> String in
            switch line {
            case .raw(let s): return s
            case .entry(let e): return e.original ?? e.rendered(lineEnding: lineEnding)
            }
        }.joined(separator: "\n")
        if hasTrailingNewline { out += "\n" }
        return (hasBOM ? "\u{FEFF}" : "") + out
    }

    var entries: [HostsEntry] {
        lines.compactMap { if case .entry(let e) = $0 { return e } else { return nil } }
    }

    private func index(of id: UUID) -> Int? {
        lines.firstIndex { if case .entry(let e) = $0 { return e.id == id } else { return false } }
    }

    /// Replaces an entry; its original text is dropped only when something changed.
    mutating func update(_ entry: HostsEntry) {
        guard let i = index(of: entry.id), case .entry(let old) = lines[i] else { return }
        var e = entry
        if e.active != old.active || e.address != old.address || e.hosts != old.hosts || e.comment != old.comment {
            e.original = nil
        } else {
            e.original = old.original
        }
        lines[i] = .entry(e)
    }

    mutating func setActive(_ id: UUID, _ active: Bool) {
        guard let i = index(of: id), case .entry(var e) = lines[i], e.active != active else { return }
        e.active = active
        e.original = nil
        lines[i] = .entry(e)
    }

    mutating func remove(_ id: UUID) {
        guard let i = index(of: id) else { return }
        lines.remove(at: i)
    }

    /// Inserts a copy right after the original.
    @discardableResult
    mutating func duplicate(_ id: UUID) -> HostsEntry? {
        guard let i = index(of: id), case .entry(let e) = lines[i] else { return nil }
        let copy = e.duplicated()
        lines.insert(.entry(copy), at: i + 1)
        return copy
    }

    mutating func add(_ entry: HostsEntry, placement: Placement) {
        var e = entry
        e.original = nil
        if lines.isEmpty { hasTrailingNewline = true }
        switch placement {
        case .bottom:
            // Before trailing blank lines, so the file keeps its shape.
            var i = lines.count
            while i > 0, case .raw(let s) = lines[i - 1], s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { i -= 1 }
            lines.insert(.entry(e), at: i)
        case .top:
            lines.insert(.entry(e), at: headerRange.upperBound)
        }
    }

    /// Moves an entry up or down among the entries (lines in between stay put).
    mutating func move(_ id: UUID, by delta: Int) {
        let entryIndices = lines.indices.filter { if case .entry = lines[$0] { return true } else { return false } }
        guard let pos = entryIndices.firstIndex(where: { if case .entry(let e) = lines[$0] { return e.id == id } else { return false } }) else { return }
        let target = pos + delta
        guard entryIndices.indices.contains(target) else { return }
        lines.swapAt(entryIndices[pos], entryIndices[target])
    }

    /// The leading run of non-entry lines (the file's header comments).
    var headerRange: Range<Int> {
        let end = lines.firstIndex { if case .entry = $0 { return true } else { return false } } ?? lines.count
        return 0..<end
    }

    var header: [String] {
        lines[headerRange].map { if case .raw(let s) = $0 { return s } else { return "" } }
    }

    /// Replaces the header comments ("additional lines").
    mutating func setHeader(_ text: [String]) {
        lines.replaceSubrange(headerRange, with: text.map { .raw($0) })
    }
}

/// Validation and warnings for hosts entries.
enum HostsValidator {
    static func isValidIPv4(_ s: String) -> Bool {
        var addr = in_addr()
        return s.withCString { inet_pton(AF_INET, $0, &addr) } == 1
    }

    static func isValidIPv6(_ s: String) -> Bool {
        let base = s.split(separator: "%", maxSplits: 1).first.map(String.init) ?? s
        var addr = in6_addr()
        return base.withCString { inet_pton(AF_INET6, $0, &addr) } == 1
    }

    static func isValidAddress(_ s: String) -> Bool { isValidIPv4(s) || isValidIPv6(s) }

    static func isLoopback(_ s: String) -> Bool {
        if isValidIPv4(s) { return s.hasPrefix("127.") }
        let base = s.split(separator: "%", maxSplits: 1).first.map(String.init) ?? s
        if isValidIPv6(base) {
            var a = in6_addr(), l = in6_addr()
            _ = base.withCString { inet_pton(AF_INET6, $0, &a) }
            _ = "::1".withCString { inet_pton(AF_INET6, $0, &l) }
            return withUnsafeBytes(of: &a) { x in withUnsafeBytes(of: &l) { y in x.elementsEqual(y) } } || base.lowercased().hasPrefix("fe80::1")
        }
        return false
    }

    /// RFC 1123 labels (letters, digits, hyphens; underscores tolerated), 1–63 characters, 253 in total.
    static func isValidHostname(_ s: String) -> Bool {
        var name = Substring(s)
        if name.hasSuffix(".") { name = name.dropLast() }
        guard !name.isEmpty, name.count <= 253, !isValidAddress(String(name)) || name.contains(where: \.isLetter) else { return false }
        return name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            guard (1...63).contains(label.count), label.first != "-", label.last != "-" else { return false }
            return label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        }
    }

    enum Issue: Equatable, Hashable {
        case invalidAddress
        case invalidHost(String)
        case duplicate(String)
        case localhostElsewhere
        case localhostDisabled
        case noHosts

        var message: String {
            switch self {
            case .invalidAddress: "Not a valid IPv4 or IPv6 address"
            case .invalidHost(let h): "“\(h)” isn't a valid host name"
            case .duplicate(let h): "\(h) is also mapped by another active entry"
            case .localhostElsewhere: "localhost should point to a loopback address (127.0.0.1 or ::1)"
            case .localhostDisabled: "Turning off the localhost entry can break apps that talk to this Mac"
            case .noHosts: "Add at least one host name"
            }
        }

        var isError: Bool {
            switch self {
            case .invalidAddress, .invalidHost, .noHosts: true
            default: false
            }
        }
    }

    /// Problems with one entry on its own.
    static func issues(_ e: HostsEntry) -> [Issue] {
        var out: [Issue] = []
        if !isValidAddress(e.address) { out.append(.invalidAddress) }
        if e.hosts.isEmpty { out.append(.noHosts) }
        for h in e.hosts where !isValidHostname(h) { out.append(.invalidHost(h)) }
        let lower = Set(e.hosts.map { $0.lowercased() })
        if lower.contains("localhost") {
            if e.active && isValidAddress(e.address) && !isLoopback(e.address) { out.append(.localhostElsewhere) }
            if !e.active && isLoopback(e.address) { out.append(.localhostDisabled) }
        }
        return out
    }

    /// Host names (lowercased) per active entry id that another active entry also maps. Two loopback
    /// addresses for the same name (127.0.0.1 and ::1) only count when `loopbackDuplicates` is on.
    static func duplicates(_ entries: [HostsEntry], loopbackDuplicates: Bool) -> [UUID: Set<String>] {
        var byHost: [String: [HostsEntry]] = [:]
        for e in entries where e.active {
            for h in Set(e.hosts.map { $0.lowercased() }) { byHost[h, default: []].append(e) }
        }
        var out: [UUID: Set<String>] = [:]
        for (host, list) in byHost where list.count > 1 {
            for (i, a) in list.enumerated() {
                let clash = list.enumerated().contains { j, b in
                    guard i != j else { return false }
                    if !loopbackDuplicates && isLoopback(a.address) && isLoopback(b.address) && a.address != b.address { return false }
                    return true
                }
                if clash { out[a.id, default: []].insert(host) }
            }
        }
        return out
    }
}

/// Timestamped backups in ~/Library/Application Support/MacToys/Hosts.
enum HostsBackups {
    enum Retention: String, Codable, CaseIterable {
        case never, count, ageAndCount

        var title: String {
            switch self {
            case .never: "Never"
            case .count: "Based on count"
            case .ageAndCount: "Based on age and count"
            }
        }
    }

    static func name(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "hosts-\(f.string(from: date))"
    }

    /// Backups to delete, given (name, modification date) pairs. Newest are kept first.
    static func toDelete(_ files: [(String, Date)], retention: Retention, keep: Int, days: Int, now: Date) -> [String] {
        let sorted = files.filter { $0.0.hasPrefix("hosts-") }.sorted { $0.1 > $1.1 }
        switch retention {
        case .never:
            return []
        case .count:
            return sorted.dropFirst(max(1, keep)).map(\.0)
        case .ageAndCount:
            let cutoff = now.addingTimeInterval(-Double(max(1, days)) * 86400)
            return sorted.enumerated().filter { $0.offset >= max(0, keep) && $0.element.1 < cutoff }.map(\.element.0)
        }
    }
}

/// Parses `ping` output: "time=12.345 ms" → 12.345.
enum PingParser {
    static func milliseconds(_ output: String) -> Double? {
        guard let r = output.range(of: "time=") else { return nil }
        let rest = output[r.upperBound...]
        let number = rest.prefix { $0.isNumber || $0 == "." }
        return Double(number)
    }
}
