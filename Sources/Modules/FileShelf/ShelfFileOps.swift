import Foundation
import MacToysCore

/// File work behind shelf actions: compressing to ZIP and moving into a folder.
enum ShelfFileOps {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The folder an archive of `items` goes to: the folder they share when it can be written to
    /// (as Finder does), otherwise a new folder in the clippings store (the archive is then owned).
    static func archiveFolder(for items: [ShelfItem], store: ClippingStore) throws -> (URL, owned: Bool) {
        let parents = Set(items.map { $0.url.deletingLastPathComponent().standardizedFileURL })
        if parents.count == 1, let parent = parents.first, !store.contains(items[0].url),
           FileManager.default.isWritableFile(atPath: parent.path) {
            return (parent, false)
        }
        return (try store.makeFolder(), true)
    }

    /// Compresses `urls` into a ZIP in `folder` like Finder's Compress: "Name.ext.zip" for one item,
    /// "Archive.zip" (localized) for several, numbered when taken. Runs `ditto` off the main thread.
    static func compress(_ urls: [URL], into folder: URL, archiveWord: String) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            try compressSync(urls, into: folder, archiveWord: archiveWord)
        }.value
    }

    static func compressSync(_ urls: [URL], into folder: URL, archiveWord: String) throws -> URL {
        let fm = FileManager.default
        guard !urls.isEmpty else { throw Failure(message: String(localized: "There is nothing to compress.")) }
        let existing = Set((try? fm.contentsOfDirectory(atPath: folder.path)) ?? [])
        let name = ShelfNaming.zipName(for: urls.map(\.lastPathComponent), archive: archiveWord, existing: existing)
        let destination = folder.appendingPathComponent(name)
        if urls.count == 1 {
            let r = Shell.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", urls[0].path, destination.path])
            guard r.ok else { throw Failure(message: r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return destination
        }
        // ditto archives one source: gather the items (as APFS clones where possible) in a staging
        // folder on the destination's volume and archive its contents.
        let staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: folder, create: true)
            .appendingPathComponent(archiveWord, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging.deletingLastPathComponent()) }
        var used: Set<String> = []
        for url in urls {
            let item = ShelfNaming.unique(url.lastPathComponent, existing: used)
            used.insert(item)
            try fm.copyItem(at: url, to: staging.appendingPathComponent(item))
        }
        let r = Shell.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", staging.path, destination.path])
        guard r.ok else { throw Failure(message: r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return destination
    }

    /// Moves `url` into `folder`, numbering the name when it's taken. Returns the new location.
    static func move(_ url: URL, into folder: URL) throws -> URL {
        let fm = FileManager.default
        if url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL { return url }
        let existing = Set((try? fm.contentsOfDirectory(atPath: folder.path)) ?? [])
        let target = folder.appendingPathComponent(ShelfNaming.unique(url.lastPathComponent, existing: existing))
        try fm.moveItem(at: url, to: target)
        return target
    }
}
