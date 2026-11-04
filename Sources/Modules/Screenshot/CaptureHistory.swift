import AppKit
import CoreGraphics
import Foundation
import ImageIO
import MacToysCore
import Observation

/// One capture kept in the history.
struct HistoryEntry: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var date: Date
    var kind: CaptureKind
    var pixelWidth: Int
    var pixelHeight: Int
    var scale: CGFloat
    /// Bytes the entry takes on disk.
    var bytes: Int64
    /// Where the finished image was saved, if it was.
    var savedPath: String?
}

/// Decides which history entries go: everything past the age limit, then the oldest until the rest fits.
enum HistoryPruner {
    static func toRemove(_ entries: [HistoryEntry], limitBytes: Int64, maxAgeDays: Int, now: Date) -> Set<UUID> {
        var remove = Set<UUID>()
        if maxAgeDays > 0 {
            let cutoff = now.addingTimeInterval(-Double(maxAgeDays) * 86_400)
            for e in entries where e.date < cutoff { remove.insert(e.id) }
        }
        let kept = entries.filter { !remove.contains($0.id) }.sorted { $0.date > $1.date }
        var total = kept.reduce(Int64(0)) { $0 + $1.bytes }
        // Oldest first; the newest capture always stays, even when it alone is over the limit.
        for e in kept.dropFirst().reversed() where total > limitBytes {
            remove.insert(e.id)
            total -= e.bytes
        }
        return remove
    }
}

