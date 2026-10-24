import AppKit
import MacToysCore
import SwiftUI

/// Zones of one display, in top-left coordinates, with the highlighted ones.
struct ZoneLayer {
    let display: ZoneDisplay
    let zones: [CGRect]
    var highlighted: Set<Int> = []
}

@MainActor
@Observable
final class ZoneScreenModel {
    var zones: [CGRect] = []
    var highlighted: Set<Int> = []
    var style: ZoneStyle

    init(style: ZoneStyle) { self.style = style }
}

private struct ZoneScreenView: View {
    let model: ZoneScreenModel
    var body: some View {
        ZoneFieldView(zones: model.zones, highlighted: model.highlighted, style: model.style)
    }
}

/// Click-through panels that draw zones while dragging and when flashing a layout, plus the
/// layout name indicator. One panel per screen, created on demand and reused.
@MainActor
final class ZoneOverlay {
    private struct ScreenPanel {
        let axFrame: CGRect
        let panel: OverlayPanel
        let model: ZoneScreenModel
    }

    private var panels: [ScreenPanel] = []
    private var namePanel: OverlayPanel?
    private var nameWork: DispatchWorkItem?
    private var flashWork: DispatchWorkItem?
    private(set) var isShowingDrag = false

    /// Shows `layers` (zones per display). With `onlyScreen`, other screens are hidden.
    func show(_ layers: [ZoneLayer], style: ZoneStyle, onlyScreen: CGRect? = nil) {
        flashWork?.cancel()
        isShowingDrag = true
        present(layers, style: style, onlyScreen: onlyScreen)
    }

    func hide() {
        isShowingDrag = false
        flashWork?.cancel()
        for p in panels { p.panel.orderOut(nil) }
    }

    /// Shows a display's zones for a moment, fading out (the "flash zones" option).
    func flash(_ layer: ZoneLayer, style: ZoneStyle) {
        guard !isShowingDrag else { return }
        flashWork?.cancel()
        present([layer], style: style, onlyScreen: nil, onlyIntersecting: layer.display.frame)
        let targets = panels.filter { $0.panel.isVisible }
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.35
                for p in targets { p.panel.animator().alphaValue = 0 }
            }, completionHandler: {
                MainActor.assumeIsolated {
                    guard self?.isShowingDrag != true else { return }
                    for p in targets { p.panel.orderOut(nil); p.panel.alphaValue = 1 }
                }
            })
        }
        flashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// The layout name indicator, placed on `display` per the settings.
    func showLayoutName(_ name: String, on display: ZoneDisplay, settings s: FancyZonesSettings) {
        guard s.showLayoutName else { return }
        let badge = LayoutNameBadge(name: name, textColor: s.layoutNameTextColor.color,
                                    background: s.layoutNameBackground.color,
                                    textSize: CGFloat(s.layoutNameTextSize), padding: CGFloat(s.layoutNamePadding))
        let fitting = NSHostingView(rootView: badge).fittingSize
        let size = CGSize(width: fitting.width + 48, height: fitting.height + 48)   // room for the shadow
        let area = display.workArea.insetBy(dx: 24, dy: 24)
        let x: CGFloat, y: CGFloat
        switch s.layoutNamePosition {
        case .topLeft, .bottomLeft: x = area.minX - 24
        case .topRight, .bottomRight: x = area.maxX - size.width + 24
        default: x = area.midX - size.width / 2
        }
        switch s.layoutNamePosition {
        case .topLeft, .topCenter, .topRight: y = area.minY - 24
        case .bottomLeft, .bottomCenter, .bottomRight: y = area.maxY - size.height + 24
        case .center: y = area.midY - size.height / 2
        }
        let frame = ScreenGeometry.toCocoa(CGRect(x: x, y: y, width: size.width, height: size.height))
        let panel = namePanel ?? OverlayPanel(frame: frame, level: .statusBar)
        panel.setFrame(frame, display: false)
        panel.setContent(badge.frame(maxWidth: .infinity, maxHeight: .infinity))
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        namePanel = panel
        nameWork?.cancel()
        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                panel.animator().alphaValue = 0
            }, completionHandler: { panel.orderOut(nil) })
        }
        nameWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.3, s.layoutNameDuration / 1000), execute: work)
    }

    /// Closes every panel (module stop, screen changes).
    func tearDown() {
        flashWork?.cancel()
        nameWork?.cancel()
        isShowingDrag = false
        for p in panels { p.panel.orderOut(nil); p.panel.close() }
        panels.removeAll()
        namePanel?.orderOut(nil)
        namePanel?.close()
        namePanel = nil
    }

    private func present(_ layers: [ZoneLayer], style: ZoneStyle, onlyScreen: CGRect?,
                         onlyIntersecting: CGRect? = nil) {
        syncPanels(style: style)
        for p in panels {
            let visible = (onlyScreen.map { $0 == p.axFrame } ?? true)
                && (onlyIntersecting.map { $0.intersects(p.axFrame) } ?? true)
            let layer = layers
                .filter { $0.display.frame.intersects(p.axFrame) }
                .max { $0.display.frame.intersection(p.axFrame).area < $1.display.frame.intersection(p.axFrame).area }
            guard visible, let layer else { p.panel.orderOut(nil); continue }
            let local = layer.zones.map { $0.offsetBy(dx: -p.axFrame.minX, dy: -p.axFrame.minY) }
            if p.model.zones != local { p.model.zones = local }
            if p.model.highlighted != layer.highlighted { p.model.highlighted = layer.highlighted }
            if p.model.style != style { p.model.style = style }
            p.panel.alphaValue = 1
            if !p.panel.isVisible { p.panel.orderFrontRegardless() }
        }
    }

    private func syncPanels(style: ZoneStyle) {
        let frames = NSScreen.screens.map(\.axFrame)
        guard frames != panels.map(\.axFrame) else { return }
        for p in panels { p.panel.orderOut(nil); p.panel.close() }
        panels = NSScreen.screens.map { screen in
            let model = ZoneScreenModel(style: style)
            let panel = OverlayPanel(frame: screen.frame, level: .floating)
            panel.setContent(ZoneScreenView(model: model))
            return ScreenPanel(axFrame: screen.axFrame, panel: panel, model: model)
        }
    }
}
