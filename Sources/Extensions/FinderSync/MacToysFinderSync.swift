import Cocoa
import FinderSync
import UniformTypeIdentifiers

/// The Finder extension: a "MacToys" submenu for selected items (PowerRename, Image Resizer,
/// File Locksmith, Peek) and a "New+" submenu on folder backgrounds. Every item opens a
/// `mactoys://<module>/<action>?…` URL; the app does the work.
///
/// The extension is sandboxed and only reads MacToys' settings and the New+ template list
/// (see the temporary-exception entitlement).
@objc(MacToysFinderSync)
final class MacToysFinderSync: FIFinderSync {
    /// The templates of the last New+ menu, indexed by menu item tag (Finder keeps tags, not objects).
    private var templates: [FinderConfig.Template] = []

    override init() {
        super.init()
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    // MARK: Toolbar button

    override var toolbarItemName: String { "MacToys" }
    override var toolbarItemToolTip: String { String(localized: "MacToys tools for the selected items") }
    override var toolbarItemImage: NSImage {
        NSImage(systemSymbolName: "puzzlepiece.extension.fill", accessibilityDescription: "MacToys") ?? NSImage()
    }

    // MARK: Menus

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        let config = FinderConfig.load()
        switch menuKind {
        case .contextualMenuForItems:
            return wrap(itemsMenu(config), title: "MacToys", symbol: "puzzlepiece.extension")
        case .contextualMenuForContainer:
            return wrap(newPlusMenu(config), title: String(localized: "New+"), symbol: "doc.badge.plus")
        case .toolbarItemMenu:
            let menu = NSMenu(title: "MacToys")
            if let items = itemsMenu(config) {
                let entries = items.items
                items.removeAllItems()
                entries.forEach(menu.addItem)
            }
            if let newPlus = newPlusMenu(config) {
                if !menu.items.isEmpty { menu.addItem(.separator()) }
                let parent = NSMenuItem(title: String(localized: "New+"), action: nil, keyEquivalent: "")
                parent.image = Self.symbol("doc.badge.plus")
                parent.submenu = newPlus
                menu.addItem(parent)
            }
            return menu.items.isEmpty ? nil : menu
        default:
            return nil
        }
    }

    /// Puts a submenu under one titled item, or nothing when it is empty.
    private func wrap(_ submenu: NSMenu?, title: String, symbol: String) -> NSMenu? {
        guard let submenu, !submenu.items.isEmpty else { return nil }
        let menu = NSMenu(title: "")
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = Self.symbol(symbol)
        item.submenu = submenu
        menu.addItem(item)
        return menu
    }

