import Darwin
import Foundation
import MacToysCore

/// Originals kept for undo: `<root>/<yyyyMMdd-HHmmss>-<id>/<file name>`, one folder per original,
/// removed after the retention period.
struct BackupStore: Sendable {
    let root: URL

    init(root: URL) {
        self.root = root
    }

    /// `~/Library/Application Support/MacToys/optimizer/Backups`.
    static var standard: BackupStore {
        BackupStore(root: Paths.data(for: "optimizer").appendingPathComponent("Backups", isDirectory: true))
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    private func newFolder(date: Date) throws -> URL {
        let id = UUID().uuidString.prefix(8).lowercased()
        let folder = root.appendingPathComponent("\(Self.stamp.string(from: date))-\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Copies `url` into a new backup folder (a clone on APFS: instant and free until either changes).
    func backup(_ url: URL, date: Date = Date()) throws -> URL {
        let target = try newFolder(date: date).appendingPathComponent(url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: target)
        return target
    }

    /// Stores data that has no file yet (a clipboard image).
    func store(_ data: Data, name: String, date: Date = Date()) throws -> URL {
        let target = try newFolder(date: date).appendingPathComponent(name)
        try data.write(to: target, options: .atomic)
        return target
    }

    /// Puts a backup back at `destination`, replacing what is there; the backup stays.
    func restore(_ backup: URL, to destination: URL) throws {
        let fm = FileManager.default
        let temp = destination.deletingLastPathComponent()
            .appendingPathComponent(".mactoys-restore-\(UUID().uuidString)-\(destination.lastPathComponent)")
        try fm.copyItem(at: backup, to: temp)
        do {
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: temp)
            } else {
                try fm.moveItem(at: temp, to: destination)
            }
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }

    /// Backup folders, oldest first, with their dates.
    func folders() -> [(url: URL, date: Date)] {
        let keys: [URLResourceKey] = [.creationDateKey, .isDirectoryKey]
        let items = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: keys,
                                                                   options: [.skipsHiddenFiles])) ?? []
        return items.compactMap { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isDirectory == true else { return nil }
            return (url, values?.creationDate ?? .distantPast)
        }
        .sorted { $0.date < $1.date }
    }

    /// Deletes backups made before `cutoff`; returns how many.
    @discardableResult
    func prune(before cutoff: Date) -> Int {
        var removed = 0
        for folder in folders() where folder.date < cutoff {
            do {
                try FileManager.default.removeItem(at: folder.url)
                removed += 1
            } catch {
                Log.for("optimizer").error("Could not remove backup \(folder.url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return removed
    }

    func deleteAll() {
        prune(before: .distantFuture)
    }

    /// Bytes used by all backups.
    func totalSize() -> Int64 {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            let v = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            total += Int64(v?.totalFileAllocatedSize ?? v?.fileSize ?? 0)
        }
        return total
    }
}

/// An extended attribute on files the Optimizer wrote or restored, so watch folders leave them alone.
enum FileMarker {
    static let name = "com.w33d.mactoys.optimizer"

    static func mark(_ url: URL) {
        let value = Array("1".utf8)
        let status = setxattr(url.path, name, value, value.count, 0, 0)
        if status != 0 {
            Log.for("optimizer").error("Could not mark \(url.path, privacy: .public): errno \(errno)")
        }
    }

    static func isMarked(_ url: URL) -> Bool {
        getxattr(url.path, name, nil, 0, 0, 0) >= 0
    }
}

/// File sizes.
enum FileSize {
    /// Read fresh from disk (URL resource values are cached per URL instance).
    static func of(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// "4.2 MB", in the user's locale.
    static func format(_ bytes: Int64, locale: Locale = .current) -> String {
        bytes.formatted(.byteCount(style: .file).locale(locale))
    }
}
