import AppKit
import MacToysCore
import SwiftUI

/// The flyout window: a key-capable glass panel under the menu bar that grows downward.
@MainActor
final class FlyoutPanel: FloatingPanel {
    private var pinnedTop: CGFloat?

    init(module: PowerDisplayModule) {
        super.init(size: CGSize(width: 372, height: 300))
        // The hosting view's min/max size follow the fixed-size content, so the panel tracks its height.
        contentView = NSHostingView(rootView: PowerDisplayFlyout(module: module).fixedSize(horizontal: false, vertical: true))
        hasShadow = true
    }

    /// Shows the panel under a status item button, or at the top right of the screen under the pointer.
    func present(below button: NSStatusBarButton?) {
        let width: CGFloat = 372
        let size = contentView?.fittingSize ?? frame.size
        let height = max(120, size.height)
        let origin: CGPoint
        if let button, let window = button.window {
            let r = window.convertToScreen(button.convert(button.bounds, to: nil))
            let screen = window.screen ?? NSScreen.main
            let vf = screen?.visibleFrame ?? r
            let x = min(max(r.midX - width / 2, vf.minX + 8), vf.maxX - width - 8)
            pinnedTop = r.minY - 6
            origin = CGPoint(x: x, y: r.minY - 6 - height)
        } else {
            let vf = (NSScreen.underMouse ?? NSScreen.main)?.visibleFrame ?? .zero
            pinnedTop = vf.maxY - 8
            origin = CGPoint(x: vf.maxX - width - 12, y: vf.maxY - 8 - height)
        }
        setFrame(CGRect(origin: origin, size: CGSize(width: width, height: height)), display: true)
        NSApp.activate()
        makeKeyAndOrderFront(nil)
    }

    /// Content height changes (linking, expanding) keep the top edge where it is.
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var r = frameRect
        if let top = pinnedTop { r.origin.y = top - r.height }
        super.setFrame(r, display: flag)
    }
}

/// Design 05 "Displays": per-monitor sliders and pickers on dark glass.
struct PowerDisplayFlyout: View {
    let module: PowerDisplayModule
    @Bindable var settings: Persisted<PowerDisplaySettings>
    var store: PowerDisplayStore
    @State private var showIndividual: Bool

    init(module: PowerDisplayModule, expanded: Bool = false) {
        self.module = module
        self.settings = module.settings
        self.store = module.store
        self._showIndividual = State(initialValue: expanded)
    }

