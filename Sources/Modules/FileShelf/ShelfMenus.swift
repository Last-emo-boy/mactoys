import AppKit
import MacToysCore

/// A menu item that runs a closure.
final class ShelfMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, symbol: String? = nil, key: String = "", modifiers: NSEvent.ModifierFlags = [.command],
         enabled: Bool = true, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: enabled ? #selector(fire) : nil, keyEquivalent: key)
        target = self
        keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        isEnabled = enabled
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func fire() { handler() }
}

extension ShelfWindowController {
    /// Right-click on items: actions for the selection.
    func itemMenu(for items: [ShelfItem], anchor: NSView) -> NSMenu {
        let menu = NSMenu()
        addItemActions(for: items, to: menu, anchor: anchor)
        if items.count == 1, let item = items.first, item.owned {
            menu.addItem(ShelfMenuItem(String(localized: "Rename…", comment: "Shelf item menu: rename a dropped text, image or link"),
                                       symbol: "pencil") { [weak self] in self?.beginRename(.item(item.id)) })
        }
        menu.addItem(.separator())
        let ids = Set(items.map(\.id))
        menu.addItem(ShelfMenuItem(String(localized: "Remove from Shelf", comment: "Shelf item menu; the file itself is kept"),
                                   symbol: "minus.circle", key: "\u{8}", modifiers: []) { [weak self] in self?.remove(ids) })
        return menu
    }

    /// The ⋯ menu and right-click on the shelf: actions for the selection (or every item), then
    /// the shelf's own commands.
    func shelfMenu(anchor: NSView) -> NSMenu {
        let menu = NSMenu()
        let items = model.actionItems
        if !items.isEmpty {
            addItemActions(for: items, to: menu, anchor: anchor)
            menu.addItem(.separator())
            menu.addItem(ShelfMenuItem(String(localized: "Select All", comment: "Shelf menu"), symbol: "checklist", key: "a") { [weak self] in
                guard let self else { return }
                if !self.model.shelf.expanded { self.toggleExpanded() }
                self.model.selection = Set(self.model.items.map(\.id))
            })
        }
        menu.addItem(ShelfMenuItem(String(localized: "Paste", comment: "Shelf menu: add what's on the clipboard"),
                                   symbol: "doc.on.clipboard", key: "v",
                                   enabled: ShelfPasteboardReader.hasContent(.general)) { [weak self] in self?.paste() })
        menu.addItem(.separator())

        let pinned = model.shelf.pinned
        menu.addItem(ShelfMenuItem(pinned ? String(localized: "Unpin Shelf", comment: "Shelf menu") : String(localized: "Pin Shelf", comment: "Shelf menu: keep the shelf open"),
                                   symbol: pinned ? "pin.slash" : "pin") { [weak self] in self?.togglePin() })
        menu.addItem(ShelfMenuItem(String(localized: "Name Shelf…", comment: "Shelf menu: give the shelf a title"),
                                   symbol: "character.cursor.ibeam") { [weak self] in self?.beginRename(.shelf) })
        let next: ShelfLayout = model.layout == .grid ? .list : .grid
        menu.addItem(ShelfMenuItem(next == .grid ? String(localized: "Show as Grid", comment: "Shelf menu") : String(localized: "Show as List", comment: "Shelf menu"),
                                   symbol: next.symbol) { [weak self] in
            guard let self else { return }
            self.setLayout(next)
            if !self.model.shelf.expanded { self.toggleExpanded() }
        })
        menu.addItem(recentShelvesItem())
        menu.addItem(.separator())
        menu.addItem(ShelfMenuItem(String(localized: "Clear Shelf", comment: "Shelf menu: remove every item (files are kept)"),
                                   symbol: "trash.slash", enabled: !model.items.isEmpty) { [weak self] in self?.clear() })
        menu.addItem(ShelfMenuItem(String(localized: "Close Shelf", comment: "Shelf menu"), symbol: "xmark.circle", key: "w") { [weak self] in
            self?.closeShelf()
        })
        return menu
    }

