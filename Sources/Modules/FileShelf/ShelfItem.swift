import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// One thing held on a shelf: a file or folder (by reference), or a clipping MacToys keeps itself —
/// text, an image or a web link that was dropped in and is saved to a file in the clippings store.
struct ShelfItem: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case file, text, image, link
    }

    var id = UUID()
    var kind: Kind
    /// The file itself for `.file`; for clippings, the file that backs it in the clippings store.
    var url: URL
    /// The name shown on the shelf; for clippings, also the file name it gets when saved or dragged out.
    var name: String
    /// A bookmark to `url` (files only), so files that move or are renamed are found again.
    var bookmark: Data?
    /// The file lives in MacToys' clippings store (dropped text, images, received file promises):
    /// it is deleted once no shelf or recent shelf refers to it, and it can be renamed.
    var owned = false
    /// The web address of a `.link`.
    var link: URL?
    /// The first few hundred characters of a `.text` clipping, for its card.
    var preview: String?
    /// SHA-256 of a clipping's content, to skip dropping the same thing twice.
    var fingerprint: String?
    var byteSize: Int64?
    var isDirectory = false
    /// Uniform type identifier of the file.
    var contentType: String?
    var added = Date()

    /// Items that are the same thing share a key: the file's standardized path, or a clipping's content.
    var dedupeKey: String {
        switch kind {
        case .file: "file:" + url.standardizedFileURL.resolvingSymlinksInPath().path
        case .link: "link:" + (link?.absoluteString ?? fingerprint ?? id.uuidString)
        case .text, .image: "\(kind.rawValue):" + (fingerprint ?? id.uuidString)
        }
    }

    var isClipping: Bool { kind != .file }

    /// Files dropped in (not received or created by MacToys) are references to the user's own files.
    var isUserFile: Bool { kind == .file && !owned }

    var utType: UTType? { contentType.flatMap(UTType.init) }

    static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Refreshes size, type and folder flag from the file system.
    mutating func refreshAttributes() {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey, .contentTypeKey, .isPackageKey])
        isDirectory = (values?.isDirectory ?? false) && !(values?.isPackage ?? false)
        byteSize = isDirectory ? nil : values?.fileSize.map(Int64.init)
        contentType = values?.contentType?.identifier ?? contentType
    }

    /// A file item for a file or folder the user dropped in.
    static func file(_ url: URL, owned: Bool = false) -> ShelfItem {
        var item = ShelfItem(kind: .file, url: url.standardizedFileURL, name: url.lastPathComponent, owned: owned)
        item.bookmark = owned ? nil : try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        item.refreshAttributes()
        return item
    }
}

/// A shelf: an ordered pile of items, in the order they were dropped.
struct Shelf: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var items: [ShelfItem] = []
    /// A name the user gave the shelf.
    var title: String?
    /// Pinned shelves stay open after dragging out or emptying, and are always kept across restarts.
    var pinned = false
    /// Last frame on screen, in Cocoa coordinates.
    var frame: CGRect?
    var expanded = false
    var created = Date()
    /// When the shelf was closed (recent shelves).
    var closed: Date?

    var isEmpty: Bool { items.isEmpty }

    /// Appends the items that aren't on the shelf yet (and aren't repeated within `new`), keeping
    /// drop order. Returns the items actually added.
    @discardableResult
    mutating func add(_ new: [ShelfItem]) -> [ShelfItem] {
        var keys = Set(items.map(\.dedupeKey))
        var added: [ShelfItem] = []
        for item in new where keys.insert(item.dedupeKey).inserted {
            added.append(item)
        }
        items += added
        return added
    }

    mutating func remove(_ ids: Set<UUID>) {
        items.removeAll { ids.contains($0.id) }
    }

    /// The items drawn on the pile, most recent on top (first).
    var pileItems: [ShelfItem] { Array(items.suffix(3).reversed()) }

    var totalBytes: Int64 { items.reduce(0) { $0 + ($1.byteSize ?? 0) } }

    /// Items in the shelf's order, restricted to `ids` (all items when `ids` is empty).
    func items(_ ids: Set<UUID>) -> [ShelfItem] {
        ids.isEmpty ? items : items.filter { ids.contains($0.id) }
    }
}

/// Everything File Shelf remembers between launches (`shelves.json`).
struct ShelfArchive: Codable, Equatable, Sendable {
    var open: [Shelf] = []
    var recent: [Shelf] = []

    static let recentLimit = 10

    /// Adds a closed shelf to the front of the recent list (shelves with items only), keeping
    /// at most `recentLimit`. Returns the shelves that fell off the end.
    @discardableResult
    static func pushRecent(_ shelf: Shelf, into recent: inout [Shelf], limit: Int = recentLimit) -> [Shelf] {
        recent.removeAll { $0.id == shelf.id }
        guard !shelf.isEmpty else { return [] }
        recent.insert(shelf, at: 0)
        guard recent.count > limit else { return [] }
        let dropped = Array(recent[limit...])
        recent.removeLast(recent.count - limit)
        return dropped
    }
}