    var body: some View {
        GlassPanel(cornerRadius: 18) {
            VStack(alignment: .leading, spacing: 12) {
                header
                if !store.hasScanned {
                    HStack { Spacer(); ProgressView().controlSize(.small); Text("Looking for displays…").foregroundStyle(.secondary); Spacer() }
                        .padding(.vertical, 20)
                } else if store.visibleMonitors.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "display.trianglebadge.exclamationmark").font(.system(size: 26)).foregroundStyle(.secondary)
                        Text("No displays with controls").font(.system(size: 13, weight: .semibold))
                        Text("Built-in displays and DDC/CI monitors appear here. Some docks and adapters don't pass DDC through.")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                } else if module.isLinked {
                    linkedCard
                    DisclosureGroup(isExpanded: $showIndividual) {
                        VStack(spacing: 10) {
                            ForEach(store.visibleMonitors) { m in MonitorCard(module: module, monitor: m, linked: true) }
                        }
                        .padding(.top, 8)
                    } label: {
                        Text("Individual displays").font(.system(size: 12.5, weight: .medium)).foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(store.visibleMonitors) { m in MonitorCard(module: module, monitor: m, linked: false) }
                }
                if module.canLinkBrightness {
                    HStack {
                        Text("Link brightness levels").font(.system(size: 13))
                        Spacer()
                        Toggle("Link brightness levels", isOn: $settings.value.linkedBrightness)
                            .toggleStyle(.adaptiveSwitch).controlSize(.small).labelsHidden()
                    }
                    .padding(.horizontal, 4)
                }
            }
            .padding(14)
            .foregroundStyle(.white)
            .disabled(store.isRefreshing)
            .overlay(alignment: .top) {
                if store.isRefreshing && store.hasScanned {
                    ProgressView().controlSize(.small).padding(.top, 16)
                }
            }
        }
        .frame(width: 372)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Displays").font(.system(size: 15, weight: .bold))
            Spacer()
            if settings.value.showProfileSwitcher {
                Menu {
                    ForEach(settings.value.profiles) { p in
                        Button {
                            module.applyProfile(id: p.id)
                        } label: {
                            if settings.value.lastAppliedProfile == p.id { Label(p.name, systemImage: "checkmark") } else { Text(p.name) }
                        }
                    }
                    if !settings.value.profiles.isEmpty { Divider() }
                    Button("Save Current as New Profile") { module.saveProfile() }
                    Button("Edit Profiles…") {
                        module.closeFlyout()
                        ModuleRegistry.shared.showSettings?(module.info.id)
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "bookmark")
                        settings.value.profiles.first { $0.id == settings.value.lastAppliedProfile }
                            .map { Text(verbatim: $0.name) } ?? Text("Profiles")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(.white.opacity(0.08)))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Apply or save a profile")
            }
            if settings.value.showIdentifyButton {
                Button { module.identify() } label: {
                    Image(systemName: "viewfinder").font(.system(size: 12, weight: .medium))
                        .frame(width: 28, height: 26)
                        .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help("Identify monitors")
            }
        }
    }

    private var linkedCard: some View {
        let linked = module.linkedMonitors.count
        let excluded = module.brightnessMonitors.count - linked
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "rectangle.on.rectangle")
                Text("All displays").font(.system(size: 13, weight: .semibold))
                Spacer()
                (excluded > 0
                    ? Text("\(linked) linked · \(excluded) excluded", comment: "Numbers of displays whose brightness is linked and excluded")
                    : Text("\(linked) linked", comment: "Number of displays whose brightness is linked"))
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            FlyoutSlider(module: module, monitorID: nil, feature: .brightness,
                         value: Binding(get: { module.linkedBrightness }, set: { module.setLinkedBrightness($0) }))
        }
        .cardStyle()
    }

    /// Sample monitors for `MacToys --snapshot`.
    @MainActor
    static func preview(linked: Bool = false) -> some View {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mactoys-preview-\(UUID().uuidString)")
        let module = PowerDisplayModule(store: SettingsStore(directory: dir))
        let builtIn = MonitorSnapshot(id: "1552-41036-0", number: 1, name: "Built-in Retina Display", displayID: 1,
                                      kind: .builtIn, transport: "Built-in", capabilities: nil,
                                      readings: [.brightness: FeatureReading(current: 72, maximum: 100)], options: [:], rotation: 0)
        let caps = DDCCapabilities.parse("(prot(monitor)type(lcd)model(27MD5KL)cmds(01 02 03 0C E3 F3)vcp(02 04 05 08 10 12 14(01 05 06 08 0B) 16 18 1A 60(0F 11 12 19) 62 8D D6(01 04) DF)mccs_ver(2.1))")
        let lg = MonitorSnapshot(id: "7789-23376-1234", number: 2, name: "LG UltraFine 5K", displayID: 2, kind: .ddc,
                                 transport: "DDC/CI · USB-C", capabilities: caps,
                                 readings: [.brightness: FeatureReading(current: 55, maximum: 100),
                                            .contrast: FeatureReading(current: 60, maximum: 100),
                                            .volume: FeatureReading(current: 30, maximum: 100),
                                            .inputSource: FeatureReading(current: 0x19, maximum: 0x1B)],
                                 options: [.inputSource: [0x0F, 0x11, 0x12, 0x19]], rotation: 0)
        module.store.monitors = [MonitorState(builtIn), MonitorState(lg)]
        module.store.visibleMonitors = module.store.monitors
        module.store.hasScanned = true
        module.settings.value.monitors[lg.id] = MonitorPrefs(showInputSource: true)
        module.settings.value.profiles = [DisplayProfileRecord(id: 1, name: "Work"), DisplayProfileRecord(id: 2, name: "Movie")]
        module.settings.value.lastAppliedProfile = 1
        module.settings.value.linkedBrightness = linked
        return PowerDisplayFlyout(module: module, expanded: linked)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 20)
    }
}

