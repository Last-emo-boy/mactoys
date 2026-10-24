import Foundation

/// The types the editor offers (Number covers integers and reals).
enum PlistType: String, CaseIterable, Identifiable {
    case dictionary, array, string, number, boolean, date, data

    var id: String { rawValue }
    var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    var isContainer: Bool { self == .dictionary || self == .array }
}

/// One node of a property list, as a value type: copies keep their ids, so undo snapshots are
/// whole trees and selection survives them.
struct PlistNode: Identifiable, Equatable {
    enum Value: Equatable {
        case dictionary([PlistNode])
        case array([PlistNode])
        case string(String)
        case integer(Int64)
        case real(Double)
        case boolean(Bool)
        case date(Date)
        case data(Data)
    }

    var id = UUID()
    /// The key in the parent dictionary (unused for array items and the root).
    var key: String
    var value: Value

    init(id: UUID = UUID(), key: String = "", value: Value) {
        self.id = id
        self.key = key
        self.value = value
    }

    var type: PlistType {
        switch value {
        case .dictionary: .dictionary
        case .array: .array
        case .string: .string
        case .integer, .real: .number
        case .boolean: .boolean
        case .date: .date
        case .data: .data
        }
    }

    var children: [PlistNode]? {
        switch value {
        case .dictionary(let c), .array(let c): c
        default: nil
        }
    }

    var isContainer: Bool { children != nil }

    /// "18 items", or the value as text.
    var summary: String {
        if let c = children { return "\(c.count) item\(c.count == 1 ? "" : "s")" }
        return valueText
    }

    // MARK: - PropertyList conversion

