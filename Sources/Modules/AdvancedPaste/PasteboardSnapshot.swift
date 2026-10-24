import AppKit
import MacToysCore

/// Every item and type on the general pasteboard, so "keep the original clipboard" puts back
/// exactly what was copied (rich text, images, files, app-private types), not a simplified copy.
struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    /// Large copies (videos as data, huge images) aren't worth holding twice.
    private static let byteLimit = 64 * 1024 * 1024

    static func capture(_ pb: NSPasteboard = .general) -> PasteboardSnapshot? {
        var total = 0
        var items: [[NSPasteboard.PasteboardType: Data]] = []
        for item in pb.pasteboardItems ?? [] {
            var entry: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else { continue }
                total += data.count
                if total > byteLimit { return nil }
                entry[type] = data
            }
            if !entry.isEmpty { items.append(entry) }
        }
        return items.isEmpty ? nil : PasteboardSnapshot(items: items)
    }

    /// Writes the snapshot back without it being recorded in the clipboard history again.
    @MainActor
    func restore(_ pb: NSPasteboard = .general) {
        if ClipboardHistory.shared.isRunning { ClipboardHistory.shared.ignoreNextChange = true }
        pb.clearContents()
        pb.writeObjects(items.map { entry in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        })
    }
}