private extension View {
    func cardStyle() -> some View {
        padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.06)))
    }
}

/// One monitor: its name, transport and the controls enabled for it.
private struct MonitorCard: View {
    let module: PowerDisplayModule
    @Bindable var monitor: MonitorState
    let linked: Bool

    var body: some View {
        let prefs = module.settings.value.prefs(monitor.id)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: monitor.snapshot.kind == .builtIn ? "laptopcomputer" : "display")
                Text(monitor.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 6)
                Text(monitor.snapshot.transportTitle).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            if monitor.supports(.brightness) && (!linked || prefs.excludeFromLinkedBrightness) {
                sliderRow(.brightness)
            }
            ForEach([DisplayFeature.contrast, .volume], id: \.self) { f in
                if monitor.supports(f) && prefs.shows(f) { sliderRow(f) }
            }
            ForEach([DisplayFeature.inputSource, .colorTemperature], id: \.self) { f in
                if monitor.supports(f) && prefs.shows(f) { pickerRow(f) }
            }
            if monitor.supports(.powerState) && prefs.showPowerState { powerRow }
            if linked && monitor.supports(.brightness) {
                Toggle(isOn: Binding(get: { prefs.excludeFromLinkedBrightness },
                                     set: { module.settings.value.monitors[monitor.id, default: MonitorPrefs()].excludeFromLinkedBrightness = $0 })) {
                    Text("Exclude from linked brightness").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .toggleStyle(.adaptiveSwitch).controlSize(.mini)
            }
        }
        .cardStyle()
    }

    private func sliderRow(_ f: DisplayFeature) -> some View {
        HStack(spacing: 10) {
            Image(systemName: f.symbol).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 16)
            FlyoutSlider(module: module, monitorID: monitor.id, feature: f,
                         value: Binding(get: { monitor.percent[f] ?? 0 }, set: { module.set(f, percent: $0, on: monitor) }))
        }
    }

    private func pickerRow(_ f: DisplayFeature) -> some View {
        let options = monitor.snapshot.options[f] ?? []
        let current = monitor.discrete[f]
        let names = module.settings.value
        return HStack(spacing: 10) {
            Image(systemName: f.symbol).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 16)
            Text(f.title).font(.system(size: 12.5)).foregroundStyle(.secondary)
            Spacer()
            Menu {
                ForEach(options, id: \.self) { v in
                    Button {
                        if f == .inputSource && v != current {
                            let input = names.localizedValueName(f, v, monitor: monitor.id)
                            guard module.confirm(String(localized: "Switch \(monitor.name) to \(input)?",
                                                        comment: "Confirmation: first a display name, then an input source, e.g. 'HDMI 1'"),
                                                 String(localized: "If that input has no signal the screen goes black, and you may need the monitor's buttons to switch back."),
                                                 button: String(localized: "Switch Input")) else { return }
                        }
                        module.setDiscrete(f, value: v, on: monitor)
                    } label: {
                        if v == current { Label(names.localizedValueName(f, v, monitor: monitor.id), systemImage: "checkmark") }
                        else { Text(names.localizedValueName(f, v, monitor: monitor.id)) }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(current.map { names.localizedValueName(f, $0, monitor: monitor.id) } ?? "—")
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.08)))
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        }
    }

    /// One row when the buttons fit, else the buttons go under the label (translations run longer).
    private var powerRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                powerLabel
                Spacer()
                powerButtons
            }
            VStack(alignment: .leading, spacing: 6) {
                powerLabel
                HStack(spacing: 6) { powerButtons }.padding(.leading, 26)
            }
            VStack(alignment: .leading, spacing: 6) {
                powerLabel
                VStack(alignment: .leading, spacing: 4) { powerButtons }.padding(.leading, 26)
            }
        }
    }

    private var powerLabel: some View {
        HStack(spacing: 10) {
            Image(systemName: "power").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 16)
            Text(LocalizedStringResource("powerdisplay.power", defaultValue: "Power", comment: "Monitor control: power state (on, standby, off)")).font(.system(size: 12.5)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var powerButtons: some View {
        let options = monitor.snapshot.options[.powerState] ?? DisplayEngine.defaultOptions(.powerState)
        let names = module.settings.value
        ForEach(options, id: \.self) { v in
            let mode = names.localizedValueName(.powerState, v, monitor: monitor.id)
            Button(mode) {
                if v != 0x01 {
                    guard module.confirm(String(localized: "Change \(monitor.name) to \(mode)?",
                                                comment: "Confirmation: first a display name, then a power mode, e.g. 'Standby'"),
                                         String(localized: "Some monitors don't wake up from software. You may need to press the monitor's power button or reconnect its cable."),
                                         button: String(localized: "Turn Off", comment: "Button: turn the monitor off or put it in standby")) else { return }
                }
                module.setPower(v, on: monitor)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11.5, weight: .medium))
            .fixedSize()
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(monitor.discrete[.powerState] == v ? 0.18 : 0.06)))
        }
    }
}

