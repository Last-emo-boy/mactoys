import CoreServices
import Foundation
import MacToysCore

/// Watches folders with FSEvents and reports files that newly appear in them (not in subfolders),
/// once they stop growing.
///
/// "New" means added to the folder after watching began (by date added, so screenshots, downloads and
/// files moved in count; renaming an old file doesn't). Hidden files, partial downloads, files MacToys
/// wrote or restored (`FileMarker`) and MacToys' own writes (`IgnoreSelf`) are skipped.
@MainActor
final class FolderWatcher {
    var onNewFile: (URL, WatchFolder) -> Void = { _, _ in }

    private var stream: FSEventStreamRef?
    private var folders: [String: WatchFolder] = [:]   // resolved path → rule
    private var startedAt = Date()
    private var pending: [String: Int64] = [:]           // path → size at the last look
    private var handled: Set<String> = []
    private let log = Log.for("optimizer")

    var watchedPaths: [String] { folders.keys.sorted() }

    /// Watches exactly the enabled folders in `list`; restarts only when the set of paths changed.
    func update(_ list: [WatchFolder]) {
        var next: [String: WatchFolder] = [:]
        for folder in list where folder.enabled {
            var isDirectory: ObjCBool = false
            let path = folder.url.resolvingSymlinksInPath().path
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            next[path] = folder
        }
        let changed = Set(next.keys) != Set(folders.keys)
        folders = next
        guard changed || (stream == nil && !next.isEmpty) else { return }
        stopStream()
        guard !next.isEmpty else { return }
        startStream(paths: Array(next.keys))
    }

    func stop() {
        stopStream()
        folders = [:]
        pending = [:]
        handled = []
    }

    private func startStream(paths: [String]) {
        startedAt = Date()
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray as? [String] ?? []
            let events = (0..<count).map { (list.indices.contains($0) ? list[$0] : "", flags[$0]) }
            MainActor.assumeIsolated { watcher.handle(events) }
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                           | kFSEventStreamCreateFlagIgnoreSelf | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(nil, callback, &context, paths as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5, flags) else {
            log.error("Could not watch folders")
            return
        }
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
        stream = s
    }

    private func stopStream() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    private func handle(_ events: [(String, FSEventStreamEventFlags)]) {
        let interesting = UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed
                                 | kFSEventStreamEventFlagItemModified)
        for (path, flags) in events {
            guard flags & UInt32(kFSEventStreamEventFlagItemIsFile) != 0, flags & interesting != 0 else { continue }
            let url = URL(fileURLWithPath: path)
            guard folders[url.deletingLastPathComponent().path] != nil, Self.isCandidateName(url.lastPathComponent),
                  !handled.contains(path), pending[path] == nil else { continue }
            pending[path] = -1
            settle(path)
        }
    }

    /// Looks again every second until the size stops changing, then reports the file.
    private func settle(_ path: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let last = self.pending[path] else { return }
                let url = URL(fileURLWithPath: path)
                guard let folder = self.folders[url.deletingLastPathComponent().path],
                      FileManager.default.fileExists(atPath: path) else {
                    self.pending[path] = nil
                    return
                }
                let size = FileSize.of(url)
                guard size > 0, size == last else {
                    self.pending[path] = size
                    self.settle(path)
                    return
                }
                self.pending[path] = nil
                guard self.isNew(url), !FileMarker.isMarked(url) else { return }
                self.handled.insert(path)
                self.onNewFile(url, folder)
            }
        }
    }

    private func isNew(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.addedToDirectoryDateKey, .creationDateKey])
        guard let added = values?.addedToDirectoryDate ?? values?.creationDate else { return false }
        return added >= startedAt.addingTimeInterval(-2)
    }

    /// Skips hidden files and downloads in progress.
    static func isCandidateName(_ name: String) -> Bool {
        guard !name.hasPrefix("."), !name.isEmpty else { return false }
        let partial: Set<String> = ["download", "crdownload", "part", "partial", "tmp", "opdownload"]
        return !partial.contains((name as NSString).pathExtension.lowercased())
    }
}