    private func addItemActions(for items: [ShelfItem], to menu: NSMenu, anchor: NSView) {
        menu.addItem(ShelfMenuItem(String(localized: "Quick Look", comment: "Shelf item menu"), symbol: "eye", key: " ", modifiers: []) { [weak self] in
            guard let self else { return }
            self.model.selection = Set(items.map(\.id))
            self.quickLook()
        })
        menu.addItem(ShelfMenuItem(String(localized: "Open", comment: "Shelf item menu: open with the default app"),
                                   symbol: "arrow.up.forward.app", key: "o") { [weak self] in self?.open(items) })
        menu.addItem(openWithItem(for: items))
        let hasUserFiles = items.contains(where: \.isUserFile)
        menu.addItem(ShelfMenuItem(String(localized: "Show in Finder", comment: "Shelf item menu"), symbol: "folder",
                                   enabled: hasUserFiles) { [weak self] in self?.reveal(items) })
        menu.addItem(.separator())
        menu.addItem(ShelfMenuItem(String(localized: "Copy", comment: "Shelf item menu: copy the items to the clipboard"),
                                   symbol: "doc.on.doc", key: "c") { [weak self] in self?.copy(items) })
        let pathTitle = items.allSatisfy { $0.kind == .link }
            ? String(localized: "Copy Link", comment: "Shelf item menu: copy the web address")
            : String(localized: "Copy Path", comment: "Shelf item menu: copy the file path")
        menu.addItem(ShelfMenuItem(pathTitle, symbol: "link") { [weak self] in self?.copyPaths(items) })
        menu.addItem(ShelfMenuItem(String(localized: "Share…", comment: "Shelf item menu: AirDrop, Mail, Messages…"),
                                   symbol: "square.and.arrow.up") { [weak self] in self?.share(items, anchor: anchor) })
        menu.addItem(.separator())
        menu.addItem(ShelfMenuItem(String(localized: "Compress to ZIP", comment: "Shelf item menu"), symbol: "doc.zipper",
                                   enabled: model.busy == nil) { [weak self] in self?.compress(items) })
        let saves = items.allSatisfy(\.owned)
        menu.addItem(ShelfMenuItem(saves ? String(localized: "Save to Folder…", comment: "Shelf item menu: save dropped text or images as files")
                                         : String(localized: "Move to Folder…", comment: "Shelf item menu: move the files into a folder"),
                                   symbol: "folder.badge.plus") { [weak self] in self?.moveToFolder(items) })
    }

    /// "Open With" and the apps that can open the first item, default app first.
    private func openWithItem(for items: [ShelfItem]) -> NSMenuItem {
        let item = NSMenuItem(title: String(localized: "Open With", comment: "Shelf item menu: submenu of apps"), action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "square.grid.3x3.square", accessibilityDescription: nil)
        let sub = NSMenu()
        if let first = items.first {
            let url = first.kind == .link ? (first.link ?? first.url) : first.url
            let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: url)
            var apps = NSWorkspace.shared.urlsForApplications(toOpen: url).filter { $0 != defaultApp }
            apps.sort { appName($0).localizedStandardCompare(appName($1)) == .orderedAscending }
            if let defaultApp {
                sub.addItem(appItem(defaultApp, title: String(localized: "\(appName(defaultApp)) (default)", comment: "Open With menu: the default app for the file"), items: items))
                if !apps.isEmpty { sub.addItem(.separator()) }
            }
            for app in apps.prefix(30) { sub.addItem(appItem(app, title: appName(app), items: items)) }
        }
        if !sub.items.isEmpty { sub.addItem(.separator()) }
        sub.addItem(ShelfMenuItem(String(localized: "Other…", comment: "Open With menu: choose another app")) { [weak self] in
            self?.chooseApp(for: items)
        })
        item.submenu = sub
        return item
    }

    private func appItem(_ app: URL, title: String, items: [ShelfItem]) -> NSMenuItem {
        let menuItem = ShelfMenuItem(title) { [weak self] in self?.open(items, with: app) }
        let icon = NSWorkspace.shared.icon(forFile: app.path)
        icon.size = NSSize(width: 16, height: 16)
        menuItem.image = icon
        return menuItem
    }

    private func appName(_ app: URL) -> String {
        FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
    }

    private func chooseApp(for items: [ShelfItem]) {
        let open = NSOpenPanel()
        open.directoryURL = URL(fileURLWithPath: "/Applications")
        open.allowedContentTypes = [.application]
        open.allowsMultipleSelection = false
        open.prompt = String(localized: "Open", comment: "App picker button: open the items with the chosen app")
        NSApp.activate()
        open.begin { [weak self] response in
            guard response == .OK, let app = open.url else { return }
            MainActor.assumeIsolated { self?.open(items, with: app) }
        }
    }

    /// "Recent Shelves" with the shelves closed lately.
    private func recentShelvesItem() -> NSMenuItem {
        let item = NSMenuItem(title: String(localized: "Recent Shelves", comment: "Shelf menu: submenu of closed shelves"), action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
        let sub = NSMenu()
        let recent = manager.recent
        if recent.isEmpty {
            sub.addItem(ShelfMenuItem(String(localized: "No Recent Shelves", comment: "Recent Shelves submenu when empty"), enabled: false) {})
        }
        for shelf in recent {
            sub.addItem(ShelfMenuItem(ShelfRecents.title(for: shelf)) { [weak self] in self?.manager.reopen(shelf.id) })
        }
        item.submenu = sub
        return item
    }
}

/// How a recent shelf is named in menus and settings.
enum ShelfRecents {
    /// "Invoices", "IMG_4821.HEIC", "IMG_4821.HEIC and 4 more".
    static func title(for shelf: Shelf) -> String {
        if let title = shelf.title, !title.isEmpty { return title }
        guard let last = shelf.items.last else { return String(localized: "Empty Shelf", comment: "A shelf with no items") }
        if shelf.items.count == 1 { return last.name }
        return String(localized: "\(last.name) and \(shelf.items.count - 1) more", comment: "Recent shelf name: an item's name, then how many other items")
    }

    /// "Closed 5 min ago".
    static func detail(for shelf: Shelf) -> String {
        let when = (shelf.closed ?? shelf.created).formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
        return String(localized: "Closed \(when)", comment: "When a recent shelf was closed, e.g. 'Closed 5 min ago'")
    }
}
