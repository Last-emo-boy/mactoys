import AppKit
import MacToysCore
import SwiftUI

/// Menu bar flyout (`design/exports/05-menubar-flyouts-huds.png`, right).
struct QuickAccessView: View {
    @State private var registry = ModuleRegistry.shared
    @State private var showsMore = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let layout = FlyoutLayout(actions: registry.quickActions, general: registry.general.value)
        let tiles = layout.tiles
        let switches = layout.switches
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
            if !switches.isEmpty || !layout.moreSwitches.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(switches.enumerated()), id: \.element.id) { i, a in
                        if i > 0 { Divider().opacity(0.5) }
                        SwitchRow(action: a)
                    }
                    if !layout.moreSwitches.isEmpty {
                        if !switches.isEmpty { Divider().opacity(0.5) }
                        moreRow(count: layout.moreSwitches.count)
                        if showsMore {
                            Divider().opacity(0.5)
                            ScrollView {
                                VStack(spacing: 0) {
                                    ForEach(Array(layout.moreSwitches.enumerated()), id: \.element.id) { i, a in
                                        if i > 0 { Divider().opacity(0.5) }
                                        SwitchRow(action: a)
                                    }
                                }
                            }
                            .frame(maxHeight: 300)
                            .transition(.opacity)
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.5)))
            }
            HStack {
                Text("\(registry.enabledCount) of \(registry.modules.count) utilities on")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                Spacer()
                Button(String(localized: "Customize…", comment: "Menu bar flyout: choose its tiles and switches")) { open("general") }
                    .buttonStyle(.link).font(.system(size: 12))
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
                // Long names (German compounds) wrap or shrink a little rather than lose their end.
                Text(verbatim: a.title).font(.system(size: 11.5, weight: .medium))
                    .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.75).allowsTightening(true)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.5)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(a.shortcut.map { "\(a.title) — \($0)" } ?? a.title)
    }

    private func moreRow(count: Int) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { showsMore.toggle() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "switch.2").frame(width: 18).foregroundStyle(.secondary)
                Text("More Switches", comment: "Menu bar flyout: show the switches not listed above").fontWeight(.medium)
                Text(verbatim: count.formatted()).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(.quaternary))
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(showsMore ? 90 : 0))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                Text(verbatim: action.title).fontWeight(.medium)
                if let d = action.detail?() ?? action.shortcut?.description {
                    Text(verbatim: d).font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Toggle("", isOn: Binding(get: { on }, set: { _ in action.perform(); tick += 1 }))
                .toggleStyle(.adaptiveSwitch).labelsHidden().controlSize(.small)
        }
        .id(tick)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

/// The flyout's tiles and switches from the enabled utilities' quick actions (see `QuickAccessLayout`).
struct FlyoutLayout {
    let tiles: [QuickAction]
    let switches: [QuickAction]
    let moreTiles: [QuickAction]
    let moreSwitches: [QuickAction]

    init(actions: [QuickAction], general: GeneralSettings) {
        let tileActions = actions.filter { $0.isOn == nil }
        let switchActions = actions.filter { $0.isOn != nil }
        let byID = Dictionary(actions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let t = QuickAccessLayout.split(available: tileActions.map(\.id), chosen: general.menuBarTiles,
                                        defaults: QuickAccessLayout.defaultTiles, limit: QuickAccessLayout.tileCount)
        let s = QuickAccessLayout.split(available: switchActions.map(\.id), chosen: general.menuBarSwitches,
                                        defaults: QuickAccessLayout.defaultSwitches, limit: QuickAccessLayout.switchCount)
        tiles = t.shown.compactMap { byID[$0] }
        moreTiles = t.more.compactMap { byID[$0] }
        switches = s.shown.compactMap { byID[$0] }
        moreSwitches = s.more.compactMap { byID[$0] }
    }
}
