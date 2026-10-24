import Foundation

/// Turns the selected files and folders into the PowerRename list: each selected item followed
/// by the contents of selected folders (depth first, Finder order). Hidden items inside folders and
/// package contents are left out.
public enum RenameItemLoader {
    public static let defaultLimit = 50_000

    private static let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .creationDateKey,
                                                 .contentModificationDateKey, .contentAccessDateKey]

    public static func load(_ urls: [URL], limit: Int = defaultLimit) -> [RenameItem] {
        var items: [RenameItem] = []
        var seen = Set<String>()
        let roots = urls.map(\.standardizedFileURL)
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        for url in roots where items.count < limit {
            add(url, depth: 0, into: &items, seen: &seen, limit: limit)
        }
        return items
    }

    private static func add(_ url: URL, depth: Int, into items: inout [RenameItem], seen: inout Set<String>, limit: Int) {
        guard items.count < limit, seen.insert(url.path).inserted else { return }
        let values = try? url.resourceValues(forKeys: Set(keys))
        guard values != nil || FileManager.default.fileExists(atPath: url.path) else { return }
        let isDirectory = values?.isDirectory ?? false
        let isFolder = isDirectory && !(values?.isPackage ?? false)
        items.append(RenameItem(id: items.count, url: url, isFolder: isFolder, depth: depth,
                                created: values?.creationDate, modified: values?.contentModificationDate,
                                accessed: values?.contentAccessDate))
        guard isFolder else { return }
        let children = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        for child in children.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            add(child.standardizedFileURL, depth: depth + 1, into: &items, seen: &seen, limit: limit)
        }
    }
}
