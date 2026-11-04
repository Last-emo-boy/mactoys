import AppKit
import MacToysCore

/// The menu bar item: the formatted date and time, a calendar icon with the day, or both.
@MainActor
final class CalendarStatusItem: NSObject {
    private weak var module: MenuBarCalendarModule?
    private(set) var item: NSStatusItem?
    private var shownText: String?
    private var shownDay: Int?
    private var shownStyle: MenuBarStyle?

    init(module: MenuBarCalendarModule) {
        self.module = module
    }

    var button: NSStatusBarButton? { item?.button }

    func install() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "com.w33d.mactoys.calendar"
        item.button?.target = self
        item.button?.action = #selector(clicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.imagePosition = .imageLeading
        self.item = item
        shownText = nil
        shownDay = nil
        shownStyle = nil
    }

    func remove() {
        guard let item else { return }
        NSStatusBar.system.removeStatusItem(item)
        self.item = nil
    }

    /// Redraws only what changed (called every minute, or every second when seconds are shown).
    func refresh(text: String, day: Int, style: MenuBarStyle, accessibility: String) {
        guard let button = item?.button else { return }
        if style != shownStyle || (style != .text && day != shownDay) {
            button.image = style == .text ? nil : DayIcon.image(day: day)
            button.imageHugsTitle = true
            shownDay = day
        }
        let title = style == .icon ? "" : text
        if title != shownText || style != shownStyle {
            let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
            button.attributedTitle = NSAttributedString(string: title, attributes: [.font: font, .baselineOffset: 0])
            shownText = title
        }
        shownStyle = style
        button.setAccessibilityLabel(accessibility)
        button.toolTip = accessibility
    }

    func setHighlighted(_ on: Bool) { item?.button?.highlight(on) }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        guard let module else { return }
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            showMenu(sender, module: module)
        } else {
            module.togglePanel()
        }
    }

    // MARK: Right-click menu

    private func showMenu(_ button: NSStatusBarButton, module: MenuBarCalendarModule) {
        let menu = NSMenu()
        let now = Date()
        let copies: [(String, String)] = module.copyChoices(now: now)
        for (label, value) in copies {
            let item = NSMenuItem(title: String(localized: "Copy “\(value)”", comment: "Menu item: copy this date or time text; the placeholder is the text"),
                                  action: #selector(copy(_:)), keyEquivalent: "")
            item.representedObject = value
            item.toolTip = label
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let open = NSMenuItem(title: String(localized: "Open Calendar"), action: #selector(openCalendarApp), keyEquivalent: "")
        open.target = self
        let prefs = NSMenuItem(title: String(localized: "Menu Bar Calendar Settings…"), action: #selector(openSettings), keyEquivalent: ",")
        prefs.target = self
        menu.items += [open, prefs]
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func copy(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        HUD.show("Copied \(value)", symbol: "doc.on.doc")
    }

    @objc private func openCalendarApp() { MenuBarCalendarModule.openCalendarApp() }

    @objc private func openSettings() { ModuleRegistry.shared.showSettings?(module?.info.id) }
}

/// A small calendar page with the day of the month, as a template image for the menu bar.
@MainActor
enum DayIcon {
    private static var cache: [Int: NSImage] = [:]

    static func image(day: Int, pointSize: CGFloat = 17) -> NSImage {
        if let cached = cache[day], cached.size.height == pointSize { return cached }
        let size = CGSize(width: pointSize + 1, height: pointSize)
        let image = NSImage(size: size, flipped: false) { rect in
            let page = rect.insetBy(dx: 1.5, dy: 1.25)
            let radius: CGFloat = 3.2
            let outline = NSBezierPath(roundedRect: page, xRadius: radius, yRadius: radius)
            NSColor.black.setStroke()
            outline.lineWidth = 1.3
            outline.stroke()
            // The binding band along the top.
            let band = NSBezierPath()
            let bandHeight = page.height * 0.24
            band.move(to: CGPoint(x: page.minX, y: page.maxY - bandHeight))
            band.line(to: CGPoint(x: page.minX, y: page.maxY - radius))
            band.appendArc(withCenter: CGPoint(x: page.minX + radius, y: page.maxY - radius), radius: radius, startAngle: 180, endAngle: 90, clockwise: true)
            band.line(to: CGPoint(x: page.maxX - radius, y: page.maxY))
            band.appendArc(withCenter: CGPoint(x: page.maxX - radius, y: page.maxY - radius), radius: radius, startAngle: 90, endAngle: 0, clockwise: true)
            band.line(to: CGPoint(x: page.maxX, y: page.maxY - bandHeight))
            band.close()
            NSColor.black.setFill()
            band.fill()
            let text = String(day) as NSString
            let font = NSFont.systemFont(ofSize: pointSize * (day >= 10 ? 0.52 : 0.56), weight: .bold)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
            let t = text.size(withAttributes: attrs)
            let body = CGRect(x: page.minX, y: page.minY, width: page.width, height: page.height - bandHeight)
            text.draw(at: CGPoint(x: body.midX - t.width / 2, y: body.midY - t.height / 2 + 0.3), withAttributes: attrs)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = String(localized: "Calendar")
        cache[day] = image
        return image
    }
}
