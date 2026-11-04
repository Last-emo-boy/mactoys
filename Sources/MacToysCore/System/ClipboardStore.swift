import Foundation

/// Reads and writes the clipboard history file. Image data is kept in one PNG file per entry next to
/// the JSON (`Images/<id>.png`), so the list file stays small and is cheap to rewrite on every copy.
/// Older history files with images inline still load; the next save moves the images out.
public enum ClipboardStore {
    private static let log = Log.for("clipboard")

    public static func load(from url: URL, images directory: URL) -> [ClipItem] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        var items: [ClipItem]
        do {
            items = try JSONDecoder().decode([ClipItem].self, from: data)
        } catch {
            log.error("Could not read the clipboard history: \(error.localizedDescription, privacy: .public)")
            return []
        }
        for i in items.indices where items[i].kind == .image && items[i].image == nil {
            items[i].image = try? Data(contentsOf: imageFile(for: items[i].id, in: directory))
        }
        return items
    }

    /// Writes `items`, their image files, and removes image files no entry refers to any more.
    public static func save(_ items: [ClipItem], to url: URL, images directory: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var listed = items
        var keep: Set<String> = []
        for i in listed.indices {
            guard let image = listed[i].image else { continue }
            let file = imageFile(for: listed[i].id, in: directory)
            let size = (try? fm.attributesOfItem(atPath: file.path))?[.size] as? Int
            if size != image.count {
                do {
                    try image.write(to: file, options: .atomic)
                } catch {
                    // Keep this one inline rather than lose it.
                    log.error("Could not write a clipboard image: \(error.localizedDescription, privacy: .public)")
                    continue
                }
            }
            keep.insert(file.lastPathComponent)
            listed[i].image = nil
        }
        do {
            try JSONEncoder().encode(listed).write(to: url, options: .atomic)
        } catch {
            log.error("Could not save the clipboard history: \(error.localizedDescription, privacy: .public)")
            return
        }
        let existing = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in existing where name.hasSuffix(".png") && !keep.contains(name) {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    static func imageFile(for id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent(id.uuidString + ".png")
    }
}
