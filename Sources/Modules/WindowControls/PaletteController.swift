import AppKit
import MacToysCore
import Observation
import SwiftUI

/// A hosting view that takes the first click: the palette never becomes key, so without this the
/// first click on it would only try to focus the panel.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Target preview

@MainActor
@Observable
final class TargetPreviewModel {
    /// In the panel's own (display-local, top-left) coordinates.
    var rect: CGRect?
    var label = ""
}

/// Outlines on screen where the window will go while a choice is hovered in the palette.
@MainActor
final class TargetPreview {
    private var panel: OverlayPanel?
    private let model = TargetPreviewModel()
    private var displayFrame = CGRect.null

    func show(_ frame: CGRect, on display: DisplayBox) {
        let p = panel ?? makePanel()
        if displayFrame != display.frame {
            displayFrame = display.frame
            model.rect = nil
            p.setFrame(ScreenGeometry.toCocoa(display.frame), display: false)
        }
        model.label = "\(Int(frame.width)) × \(Int(frame.height))"
        model.rect = frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        if !p.isVisible { p.orderFrontRegardless() }
    }

    func hide() {
        model.rect = nil
        panel?.orderOut(nil)
    }

    func tearDown() {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        displayFrame = .null
    }

    private func makePanel() -> OverlayPanel {
        // Above app windows, below the palette.
        let p = OverlayPanel(frame: .zero, level: .floating)
        p.setContent(TargetPreviewView(model: model))
        panel = p
        return p
    }
}

private struct TargetPreviewView: View {
    let model: TargetPreviewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if let r = model.rect {
                TargetOutline(label: model.label)
                    .frame(width: r.width, height: r.height)
                    .offset(x: r.minX, y: r.minY)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: model.rect)
        .ignoresSafeArea()
    }
}

/// The accent outline of where a window will go, with its size.
struct TargetOutline: View {
    let label: String

    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.accentColor.opacity(0.16))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.accentColor.opacity(0.95), lineWidth: 2.5))
            .overlay {
                Text(verbatim: label)
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.accentColor))
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
            }
    }
}

// MARK: - Palette

/// Shows the palette under a window's green button and turns choices into window moves.
@MainActor
final class PaletteController {
    private let settings: Persisted<WindowControlsSettings>
    private let mover: WindowMover
    private let model = PaletteModel()
    private let preview = TargetPreview()
    private var panel: OverlayPanel?
    private var hit: ZoomButtonWatcher.Hit?
    private var displays: [DisplayBox] = []
    private var displayIndex = 0
    private var watchTimer: Timer?
    private var outsideSince: TimeInterval?
    private var clickMonitor: Any?

    private(set) var isVisible = false

    init(settings: Persisted<WindowControlsSettings>, mover: WindowMover) {
        self.settings = settings
        self.mover = mover
        model.onGridChange = { [weak self] u in self?.previewGrid(u) }
        model.onGridCommit = { [weak self] u in self?.commit { $0.mover.run(steps: [.place(u)], on: $1) } }
        model.onHoverControl = { [weak self] c in self?.previewControl(c) }
        model.onRun = { [weak self] c in self?.commit { $0.mover.run(c, on: $1) } }
        model.onHoverDisplay = { [weak self] i in self?.previewDisplay(i) }
        model.onDisplay = { [weak self] i in self?.moveToDisplay(i) }
    }

    /// Opens the palette for the window whose green button the pointer rests on.
    func show(for hit: ZoomButtonWatcher.Hit) {
        let s = settings.value
        displays = Screens.current()
        guard let d = DisplayNavigator.index(showing: hit.windowFrame, in: displays) else { return }
        self.hit = hit
        displayIndex = d
        let visible = displays[d].visible
        let app = hit.window.app
        model.resetPointer()
        model.appName = app?.localizedName ?? ""
        model.appIcon = app?.icon
        model.windowTitle = hit.window.title ?? ""
        model.grid = GridSpec.oriented(columns: s.gridColumns, rows: s.gridRows, for: visible, swapOnPortrait: s.swapGridOnPortrait)
        model.gridSize = PaletteLayout.gridSize(for: visible)
        model.current = Placement.unitRect(of: hit.windowFrame, in: visible, spacing: s.spacing)
        model.controls = s.paletteControls
        model.displays = DisplayNavigator.readingOrder(displays).filter { $0 != d }
            .map { DisplayChoice(index: $0, name: displays[$0].name) }

        let host = FirstMouseHostingView(rootView: PaletteView(model: model))
        host.sizingOptions = []
        let size = host.fittingSize
        let inset = PaletteLayout.shadowInset
        // The glass hangs just under the button, its left edge a little left of it.
        var frame = CGRect(x: hit.buttonRect.minX - 12 - inset, y: hit.buttonRect.maxY + 8 - inset,
                           width: size.width, height: size.height)
        let bounds = displays[d].visible.insetBy(dx: -inset + 6, dy: -inset + 6)
        frame.origin.x = min(max(frame.minX, bounds.minX), bounds.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, bounds.minY), bounds.maxY - frame.height)

