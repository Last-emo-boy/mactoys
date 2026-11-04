import AppKit
import MacToysCore
import Quartz
import SwiftUI

/// One shelf on screen: its panel, its items, and everything you can do with them — drag in,
/// drag out, select, Quick Look, the action menus and the keyboard.
@MainActor
final class ShelfWindowController: NSObject, NSWindowDelegate, NSDraggingSource, ShelfViewHandler {
    let model: ShelfModel
    let panel: ShelfPanel
    private let container: ShelfContainerView
    private let hosting: ShelfHostingView<ShelfView>
    unowned let manager: ShelfManager
    private let log = Log.for("shelf")

    /// When the user last used this shelf; "Add to Shelf" goes to the most recent one.
    private(set) var lastActive = Date()
    /// The items of the drag going out right now.
    private(set) var outgoing: [ShelfItem] = []
    private var outgoingIsEverything = false
    /// Set by another shelf that took the outgoing items.
    var outgoingLandedOnShelf = false
    private var selectionAnchor: UUID?
    private var lastToggle = Date.distantPast
    private var quickLookURLs: [URL] = []
    private var appBeforeQuickLook: NSRunningApplication?
    private var pendingPromises = 0
    private var thumbnailTask: Task<Void, Never>?

    var id: UUID { model.shelf.id }

    init(shelf: Shelf, manager: ShelfManager) {
        self.manager = manager
        model = ShelfModel(shelf: shelf, layout: manager.settings.value.layout)
        let frame = CGRect(origin: .zero, size: ShelfGeometry.size(expanded: shelf.expanded, itemCount: shelf.items.count,
                                                                  layout: manager.settings.value.layout))
        panel = ShelfPanel(frame: frame)
        container = ShelfContainerView(frame: CGRect(origin: .zero, size: frame.size))
        hosting = ShelfHostingView(rootView: ShelfView(model: model))
        super.init()
        hosting.sizingOptions = []
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        container.controller = self
        panel.contentView = container
        panel.controller = self
        panel.delegate = self
        model.handler = self
        applySettings()
        loadThumbnails(for: shelf.items)
    }

    /// The shelf as it should be saved: items plus where the panel is.
    var snapshot: Shelf {
        var s = model.shelf
        s.frame = panel.frame
        return s
    }

    // MARK: Showing

