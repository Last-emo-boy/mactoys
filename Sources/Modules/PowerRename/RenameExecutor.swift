import Darwin
import Foundation

/// One rename on disk.
public struct RenameOperation: Codable, Hashable, Sendable {
    public var from: URL
    public var to: URL

    public init(from: URL, to: URL) {
        self.from = from
        self.to = to
    }

    var inverse: RenameOperation { RenameOperation(from: to, to: from) }
    var depth: Int { from.standardizedFileURL.pathComponents.count }
}

/// Performs renames safely: never overwrites, renames children before their folders, and
/// handles swaps and chains (`a→b`, `b→a`) through temporary names.
public enum RenameExecutor {
    public struct Failure: Sendable, Hashable {
        public let operation: RenameOperation
        public let message: String
    }

    public struct Outcome: Sendable {
        /// Renames that happened, in the order they were made.
        public var done: [RenameOperation] = []
        public var failures: [Failure] = []
    }

    /// Builds the operations for a preview.
    public static func operations(for previews: [RenamePreview]) -> [RenameOperation] {
        previews.compactMap { p in
            guard let name = p.newName else { return nil }
            return RenameOperation(from: p.item.url, to: p.item.url.deletingLastPathComponent().appendingPathComponent(name))
        }
    }

    /// Renames deepest paths first, so a folder is renamed after everything inside it.
    public static func apply(_ operations: [RenameOperation]) -> Outcome {
        run(operations, deepestFirst: true)
    }

    /// Reverts what `apply` did (pass its `done` list), parents first.
    public static func undo(_ done: [RenameOperation]) -> Outcome {
        run(done.map(\.inverse), deepestFirst: false)
    }

    private static func run(_ operations: [RenameOperation], deepestFirst: Bool) -> Outcome {
        var outcome = Outcome()
        let levels = Dictionary(grouping: operations.filter { $0.from != $0.to }, by: \.depth)
        let order = levels.keys.sorted(by: deepestFirst ? (>) : (<))
        for depth in order {
            let level = levels[depth] ?? []
            var pendingSources = Set(level.map { key($0.from) })
            var deferred: [(temp: URL, op: RenameOperation)] = []
            for op in level {
                switch move(op.from, op.to) {
                case .success:
                    pendingSources.remove(key(op.from))
                    outcome.done.append(op)
                case .failure(let error) where error.code == EEXIST && pendingSources.contains(key(op.to)):
                    // The target is another item that still has to move away: park this one.
                    let temp = op.from.deletingLastPathComponent()
                        .appendingPathComponent(".mactoys-rename-\(UUID().uuidString)")
                    switch move(op.from, temp) {
                    case .success:
                        pendingSources.remove(key(op.from))
                        deferred.append((temp, op))
                    case .failure(let e):
                        outcome.failures.append(Failure(operation: op, message: e.message))
                    }
                case .failure(let error):
                    outcome.failures.append(Failure(operation: op, message: error.message))
                }
            }
            for (temp, op) in deferred {
                switch move(temp, op.to) {
                case .success:
                    outcome.done.append(op)
                case .failure(let error):
                    if case .failure(let back) = move(temp, op.from) {
                        outcome.failures.append(Failure(operation: op, message: "\(error.message); the item was left as “\(temp.lastPathComponent)”: \(back.message)"))
                    } else {
                        outcome.failures.append(Failure(operation: op, message: error.message))
                    }
                }
            }
        }
        return outcome
    }

    struct POSIXFailure: Error {
        let code: Int32
        var message: String {
            code == EEXIST ? "An item with that name already exists" : String(cString: strerror(code))
        }
    }

    /// `rename(2)` that refuses to replace an existing item. Case-only renames work on
    /// case-insensitive volumes because APFS treats them as the same entry.
    static func move(_ from: URL, _ to: URL) -> Result<Void, POSIXFailure> {
        if renamex_np(from.path, to.path, UInt32(RENAME_EXCL)) == 0 { return .success(()) }
        return .failure(POSIXFailure(code: errno))
    }

    private static func key(_ url: URL) -> String {
        url.standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased()
    }
}

/// The last batch, kept on disk so it can be undone after the window closed.
public struct RenameJournal: Codable, Sendable {
    public var date: Date
    public var operations: [RenameOperation]

    public init(date: Date = Date(), operations: [RenameOperation]) {
        self.date = date
        self.operations = operations
    }

    public static func load(from url: URL) -> RenameJournal? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RenameJournal.self, from: data)
    }

    public func save(to url: URL) throws {
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}
