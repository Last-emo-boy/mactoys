import AppKit
import MacToysCore
import SwiftUI

/// Menu bar flyout (`design/exports/05-menubar-flyouts-huds.png`, right).
struct QuickAccessView: View {
    @State private var registry = ModuleRegistry.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let actions = registry.quickActions
        let tiles = Array(actions.filter { $0.isOn == nil }.prefix(9))
        let switches = actions.filter { $0.isOn != nil }
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                AppMark(size: 26)
                Text("MacToys").font(.system(size: 14, weight: .bold))
                Spacer()
                iconButton("gearshape") { open(nil) }
                iconButton("power") { NSApp.terminate(nil) }
            }
            if tiles.isEmpty {
                Text("No utilities with quick actions are on.").foregroundStyle(.secondary).font(.callout)
            } else {
                Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                    ForEach(0..<Int(ceil(Double(tiles.count) / 3)), id: \.self) { row in
                        GridRow {
                            ForEach(tiles[(row * 3)..<min(row * 3 + 3, tiles.count)]) { a in tile(a) }
                        }
                    }
                }
            }
            if !switches.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(switches.enumerated()), id: \.element.id) { i, a in
                        if i > 0 { Divider().opacity(0.5) }
                        SwitchRow(action: a)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.5)))
            }
            HStack {
                Text("\(registry.enabledCount) of \(registry.modules.count) utilities on")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                Spacer()
                Button("Open Settings…") { open(nil) }.buttonStyle(.link).font(.system(size: 12, weight: .semibold))
            }
        }
        .padding(14)
        .frame(width: 380)
    }

    private func tile(_ a: QuickAction) -> some View {
        Button {
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { a.perform() }
        } label: {
            VStack(spacing: 8) {
                ModuleIcon(symbol: a.symbol, tint: a.tint, size: 30)
                Text(a.title).font(.system(size: 11.5, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.5)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(a.shortcut.map { "\(a.title) — \($0)" } ?? a.title)
    }

    private func iconButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13)).frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(.quaternary.opacity(0.6)))
        }
        .buttonStyle(.plain)
    }

    private func open(_ page: String?) {
        dismiss()
        SettingsWindow.shared.show(page: page)
    }
}

private struct SwitchRow: View {
    let action: QuickAction
    @State private var tick = 0

    var body: some View {
        let on = action.isOn?() ?? false
        HStack(spacing: 10) {
            Image(systemName: action.symbol).frame(width: 18).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(action.title).fontWeight(.medium)
                if let d = action.detail?() ?? action.shortcut?.description { Text(d).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            Spacer()
            Toggle("", isOn: Binding(get: { on }, set: { _ in action.perform(); tick += 1 }))
                .toggleStyle(.switch).labelsHidden().controlSize(.small)
        }
        .id(tick)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}
