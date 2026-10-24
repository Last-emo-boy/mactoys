import Foundation

/// File/subfolder counts and total size of a folder, gathered in the background with progress.
public struct FolderSummary: Sendable, Equatable {
    public var files = 0
    public var folders = 0
    /// Sum of file sizes (logical bytes, like Finder's "Size").
    public var bytes: Int64 = 0
    /// Some subfolders could not be read (permissions); counts are lower bounds.
    public var incomplete = false
    public var finished = false

    public init() {}

    /// Counts everything below `url`, calling `progress` about every 150 ms and once at the end.
    /// Returns early (unfinished) when `isCancelled` becomes true.
    public static func scan(_ url: URL, progress: (FolderSummary) -> Void, isCancelled: () -> Bool = { false }) -> FolderSummary {
        var s = FolderSummary()
        var sawError = false
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .isPackageKey]
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [],
                                                          errorHandler: { _, _ in sawError = true; return true }) else {
            s.incomplete = true
            s.finished = true
            progress(s)
            return s
        }
        var lastReport = Date()
        for case let item as URL in walker {
            if isCancelled() { s.incomplete = s.incomplete || sawError; return s }
            let values = try? item.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true && values?.isSymbolicLink != true {
                s.folders += 1
            } else {
                s.files += 1
                s.bytes += Int64(values?.fileSize ?? 0)
            }
            if Date().timeIntervalSince(lastReport) > 0.15 {
                lastReport = Date()
                s.incomplete = sawError
                progress(s)
            }
        }
        s.incomplete = sawError
        s.finished = true
        progress(s)
        return s
    }

    /// The same scan as an async stream of snapshots; cancelling the consuming task stops the walk.
    public static func stream(_ url: URL) -> AsyncStream<FolderSummary> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .utility) {
                _ = scan(url, progress: { continuation.yield($0) }, isCancelled: { Task.isCancelled })
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
