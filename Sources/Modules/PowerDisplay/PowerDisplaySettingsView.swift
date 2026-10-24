import AppKit
import MacToysCore
import SwiftUI

struct PowerDisplaySettingsView: View {
    let module: PowerDisplayModule
    @Bindable var s: Persisted<PowerDisplaySettings>
    var store: PowerDisplayStore
    @State private var editing: DisplayProfileRecord?
    @State private var renaming: Int?
    @State private var renameText = ""

    init(module: PowerDisplayModule) {
        self.module = module
        self.s = module.settings
        self.store = module.store
    }

    var body: some View {
        SettingsPage(module: module) {
            HeroCard(tint: .yellow) {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Brightness, contrast, volume and input for every display")
                            .font(.system(size: 14, weight: .semibold))
                        Text(store.hasScanned ? summary : "Looking for displays…")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Identify") { module.identify() }
                    Button("Open Power Display") { module.toggleFlyout(from: nil) }.buttonStyle(.borderedProminent)
                    Keycaps(s.value.activation)
                }
            }
        } content: {
            Section("Activation") {
                ShortcutRow("Activation shortcut", subtitle: "Opens the Displays flyout.", shortcut: $s.value.activation)
                Toggle(isOn: $s.value.showMenuBarIcon) {
                    RowLabel("Show in the menu bar", subtitle: "Click the sun to open the flyout.")
                }
                Picker(selection: $s.value.menuBarWheel) {
                    ForEach(WheelTarget.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: {
                    RowLabel("Menu bar icon mouse wheel", subtitle: "Scroll over the icon to change brightness.")
                }
                .disabled(!s.value.showMenuBarIcon)
                Picker(selection: $s.value.wheelIncrement) {
                    ForEach(PowerDisplaySettings.wheelIncrements, id: \.self) { Text("\($0)").tag($0) }
                } label: {
                    RowLabel("Mouse wheel increment", subtitle: "Per notch, for the menu bar icon and the flyout sliders.")
                }
            }

            Section("Flyout") {
                Toggle(isOn: $s.value.showProfileSwitcher) { RowLabel("Show profile switcher button") }
                Toggle(isOn: $s.value.showIdentifyButton) {
                    RowLabel("Show identify monitors button", subtitle: "Briefly shows each display's number on it.")
                }
            }

            Section {
                if store.monitors.isEmpty {
                    Text(store.hasScanned ? "No displays found." : "Looking for displays…").foregroundStyle(.secondary)
                }
                ForEach(store.monitors) { m in
                    MonitorSettingsRow(module: module, monitor: m)
                }
            } header: {
                HStack {
                    Text("Monitors")
                    Spacer()
                    Button("Rescan") { module.rescan() }.controlSize(.small).disabled(store.isRefreshing)
                }
            }

            Section("Profiles") {
                if s.value.profiles.isEmpty {
                    Text("Save brightness, contrast, volume and color presets of your displays as a profile, then apply it from the flyout, Light Switch or `mactoys powerdisplay apply-profile <id>`.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                ForEach(s.value.profiles) { p in profileRow(p) }
                HStack {
                    Button("Save Current Settings as Profile") { module.saveProfile() }
                        .disabled(store.monitors.isEmpty)
                    Spacer()
                }
            }

            Section("Custom VCP names") {
                VCPNamesEditor(settings: s, monitors: store.monitors)
            }

            Section("Advanced") {
                SliderRow("Monitor refresh delay", subtitle: "Wait after a display is connected or wakes before reading it again. Raise it if monitors are missed after hot-plug.",
                          value: $s.value.refreshDelay, in: 0...15, step: 1, format: { "\(Int($0)) s" })
                Toggle(isOn: $s.value.restoreOnLaunch) {
                    RowLabel("Restore monitor brightness and color temperature when Power Display launches")
                }
                Toggle(isOn: Binding(get: { s.value.maxCompatibility }, set: { on in
                    if on {
                        guard module.confirm("Turn on max compatibility mode?",
                                             "This ignores your monitors' capability strings and probes every control directly, with slower timing. Only use it if a monitor is missing.\n\n• The screen may briefly go black or lose signal.\n• The monitor may change brightness, contrast or input unexpectedly.\n• The monitor may stop answering DDC/CI until it's power-cycled.",
                                             button: "Turn On") else { return }
                    }
                    s.value.maxCompatibility = on
                    module.rescan()
                })) {
                    RowLabel("Max compatibility mode", subtitle: "Broader, slower discovery for monitors the standard path misses.")
                }
                Text("External monitors are controlled over DDC/CI on Apple silicon; the built-in display and Apple displays use macOS's own brightness control. Many USB-C/Thunderbolt docks and DisplayLink adapters don't pass DDC/CI through. Rotation isn't offered: macOS has no public API to rotate a display — use System Settings › Displays › Rotation.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        }
        .sheet(item: $editing) { profile in
            ProfileEditor(module: module, profile: profile) { editing = nil }
        }
    }

    private var summary: String {
        let controllable = store.monitors.filter { $0.snapshot.kind != .unsupported }.count
        let total = store.monitors.count
        return controllable == total ? "\(total) display\(total == 1 ? "" : "s") ready"
            : "\(controllable) of \(total) displays can be controlled"
    }

    @ViewBuilder
    private func profileRow(_ p: DisplayProfileRecord) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "bookmark.fill").foregroundStyle(Tint.yellow.color)
            if renaming == p.id {
                TextField("Name", text: $renameText)
                    .onSubmit {
                        let name = renameText.trimmingCharacters(in: .whitespaces)
                        if !name.isEmpty, let i = s.value.profiles.firstIndex(where: { $0.id == p.id }) { s.value.profiles[i].name = name }
                        renaming = nil
                    }
                    .frame(maxWidth: 220)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(p.name)
                    Text("ID \(p.id) · \(p.monitors.count) monitor\(p.monitors.count == 1 ? "" : "s")")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Apply") { module.applyProfile(id: p.id) }
            Menu {
                Button("Edit…") { editing = p }
                Button("Rename") { renameText = p.name; renaming = p.id }
                Button("Update with Current Settings") {
                    if let i = s.value.profiles.firstIndex(where: { $0.id == p.id }) {
                        s.value.profiles[i].monitors.merge(module.currentValues()) { _, new in new }
                    }
                }
                Divider()
                Button("Move Up") { s.update { $0.moveProfile(id: p.id, by: -1) } }
                    .disabled(s.value.profiles.first?.id == p.id)
                Button("Move Down") { s.update { $0.moveProfile(id: p.id, by: 1) } }
                    .disabled(s.value.profiles.last?.id == p.id)
                Divider()
                Button("Delete", role: .destructive) { s.value.profiles.removeAll { $0.id == p.id } }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
    }
}

/// One monitor in Settings: which controls appear, linking, hiding, and its VCP capabilities.
private struct MonitorSettingsRow: View {
    let module: PowerDisplayModule
    @Bindable var monitor: MonitorState
    @State private var showCaps = false

    private var prefs: MonitorPrefs { module.settings.value.prefs(monitor.id) }

    private func binding(_ key: WritableKeyPath<MonitorPrefs, Bool>, confirm: (String, String)? = nil) -> Binding<Bool> {
        Binding(get: { prefs[keyPath: key] }, set: { on in
            if on, let (title, message) = confirm {
                guard module.confirm(title, message, button: "Turn On") else { return }
            }
            module.settings.value.monitors[monitor.id, default: MonitorPrefs()][keyPath: key] = on
        })
    }

    var body: some View {
        let snap = monitor.snapshot
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                    Text("\(snap.number)").font(.system(size: 13, weight: .bold, design: .rounded))
                }
                .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(snap.name).fontWeight(.semibold)
                    Text(detail(snap)).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Hide monitor", isOn: binding(\.hidden)).toggleStyle(.checkbox)
            }
            if snap.kind == .unsupported {
                Text("MacToys can't talk to this display. DisplayLink, AirPlay and Sidecar displays, and some docks and adapters, don't support DDC/CI.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            } else if snap.kind == .ddc {
                controls(snap)
            }
            if snap.kind == .ddc {
                DisclosureGroup(isExpanded: $showCaps) {
                    capabilities(snap)
                } label: {
                    Text("VCP capabilities").font(.system(size: 12))
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func detail(_ snap: MonitorSnapshot) -> String {
        var parts = [snap.transport]
        if snap.rotation != 0 { parts.append("rotated \(snap.rotation)°") }
        let features = snap.supported.map(\.title)
        if !features.isEmpty { parts.append(features.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func controls(_ snap: MonitorSnapshot) -> some View {
        let columns = [GridItem(.adaptive(minimum: 180), alignment: .leading)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            if monitor.supports(.contrast) { Toggle("Contrast", isOn: binding(\.showContrast)).toggleStyle(.checkbox) }
            if monitor.supports(.volume) { Toggle("Volume", isOn: binding(\.showVolume)).toggleStyle(.checkbox) }
            if monitor.supports(.inputSource) {
                Toggle("Input source", isOn: binding(\.showInputSource, confirm: (
                    "Show input source control?",
                    "Switching inputs over DDC/CI can leave the screen black if the new input has no signal, and software control may be unavailable until you switch back with the monitor's buttons. Not every monitor exposes all inputs."
                ))).toggleStyle(.checkbox)
            }
            if monitor.supports(.colorTemperature) {
                Toggle("Color temperature", isOn: binding(\.showColorTemperature, confirm: (
                    "Show color temperature control?",
                    "Color presets are written over DDC/CI. Some monitors show wrong colors or behave unpredictably, and a few keep the new value after MacToys quits and may need a factory reset."
                ))).toggleStyle(.checkbox)
            }
            if monitor.supports(.powerState) {
                Toggle("Power state", isOn: binding(\.showPowerState, confirm: (
                    "Show power state control?",
                    "Power control puts the monitor in standby or turns it off over DDC/CI. On wakes supported monitors, but some don't wake from software: you may need the power button or to reseat the cable. Others don't restore their previous state."
                ))).toggleStyle(.checkbox)
            }
            if monitor.supports(.brightness) {
                Toggle("Exclude from linked brightness", isOn: binding(\.excludeFromLinkedBrightness)).toggleStyle(.checkbox)
            }
        }
        .font(.system(size: 12.5))
    }

    @ViewBuilder
    private func capabilities(_ snap: MonitorSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let caps = snap.capabilities {
                HStack(spacing: 14) {
                    if let model = caps.model { Text("Model \(model)") }
                    if let v = caps.mccsVersion { Text("MCCS \(v)") }
                    if let t = caps.type { Text("Type \(t)") }
                }
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                ForEach(caps.codes, id: \.self) { code in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(MCCS.hex(Int(code))).font(.system(size: 11.5, design: .monospaced)).frame(width: 40, alignment: .leading)
                        Text(MCCS.featureName(code)).font(.system(size: 12)).frame(width: 190, alignment: .leading)
                        let values = caps.vcp[code] ?? []
                        if !values.isEmpty {
                            Text(values.map { MCCS.hex(Int($0)) }.joined(separator: " "))
                                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
                Text(caps.raw).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary)
                    .textSelection(.enabled).lineLimit(6)
            } else {
                Text("This monitor didn't report a capabilities string; its controls were found by probing.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Button("Read Capabilities Again") { module.rereadCapabilities(monitor.id) }.controlSize(.small)
        }
        .padding(.top, 4)
    }
}

/// Edits the saved values of one profile; settings of disconnected monitors are kept.
private struct ProfileEditor: View {
    let module: PowerDisplayModule
    @State var profile: DisplayProfileRecord
    let done: () -> Void

    init(module: PowerDisplayModule, profile: DisplayProfileRecord, done: @escaping () -> Void) {
        self.module = module
        self._profile = State(initialValue: profile)
        self.done = done
    }

    private var monitorIDs: [String] {
        var ids = module.store.monitors.map(\.id)
        for id in profile.monitors.keys.sorted() where !ids.contains(id) { ids.append(id) }
        return ids
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Edit Profile").font(.title3.bold())
                TextField("Name", text: $profile.name).frame(maxWidth: 220)
                Spacer()
                Text("ID \(profile.id)").foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(monitorIDs, id: \.self) { id in monitorBlock(id) }
                }
            }
            .frame(minHeight: 260)
            Text("Clear a check box to stop the profile from changing that setting. Applying only touches what each connected monitor supports.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Save") {
                    let name = profile.name.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { profile.name = name }
                    profile.monitors = profile.monitors.filter { !$0.value.isEmpty }
                    if let i = module.settings.value.profiles.firstIndex(where: { $0.id == profile.id }) {
                        module.settings.value.profiles[i] = profile
                    }
                    done()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 500)
    }

    @ViewBuilder
    private func monitorBlock(_ id: String) -> some View {
        let state = module.store.monitors.first { $0.id == id }
        let name = state?.name ?? module.settings.value.prefs(id).lastName ?? id
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(name).fontWeight(.semibold)
                if state == nil { Text("Not connected").font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            percentRow("Brightness", id: id, key: \.brightness, available: state?.supports(.brightness) ?? true, current: state?.percent[.brightness])
            percentRow("Contrast", id: id, key: \.contrast, available: state?.supports(.contrast) ?? true, current: state?.percent[.contrast])
            percentRow("Volume", id: id, key: \.volume, available: state?.supports(.volume) ?? true, current: state?.percent[.volume])
            if state?.supports(.colorTemperature) ?? (profile.monitors[id]?.colorPreset != nil) {
                colorRow(id: id, state: state)
            }
        }
    }

    private func percentRow(_ title: String, id: String, key: WritableKeyPath<ProfileValues, Int?>, available: Bool, current: Double?) -> some View {
        let value = profile.monitors[id]?[keyPath: key]
        return HStack(spacing: 10) {
            Toggle(title, isOn: Binding(get: { value != nil }, set: { on in
                profile.monitors[id, default: ProfileValues()][keyPath: key] = on ? Int(current ?? 50) : nil
            }))
            .toggleStyle(.checkbox)
            .frame(width: 120, alignment: .leading)
            .disabled(!available && value == nil)
            Slider(value: Binding(get: { Double(value ?? 0) }, set: { profile.monitors[id, default: ProfileValues()][keyPath: key] = Int($0) }),
                   in: 0...100, step: 1)
                .disabled(value == nil)
            Text(value.map { "\($0)%" } ?? "—").monospacedDigit().frame(width: 44, alignment: .trailing).foregroundStyle(.secondary)
        }
    }

    private func colorRow(id: String, state: MonitorState?) -> some View {
        let value = profile.monitors[id]?.colorPreset
        let options = state?.snapshot.options[.colorTemperature] ?? (value.map { [UInt16(clamping: $0)] } ?? [])
        let s = module.settings.value
        return HStack(spacing: 10) {
            Toggle("Color preset", isOn: Binding(get: { value != nil }, set: { on in
                profile.monitors[id, default: ProfileValues()].colorPreset = on ? Int(state?.discrete[.colorTemperature] ?? options.first ?? 5) : nil
            }))
            .toggleStyle(.checkbox)
            .frame(width: 120, alignment: .leading)
            Picker("", selection: Binding(get: { value ?? 0 }, set: { profile.monitors[id, default: ProfileValues()].colorPreset = $0 })) {
                ForEach(options, id: \.self) { v in Text(s.valueName(.colorTemperature, v, monitor: id)).tag(Int(v)) }
            }
            .labelsHidden()
            .disabled(value == nil)
            .frame(maxWidth: 200)
        }
    }
}

/// Custom display names for input sources (0x60) and color presets (0x14), per monitor or for all.
private struct VCPNamesEditor: View {
    @Bindable var settings: Persisted<PowerDisplaySettings>
    let monitors: [MonitorState]
    @State private var code = 0x60
    @State private var valueText = ""
    @State private var name = ""
    @State private var scope: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Rename input sources and color presets, for one monitor or all of them. Values are the hex codes listed under VCP capabilities.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            ForEach(settings.value.vcpNames) { m in
                HStack(spacing: 10) {
                    Text(m.code == 0x60 ? "Input" : "Color").frame(width: 50, alignment: .leading)
                    Text(MCCS.hex(m.value)).font(.system(size: 12, design: .monospaced)).frame(width: 46, alignment: .leading)
                    Text("→ \(m.name)")
                    Spacer()
                    Text(scopeName(m.monitorID)).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    Button { settings.value.vcpNames.removeAll { $0.id == m.id } } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 8) {
                Picker("", selection: $code) {
                    Text("Input source").tag(0x60)
                    Text("Color preset").tag(0x14)
                }
                .labelsHidden().frame(width: 130)
                TextField("0x0F", text: $valueText).frame(width: 60)
                TextField("Name", text: $name).frame(width: 130)
                Picker("", selection: $scope) {
                    Text("All monitors").tag("")
                    ForEach(monitors) { m in Text(m.name).tag(m.id) }
                }
                .labelsHidden().frame(width: 150)
                Button("Add") {
                    guard let v = parsedValue, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    settings.value.vcpNames.append(VCPNameMapping(code: code, value: v, name: name.trimmingCharacters(in: .whitespaces),
                                                                  monitorID: scope.isEmpty ? nil : scope))
                    valueText = ""
                    name = ""
                }
                .disabled(parsedValue == nil || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private var parsedValue: Int? {
        let t = valueText.trimmingCharacters(in: .whitespaces).lowercased()
        let hex = t.hasPrefix("0x") ? String(t.dropFirst(2)) : t
        guard let v = Int(hex, radix: 16), (0...0xFFFF).contains(v) else { return nil }
        return v
    }

    private func scopeName(_ id: String?) -> String {
        guard let id else { return "All monitors" }
        return monitors.first { $0.id == id }?.name ?? settings.value.prefs(id).lastName ?? id
    }
}