    struct ConversionIssue: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Builds a tree from a Foundation property list (or JSON) object. Dictionary keys are sorted,
    /// as they are when the file is written. JSON `null` becomes an empty string (`nulls` counts them).
    static func from(_ object: Any, key: String = "", nulls: inout Int) -> PlistNode {
        switch object {
        case let d as [String: Any]:
            let children = d.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { k in
                from(d[k] as Any, key: k, nulls: &nulls)
            }
            return PlistNode(key: key, value: .dictionary(children))
        case let a as [Any]:
            return PlistNode(key: key, value: .array(a.map { from($0, nulls: &nulls) }))
        case let s as String:
            return PlistNode(key: key, value: .string(s))
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return PlistNode(key: key, value: .boolean(n.boolValue)) }
            if CFNumberIsFloatType(n) { return PlistNode(key: key, value: .real(n.doubleValue)) }
            return PlistNode(key: key, value: .integer(n.int64Value))
        case let date as Date:
            return PlistNode(key: key, value: .date(date))
        case let data as Data:
            return PlistNode(key: key, value: .data(data))
        default:
            nulls += 1
            return PlistNode(key: key, value: .string(""))
        }
    }

    static func from(_ object: Any) -> PlistNode {
        var nulls = 0
        return from(object, nulls: &nulls)
    }

    /// The Foundation object for `PropertyListSerialization` / `JSONSerialization`.
    var propertyList: Any {
        switch value {
        case .dictionary(let c):
            var d: [String: Any] = [:]
            for child in c { d[child.key] = child.propertyList }
            return d
        case .array(let c): return c.map(\.propertyList)
        case .string(let s): return s
        case .integer(let i): return NSNumber(value: i)
        case .real(let r): return NSNumber(value: r)
        case .boolean(let b): return NSNumber(value: b)
        case .date(let d): return d
        case .data(let d): return d
        }
    }

    /// Whether the tree can be written as JSON (no dates, data or non-finite numbers).
    var isJSONCompatible: Bool {
        switch value {
        case .dictionary(let c), .array(let c): c.allSatisfy(\.isJSONCompatible)
        case .date, .data: false
        case .real(let r): r.isFinite
        default: true
        }
    }

    // MARK: - Values as text

    static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    var valueText: String {
        switch value {
        case .dictionary, .array: return ""
        case .string(let s): return s
        case .integer(let i): return String(i)
        case .real(let r): return Self.format(r)
        case .boolean(let b): return b ? "YES" : "NO"
        case .date(let d): return Self.dateFormatter.string(from: d)
        case .data(let d): return Self.hex(d)
        }
    }

    static func format(_ r: Double) -> String {
        if r.isFinite && r == r.rounded() && abs(r) < 1e15 { return String(format: "%.1f", r) }
        return String(r)
    }

    /// `<0a1b2c3d 4e…>` style hex, grouped by four bytes.
    static func hex(_ d: Data) -> String {
        let bytes = d.map { String(format: "%02x", $0) }
        var groups: [String] = []
        var i = 0
        while i < bytes.count {
            groups.append(bytes[i..<min(i + 4, bytes.count)].joined())
            i += 4
        }
        return "<" + groups.joined(separator: " ") + ">"
    }

    static func parseHex(_ text: String) -> Data? {
        let digits = text.filter { !" <>\n\t".contains($0) }
        guard digits.count % 2 == 0, digits.allSatisfy(\.isHexDigit) else { return nil }
        var data = Data(capacity: digits.count / 2)
        var it = digits.makeIterator()
        while let a = it.next(), let b = it.next() {
            guard let byte = UInt8(String([a, b]), radix: 16) else { return nil }
            data.append(byte)
        }
        return data
    }

    /// Parses text for this node's type; nil when invalid (the editor shows an error and keeps the old value).
    func parsed(_ text: String) -> Value? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch value {
        case .dictionary, .array: return nil
        case .string: return .string(text)
        case .integer, .real:
            if let i = Int64(t) { return .integer(i) }
            if let r = Double(t.replacingOccurrences(of: ",", with: ".")), !t.isEmpty { return .real(r) }
            return nil
        case .boolean:
            switch t.lowercased() {
            case "yes", "true", "1": return .boolean(true)
            case "no", "false", "0": return .boolean(false)
            default: return nil
            }
        case .date:
            if let d = Self.dateFormatter.date(from: t) { return .date(d) }
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
                f.dateFormat = format
                if let d = f.date(from: t) { return .date(d) }
            }
            return nil
        case .data:
            return Self.parseHex(t).map { .data($0) }
        }
    }

    // MARK: - Type changes

    /// The value converted to another type, keeping what can be kept.
    func converted(to type: PlistType) -> Value {
        guard type != self.type else { return value }
        switch type {
        case .dictionary:
            if case .array(let c) = value {
                return .dictionary(c.enumerated().map { i, n in var n = n; n.key = "Item \(i)"; return n })
            }
            return .dictionary([])
        case .array:
            if case .dictionary(let c) = value { return .array(c) }
            return .array([])
        case .string:
            switch value {
            case .data(let d): return .string(String(data: d, encoding: .utf8) ?? Self.hex(d))
            case .boolean(let b): return .string(b ? "true" : "false")
            case .dictionary, .array: return .string("")
            default: return .string(valueText)
            }
        case .number:
            switch value {
            case .string(let s):
                if let i = Int64(s.trimmingCharacters(in: .whitespaces)) { return .integer(i) }
                return .real(Double(s.trimmingCharacters(in: .whitespaces)) ?? 0)
            case .boolean(let b): return .integer(b ? 1 : 0)
            case .date(let d): return .real(d.timeIntervalSince1970)
            default: return .integer(0)
            }
        case .boolean:
            switch value {
            case .string(let s): return .boolean(["yes", "true", "1"].contains(s.lowercased().trimmingCharacters(in: .whitespaces)))
            case .integer(let i): return .boolean(i != 0)
            case .real(let r): return .boolean(r != 0)
            default: return .boolean(false)
            }
        case .date:
            switch value {
            case .string: return parsed(valueText).flatMap { if case .date = $0 { $0 } else { nil } } ?? .date(Date())
            case .integer(let i): return .date(Date(timeIntervalSince1970: TimeInterval(i)))
            case .real(let r): return .date(Date(timeIntervalSince1970: r))
            default: return .date(Date())
            }
        case .data:
            if case .string(let s) = value { return .data(Data(s.utf8)) }
            return .data(Data())
        }
    }

    // MARK: - Tree operations

    /// Calls `body` on the node with `id`; returns whether it was found.
    @discardableResult
    mutating func modify(_ id: UUID, _ body: (inout PlistNode) -> Void) -> Bool {
        if self.id == id { body(&self); return true }
        switch value {
        case .dictionary(var c):
            for i in c.indices where c[i].modify(id, body) { value = .dictionary(c); return true }
        case .array(var c):
            for i in c.indices where c[i].modify(id, body) { value = .array(c); return true }
        default: break
        }
        return false
    }

    /// Calls `body` with the children array of the node that contains `id`, and the index of `id` in it.
    @discardableResult
    mutating func modifyParent(of id: UUID, _ body: (inout [PlistNode], Int) -> Void) -> Bool {
        switch value {
        case .dictionary(var c):
            if let i = c.firstIndex(where: { $0.id == id }) { body(&c, i); value = .dictionary(c); return true }
            for i in c.indices where c[i].modifyParent(of: id, body) { value = .dictionary(c); return true }
        case .array(var c):
            if let i = c.firstIndex(where: { $0.id == id }) { body(&c, i); value = .array(c); return true }
            for i in c.indices where c[i].modifyParent(of: id, body) { value = .array(c); return true }
        default: break
        }
        return false
    }

    func node(_ id: UUID) -> PlistNode? {
        if self.id == id { return self }
        for c in children ?? [] { if let n = c.node(id) { return n } }
        return nil
    }

    /// The parent of `id`, if `id` isn't the root.
    func parent(of id: UUID) -> PlistNode? {
        guard let c = children else { return nil }
        if c.contains(where: { $0.id == id }) { return self }
        for child in c { if let p = child.parent(of: id) { return p } }
        return nil
    }

    /// Key path components from the root: dictionary keys and array indices.
    func path(to id: UUID) -> [String]? {
        if self.id == id { return [] }
        guard let c = children else { return nil }
        let isArray = type == .array
        for (i, child) in c.enumerated() {
            if let rest = child.path(to: id) { return [isArray ? String(i) : child.key] + rest }
        }
        return nil
    }

    /// PlistBuddy-style key path: `:persistent-apps:0:tile-data`.
    static func keyPath(_ components: [String]) -> String {
        ":" + components.map { $0.replacingOccurrences(of: ":", with: "\\:") }.joined(separator: ":")
    }

    /// A key not used by any sibling: "New Item", "New Item 2", …
    static func uniqueKey(_ base: String, among siblings: [PlistNode]) -> String {
        let keys = Set(siblings.map(\.key))
        guard keys.contains(base) else { return base }
        var n = 2
        while keys.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    /// A deep copy with fresh ids.
    func copyWithNewIDs() -> PlistNode {
        var copy = self
        copy.id = UUID()
        switch value {
        case .dictionary(let c): copy.value = .dictionary(c.map { $0.copyWithNewIDs() })
        case .array(let c): copy.value = .array(c.map { $0.copyWithNewIDs() })
        default: break
        }
        return copy
    }

    /// Every node id in the tree.
    var allIDs: [UUID] { [id] + (children ?? []).flatMap(\.allIDs) }
}

