import AppKit
import MacToysCore
import Observation
import SwiftUI

/// What a rename field is editing.
enum ShelfRenameTarget: Equatable {
    case item(UUID)
    case shelf
}

/// What a mouse interaction on a shelf acts on.
enum ShelfTarget: Equatable {
    /// The collapsed pile: click expands, drag takes every item.
    case pile
    /// The stack chip in an expanded shelf's header: drag takes every item.
    case all
    case item(UUID)
}

/// Actions the shelf view asks for. Implemented by `ShelfWindowController`; preview scenes have none.
@MainActor
protocol ShelfViewHandler: AnyObject {
    func toggleExpanded()
    func closeShelf()
    func togglePin()
    func setLayout(_ layout: ShelfLayout)
    /// Shows the shelf's action menu below a button (`rect` in the hosting view's coordinates).
    func showShelfMenu(below rect: CGRect)
    func click(_ target: ShelfTarget, event: NSEvent)
    func doubleClick(_ target: ShelfTarget)
    func beginDrag(_ target: ShelfTarget, from view: NSView, event: NSEvent)
    /// The right-click menu; `view` anchors pickers the menu opens (Share).
    func menu(for target: ShelfTarget, in view: NSView) -> NSMenu?
    func hover(_ target: ShelfTarget?)
    func backgroundClicked()
    func commitRename()
    func cancelRename()
}

/// Everything the shelf view shows for one shelf.
@MainActor
@Observable
final class ShelfModel {
    var shelf: Shelf
    var layout: ShelfLayout = .grid
    var selection: Set<UUID> = []
    var isDropTarget = false
    /// Items in the drag hovering over the shelf, when known.
    var dropCount = 0
    var isHovering = false
    var hoveredItem: UUID?
    var renaming: ShelfRenameTarget?
    var renameDraft = ""
    /// A long-running action in progress ("Compressing…").
    var busy: String?
    var thumbnails: [UUID: ShelfThumbnail] = [:]
    @ObservationIgnored weak var handler: ShelfViewHandler?

    init(shelf: Shelf, layout: ShelfLayout = .grid) {
        self.shelf = shelf
        self.layout = layout
    }

    var items: [ShelfItem] { shelf.items }

    /// The selected items, or every item when nothing is selected.
    var actionItems: [ShelfItem] { shelf.items(selection) }

    func thumbnail(for item: ShelfItem) -> ShelfThumbnail {
        thumbnails[item.id] ?? ShelfThumbnailLoader.shared.immediate(for: item)
    }

    /// "Invoices", "IMG_4821.HEIC", "5 items", or "Drop Here" for an empty shelf.
    var title: String {
        if let t = shelf.title, !t.isEmpty { return t }
        switch shelf.items.count {
        case 0: return String(localized: "Drop Here", comment: "Title of an empty shelf")
        case 1: return shelf.items[0].name
        default: return String(localized: "\(shelf.items.count) items", comment: "Shelf title: number of items on it")
        }
    }

    /// Under the title: the total size ("24.3 MB"), the single item's size or kind, the item count for
    /// a named shelf, or what an empty shelf takes.
    var subtitle: String {
        let items = shelf.items
        guard let top = items.last else {
            return String(localized: "Files, text or links", comment: "What can be dropped on an empty shelf")
        }
        let bytes = shelf.totalBytes
        let size = bytes > 0 ? ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) : nil
        if shelf.title?.isEmpty == false {
            guard let size else { return String(localized: "\(items.count) items", comment: "Shelf title: number of items on it") }
            return String(localized: "\(items.count) items · \(size)", comment: "Shelf subtitle: number of items, then their total size")
        }
        if items.count == 1 { return ShelfItemText.short(top) }
        return size ?? top.name
    }
}

