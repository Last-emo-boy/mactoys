import AppKit
import MacToysCore
import SwiftUI

/// Shows the pill in a click-through panel over the target display, hides it after the set time,
/// and runs the drag-to-place editor.
@MainActor
final class KeystrokePanel {
    let model: KeystrokeOverlayModel
    private var panel: OverlayPanel?
    private var hideWork: DispatchWorkItem?
    private var removeWork: DispatchWorkItem?
    private var editor: OverlayPanel?

    init(model: KeystrokeOverlayModel) {
        self.model = model
    }

    /// Shows the pill (or keeps it up) and restarts the hide timer.
    func present() {
        let frame = targetScreen().visibleFrame
        let p = panel ?? makePanel(frame)
        if p.frame != frame { p.setFrame(frame, display: false) }
        removeWork?.cancel()
        if !p.isVisible { p.orderFrontRegardless() }
        if !model.visible { model.visible = true }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fadeOut() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + min(max(model.settings.duration, 0.5), 10), execute: work)
    }

    /// Hides at once and forgets what was shown.
    func dismiss() {
        hideWork?.cancel()
        removeWork?.cancel()
        model.visible = false
        model.feed.clear()
        panel?.orderOut(nil)
    }

    func teardown() {
        dismiss()
        panel?.close()
        panel = nil
        closeEditor()
    }

    private func fadeOut() {
        model.visible = false
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.model.visible else { return }
            // Nothing typed lingers once it's off screen.
            self.model.feed.clear()
            self.panel?.orderOut(nil)
        }
        removeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func makePanel(_ frame: CGRect) -> OverlayPanel {
        let p = OverlayPanel(frame: frame, interactive: false, acceptsKey: false, level: .screenSaver)
        p.isExcludedFromWindowsMenu = true
        p.setContent(KeystrokeOverlayRoot(model: model))
        panel = p
        return p
    }

    private func targetScreen() -> NSScreen {
        switch model.settings.screen {
        case .pointer: NSScreen.underMouse ?? NSScreen.screens.first ?? NSScreen.main!
        case .main: NSScreen.screens.first ?? NSScreen.main!
        }
    }

    // MARK: Position editor

    /// Lets the user drag a sample pill where it should appear; calls `onDone` with its center as
    /// fractions of the screen.
    func editPosition(onDone: @escaping (CGPoint) -> Void) {
        closeEditor()
        dismiss()
        let screen = targetScreen()
        let s = model.settings
        let start = s.position == .custom ? CGPoint(x: s.customX, y: s.customY) : Self.center(of: s.position, in: screen.visibleFrame.size)
        let p = OverlayPanel(frame: screen.visibleFrame, interactive: true, acceptsKey: true, level: .screenSaver)
        p.appearance = NSAppearance(named: .darkAqua)   // controls on dark glass
        p.setContent(PositionEditorView(settings: s, start: start, onDone: { [weak self] point in
            onDone(point)
            self?.closeEditor()
        }, onCancel: { [weak self] in self?.closeEditor() }))
        editor = p
        p.present()
    }

    private func closeEditor() {
        editor?.orderOut(nil)
        editor?.close()
        editor = nil
    }

    /// Approximate center of a preset position, so the editor starts where the pill is now.
    static func center(of position: KeystrokeSettings.Position, in size: CGSize) -> CGPoint {
        let m = OverlayPlacement.margin + 30
        let x: CGFloat, y: CGFloat
        switch position {
        case .bottomLeading, .topLeading: x = min(0.5, (m + 120) / max(size.width, 1))
        case .bottomTrailing, .topTrailing: x = max(0.5, 1 - (m + 120) / max(size.width, 1))
        default: x = 0.5
        }
        switch position {
        case .topCenter, .topLeading, .topTrailing: y = m / max(size.height, 1)
        default: y = 1 - m / max(size.height, 1)
        }
        return CGPoint(x: x, y: y)
    }
}

/// Full-screen editor: a sample pill to drag, with Done and Cancel.
struct PositionEditorView: View {
    let settings: KeystrokeSettings
    let onDone: (CGPoint) -> Void
    let onCancel: () -> Void
    @State private var center: CGPoint
    @State private var dragStart: CGPoint?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(settings: KeystrokeSettings, start: CGPoint, onDone: @escaping (CGPoint) -> Void, onCancel: @escaping () -> Void) {
        self.settings = settings
        self.onDone = onDone
        self.onCancel = onCancel
        _center = State(initialValue: start)
    }

    var body: some View {
        let style = PillStyle(theme: settings.theme, size: settings.size, reduceTransparency: reduceTransparency)
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(0.3)
                KeystrokePill(items: KeystrokeSamples.feed(settings.mode, size: settings.size).items, style: style)
                    .padding(8)
                    .overlay(RoundedRectangle(cornerRadius: style.pillRadius + 8, style: .continuous)
                        .strokeBorder(.white.opacity(0.85), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
                    .contentShape(Rectangle())
                    .position(x: geo.size.width * center.x, y: geo.size.height * center.y)
                    .gesture(DragGesture().onChanged { value in
                        let origin = dragStart ?? center
                        dragStart = origin
                        center = Self.clamp(CGPoint(x: origin.x + value.translation.width / max(geo.size.width, 1),
                                                    y: origin.y + value.translation.height / max(geo.size.height, 1)))
                    }.onEnded { _ in dragStart = nil })
                    .onHover { inside in if inside { NSCursor.openHand.set() } else { NSCursor.arrow.set() } }
                VStack {
                    GlassPanel(cornerRadius: 20) {
                        HStack(spacing: 14) {
                            Image(systemName: "hand.draw.fill")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(Color(nsColor: Tint.yellow.nsColor))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Drag the keystrokes where they should appear").font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.white)
                                Text("The same spot is used on every display.").font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.65))
                            }
                            .fixedSize()
                            Spacer(minLength: 16)
                            Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                            Button("Done") { onDone(center) }
                                .keyboardShortcut(.defaultAction)
                                .buttonStyle(.borderedProminent)
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 14)
                    }
                    .fixedSize()
                    .padding(.top, 36)
                    Spacer()
                }
            }
        }
    }

    static func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0.04), 0.96), y: min(max(p.y, 0.04), 0.96))
    }
}
