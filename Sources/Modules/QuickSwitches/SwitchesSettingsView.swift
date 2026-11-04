import AppKit
import MacToysCore
import SwiftUI

/// One tile of the switches grid (live from the engine, or sample data in previews).
struct SwitchTile: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let tint: Tint
    let isToggle: Bool
    let isOn: Bool
    let detail: String?
    let action: () -> Void
}

extension SwitchEngine {
    /// Tiles for the enabled switches, with their current state.
    func tiles() -> [SwitchTile] {
        let s = settings.value
        var out: [SwitchTile] = []
        for kind in SwitchKind.allCases where s.isEnabled(kind) {
            if kind == .bluetooth {
                for d in devices() {
                    out.append(SwitchTile(id: "bt.\(d.id)", title: d.name, symbol: d.kind.symbol, tint: .blue, isToggle: true,
                                          isOn: d.connected,
                                          detail: isConnecting(d.id) ? String(localized: "Connecting…") : nil,
                                          action: { [weak self] in self?.setDevice(d.id, connected: !d.connected) }))
                }
                continue
            }
            out.append(SwitchTile(id: kind.rawValue, title: kind.title, symbol: kind.symbol, tint: kind.tint, isToggle: kind.isToggle,
                                  isOn: kind.isToggle && isOn(kind), detail: detail(kind),
                                  action: { [weak self] in self?.activate(kind) }))
        }
        return out
    }
}

/// The switches as tiles: a tinted circle when on, the name and the state under it.
struct SwitchesGrid: View {
    let tiles: [SwitchTile]
    var columns = 4

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: columns), spacing: 10) {
            ForEach(tiles) { tile in SwitchTileView(tile: tile) }
        }
    }
}

private struct SwitchTileView: View {
    let tile: SwitchTile
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: tile.action) {
            VStack(spacing: 8) {
                ZStack {
                    Circle().fill(tile.isOn ? AnyShapeStyle(tile.tint.gradient) : AnyShapeStyle(Color.primary.opacity(scheme == .dark ? 0.14 : 0.08)))
                    Image(systemName: tile.symbol)
                        .font(.system(size: 16, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(tile.isOn ? Color.white : Color.primary.opacity(0.75))
                }
                .frame(width: 40, height: 40)
                VStack(spacing: 2) {
                    Text(verbatim: tile.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                    Text(verbatim: stateText)
                        .font(.system(size: 10.5))
                        .foregroundStyle(tile.isOn ? AnyShapeStyle(tile.tint.color) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
                .frame(maxHeight: .infinity)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 6)
            // One height for every tile, so a two-line title doesn't make a ragged row.
            .frame(maxWidth: .infinity)
            .frame(height: 118, alignment: .top)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(scheme == .dark ? Color.white.opacity(0.06) : Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(tile.isOn ? tile.tint.color.opacity(0.45) : Color.primary.opacity(0.08)))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: tile.title))
        .accessibilityValue(Text(verbatim: stateText))
    }

    private var stateText: String {
        if let detail = tile.detail { return detail }
        guard tile.isToggle else { return String(localized: "Run", comment: "Quick switch tile: an action, not an on/off switch") }
        return tile.isOn ? String(localized: "On", comment: "Quick switch state") : String(localized: "Off", comment: "Quick switch state")
    }
}

/// A row as the MacToys menu bar flyout draws switches (for the preview scene).
struct FlyoutSwitchRow: View {
    let tile: SwitchTile

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: tile.symbol).frame(width: 18).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: tile.title).fontWeight(.medium)
                if let d = tile.detail { Text(verbatim: d).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            Spacer()
            Toggle("", isOn: .constant(tile.isOn)).toggleStyle(.adaptiveSwitch).labelsHidden().controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

struct SwitchesSettingsView: View {
    let module: QuickSwitchesModule
    @Bindable var s: Persisted<SwitchesSettings>
    @State private var shortcutNames: [String] = []
    @State private var loadingShortcuts = false

    init(module: QuickSwitchesModule) {
        self.module = module
        self.s = module.settings
    }

    var body: some View {
        SettingsPage(module: module) {
            HeroCard(tint: .blue) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Your switches").font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Text("Also in the MacToys menu bar menu. Click one to flip it.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    TimelineView(.periodic(from: .now, by: 2)) { _ in
                        let tiles = module.engine.tiles()
                        if tiles.isEmpty {
                            Text("Turn on switches below to see them here.").font(.system(size: 12)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 80)
                        } else {
                            SwitchesGrid(tiles: tiles, columns: 5)
                        }
                    }
                }
            }
        } content: {
            Section {
                ForEach(SwitchKind.allCases) { kind in
                    SwitchSettingRow(kind: kind, settings: s)
                }
            } header: {
                Text("Switches")
            } footer: {
                Text("Night Shift isn’t here: macOS gives apps no public way to turn it on or off. Use Control Center or System Settings › Displays.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Clean Keyboard") {
                SliderRow("Lock the keyboard for", subtitle: "Every key, including media and brightness keys, is ignored. Needs Accessibility access.",
                          value: Binding(get: { Double(s.value.cleanSeconds) }, set: { s.value.cleanSeconds = Int($0) }),
                          in: Double(SwitchesSettings.cleanRange.lowerBound)...Double(SwitchesSettings.cleanRange.upperBound), step: 5,
                          format: { Duration.seconds(Int($0)).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated)) })
                LabeledContent {
                    Button("Start Now") { module.engine.perform(.cleanKeyboard) }
                } label: {
                    RowLabel(title: Text("Clean the keyboard now"),
                             subtitle: Text("Press esc three times to stop early."))
                }
            }

            Section("Do Not Disturb") {
                Picker(selection: $s.value.focusOnShortcut) {
                    Text("None", comment: "No shortcut chosen").tag(String?.none)
                    ForEach(shortcutNames, id: \.self) { Text(verbatim: $0).tag(Optional($0)) }
                } label: {
                    RowLabel("Shortcut that turns Focus on",
                             subtitle: "In the Shortcuts app, make a shortcut with the Set Focus action (for example Do Not Disturb, Turn On).")
                }
                Picker(selection: $s.value.focusOffShortcut) {
                    Text("Same shortcut", comment: "Run the same shortcut to turn Focus off (it toggles)").tag(String?.none)
                    ForEach(shortcutNames, id: \.self) { Text(verbatim: $0).tag(Optional($0)) }
                } label: {
                    RowLabel("Shortcut that turns Focus off", subtitle: "Leave it on Same shortcut if yours toggles the Focus.")
                }
                HStack {
                    Button("Open Shortcuts") {
                        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.shortcuts") {
                            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                        }
                    }
                    Button("Reload List") { Task { await loadShortcuts() } }
                    if loadingShortcuts { ProgressView().controlSize(.small) }
                    Spacer()
                }
                Text("macOS doesn’t tell apps whether a Focus is on, so the switch shows what it last set unless MacToys has Full Disk Access.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            BluetoothSection(module: module)

            Section("Feedback") {
                Toggle(isOn: $s.value.showHUD) {
                    RowLabel("Show a confirmation when a switch changes", subtitle: "Errors are always shown.")
                }
            }
        }
        .task { await loadShortcuts() }
    }

    private func loadShortcuts() async {
        loadingShortcuts = true
        shortcutNames = await FocusShortcuts.list()
        loadingShortcuts = false
    }
}

