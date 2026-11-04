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
    /// Bundle identifier of the app it was copied from (newer entries only), for its icon and filters.
    public var sourceBundleID: String?
    /// A name the user gave the entry (Clipboard History's rename).
    public var name: String?

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
        let source = sourceApplication(of: pb)
        let app = source?.localizedName
        let bid = source?.bundleIdentifier
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return ClipItem(kind: .files, text: urls.map(\.path).joined(separator: "\n"), files: urls, sourceApp: app, sourceBundleID: bid)
        }
        if let img = NSImage(pasteboard: pb), pb.availableType(from: [.png, .tiff]) != nil,
           let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return ClipItem(kind: .image, text: pb.string(forType: .string), image: png, sourceApp: app, sourceBundleID: bid)
        }
        let text = pb.string(forType: .string)
        if let html = pb.string(forType: .html) {
            return ClipItem(kind: .html, text: text, html: html, rtf: pb.data(forType: .rtf), sourceApp: app, sourceBundleID: bid)
        }
        if let rtf = pb.data(forType: .rtf) {
            let plain = text ?? NSAttributedString(rtf: rtf, documentAttributes: nil)?.string
            return ClipItem(kind: .richText, text: plain, rtf: rtf, sourceApp: app, sourceBundleID: bid)
        }
        if let text { return ClipItem(kind: .text, text: text, sourceApp: app, sourceBundleID: bid) }
        // A color from a color well or picker, without a text version: keep it as its hex value.
        if pb.availableType(from: [.color]) != nil, let color = NSColor(from: pb) {
            return ClipItem(kind: .text, text: RGBA(color).hex, sourceApp: app, sourceBundleID: bid)
        }
        return nil
    }

    /// The app that put the content on a pasteboard: the one named by the `org.nspasteboard.source`
    /// marker when the writer set it, otherwise the frontmost app.
    public static func sourceApplication(of pb: NSPasteboard) -> NSRunningApplication? {
        if let bid = pb.string(forType: NSPasteboard.PasteboardType("org.nspasteboard.source")), !bid.isEmpty,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first {
            return app
        }
        return NSWorkspace.shared.frontmostApplication
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
    /// Unpinned entries kept. New copies push out the oldest one; `prune()` applies a lowered limit at once.
    public var limit = 100
    /// Unpinned entries older than this are dropped (nil keeps them until the limit pushes them out).
    @ObservationIgnored public var maxAge: TimeInterval?
    /// While true, copies are not recorded (the pasteboard is still watched so nothing is picked up on resume).
    public var isPaused = false

    @ObservationIgnored private var users: Set<String> = []
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastChange = NSPasteboard.general.changeCount
    @ObservationIgnored private var listeners: [(ClipItem) -> Void] = []
    @ObservationIgnored private let file = Paths.data(for: "clipboard").appendingPathComponent("history.json")
    @ObservationIgnored private let imageDirectory = Paths.data(for: "clipboard").appendingPathComponent("Images", isDirectory: true)
    /// Saves run one after another, so an older snapshot never removes a newer entry's image file.
    private static let saveQueue = DispatchQueue(label: "com.w33d.mactoys.clipboard-history", qos: .utility)
    /// Set when MacToys writes the pasteboard itself so the write isn't recorded again.
    @ObservationIgnored public var ignoreNextChange = false
    /// Apps whose copies are never recorded (password managers).
    @ObservationIgnored public var excludedBundleIDs: Set<String> = ["com.1password.1password", "com.agilebits.onepassword7",
                                                                     "com.apple.keychainaccess", "com.bitwarden.desktop"]
    /// More apps whose copies are never recorded: app names or bundle identifiers (see `[String].matches(app:)`).
    @ObservationIgnored public var excludedApps: [String] = []

    /// Pasteboard types that mark content as private or temporary (nspasteboard.org conventions and their
    /// older equivalents): passwords from password managers, one-time codes, generated intermediate copies.
    nonisolated public static let privateTypes: Set<String> = [
        "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType",
        "de.petermaurer.TransientPasteboardType", "com.typeit4me.clipping", "Pasteboard generator type",
        "com.agilebits.onepassword",
    ]

    /// Whether content with these pasteboard types must not be recorded.
    nonisolated public static func isPrivate(_ types: [NSPasteboard.PasteboardType]) -> Bool {
        types.contains { privateTypes.contains($0.rawValue) }
    }

    /// `items` (newest first) without unpinned entries beyond `limit` or older than `maxAge`.
    nonisolated public static func pruned(_ items: [ClipItem], limit: Int, maxAge: TimeInterval?, now: Date = Date()) -> [ClipItem] {
        var kept = 0
        return items.filter { item in
            if item.pinned { return true }
            if let maxAge, now.timeIntervalSince(item.date) > maxAge { return false }
            kept += 1
            return kept <= limit
        }
    }

    private init() {
        items = ClipboardStore.load(from: file, images: imageDirectory)
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
    public func delete(ids: Set<UUID>) {
        guard items.contains(where: { ids.contains($0.id) }) else { return }
        items.removeAll { ids.contains($0.id) }
        save()
    }

    /// Replaces the entry with the same id (an edited or renamed entry).
    public func update(_ item: ClipItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }), items[i] != item else { return }
        items[i] = item
        save()
    }

    /// Puts an entry at the top without treating it as a new copy (a merged entry, or one pasted again).
    public func add(_ item: ClipItem) {
        items.removeAll { $0.id == item.id }
        insertAtTop(item)
    }

    /// Applies `limit` and `maxAge` to the whole history now.
    public func prune() {
        let kept = Self.pruned(items, limit: limit, maxAge: maxAge)
        guard kept.count != items.count else { return }
        items = kept
        save()
    }

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
        if isPaused { return }
        if Self.isPrivate(pb.types ?? []) { return }
        let source = ClipItem.sourceApplication(of: pb)
        if let bid = source?.bundleIdentifier, excludedBundleIDs.contains(bid) { return }
        if excludedApps.matches(app: source) { return }
        guard var item = ClipItem.current(from: pb) else { return }
        let isDuplicate = { (old: ClipItem) in !old.pinned && old.kind == item.kind && old.text == item.text && old.image == item.image }
        // Copying a renamed entry again keeps its name.
        if item.name == nil { item.name = items.first(where: isDuplicate)?.name }
        items.removeAll(where: isDuplicate)
        insertAtTop(item)
        for l in listeners { l(item) }
    }

    private func insertAtTop(_ item: ClipItem) {
        items.insert(item, at: 0)
        let unpinned = items.filter { !$0.pinned }
        if unpinned.count > limit, let drop = unpinned.last { items.removeAll { $0.id == drop.id } }
        if maxAge != nil { items = Self.pruned(items, limit: .max, maxAge: maxAge) }
        save()
    }

    private func save() {
        let snapshot = items
        let url = file
        let images = imageDirectory
        Self.saveQueue.async { ClipboardStore.save(snapshot, to: url, images: images) }
    }
}
