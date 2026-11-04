import Foundation
import MacToysCore
import Observation

/// A named, colored collection of clipboard entries. Entries on a pinboard are copies: they never
/// expire with the history and survive "Clear history".
public struct Pinboard: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    public var tint: Tint
    /// Newest first.
    public var items: [ClipItem] = []

    public init(name: String, tint: Tint, items: [ClipItem] = []) {
        self.name = name
        self.tint = tint
        self.items = items
    }

    /// Colors offered for pinboards, in picker order.
    static let tints: [Tint] = [.blue, .purple, .pink, .red, .orange, .yellow, .green, .mint, .teal, .graphite]
}

extension Tint {
    /// The color's name, for pinboard color menus and VoiceOver.
    var colorName: String {
        switch self {
        case .blue: String(localized: "Blue", comment: "Color name")
        case .indigo: String(localized: "Indigo", comment: "Color name")
        case .purple: String(localized: "Purple", comment: "Color name")
        case .pink: String(localized: "Pink", comment: "Color name")
        case .red: String(localized: "Red", comment: "Color name")
        case .orange: String(localized: "Orange", comment: "Color name")
        case .yellow: String(localized: "Yellow", comment: "Color name")
        case .green: String(localized: "Green", comment: "Color name")
        case .mint: String(localized: "Mint", comment: "Color name")
        case .teal: String(localized: "Teal", comment: "Color name")
        case .cyan: String(localized: "Cyan", comment: "Color name")
        case .graphite: String(localized: "Graphite", comment: "Color name")
        case .brown: String(localized: "Brown", comment: "Color name")
        }
    }
}

/// What `library.json` holds.
struct LibraryData: Codable, Equatable {
    var version = 1
    var pinboards: [Pinboard] = []
    var snippets: [Snippet] = []

    init(pinboards: [Pinboard] = [], snippets: [Snippet] = []) {
        self.pinboards = pinboards
        self.snippets = snippets
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> LibraryData {
        try JSONDecoder().decode(LibraryData.self, from: data)
    }
}

/// Pinboards and snippets, saved in `~/Library/Application Support/MacToys/clipboard/library.json`.
@MainActor
@Observable
final class ClipLibrary {
    private(set) var pinboards: [Pinboard]
    private(set) var snippets: [Snippet]

    @ObservationIgnored private let file: URL?
    @ObservationIgnored private var pendingSave: DispatchWorkItem?
    @ObservationIgnored private let log = Log.for("clipboard")
    nonisolated private static let saveQueue = DispatchQueue(label: "com.w33d.mactoys.clipboard-library", qos: .utility)

    static var defaultFile: URL { Paths.data(for: "clipboard").appendingPathComponent("library.json") }

    /// `file` nil keeps everything in memory (previews).
    init(file: URL?, initial: LibraryData = LibraryData()) {
        self.file = file
        var data = initial
        if let file, let stored = try? Data(contentsOf: file) {
            do { data = try LibraryData.decode(stored) } catch {
                Log.for("clipboard").error("Could not read the pinboards: \(error.localizedDescription, privacy: .public)")
            }
        }
        pinboards = data.pinboards
        snippets = data.snippets
    }

    var data: LibraryData { LibraryData(pinboards: pinboards, snippets: snippets) }

    func pinboard(_ id: UUID) -> Pinboard? { pinboards.first { $0.id == id } }

    // MARK: Pinboards

    @discardableResult
    func createPinboard(name: String, tint: Tint? = nil) -> Pinboard {
        let color = tint ?? Pinboard.tints[pinboards.count % Pinboard.tints.count]
        let board = Pinboard(name: name, tint: color)
        pinboards.append(board)
        changed()
        return board
    }

    func updatePinboard(_ id: UUID, _ change: (inout Pinboard) -> Void) {
        guard let i = pinboards.firstIndex(where: { $0.id == id }) else { return }
        var board = pinboards[i]
        change(&board)
        guard board != pinboards[i] else { return }
        pinboards[i] = board
        changed()
    }

    func deletePinboard(_ id: UUID) {
        pinboards.removeAll { $0.id == id }
        changed()
    }

    func movePinboards(from source: IndexSet, to destination: Int) {
        pinboards.move(fromOffsets: source, toOffset: destination)
        changed()
    }

    /// Copies entries onto a pinboard (newest on top). Content already there moves to the top instead.
    func add(_ items: [ClipItem], to id: UUID) {
        updatePinboard(id) { board in
            for item in items.reversed() {
                var copy = item
                copy.id = UUID()
                copy.pinned = false
                if let existing = board.items.firstIndex(where: { $0.hasSameContent(as: item) }) {
                    copy = board.items.remove(at: existing)
                    if let name = item.name { copy.name = name }
                }
                board.items.insert(copy, at: 0)
            }
        }
    }

    func remove(_ ids: Set<UUID>, from id: UUID) {
        updatePinboard(id) { $0.items.removeAll { ids.contains($0.id) } }
    }

    func update(_ item: ClipItem, in id: UUID) {
        updatePinboard(id) { board in
            if let i = board.items.firstIndex(where: { $0.id == item.id }) { board.items[i] = item }
        }
    }

    // MARK: Snippets

    func addSnippet(_ snippet: Snippet) {
        snippets.append(snippet)
        changed()
    }

    func updateSnippet(_ snippet: Snippet) {
        guard let i = snippets.firstIndex(where: { $0.id == snippet.id }) else { addSnippet(snippet); return }
        guard snippets[i] != snippet else { return }
        snippets[i] = snippet
        changed()
    }

    func deleteSnippet(_ id: UUID) {
        snippets.removeAll { $0.id == id }
        changed()
    }

    // MARK: Saving

    private func changed() {
        guard file != nil else { return }
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.flush() } }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// Writes pending changes now.
    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        guard let file else { return }
        let snapshot = data
        let log = log
        Self.saveQueue.async {
            do {
                try snapshot.encoded().write(to: file, options: .atomic)
            } catch {
                log.error("Could not save the pinboards: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Waits for writes already queued (tests).
    nonisolated static func waitForSaves() {
        saveQueue.sync {}
    }
}