    func present(at frame: CGRect, animated: Bool) {
        panel.setFrame(frame, display: false)
        updateFrame(animated: false)
        panel.alphaValue = animated && !reduceMotion ? 0 : 1
        panel.orderFrontRegardless()
        if animated && !reduceMotion {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                panel.animator().alphaValue = 1
            }
        }
    }

    /// Takes the panel off screen (the manager decides whether the shelf is remembered).
    func dismiss(animated: Bool) {
        thumbnailTask?.cancel()
        endQuickLookIfOurs()
        let panel = self.panel
        guard animated, !reduceMotion, panel.isVisible else {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.16
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    func applySettings() {
        let s = manager.settings.value
        panel.collectionBehavior = s.showOnAllSpaces
            ? [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            : [.managed, .fullScreenAuxiliary, .ignoresCycle]
        if model.layout != s.layout {
            model.layout = s.layout
            updateFrame(animated: true)
        }
    }

    /// Moves an empty shelf to a new spot (a shake while one is already waiting).
    func move(to frame: CGRect) {
        panel.setFrame(frame, display: true, animate: !reduceMotion && panel.isVisible)
        panel.orderFrontRegardless()
        changed()
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Resizes the panel for the current state, keeping its top edge and center.
    private func updateFrame(animated: Bool) {
        let size = ShelfGeometry.size(expanded: model.shelf.expanded, itemCount: model.items.count, layout: model.layout)
        let visible = (panel.screen ?? NSScreen.underMouse ?? NSScreen.main)?.visibleFrame ?? panel.frame
        let target = ShelfGeometry.resized(panel.frame, to: size, within: visible)
        guard target != panel.frame else { return }
        if animated, !reduceMotion, panel.isVisible {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setFrame(target, display: true)
        }
    }

    private func changed() {
        lastActive = Date()
        manager.shelfChanged()
    }

    func windowDidMove(_ notification: Notification) {
        manager.shelfChanged()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        updateFrame(animated: false)
    }

    // MARK: Items

    /// Adds drops (from a drag, a paste, a URL action): clippings are saved first.
    func add(_ drops: [ShelfDrop]) {
        var items: [ShelfItem] = []
        for drop in drops {
            do { items.append(try manager.store.item(for: drop)) } catch {
                log.error("Could not keep a dropped item: \(error.localizedDescription, privacy: .public)")
            }
        }
        if items.count < drops.count { HUD.show("Some items couldn’t be added to the shelf", symbol: "exclamationmark.triangle") }
        add(items)
    }

    func add(_ items: [ShelfItem]) {
        let added = model.shelf.add(items)
        guard !added.isEmpty else { return }
        loadThumbnails(for: added)
        updateFrame(animated: true)
        changed()
    }

    func remove(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        model.shelf.remove(ids)
        model.selection.subtract(ids)
        if model.hoveredItem.map(ids.contains) == true { model.hoveredItem = nil }
        if model.shelf.isEmpty, manager.settings.value.closeWhenEmptied, !model.shelf.pinned {
            manager.close(self, remember: false)
            return
        }
        updateFrame(animated: true)
        changed()
    }

    private func replace(_ item: ShelfItem) {
        guard let i = model.shelf.items.firstIndex(where: { $0.id == item.id }) else { return }
        model.shelf.items[i] = item
        model.thumbnails[item.id] = nil
        loadThumbnails(for: [item])
        changed()
    }

    /// Finds files that moved (dragged into a folder) and drops items whose files are gone.
    func refreshLocations() {
        var gone: Set<UUID> = []
        for item in model.shelf.items {
            guard let url = ShelfPersistence.locate(item) else { gone.insert(item.id); continue }
            if url.standardizedFileURL != item.url.standardizedFileURL {
                var moved = item
                moved.url = url.standardizedFileURL
                if !item.owned { moved.name = url.lastPathComponent }
                moved.bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
                replace(moved)
            }
        }
        remove(gone)
    }

    private func loadThumbnails(for items: [ShelfItem]) {
        let files = items.filter { $0.kind == .file || $0.kind == .image }
        guard !files.isEmpty else { return }
        let previous = thumbnailTask
        thumbnailTask = Task { [weak self] in
            await previous?.value
            for item in files {
                guard !Task.isCancelled else { return }
                let thumb = await ShelfThumbnailLoader.shared.load(item)
                self?.model.thumbnails[item.id] = thumb
            }
        }
    }

    // MARK: ShelfViewHandler

    func toggleExpanded() {
        // A double-click on the pile would otherwise expand and collapse again.
        guard Date().timeIntervalSince(lastToggle) > 0.35 else { return }
        lastToggle = Date()
        model.renaming = nil
        model.shelf.expanded.toggle()
        if model.shelf.expanded { refreshLocations() }
        updateFrame(animated: true)
        changed()
    }

    func closeShelf() {
        manager.close(self, remember: true)
    }

    func togglePin() {
        model.shelf.pinned.toggle()
        changed()
    }

    func setLayout(_ layout: ShelfLayout) {
        manager.settings.value.layout = layout
    }

    func showShelfMenu(below rect: CGRect) {
        let menu = shelfMenu(anchor: hosting)
        let point = rect == .zero ? hosting.convert(panel.mouseLocationOutsideOfEventStream, from: nil)
            : CGPoint(x: rect.minX, y: rect.maxY + 4)
        menu.popUp(positioning: nil, at: point, in: hosting)
    }

    func click(_ target: ShelfTarget, event: NSEvent) {
        panel.makeKey()
        lastActive = Date()
        switch target {
        case .pile:
            toggleExpanded()
        case .all:
            break
        case .item(let id):
            let flags = event.modifierFlags
            if flags.contains(.command) {
                if model.selection.contains(id) { model.selection.remove(id) } else { model.selection.insert(id) }
                selectionAnchor = id
            } else if flags.contains(.shift), let anchor = selectionAnchor,
                      let a = model.items.firstIndex(where: { $0.id == anchor }),
                      let b = model.items.firstIndex(where: { $0.id == id }) {
                model.selection = Set(model.items[min(a, b)...max(a, b)].map(\.id))
            } else {
                model.selection = [id]
                selectionAnchor = id
            }
            if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { refreshQuickLook() }
        }
    }

    func doubleClick(_ target: ShelfTarget) {
        guard case .item(let id) = target, let item = model.items.first(where: { $0.id == id }) else { return }
        open([item])
    }

    func backgroundClicked() {
        panel.makeKey()
        model.selection = []
        if model.renaming != nil { commitRename() }
    }

    func hover(_ target: ShelfTarget?) {
        if case .item(let id)? = target { model.hoveredItem = id } else { model.hoveredItem = nil }
    }

    func setHovering(_ on: Bool) {
        model.isHovering = on
        if !on { model.hoveredItem = nil }
    }

    func menu(for target: ShelfTarget, in view: NSView) -> NSMenu? {
        switch target {
        case .pile, .all:
            return shelfMenu(anchor: view)
        case .item(let id):
            if !model.selection.contains(id) {
                model.selection = [id]
                selectionAnchor = id
            }
            return itemMenu(for: model.actionItems, anchor: view)
        }
    }

    func commitRename() {
        guard let target = model.renaming else { return }
        let draft = model.renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        model.renaming = nil
        switch target {
        case .shelf:
            model.shelf.title = draft.isEmpty ? nil : draft
            changed()
        case .item(let id):
            guard let item = model.items.first(where: { $0.id == id }), item.owned, !draft.isEmpty, draft != item.name else { return }
            do {
                replace(try manager.store.rename(item, to: draft))
            } catch {
                presentError(String(localized: "Couldn’t rename “\(item.name)”", comment: "Alert title; the placeholder is a file name"), error)
            }
        }
    }

    func cancelRename() {
        model.renaming = nil
    }

    func beginRename(_ target: ShelfRenameTarget) {
        panel.makeKey()
        switch target {
        case .shelf:
            if !model.shelf.expanded { toggleExpanded() }
            model.renameDraft = model.shelf.title ?? ""
        case .item(let id):
            guard let item = model.items.first(where: { $0.id == id }) else { return }
            if !model.shelf.expanded { toggleExpanded() }
            model.renameDraft = item.name
        }
        model.renaming = target
    }

    // MARK: Keyboard

    func handleKeyDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control])
        guard flags.isEmpty else { return false }
        switch Int(event.keyCode) {
        case 49: quickLook(); return true                         // Space
        case 51, 117: removeSelectionOrNothing(); return true    // Delete, Forward Delete
        case 36, 76: if !model.selection.isEmpty { open(model.actionItems) }; return true  // Return, Enter
        case 123: moveSelection(-1); return true                  // ←
        case 124: moveSelection(1); return true                   // →
        case 125: moveSelection(model.layout == .grid ? ShelfGeometry.gridColumns : 1); return true  // ↓
        case 126: moveSelection(model.layout == .grid ? -ShelfGeometry.gridColumns : -1); return true // ↑
        default: return false
        }
    }

    func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .option, .control]) == .command,
              let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        switch key {
        case "a": model.selection = Set(model.items.map(\.id))
        case "c": copy(model.actionItems)
        case "v": paste()
        case "w": closeShelf()
        case "o": open(model.actionItems)
        case "y": quickLook()
        default: return false
        }
        return true
    }

    func escape() {
        if model.renaming != nil { cancelRename() }
        else if !model.selection.isEmpty { model.selection = [] }
        else if model.shelf.expanded { toggleExpanded() }
    }

    private func removeSelectionOrNothing() {
        // ⌫ never empties the whole shelf by accident: it removes the selection only.
        remove(model.selection)
    }

    private func moveSelection(_ delta: Int) {
        let items = model.items
        guard !items.isEmpty else { return }
        if !model.shelf.expanded { toggleExpanded() }
        let current = items.lastIndex { model.selection.contains($0.id) }
        let next = current.map { min(max($0 + delta, 0), items.count - 1) } ?? (delta > 0 ? 0 : items.count - 1)
        model.selection = [items[next].id]
        selectionAnchor = items[next].id
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { refreshQuickLook() }
    }

    // MARK: Drag out

    func beginDrag(_ target: ShelfTarget, from view: NSView, event: NSEvent) {
        let items: [ShelfItem]
        switch target {
        case .pile, .all:
            items = model.items
            outgoingIsEverything = true
        case .item(let id):
            if !model.selection.contains(id) {
                model.selection = [id]
                selectionAnchor = id
            }
            items = model.actionItems
            outgoingIsEverything = items.count == model.items.count
        }
        guard !items.isEmpty else { return }
        outgoing = items
        outgoingLandedOnShelf = false
        let origin = view.convert(event.locationInWindow, from: nil)
        let side: CGFloat = items.count > 1 ? 56 : 64
        let dragging = items.prefix(24).enumerated().map { index, item in
            let d = NSDraggingItem(pasteboardWriter: ShelfPasteboardWriter.dragWriter(for: item))
            let offset = CGFloat(min(index, 4)) * 5
            d.setDraggingFrame(CGRect(x: origin.x - side / 2 + offset, y: origin.y - side / 2 - offset, width: side, height: side),
                               contents: dragImage(for: item, side: side))
            return d
        }
        // Items past the first 24 still travel; they just don't get their own image.
        let rest = items.dropFirst(24).map { item in
            let d = NSDraggingItem(pasteboardWriter: ShelfPasteboardWriter.dragWriter(for: item))
            d.setDraggingFrame(CGRect(x: origin.x - side / 2, y: origin.y - side / 2, width: side, height: side), contents: nil)
            return d
        }
        let session = view.beginDraggingSession(with: dragging + rest, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .pile
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        if context == .withinApplication { return [.move, .copy, .generic] }
        return manager.settings.value.alwaysCopyOnDragOut ? [.copy] : [.copy, .move, .link, .generic, .delete]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        let items = outgoing
        let everything = outgoingIsEverything
        let landedOnShelf = outgoingLandedOnShelf
        outgoing = []
        outgoingIsEverything = false
        outgoingLandedOnShelf = false
        guard !operation.isEmpty, !items.isEmpty else { return }
        let ids = Set(items.map(\.id))
        if landedOnShelf || operation.contains(.delete) {
            // Moved to another shelf, or dropped on the Trash.
            remove(ids)
            return
        }
        let keepOpen = NSEvent.modifierFlags.contains(.shift) || model.shelf.pinned
        if everything, manager.settings.value.closeAfterDragOut, !keepOpen {
            manager.close(self, remember: true)
            return
        }
        // A Finder drop may have moved the files: follow them once the move is done.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.refreshLocations() }
    }

    /// A picture of the item for drags: the same card or thumbnail the shelf shows.
    private func dragImage(for item: ShelfItem, side: CGFloat) -> NSImage {
        let renderer = ImageRenderer(content: ShelfItemThumb(item: item, thumbnail: model.thumbnail(for: item), side: side)
            .frame(width: side, height: side))
        renderer.scale = panel.backingScaleFactor
        return renderer.nsImage ?? model.thumbnail(for: item).image
    }

    // MARK: Drop in

    /// Called for every pointer move over the shelf during a drag: only real changes reach the view.
    func dragUpdated(_ info: NSDraggingInfo) -> NSDragOperation {
        let op = dropOperation(info)
        let count = op.isEmpty ? 0 : info.numberOfValidItemsForDrop
        if model.isDropTarget == op.isEmpty { model.isDropTarget = !op.isEmpty }
        if model.dropCount != count { model.dropCount = count }
        return op
    }

    func dragEnded() {
        if model.isDropTarget { model.isDropTarget = false }
        if model.dropCount != 0 { model.dropCount = 0 }
    }

    private func dropOperation(_ info: NSDraggingInfo) -> NSDragOperation {
        if let source = info.draggingSource as? ShelfWindowController {
            return source === self ? [] : .move
        }
        let mask = info.draggingSourceOperationMask
        // Never accept a move from another app: the shelf keeps references, it doesn't take things away.
        for op in [NSDragOperation.copy, .generic, .link] where mask.contains(op) { return op }
        return []
    }

    func performDrop(_ info: NSDraggingInfo) -> Bool {
        defer { dragEnded() }
        lastActive = Date()
        if let source = info.draggingSource as? ShelfWindowController {
            guard source !== self else { return false }
            add(source.outgoing)
            source.outgoingLandedOnShelf = true
            return true
        }
        let pb = info.draggingPasteboard
        let hasFileURLs = pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        if !hasFileURLs, let receivers = pb.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver],
           !receivers.isEmpty {
            receive(receivers)
            return true
        }
        let drops = ShelfPasteboardReader.drops(from: pb)
        guard !drops.isEmpty else { return false }
        add(drops)
        return true
    }

    /// Files promised by the drag source (Mail attachments, Photos, images from a browser) are
    /// written into the clippings store, then added.
    private func receive(_ receivers: [NSFilePromiseReceiver]) {
        pendingPromises += receivers.count
        model.busy = String(localized: "Receiving…", comment: "Shelf status while files dragged from another app are written")
        for receiver in receivers {
            let folder: URL
            do { folder = try manager.store.makeFolder() } catch {
                log.error("No folder for received files: \(error.localizedDescription, privacy: .public)")
                promiseFinished(nil)
                continue
            }
            receiver.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: ShelfWindowController.promiseQueue) { [weak self] url, error in
                let received: URL? = error == nil ? url : nil
                if let error { Log.for("shelf").error("Promised file failed: \(error.localizedDescription, privacy: .public)") }
                Task { @MainActor in self?.promiseFinished(received) }
            }
        }
    }

    private func promiseFinished(_ url: URL?) {
        if let url { add([ShelfItem.file(url, owned: true)]) }
        pendingPromises = max(0, pendingPromises - 1)
        if pendingPromises == 0 { model.busy = nil }
    }

    private static let promiseQueue: OperationQueue = {
        let q = OperationQueue()
        q.qualityOfService = .userInitiated
        q.name = "shelf.receive"
        return q
    }()

    // MARK: Actions

    func open(_ items: [ShelfItem]) {
        for item in items {
            NSWorkspace.shared.open(item.kind == .link ? (item.link ?? item.url) : item.url)
        }
    }

    func open(_ items: [ShelfItem], with app: URL) {
        let urls = items.map { $0.kind == .link ? ($0.link ?? $0.url) : $0.url }
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { Log.for("shelf").error("Open with failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    func reveal(_ items: [ShelfItem]) {
        let urls = items.filter(\.isUserFile).map(\.url)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func copy(_ items: [ShelfItem]) {
        guard !items.isEmpty else { return }
        ShelfPasteboardWriter.copy(items)
    }

    func copyPaths(_ items: [ShelfItem]) {
        let lines = items.map { $0.kind == .link ? ($0.link?.absoluteString ?? "") : $0.url.path }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    func paste() {
        let drops = ShelfPasteboardReader.drops(from: .general)
        guard !drops.isEmpty else {
            HUD.show("Nothing on the clipboard to add", symbol: "doc.on.clipboard")
            return
        }
        add(drops)
    }

    func share(_ items: [ShelfItem], anchor: NSView) {
        let shareable: [Any] = items.map { item -> Any in
            switch item.kind {
            case .link: item.link ?? item.url
            case .text: (try? String(contentsOf: item.url, encoding: .utf8)) ?? item.url
            case .file, .image: item.url
            }
        }
        guard !shareable.isEmpty else { return }
        let picker = NSSharingServicePicker(items: shareable)
        picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    func compress(_ items: [ShelfItem]) {
        guard !items.isEmpty, model.busy == nil else { return }
        let urls = items.map(\.url)
        let destination: (URL, owned: Bool)
        do { destination = try ShelfFileOps.archiveFolder(for: items, store: manager.store) } catch {
            presentError(String(localized: "Couldn’t compress the items", comment: "Alert title"), error)
            return
        }
        model.busy = String(localized: "Compressing…", comment: "Shelf status while making a ZIP archive")
        let archiveWord = String(localized: "Archive", comment: "File name of a ZIP made from several items, as in Finder: Archive.zip")
        Task { [weak self] in
            do {
                let zip = try await ShelfFileOps.compress(urls, into: destination.0, archiveWord: archiveWord)
                guard let self else { return }
                self.model.busy = nil
                let item = ShelfItem.file(zip, owned: destination.owned)
                self.add([item])
                self.model.selection = [item.id]
            } catch {
                self?.model.busy = nil
                self?.presentError(String(localized: "Couldn’t compress the items", comment: "Alert title"), error)
            }
        }
    }

    /// Asks for a folder, then moves files there (clippings are saved there as files).
    func moveToFolder(_ items: [ShelfItem]) {
        guard !items.isEmpty else { return }
        let open = NSOpenPanel()
        open.canChooseFiles = false
        open.canChooseDirectories = true
        open.canCreateDirectories = true
        open.allowsMultipleSelection = false
        let savesClippings = items.allSatisfy(\.owned)
        open.prompt = savesClippings ? String(localized: "Save", comment: "Folder picker button: save clippings into the folder")
            : String(localized: "Move", comment: "Folder picker button: move the files into the folder")
        open.message = savesClippings
            ? String(localized: "Choose a folder to save \(items.count) items in.", comment: "Folder picker message")
            : String(localized: "Choose a folder to move \(items.count) items to.", comment: "Folder picker message")
        NSApp.activate()
        open.begin { [weak self] response in
            guard response == .OK, let folder = open.url else { return }
            MainActor.assumeIsolated { self?.move(items, into: folder) }
        }
    }

    private func move(_ items: [ShelfItem], into folder: URL) {
        var failures: [String] = []
        for item in items {
            do {
                let target = try ShelfFileOps.move(item.url, into: folder)
                var moved = ShelfItem.file(target)
                moved.id = item.id
                moved.added = item.added
                replace(moved)
            } catch {
                log.error("Move failed: \(error.localizedDescription, privacy: .public)")
                failures.append(item.name)
            }
        }
        if !failures.isEmpty {
            let names = failures.formatted(.list(type: .and))
            presentError(String(localized: "Couldn’t move \(names)", comment: "Alert title; the placeholder lists file names"), nil)
        }
    }

    func clear() {
        remove(Set(model.items.map(\.id)))
    }

    private func presentError(_ title: String, _ error: Error?) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error?.localizedDescription ?? String(localized: "The files may have been moved, or the folder can’t be written to.")
        alert.alertStyle = .warning
        NSApp.activate()
        alert.runModal()
    }

    // MARK: Quick Look

    var hasQuickLookItems: Bool { !quickLookURLs.isEmpty || !model.items.isEmpty }

    func quickLook() {
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().orderOut(nil)
            return
        }
        quickLookURLs = model.actionItems.map(\.url)
        guard !quickLookURLs.isEmpty else { return }
        if let front = NSWorkspace.shared.frontmostApplication, front != NSRunningApplication.current { appBeforeQuickLook = front }
        NSApp.activate()
        panel.makeKey()
        QLPreviewPanel.shared().makeKeyAndOrderFront(nil)
    }

    private func refreshQuickLook() {
        quickLookURLs = model.actionItems.map(\.url)
        QLPreviewPanel.shared().reloadData()
    }

    func beginQuickLook(_ ql: QLPreviewPanel) {
        if quickLookURLs.isEmpty { quickLookURLs = model.actionItems.map(\.url) }
        ql.dataSource = self
        ql.delegate = self
        ql.reloadData()
    }

    func endQuickLook(_ ql: QLPreviewPanel) {
        ql.dataSource = nil
        ql.delegate = nil
        quickLookURLs = []
        // Give the keyboard back to the app you were in.
        if let app = appBeforeQuickLook, !app.isTerminated, NSApp.isActive,
           !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
            app.activate()
        }
        appBeforeQuickLook = nil
    }

    private func endQuickLookIfOurs() {
        guard QLPreviewPanel.sharedPreviewPanelExists() else { return }
        let ql = QLPreviewPanel.shared()
        if ql?.dataSource === self, ql?.isVisible == true { ql?.orderOut(nil) }
    }
}

extension ShelfWindowController: @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { quickLookURLs.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        quickLookURLs.indices.contains(index) ? quickLookURLs[index] as NSURL : nil
    }
}