/// A switch row: its icon and explanation, a shortcut, and whether it's in the menu bar menu.
private struct SwitchSettingRow: View {
    let kind: SwitchKind
    @Bindable var settings: Persisted<SwitchesSettings>

    var body: some View {
        LabeledContent {
            HStack(spacing: 12) {
                ShortcutRecorder(shortcut: Binding(get: { settings.value.shortcuts[kind.rawValue] },
                                                   set: { settings.value.shortcuts[kind.rawValue] = $0 }))
                Toggle("Show in the menu", isOn: Binding(get: { settings.value.isEnabled(kind) },
                                                         set: { settings.value.enabled[kind.rawValue] = $0 }))
                    .toggleStyle(.adaptiveSwitch)
                    .labelsHidden()
                    .accessibilityLabel(Text("Show \(kind.title) in the menu", comment: "Accessibility label; the placeholder is a switch name"))
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                ModuleIcon(symbol: kind.symbol, tint: kind.tint, size: 24)
                RowLabel(title: Text(verbatim: kind.title), subtitle: Text(verbatim: kind.subtitle))
            }
        }
    }
}

private struct BluetoothSection: View {
    let module: QuickSwitchesModule
    @Bindable var settings: Persisted<SwitchesSettings>

    init(module: QuickSwitchesModule) {
        self.module = module
        self.settings = module.settings
    }

    var body: some View {
        Section("Bluetooth devices") {
            if !BluetoothDevices.isAvailable {
                InfoBar(.info, title: Text("Bluetooth isn’t available in this build"),
                        message: Text("This copy of MacToys can’t use Bluetooth. Connect devices from Control Center."))
            } else {
                TimelineView(.periodic(from: .now, by: 3)) { _ in
                    let devices = module.engine.bluetooth.paired()
                    if devices.isEmpty {
                        Text("No paired devices. Pair headphones and other devices in System Settings › Bluetooth.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            RowLabel("Show as switches", subtitle: "Until you pick some, every paired audio device is shown.")
                            ForEach(devices) { d in
                                HStack(spacing: 10) {
                                    Toggle(isOn: pinned(d.id, devices: devices)) {
                                        HStack(spacing: 8) {
                                            Image(systemName: d.kind.symbol).frame(width: 20).foregroundStyle(.secondary)
                                            Text(verbatim: d.name)
                                        }
                                    }
                                    .toggleStyle(.checkbox)
                                    Spacer()
                                    Text(d.connected ? "Connected" : "Not connected", comment: "Bluetooth device state")
                                        .font(.system(size: 12)).foregroundStyle(d.connected ? Tint.green.color : .secondary)
                                    Button(d.connected ? "Disconnect" : "Connect") {
                                        module.engine.setDevice(d.id, connected: !d.connected)
                                    }
                                    .disabled(module.engine.isConnecting(d.id))
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func pinned(_ id: String, devices: [BluetoothDeviceInfo]) -> Binding<Bool> {
        Binding(get: { BluetoothDeviceInfo.shown(devices, pinned: settings.value.bluetoothPinned).contains { $0.id == id } },
                set: { on in
                    var list = settings.value.bluetoothPinned ?? BluetoothDeviceInfo.shown(devices, pinned: nil).map(\.id)
                    if on { if !list.contains(id) { list.append(id) } } else { list.removeAll { $0 == id } }
                    settings.value.bluetoothPinned = list
                })
    }
}
