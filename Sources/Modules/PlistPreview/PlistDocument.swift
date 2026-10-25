import AppKit
import Foundation
import MacToysCore
import Observation

/// File formats Plist Preview reads and writes.
enum PlistFormat: String, Codable, CaseIterable {
    case xml, binary, json
    /// Old-style ASCII plists can be read but are saved as XML.
    case openStep

    var title: String {
        switch self {
        case .xml: "XML"
        case .binary: String(localized: "Binary", comment: "Property list file format")
        case .json: "JSON"
        case .openStep: String(localized: "OpenStep (read-only)", comment: "Property list file format; OpenStep is a name")
        }
    }
}

enum PlistCodec {
    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Reads XML, binary, OpenStep or JSON data.
    static func decode(_ data: Data) throws -> (PlistNode, PlistFormat, nulls: Int) {
        var format = PropertyListSerialization.PropertyListFormat.xml
        if let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: &format) {
            let f: PlistFormat = format == .binary ? .binary : (format == .openStep ? .openStep : .xml)
            // A bare JSON string like `"x"` also parses as OpenStep; prefer JSON for those.
            if f == .openStep, let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
               json is [String: Any] || json is [Any] {
                var nulls = 0
                return (PlistNode.from(json, nulls: &nulls), .json, nulls)
            }
            var nulls = 0
            return (PlistNode.from(object, nulls: &nulls), f, nulls)
        }
        do {
            let json = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            var nulls = 0
            return (PlistNode.from(json, nulls: &nulls), .json, nulls)
        } catch {
            throw Failure(message: String(localized: "This isn't a property list (XML, binary or OpenStep) or JSON file."))
        }
    }

    static func encode(_ root: PlistNode, as format: PlistFormat) throws -> Data {
        switch format {
        case .json:
            guard root.isJSONCompatible else {
                throw Failure(message: String(localized: "JSON can't hold dates, data or non-finite numbers. Save as XML or binary instead."))
            }
            return try JSONSerialization.data(withJSONObject: root.propertyList,
                                              options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
        case .xml, .openStep:
            return try PropertyListSerialization.data(fromPropertyList: root.propertyList, format: .xml, options: 0)
        case .binary:
            return try PropertyListSerialization.data(fromPropertyList: root.propertyList, format: .binary, options: 0)
        }
    }
}

/// One open document: the tree, its file and format, undo history, expansion and search.
@MainActor
@Observable
final class PlistDocument {
    struct Message: Equatable {
        var kind: InfoKind
        var text: String
    }

    var root: PlistNode
    var fileURL: URL?
    var format: PlistFormat
    /// Set for documents opened from `defaults export`; enables "Write to defaults" with that domain.
    var domain: String?
    /// Read-only views (the defaults browser).
    var readOnly = false
    var expanded: Set<UUID> = []
    var selection: UUID?
    var searchText = ""
    var message: Message?
    var differences: [PlistDifference]?
    private(set) var savedRoot: PlistNode
    private var undoStack: [PlistNode] = []
    private var redoStack: [PlistNode] = []
    private let log = Log.for("plistpreview")

    init(root: PlistNode, fileURL: URL? = nil, format: PlistFormat = .xml, domain: String? = nil) {
        self.root = root
        self.savedRoot = root
        self.fileURL = fileURL
        self.format = format
        self.domain = domain
        expanded = [root.id]
    }

    static func untitled() -> PlistDocument {
        PlistDocument(root: PlistNode(value: .dictionary([])))
    }

    static func open(_ url: URL) throws -> PlistDocument {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attrs[.size] as? NSNumber, size.intValue > 64 * 1024 * 1024 {
            let limit = ByteCountFormatter.string(fromByteCount: 64 * 1024 * 1024, countStyle: .memory)
            throw PlistCodec.Failure(message: String(localized: "\(url.lastPathComponent) is larger than \(limit).",
                                                     comment: "First a file name, then a size such as '64 MB'"))
        }
        let (root, format, nulls) = try PlistCodec.decode(try Data(contentsOf: url))
        let doc = PlistDocument(root: root, fileURL: url, format: format, domain: domainGuess(for: url))
        if nulls > 0 {
            doc.message = Message(kind: .warning, text: String(localized: "\(nulls) JSON null values became empty strings.",
                                                               comment: "null is a JSON value, keep it as is"))
        }
        return doc
    }

