import Foundation

/// The files Peek steps through and which one is shown.
struct PeekItems: Equatable {
    private(set) var urls: [URL]
    private(set) var index: Int

    init(_ urls: [URL], index: Int = 0) {
        self.urls = urls
        self.index = urls.isEmpty ? 0 : min(max(0, index), urls.count - 1)
    }

    var current: URL? { urls.indices.contains(index) ? urls[index] : nil }
    var count: Int { urls.count }
    var isEmpty: Bool { urls.isEmpty }

    /// "IMG_4822.HEIC — 3 of 6" (just the name for a single item).
    var title: String {
        guard let current else { return String(localized: "Peek") }
        guard count > 1 else { return current.lastPathComponent }
        return String(localized: "\(current.lastPathComponent) — \(index + 1) of \(count)",
                      comment: "Peek window title: file name — position of this file and number of files")
    }

    /// Next item, wrapping around at the end.
    mutating func next() {
        guard count > 1 else { return }
        index = (index + 1) % count
    }

    mutating func previous() {
        guard count > 1 else { return }
        index = (index - 1 + count) % count
    }

    /// Drops the current item (after it was moved to the Trash); the following one takes its place.
    mutating func removeCurrent() {
        guard !urls.isEmpty else { return }
        urls.remove(at: index)
        if index >= urls.count { index = max(0, urls.count - 1) }
    }

    /// The items of `file`'s folder in Finder's name order (hidden files skipped), positioned at `file`.
    static func siblings(of file: URL, fileManager: FileManager = .default) -> PeekItems {
        let folder = file.deletingLastPathComponent()
        let contents = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isHiddenKey],
                                                             options: [.skipsHiddenFiles])) ?? []
        var urls = contents.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let target = file.standardizedFileURL.path
        if let i = urls.firstIndex(where: { $0.standardizedFileURL.path == target }) {
            return PeekItems(urls, index: i)
        }
        // A hidden file was selected: show it in front of the others.
        urls.insert(file, at: 0)
        return PeekItems(urls, index: 0)
    }

    /// Existing paths only (the CLI may pass stale ones), in the given order, without duplicates.
    static func existing(_ urls: [URL], fileManager: FileManager = .default) -> [URL] {
        var seen = Set<String>()
        return urls.filter { url in
            let path = url.standardizedFileURL.path
            guard fileManager.fileExists(atPath: path), seen.insert(path).inserted else { return false }
            return true
        }
    }
}
