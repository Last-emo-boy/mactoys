import AppKit
import Observation

/// One clipboard entry.
public struct ClipItem: Identifiable, Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case text, richText, html, image, files }

    public var id = UUID()
    public var date = Date()
    public var kind: Kind
    /// Plain-text representation (always set when the item has any text).
    public var text: String?
    public var html: String?
    public var rtf: Data?
    /// PNG data for images.
    public var image: Data?
    public var files: [URL] = []
    public var sourceApp: String?
    public var pinned = false

    /// Short human summary for lists.
    public var title: String {
        switch kind {
        case .image: "Image"
        case .files: files.count == 1 ? files[0].lastPathComponent : "\(files.count) files"
        default: (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ↵ ")
        }
    }

    /// Reads whatever is on a pasteboard now.
    public static func current(from pb: NSPasteboard = .general) -> ClipItem? {
        let app = NSWorkspace.shared.frontmostApplication?.localizedName
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return ClipItem(kind: .files, text: urls.map(\.path).joined(separator: "\n"), files: urls, sourceApp: app)
        }
        if let img = NSImage(pasteboard: pb), pb.availableType(from: [.png, .tiff]) != nil,
           let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return ClipItem(kind: .image, text: pb.string(forType: .string), image: png, sourceApp: app)
        }
        let text = pb.string(forType: .string)
        if let html = pb.string(forType: .html) {
            return ClipItem(kind: .html, text: text, html: html, rtf: pb.data(forType: .rtf), sourceApp: app)
        }
        if let rtf = pb.data(forType: .rtf) {
            let plain = text ?? NSAttributedString(rtf: rtf, documentAttributes: nil)?.string
            return ClipItem(kind: .richText, text: plain, rtf: rtf, sourceApp: app)
        }
        if let text { return ClipItem(kind: .text, text: text, sourceApp: app) }
        return nil
    }

    /// Puts this item back on the pasteboard.
    public func write(to pb: NSPasteboard = .general) {
        pb.clearContents()
        switch kind {
        case .files:
            pb.writeObjects(files as [NSURL])
        case .image:
            if let image { pb.setData(image, forType: .png) }
            if let text { pb.setString(text, forType: .string) }
        default:
            if let html { pb.setString(html, forType: .html) }
            if let rtf { pb.setData(rtf, forType: .rtf) }
            if let text { pb.setString(text, forType: .string) }
        }
    }
}

/// Watches the general pasteboard and keeps a history. Turned on by modules that need it
/// (Advanced Paste, Command Palette) via `retain(_:)`/`release(_:)`.
@MainActor
@Observable
public final class ClipboardHistory {
    public static let shared = ClipboardHistory()

    public private(set) var items: [ClipItem] = []
    public var limit = 100

    @ObservationIgnored private var users: Set<String> = []
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastChange = NSPasteboard.general.changeCount
    @ObservationIgnored private var listeners: [(ClipItem) -> Void] = []
    @ObservationIgnored private let file = Paths.data(for: "clipboard").appendingPathComponent("history.json")
    /// Set when MacToys writes the pasteboard itself so the write isn't recorded again.
    @ObservationIgnored public var ignoreNextChange = false
    /// Apps whose copies are never recorded (password managers).
    @ObservationIgnored public var excludedBundleIDs: Set<String> = ["com.1password.1password", "com.agilebits.onepassword7",
                                                                     "com.apple.keychainaccess", "com.bitwarden.desktop"]

    private init() {
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([ClipItem].self, from: data) {
            items = saved
        }
    }

    public var isRunning: Bool { timer != nil }

    public func retain(_ user: String) {
        users.insert(user)
        guard timer == nil else { return }
        lastChange = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
            MainActor.assumeIsolated { ClipboardHistory.shared.poll() }
        }
    }

    public func release(_ user: String) {
        users.remove(user)
        if users.isEmpty { timer?.invalidate(); timer = nil }
    }

    public func onNewItem(_ listener: @escaping (ClipItem) -> Void) { listeners.append(listener) }

    public func delete(_ item: ClipItem) { items.removeAll { $0.id == item.id }; save() }
    public func togglePin(_ item: ClipItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i].pinned.toggle(); save()
    }
    public func clear() { items.removeAll { !$0.pinned }; save() }

    /// Writes an item to the pasteboard without recording it again.
    public func restore(_ item: ClipItem) {
        ignoreNextChange = true
        item.write()
        lastChange = NSPasteboard.general.changeCount
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        if ignoreNextChange { ignoreNextChange = false; return }
        if let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, excludedBundleIDs.contains(bid) { return }
        if pb.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) == true { return }
        guard let item = ClipItem.current(from: pb) else { return }
        items.removeAll { !$0.pinned && $0.kind == item.kind && $0.text == item.text && $0.image == item.image }
        items.insert(item, at: 0)
        let unpinned = items.filter { !$0.pinned }
        if unpinned.count > limit, let drop = unpinned.last { items.removeAll { $0.id == drop.id } }
        save()
        for l in listeners { l(item) }
    }

    private func save() {
        let snapshot = items
        let url = file
        Task.detached { try? JSONEncoder().encode(snapshot).write(to: url, options: .atomic) }
    }
}
