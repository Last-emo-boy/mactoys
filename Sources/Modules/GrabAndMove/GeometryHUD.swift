import AppKit
import MacToysCore
import SwiftUI

@MainActor
@Observable
final class GeometryReadoutModel {
    var frame: CGRect = .zero
    var resizing = false
}

/// The glass geometry readout (design 05): "✥  x 412  y 188  ·  1280 × 820".
struct GeometryReadout: View {
    let model: GeometryReadoutModel

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: model.resizing ? "arrow.up.left.and.arrow.down.right" : "arrow.up.and.down.and.arrow.left.and.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
            Text(verbatim: GrabGeometry.readout(model.frame))
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .background(Color(red: 0.11, green: 0.11, blue: 0.13).opacity(0.82), in: .rect(cornerRadius: 10))
        .glassEffect(.regular, in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.13)))
        .environment(\.colorScheme, .dark)
        .fixedSize()
    }
}

/// A click-through panel that follows the pointer with the window's position and size.
@MainActor
final class GeometryHUD {
    private var panel: OverlayPanel?
    private let model = GeometryReadoutModel()
    private static let size = CGSize(width: 330, height: 52)

    /// Shows or moves the readout next to `pointer` (top-left coordinates).
    func show(_ frame: CGRect, resizing: Bool, near pointer: CGPoint) {
        if model.frame != frame { model.frame = frame }
        if model.resizing != resizing { model.resizing = resizing }
        let p = panel ?? makePanel()
        let screen = ScreenGeometry.screen(containingAX: pointer)?.axFrame ?? ScreenGeometry.desktopAXFrame
        let s = Self.size
        var x = pointer.x + 16, y = pointer.y + 22
        if x + s.width > screen.maxX { x = pointer.x - s.width - 8 }
        if y + s.height > screen.maxY { y = pointer.y - s.height - 12 }
        let target = ScreenGeometry.toCocoa(CGRect(x: x, y: y, width: s.width, height: s.height))
        if p.frame != target { p.setFrame(target, display: false) }
        if !p.isVisible { p.orderFrontRegardless() }
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func tearDown() {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }

    private func makePanel() -> OverlayPanel {
        let p = OverlayPanel(frame: CGRect(origin: .zero, size: Self.size), level: .popUpMenu)
        p.setContent(GeometryReadout(model: model).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
        panel = p
        return p
    }
}