    /// `~/Library/Preferences/com.apple.dock.plist` → `com.apple.dock`.
    static func domainGuess(for url: URL) -> String? {
        guard url.pathExtension == "plist" else { return nil }
        let dir = url.deletingLastPathComponent().path
        let prefs = ["/Library/Preferences", NSHomeDirectory() + "/Library/Preferences"]
        guard prefs.contains(where: { dir == $0 || dir.hasPrefix($0 + "/ByHost") }) else { return nil }
        var name = url.deletingPathExtension().lastPathComponent
        // ByHost files carry the hardware UUID: com.apple.x.<UUID>.plist
        if dir.hasSuffix("/ByHost"), let dot = name.lastIndex(of: ".") { name = String(name[..<dot]) }
        return name == ".GlobalPreferences" ? "NSGlobalDomain" : name
    }

    var displayName: String {
        if let fileURL { return fileURL.lastPathComponent }
        if let domain { return domain }
        return Self.untitledName
    }

    /// The file name of a new document: "Untitled.plist".
    static var untitledName: String {
        String(localized: "Untitled", comment: "Name of a new, unsaved document (a file name without extension)") + ".plist"
    }

    var isDirty: Bool { root != savedRoot }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    var matches: Set<UUID>? {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? nil : PlistOutline.search(root, q)
    }

    var rows: [PlistRow] { PlistOutline.rows(root, expanded: expanded, matches: matches) }

    // MARK: - Undo

    private func change(_ body: (inout PlistNode) -> Void) {
        guard !readOnly else { return }
        let before = root
        body(&root)
        guard root != before else { return }
        undoStack.append(before)
        if undoStack.count > 300 { undoStack.removeFirst() }
        redoStack.removeAll()
        differences = nil
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(root)
        root = previous
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(root)
        root = next
    }

    // MARK: - Editing

    /// Renames a dictionary key; refuses keys a sibling already uses.
    @discardableResult
    func rename(_ id: UUID, to key: String) -> Bool {
        guard let parent = root.parent(of: id), parent.type == .dictionary else { return false }
        if parent.children?.contains(where: { $0.id != id && $0.key == key }) == true {
            message = Message(kind: .error, text: String(localized: "“\(key)” is already used in this dictionary.",
                                                         comment: "The placeholder is a property list key"))
            return false
        }
        change { $0.modify(id) { $0.key = key } }
        return true
    }

    /// Sets a scalar from text; returns false (and explains) when the text doesn't fit the type.
    @discardableResult
    func setValue(_ id: UUID, text: String) -> Bool {
        guard let node = root.node(id) else { return false }
        guard let value = node.parsed(text) else {
            message = Message(kind: .error, text: Self.invalidValueMessage(text, type: node.type))
            return false
        }
        change { $0.modify(id) { $0.value = value } }
        return true
    }

    private static func invalidValueMessage(_ text: String, type: PlistType) -> String {
        switch type {
        case .number: String(localized: "“\(text)” isn't a valid number.", comment: "The placeholder is what the user typed")
        case .boolean: String(localized: "“\(text)” isn't a valid boolean.", comment: "The placeholder is what the user typed")
        case .date: String(localized: "“\(text)” isn't a valid date.", comment: "The placeholder is what the user typed")
        case .data: String(localized: "“\(text)” isn't valid data.", comment: "The placeholder is what the user typed; data is raw bytes in hex")
        default: String(localized: "“\(text)” isn't a valid \(type.title) value.",
                        comment: "First what the user typed, then a property list type such as 'String'")
        }
    }

    func setValue(_ id: UUID, _ value: PlistNode.Value) {
        change { $0.modify(id) { $0.value = value } }
    }

    func changeType(_ id: UUID, to type: PlistType) {
        change { $0.modify(id) { $0.value = $0.converted(to: type) } }
        if type.isContainer { expanded.insert(id) }
    }

    /// Adds a child to a container, or a sibling after a scalar.
    func add(near id: UUID?) {
        let target = id ?? root.id
        guard let node = root.node(target) else { return }
        if node.isContainer {
            let siblings = node.children ?? []
            let child = PlistNode(key: node.type == .dictionary ? PlistNode.uniqueKey("New Item", among: siblings) : "",
                                  value: .string(""))
            change { $0.modify(target) { n in
                switch n.value {
                case .dictionary(var c): c.append(child); n.value = .dictionary(c)
                case .array(var c): c.append(child); n.value = .array(c)
                default: break
                }
            } }
            expanded.insert(target)
            selection = child.id
        } else if let parent = root.parent(of: target) {
            let siblings = parent.children ?? []
            let child = PlistNode(key: parent.type == .dictionary ? PlistNode.uniqueKey("New Item", among: siblings) : "",
                                  value: .string(""))
            change { $0.modifyParent(of: target) { c, i in c.insert(child, at: i + 1) } }
            selection = child.id
        }
    }

    func delete(_ id: UUID) {
        guard id != root.id else { return }
        let parent = root.parent(of: id)
        change { $0.modifyParent(of: id) { c, i in c.remove(at: i) } }
        if selection == id { selection = parent?.id }
    }

