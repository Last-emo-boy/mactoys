import AppKit
import MacToysCore
import SwiftUI

/// The settings hero: the displays as they are arranged, drawn small, each showing its
/// resolution and how bright it is set.
struct DisplayArrangementDiagram: View {
    let module: PowerDisplayModule

    struct Item: Identifiable {
        var id: CGDirectDisplayID
        var number: Int
        var name: String
        var bounds: CGRect
        var isMain: Bool
        var builtIn: Bool
        var mode: String
        /// 0…1 for the tint; nil when unknown.
        var light: Double?
    }

    /// Displays from the last scan; the live arrangement before one (and in snapshots).
    private var items: [Item] {
        let monitors = module.store.monitors.filter { !$0.facts.bounds.isEmpty && $0.facts.mirrorOf == nil }
        if !monitors.isEmpty {
            return monitors.map { m in
                let c = m.components
                let light = m.supports(.brightness) || c.dim > 0 ? min(1.2, (c.hardware / 100) * (1 - c.dim * 0.8) + c.boost * 0.2) : nil
                return Item(id: m.snapshot.displayID, number: m.snapshot.number, name: m.name, bounds: m.facts.bounds,
                            isMain: m.facts.isMain, builtIn: m.snapshot.kind == .builtIn,
                            mode: m.modes?.current?.resolution.title ?? "", light: light)
            }
        }
        return Self.liveItems()
    }

    static func liveItems() -> [Item] {
        let names = DisplayEngine.screenNames()
        let ids = DisplayArranger.activeDisplays().filter { DisplayArranger.mirrorSource(of: $0) == nil }
        let sorted = ids.sorted { a, b in
            let ba = CGDisplayIsBuiltin(a) != 0, bb = CGDisplayIsBuiltin(b) != 0
            if ba != bb { return ba }
            return CGDisplayBounds(a).minX < CGDisplayBounds(b).minX
        }
        return sorted.enumerated().map { i, id in
            Item(id: id, number: i + 1, name: names[id] ?? String(localized: "Display \(i + 1)"), bounds: CGDisplayBounds(id),
                 isMain: CGDisplayIsMain(id) != 0, builtIn: CGDisplayIsBuiltin(id) != 0,
                 mode: DisplayModeReader.current(id)?.resolution.title ?? "", light: nil)
        }
    }

    /// "2 displays connected" for the hero before the first scan.
    static func liveSummary() -> String {
        String(localized: "\(liveItems().count) displays connected", comment: "Power Display hero: number of connected displays")
    }

    var body: some View {
        GeometryReader { geo in
            let list = items
            let union = list.map(\.bounds).reduce(CGRect.null) { $0.union($1) }
            let scale = union.isNull ? 1 : min((geo.size.width - 8) / union.width, (geo.size.height - 8) / union.height)
            let offset = CGPoint(x: (geo.size.width - union.width * scale) / 2 - union.minX * scale,
                                 y: (geo.size.height - union.height * scale) / 2 - union.minY * scale)
            ZStack(alignment: .topLeading) {
                ForEach(list) { item in
                    screen(item, size: CGSize(width: item.bounds.width * scale - 4, height: item.bounds.height * scale - 4))
                        .offset(x: item.bounds.minX * scale + offset.x + 2, y: item.bounds.minY * scale + offset.y + 2)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Display arrangement"))
    }

    private func screen(_ item: Item, size: CGSize) -> some View {
        let light = item.light ?? 0.85
        return ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.2, green: 0.3, blue: 0.7), Color(red: 0.62, green: 0.32, blue: 0.62),
                                              Color(red: 0.95, green: 0.6, blue: 0.45)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.black.opacity(max(0, 0.7 - light * 0.7))))
            if item.isMain {
                UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6, style: .continuous)
                    .fill(.white.opacity(0.55)).frame(height: max(3, size.height * 0.07))
            }
            VStack(spacing: 1) {
                Text(item.number, format: .number).font(.system(size: min(22, size.height * 0.32), weight: .bold, design: .rounded))
                if size.height > 46 && !item.mode.isEmpty {
                    Text(verbatim: item.mode).font(.system(size: 9.5, weight: .semibold)).monospacedDigit().lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.3), radius: 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.black.opacity(item.builtIn ? 0.55 : 0.4), lineWidth: item.builtIn ? 2.5 : 3))
        .frame(width: max(10, size.width), height: max(8, size.height))
        .help(Text(verbatim: item.name))
    }
}

/// Settings › Picture in Picture.
struct PiPSettingsSection: View {
    let module: PowerDisplayModule
    @Bindable var s: Persisted<PowerDisplaySettings>
    @State private var permissions = PermissionCenter.shared

    init(module: PowerDisplayModule) {
        self.module = module
        self.s = module.settings
    }