/// The wide capsule slider from the design, with drag, scroll wheel (via the module's monitor) and arrow keys.
struct FlyoutSlider: View {
    let module: PowerDisplayModule
    let monitorID: String?
    let feature: DisplayFeature
    @Binding var value: Double
    @FocusState private var focused: Bool

    private var percentText: String { (value / 100).formatted(.percent.precision(.fractionLength(0))) }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.13))
                Capsule().fill(.white.opacity(0.92))
                    .frame(width: max(22, geo.size.width * value / 100))
                    .opacity(value <= 0 ? 0.35 : 1)
            }
            .overlay(Capsule().strokeBorder(.white.opacity(focused ? 0.45 : 0), lineWidth: 1.5))
            .contentShape(Capsule())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                value = max(0, min(100, g.location.x / max(1, geo.size.width) * 100))
            })
        }
        .frame(height: 22)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { value = max(0, value - Double(module.settings.value.wheelIncrement)); return .handled }
        .onKeyPress(.rightArrow) { value = min(100, value + Double(module.settings.value.wheelIncrement)); return .handled }
        .onHover { inside in
            if inside { module.hoveredSlider = (monitorID, feature) }
            else if module.hoveredSlider?.monitor == monitorID && module.hoveredSlider?.feature == feature { module.hoveredSlider = nil }
        }
        .help(Text(verbatim: "\(feature.title) \(percentText)"))
        .accessibilityElement()
        .accessibilityLabel(feature.title)
        .accessibilityValue(Text(verbatim: percentText))
        .accessibilityAdjustableAction { direction in
            let step = Double(module.settings.value.wheelIncrement)
            value = direction == .increment ? min(100, value + step) : max(0, value - step)
        }
    }
}

/// "Identify monitors": a big number on each screen for a couple of seconds.
@MainActor
enum IdentifyOverlay {
    private static var panels: [OverlayPanel] = []
    private static var hide: DispatchWorkItem?

    static func show(_ monitors: [(CGDirectDisplayID, Int, String)]) {
        dismiss()
        for screen in NSScreen.screens {
            guard let m = monitors.first(where: { $0.0 == screen.displayID }) else { continue }
            let size = CGSize(width: 300, height: 230)
            let frame = CGRect(x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2,
                               width: size.width, height: size.height)
            let panel = OverlayPanel(frame: frame, level: .statusBar)
            panel.setContent(GlassPanel(cornerRadius: 28) {
                VStack(spacing: 6) {
                    Text(m.1, format: .number).font(.system(size: 120, weight: .bold, design: .rounded)).monospacedDigit()
                    Text(verbatim: m.2).font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            })
            panel.orderFrontRegardless()
            panels.append(panel)
        }
        let work = DispatchWorkItem { MainActor.assumeIsolated { dismiss() } }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    static func dismiss() {
        hide?.cancel()
        hide = nil
        for p in panels { p.orderOut(nil) }
        panels.removeAll()
    }
}