    func duplicate(_ id: UUID) {
        guard id != root.id, let node = root.node(id), let parent = root.parent(of: id) else { return }
        var copy = node.copyWithNewIDs()
        if parent.type == .dictionary { copy.key = PlistNode.uniqueKey(node.key + " copy", among: parent.children ?? []) }
        change { $0.modifyParent(of: id) { c, i in c.insert(copy, at: i + 1) } }
        selection = copy.id
    }

    func move(_ id: UUID, by delta: Int) {
        change { $0.modifyParent(of: id) { c, i in
            let j = i + delta
            if c.indices.contains(j) { c.swapAt(i, j) }
        } }
    }

    func toggleExpanded(_ id: UUID) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    func expandAll() { expanded = Set(root.allIDs) }
    func collapseAll() { expanded = [root.id] }

    func keyPath(_ id: UUID) -> String? { root.path(to: id).map(PlistNode.keyPath) }

    func copyKeyPath(_ id: UUID) {
        guard let path = keyPath(id) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    // MARK: - Files

    /// Saves in the document's format (OpenStep files become XML).
    func save() throws {
        guard let url = fileURL else { throw PlistCodec.Failure(message: String(localized: "Choose where to save first.")) }
        try write(to: url, format: format == .openStep ? .xml : format)
    }

    func write(to url: URL, format: PlistFormat) throws {
        let data = try PlistCodec.encode(root, as: format)
        try data.write(to: url, options: .atomic)
        fileURL = url
        self.format = format
        savedRoot = root
        differences = nil
        message = Message(kind: .success, text: String(localized: "Saved as \(format.title).", comment: "The placeholder is a file format, e.g. 'XML'"))
        log.info("saved \(url.path, privacy: .public)")
    }

    /// Re-reads the file; edits are lost (undo still has them).
    func reload() throws {
        guard let url = fileURL else { return }
        let (fresh, format, _) = try PlistCodec.decode(try Data(contentsOf: url))
        undoStack.append(root)
        root = fresh
        savedRoot = fresh
        self.format = format
        expanded = [fresh.id]
        differences = nil
    }

    /// Compares the document with the file on disk (or the live defaults domain).
    func compareWithSource() throws {
        let other: PlistNode
        if let url = fileURL {
            other = try PlistCodec.decode(try Data(contentsOf: url)).0
        } else if let domain {
            other = try DefaultsDomains.export(domain)
        } else {
            throw PlistCodec.Failure(message: String(localized: "This document hasn't been saved yet."))
        }
        differences = PlistDiff.diff(other, root)
    }

    /// Imports the document into a defaults domain (`defaults import`), replacing that domain.
    func writeToDefaults(domain: String) throws {
        guard root.type == .dictionary else {
            throw PlistCodec.Failure(message: String(localized: "Only a dictionary can be written to a defaults domain."))
        }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("mactoys-defaults-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: temp) }
        try PlistCodec.encode(root, as: .xml).write(to: temp)
        let r = Shell.run("/usr/bin/defaults", ["import", domain, temp.path])
        guard r.ok else {
            throw PlistCodec.Failure(message: r.stderr.isEmpty ? String(localized: "defaults import failed", comment: "defaults import is a command") : r.stderr)
        }
        self.domain = domain
        message = Message(kind: .success, text: String(localized: "Wrote \(root.children?.count ?? 0) keys to \(domain).",
                                                       comment: "First a number of keys, then a defaults domain such as com.apple.dock"))
        log.info("imported into defaults domain \(domain, privacy: .public)")
    }
}

/// `defaults domains` / `defaults export`.
enum DefaultsDomains {
    static func list() -> [String] {
        let r = Shell.run("/usr/bin/defaults", ["domains"])
        let names = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: ", ").filter { !$0.isEmpty }
        return ["NSGlobalDomain"] + names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func export(_ domain: String) throws -> PlistNode {
        let r = Shell.run("/usr/bin/defaults", ["export", domain, "-"])
        guard r.ok, let data = r.stdout.data(using: .utf8) else {
            throw PlistCodec.Failure(message: r.stderr.isEmpty ? String(localized: "Couldn't read \(domain).", comment: "The placeholder is a defaults domain")
                                         : r.stderr)
        }
        return try PlistCodec.decode(data).0
    }

    /// Processes that only pick up changes after a restart.
    static func relaunchTarget(for domain: String) -> String? {
        ["com.apple.dock": "Dock", "com.apple.finder": "Finder", "com.apple.systemuiserver": "SystemUIServer",
         "com.apple.menuextra.clock": "SystemUIServer"][domain.lowercased()]
    }
}