/// The visible rows of the outline.
struct PlistRow: Identifiable, Equatable {
    var node: PlistNode
    var depth: Int
    /// Index in the parent array (nil for dictionary children and the root).
    var arrayIndex: Int?
    var id: UUID { node.id }

    var displayKey: String {
        if depth == 0 { return "Root" }
        if let i = arrayIndex { return "Item \(i)" }
        return node.key
    }
}

enum PlistOutline {
    /// Depth-first rows for expanded nodes. With `matches`, rows on the way to a match are shown expanded
    /// and everything else is hidden.
    static func rows(_ root: PlistNode, expanded: Set<UUID>, matches: Set<UUID>? = nil) -> [PlistRow] {
        var out: [PlistRow] = []
        func visit(_ n: PlistNode, depth: Int, index: Int?) -> Bool {
            let start = out.count
            out.append(PlistRow(node: n, depth: depth, arrayIndex: index))
            var keep = matches?.contains(n.id) ?? true
            let isArray = n.type == .array
            if let c = n.children, matches != nil || expanded.contains(n.id) {
                for (i, child) in c.enumerated() where visit(child, depth: depth + 1, index: isArray ? i : nil) { keep = true }
            }
            if !keep { out.removeSubrange(start...) }
            return keep
        }
        _ = visit(root, depth: 0, index: nil)
        return out
    }

