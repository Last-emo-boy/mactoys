import AppKit
import MacToysCore
import SwiftUI

/// The gesture cheat sheet: every gesture that is on, grouped by where it's made, drawn on a
/// small trackpad each.
struct CheatSheetView: View {
    let entries: [GestureEntry]
    var onSettings: (() -> Void)?

    private var titleBar: [GestureEntry] { entries.filter { $0.place == .titleBar } }
    private var dock: [GestureEntry] { entries.filter { $0.place == .dock } }
    private var menuBar: [GestureEntry] { entries.filter { $0.place == .menuBar } }

    var body: some View {
        GlassPanel(cornerRadius: 22) {
            VStack(alignment: .leading, spacing: 18) {
                header
                if entries.isEmpty {
                    ContentUnavailableView {
                        Label("No gestures are on", systemImage: "hand.raised.slash")
                    } description: {
                        Text("Choose what each gesture does in Window Gestures settings.")
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    HStack(alignment: .top, spacing: 28) {
                        column(Text("On a title bar"), symbol: "macwindow", titleBar)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        if !dock.isEmpty || !menuBar.isEmpty {
                            VStack(alignment: .leading, spacing: 22) {
                                if !dock.isEmpty { column(Text("On a Dock icon"), symbol: "dock.rectangle", dock) }
                                if !menuBar.isEmpty { column(Text("On the menu bar"), symbol: "menubar.rectangle", menuBar) }
                                tip
                            }
                            .frame(width: 300, alignment: .topLeading)
                        }
                    }
                }
            }
            .padding(24)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ModuleIcon(symbol: "hand.draw.fill", tint: .cyan, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("Window Gestures").font(.system(size: 19, weight: .bold)).kerning(-0.3)
                Text("Two fingers on the trackpad. A preview shows where the window goes before you lift them.")
                    .font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if let onSettings {
                Button(action: onSettings) {
                    Label("Settings…", systemImage: "gearshape")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(.white.opacity(0.1)))
                        .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .foregroundStyle(.white)
    }

    private func column(_ title: Text, symbol: String, _ items: [GestureEntry]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label { title } icon: { Image(systemName: symbol) }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Tint.cyan.color.mix(with: .white, by: 0.35))
                .padding(.bottom, 6)
            ForEach(items) { e in
                row(e)
                if e.id != items.last?.id { Rectangle().fill(.white.opacity(0.07)).frame(height: 1).padding(.leading, 56) }
            }
        }
    }

    private func row(_ e: GestureEntry) -> some View {
        HStack(spacing: 12) {
            GestureGlyph(kind: e.glyph, width: 44, tint: Tint.cyan.color, onGlass: true)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: e.title).font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                if let detail = e.detail {
                    Text(verbatim: detail).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.55))
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Keycaps(e.keys, dark: true)
        }
        .padding(.vertical, 5)
    }

    private var tip: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lightbulb").font(.system(size: 12, weight: .semibold)).foregroundStyle(.yellow.opacity(0.85))
            Text("Scrolling in a window's content is never touched: only the title bar and toolbar take gestures.")
                .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.05)))
    }
}

/// Shows the cheat sheet in a floating panel; esc or a click elsewhere closes it.
@MainActor
final class CheatSheetController {
    private var panel: FloatingPanel?

    var isVisible: Bool { panel?.isVisible == true }

    func toggle(_ entries: [GestureEntry]) {
        if isVisible { close() } else { show(entries) }
    }

    func show(_ entries: [GestureEntry]) {
        let view = CheatSheetView(entries: entries) { [weak self] in
            self?.close()
            ModuleRegistry.shared.showSettings?("gestures")
        }
        let p = panel ?? FloatingPanel(size: CGSize(width: 860, height: 560))
        p.setContent(view.fixedSize(horizontal: false, vertical: true).frame(width: 860))
        if let host = p.contentView { p.setContentSize(host.fittingSize) }
        panel = p
        p.show(verticalFraction: 0.16)
    }

    func close() {
        guard let panel, panel.isVisible else { return }
        panel.dismiss()
    }

    func tearDown() {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }
}