    var body: some View {
        Section("Picture in Picture") {
            if !permissions.isGranted(.screenRecording) {
                InfoBar(.info, title: "Screen Recording permission needed",
                        message: "Only picture in picture uses it, to show a live image of a display.",
                        actionTitle: "Grant Access") { permissions.request(.screenRecording) }
            }
            Picker(selection: $s.value.pip.frameRate) {
                ForEach(PiPOptions.frameRates, id: \.self) { Text("\($0) fps", comment: "Frames per second").tag($0) }
            } label: {
                RowLabel("Frame rate", subtitle: "Higher rates are smoother and use more energy.")
            }
            Toggle(isOn: $s.value.pip.showsCursor) { RowLabel("Show the pointer") }
            Toggle(isOn: $s.value.pip.floats) { RowLabel("Float above other windows") }
            Toggle(isOn: $s.value.pip.allSpaces) { RowLabel("Show on all Spaces") }
            Text("Open a display in picture in picture from its Arrange tab in the flyout, or with `mactoys powerdisplay pip -n <n>`. Right-click the window for size and options.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
    }
}

/// Settings › Virtual displays: the list, connection switches and an inline editor.
struct VirtualDisplaysSection: View {
    let module: PowerDisplayModule
    @Bindable var s: Persisted<PowerDisplaySettings>
    @State private var editing: UUID?

    init(module: PowerDisplayModule, previewEditing: UUID? = nil) {
        self.module = module
        self.s = module.settings
        self._editing = State(initialValue: previewEditing)
    }

    var body: some View {
        Section {
            if !module.virtualDisplaysAvailable {
                Text("Virtual displays aren't available on this version of macOS.")
                    .foregroundStyle(.secondary)
            } else {
                if s.value.virtualDisplays.isEmpty {
                    Text("A virtual display is a screen that exists only in software. Mirror a monitor without HiDPI onto a HiDPI virtual display for sharper text, or give apps a screen to stream or record. Virtual displays exist while MacToys runs.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                ForEach(s.value.virtualDisplays) { config in
                    VirtualDisplayRow(module: module, config: config, expanded: editing == config.id) {
                        withAnimation(.snappy(duration: 0.2)) { editing = editing == config.id ? nil : config.id }
                    }
                }
                HStack {
                    Menu("Add Virtual Display") {
                        ForEach(VirtualDisplayPreset.all) { p in
                            Button {
                                let c = module.addVirtualDisplay(width: p.width, height: p.height)
                                editing = c.id
                            } label: {
                                Text("\(String(p.width)) × \(String(p.height)) · \(p.aspect.title())", comment: "Virtual display preset: pixel size (width × height) and aspect ratio")
                            }
                        }
                    }
                    .fixedSize()
                    Spacer()
                }
            }
        } header: {
            Text("Virtual displays")
        }
    }
}

/// One virtual display: summary and connection switch; expands into its editor.
private struct VirtualDisplayRow: View {
    let module: PowerDisplayModule
    let config: VirtualDisplayConfig
    let expanded: Bool
    let toggleExpanded: () -> Void
    @State private var draft: VirtualDisplayConfig
    @State private var widthText: String
    @State private var heightText: String

    init(module: PowerDisplayModule, config: VirtualDisplayConfig, expanded: Bool, toggleExpanded: @escaping () -> Void) {
        self.module = module
        self.config = config
        self.expanded = expanded
        self.toggleExpanded = toggleExpanded
        _draft = State(initialValue: config)
        _widthText = State(initialValue: String(config.width))
        _heightText = State(initialValue: String(config.height))
    }

    private var connected: Bool { module.store.connectedVirtual.contains(config.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                VirtualDisplayGlyph(width: config.width, height: config.height, hiDPI: config.hiDPI, connected: connected)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: config.name).fontWeight(.semibold)
                    Text(verbatim: summary(config)).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    if let target = config.mirroredBy {
                        Label {
                            Text("Shown on \(monitorName(target))", comment: "Virtual display: a physical monitor mirrors it; the placeholder is its name")
                        } icon: { Image(systemName: "rectangle.on.rectangle") }
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Toggle("Connected", isOn: Binding(get: { connected }, set: { module.setVirtualDisplay(config.id, connected: $0) }))
                    .toggleStyle(.adaptiveSwitch).labelsHidden()
                    .help(connected ? Text("Disconnect") : Text("Connect"))
                Button(action: toggleExpanded) {
                    Image(systemName: "chevron.down").rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .buttonStyle(.borderless)
                .help(expanded ? Text("Done") : Text("Edit"))
            }
            if expanded { editor.transition(.opacity) }
        }
        .padding(.vertical, 4)
        .onChange(of: config) { _, new in
            draft = new
            widthText = String(new.width)
            heightText = String(new.height)
        }
    }

    private func summary(_ c: VirtualDisplayConfig) -> String {
        let rate = RefreshFormat.title(c.refreshRate)
        if c.hiDPI {
            let (w, h) = c.looksLike
            return String(localized: "\(String(c.width)) × \(String(c.height)) · HiDPI, looks like \(String(w)) × \(String(h)) · \(rate)",
                          comment: "Virtual display summary: pixel size (width × height), HiDPI desktop size, refresh rate")
        }
        return String(localized: "\(String(c.width)) × \(String(c.height)) · \(rate)",
                      comment: "Virtual display summary: pixel size (width × height) and refresh rate")
    }

    private func monitorName(_ id: String) -> String {
        module.monitor(id: id)?.name ?? module.settings.value.prefs(id).lastName ?? id
    }

    /// Physical monitors that can show a virtual display's picture.
    private var physicalMonitors: [MonitorState] {
        module.store.monitors.filter { $0.snapshot.kind != .virtual }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Name") {
                TextField("Name", text: $draft.name).labelsHidden().textFieldStyle(.roundedBorder).multilineTextAlignment(.leading).frame(maxWidth: 260)
            }
            LabeledContent("Size") {
                HStack(spacing: 6) {
                    Menu("Presets") {
                        ForEach(VirtualDisplayPreset.all) { p in
                            Button {
                                draft.width = p.width
                                draft.height = p.height
                                widthText = String(p.width)
                                heightText = String(p.height)
                            } label: {
                                Text("\(String(p.width)) × \(String(p.height)) · \(p.aspect.title())", comment: "Virtual display preset: pixel size (width × height) and aspect ratio")
                            }
                        }
                    }
                    .fixedSize()
                    TextField("Width", text: $widthText).labelsHidden().textFieldStyle(.roundedBorder).frame(width: 64).multilineTextAlignment(.trailing)
                        .accessibilityLabel(Text("Width"))
                        .onChange(of: widthText) { _, t in if let v = Int(t) { draft.width = VirtualDisplayModes.clamp(v) } }
                    Text(verbatim: "×").foregroundStyle(.secondary)
                    TextField("Height", text: $heightText).labelsHidden().textFieldStyle(.roundedBorder).frame(width: 64)
                        .accessibilityLabel(Text("Height"))
                        .onChange(of: heightText) { _, t in if let v = Int(t) { draft.height = VirtualDisplayModes.clamp(v) } }
                    Text("pixels").foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: $draft.hiDPI) {
                RowLabel("HiDPI", subtitle: "Also offers each size at half its pixels per side, drawn twice as sharp.")
            }
            Picker("Refresh rate", selection: $draft.refreshRate) {
                ForEach([30.0, 60, 120], id: \.self) { Text(verbatim: RefreshFormat.title($0)).tag($0) }
            }
            Picker(selection: Binding(get: { draft.mirroredBy ?? "" }, set: { draft.mirroredBy = $0.isEmpty ? nil : $0 })) {
                Text("Nowhere", comment: "Virtual display: no physical monitor shows it").tag("")
                ForEach(physicalMonitors) { m in Text(verbatim: m.name).tag(m.id) }
            } label: {
                RowLabel("Show on", subtitle: "The monitor mirrors the virtual display: for HiDPI on a monitor that doesn't offer it.")
            }
            HStack {
                Button("Remove", role: .destructive) { module.removeVirtualDisplay(config.id) }
                Spacer()
                Button("Revert") {
                    draft = config
                    widthText = String(config.width)
                    heightText = String(config.height)
                }
                .disabled(draft == config)
                Button("Apply") {
                    var d = draft
                    d.name = d.name.trimmingCharacters(in: .whitespaces).isEmpty ? config.name : d.name.trimmingCharacters(in: .whitespaces)
                    module.updateVirtualDisplay(d)
                    toggleExpanded()
                }
                .buttonStyle(.borderedProminent)
                .disabled(draft == config)
            }
        }
        .padding(.leading, 56)
    }
}

/// A small screen in the virtual display's shape, dashed while disconnected.
private struct VirtualDisplayGlyph: View {
    let width: Int
    let height: Int
    let hiDPI: Bool
    let connected: Bool

    var body: some View {
        let ratio = CGFloat(height) / CGFloat(max(1, width))
        let w: CGFloat = ratio > 1 ? 26 : 44
        let h = min(36, max(16, w * ratio))
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(connected ? AnyShapeStyle(Tint.yellow.gradient) : AnyShapeStyle(Color.secondary.opacity(0.12)))
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(connected ? Color.black.opacity(0.15) : Color.secondary.opacity(0.6),
                              style: StrokeStyle(lineWidth: 1, dash: connected ? [] : [3, 2]))
            if hiDPI {
                Text(verbatim: "2×").font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(connected ? .white : .secondary)
            }
        }
        .frame(width: w, height: h)
        .frame(width: 48, height: 38)
    }
}