    /// Ids of nodes whose key or value contains `query` (case-insensitive).
    static func search(_ root: PlistNode, _ query: String) -> Set<UUID> {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        var out = Set<UUID>()
        func visit(_ n: PlistNode, index: Int?) {
            let key = index.map { "Item \($0)" } ?? n.key
            if key.localizedCaseInsensitiveContains(q) || (!n.isContainer && n.valueText.localizedCaseInsensitiveContains(q)) {
                out.insert(n.id)
            }
            let isArray = n.type == .array
            for (i, c) in (n.children ?? []).enumerated() { visit(c, index: isArray ? i : nil) }
        }
        visit(root, index: nil)
        out.remove(root.id)
        return out
    }
}

/// Differences between two trees, by key path.
struct PlistDifference: Identifiable, Equatable {
    enum Kind: String { case added, removed, changed }
    var path: [String]
    var kind: Kind
    var old: String?
    var new: String?
    var id: String { PlistNode.keyPath(path) + kind.rawValue }
}

enum PlistDiff {
    /// What changed from `old` (e.g. the file on disk) to `new` (the document).
    static func diff(_ old: PlistNode, _ new: PlistNode, path: [String] = []) -> [PlistDifference] {
        func describe(_ n: PlistNode) -> String { n.isContainer ? "\(n.type.title) (\(n.summary))" : "\(n.type.title) \(n.valueText)" }
        switch (old.value, new.value) {
        case let (.dictionary(a), .dictionary(b)):
            var out: [PlistDifference] = []
            let bKeys = Dictionary(b.map { ($0.key, $0) }, uniquingKeysWith: { x, _ in x })
            let aKeys = Dictionary(a.map { ($0.key, $0) }, uniquingKeysWith: { x, _ in x })
            for child in a {
                if let other = bKeys[child.key] { out += diff(child, other, path: path + [child.key]) }
                else { out.append(PlistDifference(path: path + [child.key], kind: .removed, old: describe(child), new: nil)) }
            }
            for child in b where aKeys[child.key] == nil {
                out.append(PlistDifference(path: path + [child.key], kind: .added, old: nil, new: describe(child)))
            }
            return out
        case let (.array(a), .array(b)):
            var out: [PlistDifference] = []
            for i in 0..<max(a.count, b.count) {
                let p = path + [String(i)]
                if i < a.count && i < b.count { out += diff(a[i], b[i], path: p) }
                else if i < a.count { out.append(PlistDifference(path: p, kind: .removed, old: describe(a[i]), new: nil)) }
                else { out.append(PlistDifference(path: p, kind: .added, old: nil, new: describe(b[i]))) }
            }
            return out
        default:
            let same: Bool
            switch (old.value, new.value) {
            case let (.integer(x), .real(y)), let (.real(y), .integer(x)): same = Double(x) == y
            case let (.date(x), .date(y)): same = abs(x.timeIntervalSince(y)) < 1
            default: same = old.value == new.value
            }
            return same ? [] : [PlistDifference(path: path, kind: .changed, old: describe(old), new: describe(new))]
        }
    }
}
