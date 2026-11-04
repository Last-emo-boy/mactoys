import AppKit
import MacToysCore
import Observation

/// Owns every open shelf and the recent ones: opening, closing, reopening, saving and restoring.
@MainActor
@Observable
final class ShelfManager {
    private(set) var shelves: [ShelfWindowController] = []
    private(set) var recent: [Shelf] = []

    @ObservationIgnored let settings: Persisted<ShelfSettings>
    @ObservationIgnored let store: ClippingStore
    @ObservationIgnored private let archiveURL: URL
    /// Shelves put away by `stop()`, shown again by the next `start()` in this session.
    @ObservationIgnored private var suspended: [Shelf]?
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    @ObservationIgnored private(set) var isRunning = false

    init(settings: Persisted<ShelfSettings>, store: ClippingStore = .standard, archiveURL: URL = ShelfPersistence.standardURL) {
        self.settings = settings
        self.store = store
        self.archiveURL = archiveURL
    }

    var itemCount: Int { shelves.reduce(0) { $0 + $1.model.items.count } }

    // MARK: Lifecycle

    /// Shows the shelves from before: those put away by `stop()`, or at launch the saved ones
    /// (unpinned ones only when "keep across restarts" is on), leaving out files that are gone.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        var open: [Shelf]
        if let suspended {
            open = suspended
            self.suspended = nil
        } else if !loaded {
            let archive = ShelfPersistence.load(from: archiveURL)
            recent = archive.recent.compactMap { ShelfPersistence.restore($0) }
            open = settings.value.keepAcrossRestarts ? archive.open : archive.open.filter(\.pinned)
        } else {
            open = []
        }
        loaded = true
        for shelf in open {
            guard let restored = ShelfPersistence.restore(shelf) else { continue }
            show(restored, frame: restoredFrame(restored), animated: false)
        }
        collectGarbage()
    }

    /// Saves and takes every shelf off screen.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        suspended = shelves.map(\.snapshot)
        saveWork?.cancel()
        saveNow()
        for c in shelves { c.dismiss(animated: false) }
        shelves = []
    }

    func applySettings() {
        for c in shelves { c.applySettings() }
        scheduleSave()
    }

    // MARK: Opening

    /// A new shelf where the settings say (near `pointer`, or the pointer now), with `drops` on it.
    @discardableResult
    func newShelf(with drops: [ShelfDrop] = [], items: [ShelfItem] = [], at pointer: CGPoint? = nil) -> ShelfWindowController {
        let p = pointer ?? NSEvent.mouseLocation
        let controller = show(Shelf(), frame: newFrame(at: p), animated: true)
        controller.add(drops)
        controller.add(items)
        return controller
    }

    /// The pointer was shaken during a drag: an empty shelf comes to it, or a new one opens.
    func shakeDetected(at pointer: CGPoint) {
        if let waiting = shelves.last(where: { $0.model.shelf.isEmpty && !$0.model.shelf.pinned }) {
            let others = shelves.filter { $0 !== waiting }.map(\.panel.frame)
            waiting.move(to: ShelfGeometry.newFrame(size: waiting.panel.frame.size, placement: settings.value.placement,
                                                    pointer: pointer, visible: visibleFrame(at: pointer), occupied: others))
            return
        }
        newShelf(at: pointer)
    }

    /// Adds to the shelf used last ("Add to Shelf"), or to a new one.
    func addToCurrentShelf(_ drops: [ShelfDrop]) {
        guard let current = shelves.max(by: { $0.lastActive < $1.lastActive }) else {
            newShelf(with: drops)
            return
        }
        current.add(drops)
        current.panel.orderFrontRegardless()
    }

    /// A new shelf with what's on the clipboard.
    func newShelfFromClipboard() {
        let drops = ShelfPasteboardReader.drops(from: .general)
        guard !drops.isEmpty else {
            HUD.show("The clipboard is empty", symbol: "doc.on.clipboard")
            return
        }
        newShelf(with: drops)
    }

    /// Opens a recently closed shelf again (the most recent when `id` is nil).
    func reopen(_ id: UUID? = nil) {
        guard let index = id.map({ id in recent.firstIndex { $0.id == id } }) ?? (recent.isEmpty ? nil : 0) else {
            HUD.show("No recently closed shelves", symbol: "clock.arrow.circlepath")
            return
        }
        let shelf = recent.remove(at: index)
        guard var restored = ShelfPersistence.restore(shelf) else {
            HUD.show("The items on that shelf no longer exist", symbol: "questionmark.folder")
            scheduleSave()
            return
        }
        restored.closed = nil
        show(restored, frame: restoredFrame(restored), animated: true)
        scheduleSave()
    }

    func clearRecent() {
        recent = []
        scheduleSave()
    }

    func closeAll() {
        for c in shelves { close(c, remember: true) }
    }

    // MARK: From shelves

    /// Takes a shelf off screen; remembered shelves (with items) go to the recent list.
    func close(_ controller: ShelfWindowController, remember: Bool) {
        guard let index = shelves.firstIndex(where: { $0 === controller }) else { return }
        shelves.remove(at: index)
        if remember {
            var shelf = controller.snapshot
            shelf.closed = Date()
            shelf.expanded = false
            ShelfArchive.pushRecent(shelf, into: &recent)
        }
        controller.dismiss(animated: true)
        scheduleSave()
    }

    func shelfChanged() {
        scheduleSave()
    }

    // MARK: Saving

    func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.saveNow()
                self?.collectGarbage()
            }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// Writes open and recent shelves. Without "keep across restarts", only pinned shelves are saved.
    func saveNow() {
        var archive = ShelfArchive(open: isRunning ? shelves.map(\.snapshot) : (suspended ?? []), recent: recent)
        if !settings.value.keepAcrossRestarts {
            archive.open = archive.open.filter(\.pinned)
            archive.recent = []
        }
        ShelfPersistence.save(archive, to: archiveURL)
    }

    private func collectGarbage() {
        let open = isRunning ? shelves.map(\.model.shelf) : (suspended ?? [])
        let items = (open + recent).flatMap(\.items)
        let store = self.store
        let spare = Date().addingTimeInterval(-600)
        Task.detached(priority: .utility) { store.collectGarbage(keeping: items, sparingAfter: spare) }
    }

    // MARK: Placement

    @discardableResult
    private func show(_ shelf: Shelf, frame: CGRect, animated: Bool) -> ShelfWindowController {
        let controller = ShelfWindowController(shelf: shelf, manager: self)
        shelves.append(controller)
        controller.present(at: frame, animated: animated)
        scheduleSave()
        return controller
    }

    private func newFrame(at pointer: CGPoint) -> CGRect {
        ShelfGeometry.newFrame(size: ShelfGeometry.collapsedSize, placement: settings.value.placement, pointer: pointer,
                               visible: visibleFrame(at: pointer), occupied: shelves.map(\.panel.frame))
    }

    /// Where a saved shelf goes back: its old spot when that is still on a screen.
    private func restoredFrame(_ shelf: Shelf) -> CGRect {
        let size = ShelfGeometry.size(expanded: shelf.expanded, itemCount: shelf.items.count, layout: settings.value.layout)
        guard let old = shelf.frame,
              let screen = NSScreen.screens.max(by: { $0.visibleFrame.intersection(old).area < $1.visibleFrame.intersection(old).area }),
              screen.visibleFrame.intersects(old) else {
            return newFrame(at: NSEvent.mouseLocation)
        }
        let frame = CGRect(x: old.midX - size.width / 2, y: old.maxY - size.height, width: size.width, height: size.height)
        return ShelfGeometry.clamp(frame, to: screen.visibleFrame)
    }

    private func visibleFrame(at point: CGPoint) -> CGRect {
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        return screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }
}
