import AppKit
import Foundation
import MacToysCore
import UniformTypeIdentifiers

/// What a drop or paste contained, before it becomes a `ShelfItem`.
enum ShelfDrop: Equatable, Sendable {
    case file(URL)
    case text(String)
    /// Image bytes and the file extension they are saved with ("png", "jpg", "gif").
    case image(Data, String)
    case link(URL, title: String?)
}

/// The folder where clippings (dropped text, images, links, received file promises) are kept as
/// files, one subfolder per drop so every clipping keeps the name the user gives it.
struct ClippingStore: Sendable {
    let root: URL

    static var standard: ClippingStore {
        ClippingStore(root: Paths.data(for: "shelf").appendingPathComponent("Clippings", isDirectory: true))
    }

    /// A new, empty folder for one clipping or one batch of received files.
    func makeFolder() throws -> URL {
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func contains(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/")
    }

    /// Turns a drop into an item; clippings are written to the store first.
    func item(for drop: ShelfDrop, now: Date = Date()) throws -> ShelfItem {
        switch drop {
        case .file(let url):
            return ShelfItem.file(url, owned: contains(url))
        case .text(let text):
            let data = Data(text.utf8)
            let name = ShelfNaming.textClippingName(text)
            let url = try makeFolder().appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            var item = ShelfItem(kind: .text, url: url, name: name, owned: true)
            item.preview = String(text.prefix(400))
            item.fingerprint = ShelfItem.fingerprint(data)
            item.byteSize = Int64(data.count)
            item.contentType = UTType.plainText.identifier
            return item
        case .image(let data, let ext):
            let name = ShelfNaming.imageClippingName(date: now, ext: ext)
            let url = try makeFolder().appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            var item = ShelfItem(kind: .image, url: url, name: name, owned: true)
            item.fingerprint = ShelfItem.fingerprint(data)
            item.byteSize = Int64(data.count)
            item.contentType = UTType(filenameExtension: ext)?.identifier ?? UTType.image.identifier
            return item
        case .link(let link, let title):
            let name = ShelfNaming.linkClippingName(link, title: title)
            let data = try PropertyListSerialization.data(fromPropertyList: ["URL": link.absoluteString], format: .xml, options: 0)
            let url = try makeFolder().appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            var item = ShelfItem(kind: .link, url: url, name: name, owned: true)
            item.link = link
            item.preview = title
            item.fingerprint = ShelfItem.fingerprint(Data(link.absoluteString.utf8))
            item.byteSize = Int64(data.count)
            item.contentType = "com.apple.web-internet-location"
            return item
        }
    }

    /// Renames an owned item's file inside its folder. Returns the updated item.
    func rename(_ item: ShelfItem, to proposed: String) throws -> ShelfItem {
        let folder = item.url.deletingLastPathComponent()
        var name = ShelfNaming.sanitize(proposed)
        if name.isEmpty { return item }
        // Keep the extension when the new name has none (a text clipping stays a .txt).
        let ext = item.url.pathExtension
        if !ext.isEmpty, (name as NSString).pathExtension.isEmpty { name += "." + ext }
        guard name != item.url.lastPathComponent else { return item }
        let existing = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .subtracting([item.url.lastPathComponent])
        name = ShelfNaming.unique(name, existing: existing)
        let target = folder.appendingPathComponent(name)
        try FileManager.default.moveItem(at: item.url, to: target)
        var renamed = item
        renamed.url = target
        renamed.name = name
        return renamed
    }

    /// Deletes clipping folders that no shelf refers to any more. Folders created after
    /// `sparingAfter` are left alone: files from a drag may still be arriving in them.
    func collectGarbage(keeping items: [ShelfItem], sparingAfter: Date? = nil) {
        let keep = Set(items.filter(\.owned).map { $0.url.deletingLastPathComponent().standardizedFileURL.path })
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey]) else { return }
        for folder in folders where !keep.contains(folder.standardizedFileURL.path) {
            if let sparingAfter, let created = (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate,
               created > sparingAfter { continue }
            do { try fm.removeItem(at: folder) } catch {
                Log.for("shelf").error("Could not remove clipping \(folder.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

/// Reads and writes `shelves.json` and brings saved shelves back, leaving out files that are gone.
enum ShelfPersistence {
    static var standardURL: URL { Paths.data(for: "shelf").appendingPathComponent("shelves.json") }

    static func load(from url: URL) -> ShelfArchive {
        guard let data = try? Data(contentsOf: url) else { return ShelfArchive() }
        do {
            return try decoder.decode(ShelfArchive.self, from: data)
        } catch {
            Log.for("shelf").error("Could not read saved shelves: \(error.localizedDescription, privacy: .public)")
            return ShelfArchive()
        }
    }

    static func save(_ archive: ShelfArchive, to url: URL) {
        do {
            try encoder.encode(archive).write(to: url, options: .atomic)
        } catch {
            Log.for("shelf").error("Could not save shelves: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The shelf as it can be shown again: items whose files still exist (found again through their
    /// bookmarks when they moved), or nil when an unpinned shelf has nothing left.
    static func restore(_ shelf: Shelf, locate: (ShelfItem) -> URL? = locate) -> Shelf? {
        var restored = shelf
        restored.items = shelf.items.compactMap { item in
            guard let url = locate(item) else { return nil }
            var copy = item
            if url.standardizedFileURL != item.url.standardizedFileURL {
                copy.url = url.standardizedFileURL
                if item.kind == .file, !item.owned { copy.name = url.lastPathComponent }
            }
            return copy
        }
        if restored.items.isEmpty && !restored.pinned { return nil }
        return restored
    }

    /// Where an item's file is now, or nil when it is gone.
    static func locate(_ item: ShelfItem) -> URL? {
        let fm = FileManager.default
        if !item.owned, let bookmark = item.bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                  relativeTo: nil, bookmarkDataIsStale: &stale),
               fm.fileExists(atPath: url.path) {
                return url
            }
        }
        return fm.fileExists(atPath: item.url.path) ? item.url : nil
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private static let decoder = JSONDecoder()
}