/// How items are described on a shelf.
enum ShelfItemText {
    /// The short second line under a grid tile: a size, "Folder", "Text" or the link's host.
    static func short(_ item: ShelfItem) -> String {
        switch item.kind {
        case .text: return String(localized: "Text", comment: "Kind of shelf item: text that was dropped on the shelf")
        case .link: return item.link?.host() ?? String(localized: "Link", comment: "Kind of shelf item: a web link")
        case .file, .image:
            if item.isDirectory { return String(localized: "Folder", comment: "Kind of shelf item") }
            return item.byteSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""
        }
    }

    /// The list row's second line: "PDF document · 2.4 MB", "Text · 312 bytes", the link's address.
    static func detail(_ item: ShelfItem) -> String {
        switch item.kind {
        case .link: return item.link?.absoluteString ?? ""
        case .text:
            let size = ByteCountFormatter.string(fromByteCount: item.byteSize ?? 0, countStyle: .file)
            return String(localized: "Text · \(size)", comment: "Shelf item details: dropped text, then its size")
        case .file, .image:
            if item.isDirectory { return String(localized: "Folder", comment: "Kind of shelf item") }
            let kind = item.utType?.localizedDescription ?? ""
            guard let bytes = item.byteSize else { return kind }
            let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            return kind.isEmpty ? size : String(localized: "\(kind) · \(size)", comment: "Shelf item details: kind of file, then its size")
        }
    }
}

// MARK: - AppKit bridges

/// A transparent view over a pile, chip or item that turns mouse input into shelf actions:
/// click, double-click, drag (starting a drag-and-drop session), right-click menu, hover.
struct ShelfInteraction: NSViewRepresentable {
    let target: ShelfTarget
    let handler: ShelfViewHandler?

    func makeNSView(context: Context) -> ShelfInteractionView {
        let view = ShelfInteractionView()
        view.target = target
        view.handler = handler
        return view
    }

    func updateNSView(_ view: ShelfInteractionView, context: Context) {
        view.target = target
        view.handler = handler
    }
}

final class ShelfInteractionView: NSView {
    var target: ShelfTarget = .pile
    weak var handler: ShelfViewHandler?
    private var downEvent: NSEvent?
    private var dragging = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { handler?.hover(target) }
    override func mouseExited(with event: NSEvent) { handler?.hover(nil) }

    override func mouseDown(with event: NSEvent) {
        downEvent = event
        dragging = false
        if event.clickCount == 2 { handler?.doubleClick(target) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragging, let down = downEvent else { return }
        let a = down.locationInWindow, b = event.locationInWindow
        guard hypot(b.x - a.x, b.y - a.y) > 3 else { return }
        dragging = true
        handler?.beginDrag(target, from: self, event: down)
    }

    override func mouseUp(with event: NSEvent) {
        defer { downEvent = nil; dragging = false }
        guard !dragging, let down = downEvent, down.clickCount < 2 else { return }
        handler?.click(target, event: down)
    }

    override func menu(for event: NSEvent) -> NSMenu? { handler?.menu(for: target, in: self) }
}

/// The shelf's background: drag to move the panel, double-click to expand or collapse,
/// click to clear the selection, right-click for the shelf menu.
struct ShelfWindowDragArea: NSViewRepresentable {
    let handler: ShelfViewHandler?

    func makeNSView(context: Context) -> ShelfWindowDragView {
        let view = ShelfWindowDragView()
        view.handler = handler
        return view
    }

    func updateNSView(_ view: ShelfWindowDragView, context: Context) { view.handler = handler }
}

final class ShelfWindowDragView: NSView {
    weak var handler: ShelfViewHandler?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            handler?.toggleExpanded()
            return
        }
        guard let window else { return }
        let before = window.frame.origin
        window.performDrag(with: event)
        if window.frame.origin == before { handler?.backgroundClicked() }
    }

    override func menu(for event: NSEvent) -> NSMenu? { handler?.menu(for: .all, in: self) }
}

/// Hosts the SwiftUI shelf; clicks work on the first try even while another app is active.
final class ShelfHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