/// Recent captures in `~/Library/Application Support/MacToys/screenshot/History`: the original
/// image, its annotations and a thumbnail per capture, so any of them can be annotated again.
@MainActor
@Observable
final class CaptureHistory {
    private(set) var entries: [HistoryEntry] = []
    @ObservationIgnored let directory: URL
    @ObservationIgnored private var thumbnails: [UUID: NSImage] = [:]
    @ObservationIgnored private let log = Log.for("screenshot")
    @ObservationIgnored private var indexURL: URL { directory.appendingPathComponent("index.json") }

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL) {
            do {
                entries = try JSONDecoder().decode([HistoryEntry].self, from: data)
            } catch {
                log.error("History index unreadable: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    var totalBytes: Int64 { entries.reduce(0) { $0 + $1.bytes } }

    private func folder(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString, isDirectory: true) }
    private func imageURL(_ id: UUID) -> URL { folder(id).appendingPathComponent("capture.png") }
    private func thumbURL(_ id: UUID) -> URL { folder(id).appendingPathComponent("thumbnail.png") }
    private func markupURL(_ id: UUID) -> URL { folder(id).appendingPathComponent("markup.json") }

    /// Stores a new capture. `rendered` is the finished image, for the thumbnail.
    func add(id: UUID, image: CGImage, rendered: CGImage, document: MarkupDocument, kind: CaptureKind, date: Date,
             savedURL: URL?, limitMB: Int, maxAgeDays: Int) {
        let entry = HistoryEntry(id: id, date: date, kind: kind, pixelWidth: image.width, pixelHeight: image.height,
                                 scale: document.scale, bytes: 0, savedPath: savedURL?.path)
        entries.insert(entry, at: 0)
        thumbnails[id] = Self.thumbnail(rendered).map { NSImage(cgImage: $0, size: .zero) }
        let folder = folder(id), imageURL = imageURL(id), thumbURL = thumbURL(id), markupURL = markupURL(id)
        let original = image
        let finished = rendered
        let doc = document
        Task.detached(priority: .utility) {
            var bytes: Int64 = 0
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let png = try ImageEncoder.data(original, format: .png, quality: 1, scale: doc.scale)
                try png.write(to: imageURL, options: .atomic)
                bytes += Int64(png.count)
                if let thumb = Self.thumbnail(finished), let data = try? ImageEncoder.data(thumb, format: .png, quality: 1) {
                    try data.write(to: thumbURL, options: .atomic)
                    bytes += Int64(data.count)
                }
                let json = try JSONEncoder().encode(doc)
                try json.write(to: markupURL, options: .atomic)
                bytes += Int64(json.count)
            } catch {
                Log.for("screenshot").error("Saving to history failed: \(error.localizedDescription, privacy: .public)")
            }
            let total = bytes
            await MainActor.run { [weak self] in
                guard let self, let i = self.entries.firstIndex(where: { $0.id == entry.id }) else { return }
                self.entries[i].bytes = total
                self.prune(limitMB: limitMB, maxAgeDays: maxAgeDays)
                self.saveIndex()
            }
        }
    }

    /// Saves edited annotations and the refreshed thumbnail.
    func update(_ id: UUID, document: MarkupDocument, rendered: CGImage) {
        guard entries.contains(where: { $0.id == id }) else { return }
        thumbnails[id] = Self.thumbnail(rendered).map { NSImage(cgImage: $0, size: .zero) }
        let markupURL = markupURL(id), thumbURL = thumbURL(id)
        let finished = rendered
        Task.detached(priority: .utility) {
            do {
                try JSONEncoder().encode(document).write(to: markupURL, options: .atomic)
                if let thumb = Self.thumbnail(finished) {
                    try ImageEncoder.data(thumb, format: .png, quality: 1).write(to: thumbURL, options: .atomic)
                }
            } catch {
                Log.for("screenshot").error("Updating history failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func setSaved(_ id: UUID, url: URL) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].savedPath = url.path
        saveIndex()
    }

    func delete(_ id: UUID) {
        entries.removeAll { $0.id == id }
        thumbnails[id] = nil
        remove(folders: [id])
        saveIndex()
    }

    func clear() {
        let ids = entries.map(\.id)
        entries.removeAll()
        thumbnails.removeAll()
        remove(folders: ids)
        saveIndex()
    }

    /// Applies the size and age limits.
    func prune(limitMB: Int, maxAgeDays: Int) {
        let drop = HistoryPruner.toRemove(entries, limitBytes: Int64(limitMB) * 1_000_000, maxAgeDays: maxAgeDays, now: Date())
        guard !drop.isEmpty else { return }
        entries.removeAll { drop.contains($0.id) }
        for id in drop { thumbnails[id] = nil }
        remove(folders: Array(drop))
        saveIndex()
    }

    func image(for id: UUID) -> (CGImage, CGFloat)? { CaptureTransfer.load(imageURL(id)) }

    func document(for id: UUID) -> MarkupDocument? {
        guard let data = try? Data(contentsOf: markupURL(id)) else { return nil }
        do {
            return try JSONDecoder().decode(MarkupDocument.self, from: data)
        } catch {
            log.error("History annotations unreadable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func thumbnail(for id: UUID) -> NSImage? {
        if let cached = thumbnails[id] { return cached }
        guard let image = NSImage(contentsOf: thumbURL(id)) else { return nil }
        thumbnails[id] = image
        return image
    }

    /// Puts a ready-made thumbnail in the cache (previews).
    func setThumbnail(_ image: NSImage, for id: UUID) { thumbnails[id] = image }

    /// Replaces the entries without touching disk (previews).
    func setPreviewEntries(_ list: [HistoryEntry]) { entries = list }

    private func remove(folders ids: [UUID]) {
        let urls = ids.map(folder)
        Task.detached(priority: .utility) {
            for url in urls where FileManager.default.fileExists(atPath: url.path) {
                do { try FileManager.default.removeItem(at: url) } catch {
                    Log.for("screenshot").error("Removing a history item failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    private func saveIndex() {
        let snapshot = entries
        let url = indexURL
        Task.detached(priority: .utility) {
            do {
                try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
            } catch {
                Log.for("screenshot").error("Saving the history index failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// A small version of the finished image (at most 640 px on its long side).
    nonisolated static func thumbnail(_ image: CGImage, maxSide: CGFloat = 640) -> CGImage? {
        let long = CGFloat(max(image.width, image.height))
        guard long > maxSide else { return image }
        return Compositor.downscaled(image, by: maxSide / long)
    }
}
