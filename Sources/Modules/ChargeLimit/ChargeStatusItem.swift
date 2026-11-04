import AppKit
import MacToysCore
import SwiftUI

/// Charge Limit's optional menu bar item: a battery with the limit marked (and the percentage), which
/// opens the flyout.
@MainActor
final class ChargeStatusItem: NSObject {
    private weak var module: ChargeLimitModule?
    private var item: NSStatusItem?
    private var panel: ChargeFlyoutPanel?
    private var shown: (level: Int, limit: Int?, charging: Bool, percent: Bool)?

    init(module: ChargeLimitModule) {
        self.module = module
    }

    func install() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "com.w33d.mactoys.chargelimit"
        item.button?.target = self
        item.button?.action = #selector(clicked(_:))
        item.button?.imagePosition = .imageTrailing
        item.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        self.item = item
        shown = nil
        refresh()
    }

    func remove() {
        panel?.dismiss()
        guard let item else { return }
        NSStatusBar.system.removeStatusItem(item)
        self.item = nil
    }

    func refresh() {
        guard let item, let module else { return }
        let model = module.model
        let level = model.battery?.percent ?? 0
        let limit = model.isLimiting ? model.config?.upper : nil
        let charging = model.battery?.isCharging == true
        let percent = module.settings.value.showPercentInMenuBar
        if shown.map({ $0 != (level, limit, charging, percent) }) ?? true {
            item.button?.image = ChargeMenuIcon.image(level: level, limit: limit, charging: charging)
            item.button?.title = percent ? ChargeText.percent(level) + " " : ""
            shown = (level, limit, charging, percent)
        }
        let line = module.statusLine
        item.button?.toolTip = String(localized: "Charge Limit — \(line)", comment: "Menu bar tooltip; the placeholder is the status line")
        item.button?.setAccessibilityLabel(String(localized: "Charge Limit, \(line)", comment: "Menu bar item accessibility label"))
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        toggleFlyout(from: sender)
    }

    func toggleFlyout(from button: NSStatusBarButton?) {
        guard let module else { return }
        if let panel, panel.isVisible { panel.dismiss(); return }
        let panel = self.panel ?? ChargeFlyoutPanel(module: module)
        self.panel = panel
        panel.present(below: button ?? item?.button)
        Task { await module.sync() }
    }
}

/// Template images for the menu bar: a battery outline, the level, a tick at the limit and a bolt
/// while charging.
enum ChargeMenuIcon {
    static func image(level: Int, limit: Int?, charging: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 26, height: 13), flipped: false) { _ in
            let body = NSRect(x: 0.5, y: 0.5, width: 22, height: 12)
            let outline = NSBezierPath(roundedRect: body, xRadius: 3.5, yRadius: 3.5)
            outline.lineWidth = 1
            NSColor.black.withAlphaComponent(0.45).setStroke()
            outline.stroke()
            NSColor.black.withAlphaComponent(0.45).setFill()
            NSBezierPath(roundedRect: NSRect(x: 23.5, y: 4.5, width: 1.8, height: 4), xRadius: 0.9, yRadius: 0.9).fill()
            let inner = body.insetBy(dx: 2, dy: 2)
            let fraction = CGFloat(min(max(level, 0), 100)) / 100
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: inner.minX, y: inner.minY, width: max(1.5, inner.width * fraction), height: inner.height),
                         xRadius: 1.6, yRadius: 1.6).fill()
            let ctx = NSGraphicsContext.current
            if let limit {
                let x = (inner.minX + inner.width * CGFloat(limit) / 100).rounded() + 0.5
                ctx?.compositingOperation = .destinationOut
                NSBezierPath(rect: NSRect(x: x - 1.3, y: body.minY, width: 2.6, height: body.height)).fill()
                ctx?.compositingOperation = .sourceOver
                NSColor.black.setFill()
                NSBezierPath(rect: NSRect(x: x - 0.5, y: 0, width: 1, height: 13)).fill()
            }
            if charging, let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 8, weight: .black)) {
                let r = NSRect(x: body.midX - bolt.size.width / 2, y: body.midY - bolt.size.height / 2,
                               width: bolt.size.width, height: bolt.size.height)
                bolt.draw(in: r.insetBy(dx: -1, dy: -1), from: .zero, operation: .destinationOut, fraction: 1)
                bolt.draw(in: r, from: .zero, operation: .sourceOver, fraction: fraction > 0.5 ? 0 : 1)
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = String(localized: "Charge Limit")
        return image
    }
}

/// The flyout window: a key-capable glass panel under the menu bar.
@MainActor
final class ChargeFlyoutPanel: FloatingPanel {
    static let width: CGFloat = 340

    init(module: ChargeLimitModule) {
        super.init(size: CGSize(width: Self.width, height: 300))
        contentView = NSHostingView(rootView: ChargeFlyout(module: module).fixedSize(horizontal: false, vertical: true))
        hasShadow = true
    }

    func present(below button: NSStatusBarButton?) {
        let size = contentView?.fittingSize ?? frame.size
        let height = max(120, size.height)
        let origin: CGPoint
        if let button, let window = button.window {
            let r = window.convertToScreen(button.convert(button.bounds, to: nil))
            let vf = (window.screen ?? NSScreen.main)?.visibleFrame ?? r
            let x = min(max(r.midX - Self.width / 2, vf.minX + 8), vf.maxX - Self.width - 8)
            origin = CGPoint(x: x, y: r.minY - 6 - height)
        } else {
            let vf = (NSScreen.underMouse ?? NSScreen.main)?.visibleFrame ?? .zero
            origin = CGPoint(x: vf.maxX - Self.width - 12, y: vf.maxY - 8 - height)
        }
        setFrame(CGRect(origin: origin, size: CGSize(width: Self.width, height: height)), display: true)
        NSApp.activate()
        makeKeyAndOrderFront(nil)
    }
}