        let p = panel ?? OverlayPanel(frame: .zero, interactive: true, acceptsKey: false, level: .popUpMenu)
        p.contentView = host
        host.frame = CGRect(origin: .zero, size: frame.size)
        host.autoresizingMask = [.width, .height]
        p.setFrame(ScreenGeometry.toCocoa(frame), display: true)
        p.alphaValue = 1
        p.orderFrontRegardless()
        panel = p
        isVisible = true
        startWatching(glass: frame.insetBy(dx: inset, dy: inset), button: hit.buttonRect)
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        watchTimer?.invalidate()
        watchTimer = nil
        outsideSince = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        preview.hide()
        panel?.orderOut(nil)
        panel?.contentView = nil
        model.resetPointer()
        hit = nil
    }

    func tearDown() {
        hide()
        panel?.close()
        panel = nil
        preview.tearDown()
    }

    // MARK: Pointer

    /// Closes the palette once the pointer has left the button, the palette and the way between
    /// them for a moment (never during a grid drag), or on a click elsewhere.
    private func startWatching(glass: CGRect, button: CGRect) {
        let bridge = CGRect(x: min(button.minX, glass.minX), y: button.minY,
                            width: max(button.maxX, glass.minX + 60) - min(button.minX, glass.minX),
                            height: max(0, glass.minY - button.minY) + 4)
        let keep = [glass.insetBy(dx: -10, dy: -10), button.insetBy(dx: -6, dy: -6), bridge]
        outsideSince = nil
        watchTimer?.invalidate()
        let t = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isVisible else { return }
                let p = ScreenGeometry.toAX(NSEvent.mouseLocation)
                if self.model.isDragging || keep.contains(where: { $0.contains(p) }) {
                    self.outsideSince = nil
                    return
                }
                let now = ProcessInfo.processInfo.systemUptime
                if let since = self.outsideSince {
                    if now - since > 0.3 { self.hide() }
                } else {
                    self.outsideSince = now
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        watchTimer = t
        if clickMonitor == nil {
            // Global monitors see clicks in other apps only, so any click here is outside the palette.
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) {
                [weak self] _ in MainActor.assumeIsolated { self?.hide() }
            }
        }
    }

    // MARK: Choices

    private var context: PlanContext? {
        guard let hit else { return nil }
        return PlanContext(displays: displays, spacing: settings.value.spacing, resizable: hit.window.isResizable)
    }

    private func showPreview(_ target: CGRect?) {
        model.targetSize = target?.size
        guard settings.value.showPreview, let target,
              let i = DisplayNavigator.index(showing: target, in: displays) else {
            preview.hide()
            return
        }
        preview.show(target, on: displays[i])
    }

    private func previewGrid(_ u: UnitRect?) {
        guard let u, let hit, let ctx = context else { return showPreview(nil) }
        showPreview(ControlPlanner.plan([.place(u)], frame: hit.windowFrame, context: ctx))
    }

    private func previewControl(_ control: WindowControl?) {
        guard let control, let hit, let ctx = context else { return showPreview(nil) }
        let steps = control.chainMode == .cycle ? Array(control.steps.prefix(1)) : control.steps
        showPreview(ControlPlanner.plan(steps, frame: hit.windowFrame, context: ctx))
    }

    private func previewDisplay(_ index: Int?) {
        guard let index, let hit, displays.indices.contains(index) else { return showPreview(nil) }
        showPreview(Placement.transfer(hit.windowFrame, from: displays[displayIndex], to: displays[index],
                                       spacing: settings.value.spacing))
    }

    private func moveToDisplay(_ index: Int) {
        guard let hit, displays.indices.contains(index) else { return }
        let target = Placement.transfer(hit.windowFrame, from: displays[displayIndex], to: displays[index],
                                        spacing: settings.value.spacing)
        let displays = self.displays
        commit { me, w in me.mover.place(w, at: target, displays: displays) }
    }

    /// Closes the palette, then moves the window (so the move isn't hidden behind the palette).
    private func commit(_ action: @escaping (PaletteController, WindowRef) -> MoveOutcome) {
        guard let window = hit?.window else { return }
        hide()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            _ = action(self, window)
        }
    }
}
