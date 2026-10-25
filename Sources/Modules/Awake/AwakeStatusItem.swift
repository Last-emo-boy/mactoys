import AppKit
import MacToysCore

/// Awake's own optional menu bar item: a cup that shows the mode, with the Awake menu.
@MainActor
final class AwakeStatusItem: NSObject, NSMenuDelegate {
    private weak var module: AwakeModule?
    private var item: NSStatusItem?
    private var entries: [AwakeMenuEntry] = []
    private var shownMode: AwakeMode?

    init(module: AwakeModule) {
        self.module = module
    }

    func install() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "com.w33d.mactoys.awake"
        let menu = NSMenu(title: String(localized: "Awake"))
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        self.item = item
        shownMode = nil
        refresh()
    }

    func remove() {
        guard let item else { return }
        NSStatusBar.system.removeStatusItem(item)
        self.item = nil
    }

    func refresh() {
        guard let item, let module else { return }
        let mode = module.settings.value.mode
        if mode != shownMode {
            item.button?.image = AwakeIcon.image(for: mode)
            shownMode = mode
        }
        item.button?.toolTip = String(localized: "Awake — \(module.statusText)",
                                      comment: "Menu bar tooltip; the placeholder is the status, e.g. 'Indefinitely · screen stays on'")
        item.button?.setAccessibilityLabel(String(localized: "Awake, \(module.statusText)",
                                                  comment: "Menu bar item accessibility label; the placeholder is the status"))
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let module else { return }
        menu.removeAllItems()
        entries = AwakeMenu.entries(module.settings.value, now: Date())
        for (index, entry) in entries.enumerated() {
            switch entry {
            case .header(let title):
                menu.addItem(NSMenuItem.sectionHeader(title: title))
            case .separator:
                menu.addItem(.separator())
            case let .item(title, checked, badge, action):
                let mi = NSMenuItem(title: title, action: #selector(pick(_:)), keyEquivalent: action == .settings ? "," : "")
                mi.target = self
                mi.tag = index
                mi.state = checked ? .on : .off
                if let badge { mi.badge = NSMenuItemBadge(string: badge) }
                if action == .until {
                    mi.toolTip = String(localized: "Keeps this Mac awake until the date and time set in Awake settings.")
                }
                menu.addItem(mi)
            }
        }
    }

    @objc private func pick(_ sender: NSMenuItem) {
        guard entries.indices.contains(sender.tag), case let .item(_, _, _, action) = entries[sender.tag] else { return }
        module?.perform(action)
    }
}

/// Template images for the menu bar: an empty cup when off, a full cup when awake, with a
/// clock (interval) or calendar (until) badge.
enum AwakeIcon {
    static func image(for mode: AwakeMode) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let cupName = mode == .off ? "cup.and.saucer" : "cup.and.saucer.fill"
        guard let cup = NSImage(systemSymbolName: cupName, accessibilityDescription: String(localized: "Awake"))?
            .withSymbolConfiguration(config) else { return NSImage() }
        let badgeName: String? = switch mode {
        case .timed: "clock.fill"
        case .until: "calendar"
        case .off, .indefinite: nil
        }
        guard let badgeName,
              let badge = NSImage(systemSymbolName: badgeName, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)) else {
            cup.isTemplate = true
            return cup
        }
        let size = CGSize(width: cup.size.width + 3, height: cup.size.height + 1)
        let image = NSImage(size: size, flipped: false) { rect in
            cup.draw(in: CGRect(x: 0, y: rect.height - cup.size.height, width: cup.size.width, height: cup.size.height))
            let b = CGRect(x: rect.width - badge.size.width - 0.5, y: 0, width: badge.size.width, height: badge.size.height)
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSBezierPath(ovalIn: b.insetBy(dx: -1.5, dy: -1.5)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            badge.draw(in: b)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = String(localized: "Awake")
        return image
    }
}