    private func itemsMenu(_ config: FinderConfig) -> NSMenu? {
        let selected = FIFinderSyncController.default().selectedItemURLs() ?? []
        guard !selected.isEmpty else { return nil }
        let option = NSEvent.modifierFlags.contains(.option)
        let menu = NSMenu(title: "MacToys")
        if config.shows("powerrename", optionHeld: option) {
            menu.addItem(item(String(localized: "PowerRename"), symbol: config.flag("powerrename", "showFinderMenuIcon", default: true)
                                ? "character.cursor.ibeam" : nil, action: #selector(powerRename(_:))))
        }
        if config.shows("imageresizer", optionHeld: option), selected.contains(where: Self.isImage) {
            menu.addItem(item(String(localized: "Resize with Image Resizer"), symbol: "photo.on.rectangle.angled", action: #selector(resizeImages(_:))))
        }
        if config.shows("filelocksmith", optionHeld: option) {
            let title = selected.count > 1 ? String(localized: "What’s Using These Items?")
                : Self.isFolder(selected[0]) ? String(localized: "What’s Using This Folder?")
                : String(localized: "What’s Using This File?")
            menu.addItem(item(title, symbol: "lock.doc", action: #selector(fileLocksmith(_:))))
        }
        if config.isEnabled("peek") {
            menu.addItem(item(String(localized: "Peek"), symbol: "eye", action: #selector(peek(_:))))
        }
        return menu
    }

    private func newPlusMenu(_ config: FinderConfig) -> NSMenu? {
        guard config.isEnabled("newplus"), config.flag("newplus", "showInFinderMenu", default: true) else { return nil }
        templates = config.templates()
        let menu = NSMenu(title: "New+")
        for (i, t) in templates.enumerated() {
            let entry = NSMenuItem(title: t.title, action: #selector(createFromTemplate(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = i
            entry.image = Self.templateIcon(t)
            menu.addItem(entry)
        }
        if templates.isEmpty {
            let empty = NSMenuItem(title: String(localized: "No Templates"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Open Templates Folder"), symbol: "folder", action: #selector(openTemplates(_:))))
        return menu
    }

    /// `title` is localized.
    private func item(_ title: String, symbol: String?, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = symbol.flatMap(Self.symbol)
        return item
    }

    // MARK: Actions

    @objc private func powerRename(_ sender: NSMenuItem) { send("powerrename", "open", files: selection()) }
    @objc private func resizeImages(_ sender: NSMenuItem) { send("imageresizer", "open", files: selection().filter(Self.isImage)) }
    @objc private func fileLocksmith(_ sender: NSMenuItem) { send("filelocksmith", "open", files: selection()) }
    @objc private func peek(_ sender: NSMenuItem) { send("peek", "open", files: selection()) }
    @objc private func openTemplates(_ sender: NSMenuItem) { send("newplus", "templates") }

    @objc private func createFromTemplate(_ sender: NSMenuItem) {
        guard templates.indices.contains(sender.tag) else { return }
        var params = ["template": templates[sender.tag].fileName]
        if let dir = FIFinderSyncController.default().targetedURL() { params["dir"] = dir.path }
        send("newplus", "create", parameters: params)
    }

    private func selection() -> [URL] {
        let controller = FIFinderSyncController.default()
        let selected = controller.selectedItemURLs() ?? []
        if !selected.isEmpty { return selected }
        return controller.targetedURL().map { [$0] } ?? []
    }

    /// Opens `mactoys://module/action?k=v&file=…` (the format of the app's `AppCommand`).
    private func send(_ module: String, _ action: String, parameters: [String: String] = [:], files: [URL] = []) {
        var c = URLComponents()
        c.scheme = "mactoys"
        c.host = module
        c.path = "/" + action
        var query = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        query += files.map { URLQueryItem(name: "file", value: $0.path) }
        c.queryItems = query.isEmpty ? nil : query
        guard let url = c.url else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Helpers

    static func isImage(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    }

    static func isFolder(_ url: URL) -> Bool {
        url.hasDirectoryPath || (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    static func templateIcon(_ t: FinderConfig.Template) -> NSImage {
        let type: UTType = t.isFolder ? .folder : (UTType(filenameExtension: (t.fileName as NSString).pathExtension) ?? .data)
        let icon = NSWorkspace.shared.icon(for: type)
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }
}

/// MacToys settings as the extension sees them, read fresh for every menu.
struct FinderConfig {
    struct Template {
        var fileName: String
        var title: String
        var isFolder: Bool
    }

    /// `~/Library/Application Support/MacToys` of the real home folder (not the sandbox container).
    static var supportFolder: URL {
        let home: String
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            home = String(cString: dir)
        } else {
            home = NSHomeDirectory()
        }
        return URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/MacToys", isDirectory: true)
    }

    var files: [String: [String: Any]] = [:]

    static func load() -> FinderConfig {
        var config = FinderConfig()
        for id in ["general", "powerrename", "imageresizer", "filelocksmith", "newplus", "peek"] {
            let url = supportFolder.appendingPathComponent("Settings/\(id).json")
            if let data = try? Data(contentsOf: url),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                config.files[id] = object
            }
        }
        return config
    }

    /// Modules are on unless the user turned them off (all of these default to on).
    func isEnabled(_ id: String) -> Bool {
        ((files["general"]?["enabled"] as? [String: Any])?[id] as? Bool) ?? true
    }

    func flag(_ id: String, _ key: String, default value: Bool) -> Bool {
        (files[id]?[key] as? Bool) ?? value
    }

    /// Enabled, shown in the Finder menu, and the ⌥ requirement met.
    func shows(_ id: String, optionHeld: Bool) -> Bool {
        isEnabled(id) && flag(id, "showInFinderMenu", default: true)
            && (optionHeld || !flag(id, "finderMenuNeedsOption", default: false))
    }

    /// The list the app wrote (`NewPlus/menu.json`), or the default templates folder read directly.
    func templates() -> [Template] {
        let manifest = Self.supportFolder.appendingPathComponent("NewPlus/menu.json")
        if let data = try? Data(contentsOf: manifest),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let items = object["items"] as? [[String: Any]] {
            return items.compactMap { d in
                guard let name = d["fileName"] as? String else { return nil }
                return Template(fileName: name, title: d["title"] as? String ?? name, isFolder: d["isFolder"] as? Bool ?? false)
            }
        }
        let folder = Self.supportFolder.appendingPathComponent("NewPlus/Templates", isDirectory: true)
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                                 options: [.skipsHiddenFiles])) ?? []
        let hideExtension = flag("newplus", "hideExtensions", default: true)
        return urls.map { url in
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let name = url.lastPathComponent
            let title = hideExtension && !isFolder ? (name as NSString).deletingPathExtension : name
            return Template(fileName: name, title: title.isEmpty ? name : title, isFolder: isFolder)
        }
        .sorted { $0.isFolder != $1.isFolder ? $0.isFolder : $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
    }
}
