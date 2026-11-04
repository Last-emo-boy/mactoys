import AppKit
import MacToysCore
import SwiftUI

/// The flyout window: a key-capable glass panel under the menu bar that grows downward.
@MainActor
final class FlyoutPanel: FloatingPanel {
    static let width: CGFloat = 384
    private var pinnedTop: CGFloat?

    init(module: PowerDisplayModule) {
        super.init(size: CGSize(width: Self.width, height: 300))
        // The hosting view's min/max size follow the fixed-size content, so the panel tracks its height.
        contentView = NSHostingView(rootView: PowerDisplayFlyout(module: module).fixedSize(horizontal: false, vertical: true))
        hasShadow = true
    }

    /// Shows the panel under a status item button, or at the top right of the screen under the pointer.
    func present(below button: NSStatusBarButton?) {
        let width = Self.width
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

/// Design 05 "Displays": per-monitor sliders and pickers on dark glass, with resolution, color
/// and arrangement controls behind each display's disclosure button.
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
                        Text("No displays").font(.system(size: 13, weight: .semibold))
                        Text("Every display is hidden. Show them again in Power Display settings.")
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
                FlyoutFooter(module: module)
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
        .frame(width: FlyoutPanel.width)
        .animation(.snappy(duration: 0.22), value: store.expanded)
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
            BrightnessSlider(module: module, monitorID: nil, track: module.linkedTrack,
                             position: Binding(get: { module.linkedPosition }, set: { module.setLinkedPosition($0) }))
        }
        .cardStyle()
    }
}

extension View {
    func cardStyle() -> some View {
        padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.06)))
    }
}

/// One monitor: name, transport, its brightness and the controls enabled for it; the disclosure
/// button opens resolution, color and arrangement.
struct MonitorCard: View {
    let module: PowerDisplayModule
    @Bindable var monitor: MonitorState
    let linked: Bool

    private var expanded: Bool { module.store.expanded.contains(monitor.id) }

    var body: some View {
        let prefs = module.settings.value.prefs(monitor.id)
        VStack(alignment: .leading, spacing: 10) {
            header
            let t = module.track(for: monitor)
            if !t.isEmpty && (!linked || prefs.excludeFromLinkedBrightness || !monitor.supports(.brightness)) {
                HStack(spacing: 10) {
                    rowIcon(monitor.softDim > 0 ? "moon.fill" : "sun.max")
                    BrightnessSlider(module: module, monitorID: monitor.id, track: t,
                                     position: Binding(get: { module.brightnessPosition(monitor) },
                                                       set: { module.setBrightnessPosition($0, on: monitor) }))
                }
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
            if expanded {
                DisplayPanes(module: module, monitor: monitor)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .cardStyle()
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).symbolRenderingMode(.hierarchical).frame(width: 18)
            Text(verbatim: monitor.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            if monitor.facts.isMain && module.store.monitors.count > 1 {
                FlyoutBadge(text: Text("Main", comment: "Badge: the main display (menu bar)"), tint: nil)
            }
            if monitor.facts.mirrorOf != nil {
                FlyoutBadge(text: Text("Mirroring", comment: "Badge: this display shows a copy of another display"), tint: nil)
            }
            Spacer(minLength: 6)
            if monitor.snapshot.kind != .builtIn {
                Text(verbatim: monitor.snapshot.transportTitle).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Button {
                withAnimation(.snappy(duration: 0.22)) {
                    if expanded { module.store.expanded.remove(monitor.id) } else { module.store.expanded.insert(monitor.id) }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .rotationEffect(.degrees(expanded ? 180 : 0))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(.white.opacity(expanded ? 0.16 : 0.08)))
            }
            .buttonStyle(.plain)
            .help(expanded ? Text("Hide resolution, color and arrangement") : Text("Resolution, color and arrangement"))
            .accessibilityLabel(Text("Display options"))
        }
    }

    private var symbol: String {
        switch monitor.snapshot.kind {
        case .builtIn: "laptopcomputer"
        case .virtual: "rectangle.dashed"
        default: "display"
        }
    }

    private func rowIcon(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 16)
    }

    private func sliderRow(_ f: DisplayFeature) -> some View {
        HStack(spacing: 10) {
            rowIcon(f.symbol)
            FlyoutSlider(module: module, monitorID: monitor.id, feature: f,
                         value: Binding(get: { monitor.percent[f] ?? 0 }, set: { module.set(f, percent: $0, on: monitor) }))
        }
    }

    private func pickerRow(_ f: DisplayFeature) -> some View {
        let options = monitor.snapshot.options[f] ?? []
        let current = monitor.discrete[f]
        let names = module.settings.value
        return HStack(spacing: 10) {
            rowIcon(f.symbol)
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
                FlyoutChipLabel(text: Text(verbatim: current.map { names.localizedValueName(f, $0, monitor: monitor.id) } ?? "—"))
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
            rowIcon("power")
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
        HStack(spacing: 8) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.13))
                    Capsule().fill(.white.opacity(0.92))
                        .frame(width: max(22, geo.size.width * value / 100))
                        .opacity(value <= 0 ? 0.35 : 1)
                }
                .overlay(Capsule(style: .circular).strokeBorder(.white.opacity(focused ? 0.45 : 0), lineWidth: 1.5))
                .contentShape(Capsule())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    value = max(0, min(100, g.location.x / max(1, geo.size.width) * 100))
                })
            }
            .frame(height: 22)
            SliderValueLabel(text: Text(verbatim: percentText))
        }
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

/// The trailing value of a flyout slider.
struct SliderValueLabel: View {
    let text: Text

    var body: some View {
        text.font(.system(size: 11.5, weight: .medium)).monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(minWidth: 40, alignment: .trailing)
    }
}

/// The combined brightness slider: software dimming (left of the first mark), hardware range,
/// extra brightness (right of the second mark). One drag continues across all three.
struct BrightnessSlider: View {
    let module: PowerDisplayModule
    let monitorID: String?
    let track: BrightnessTrack
    @Binding var position: Double
    @FocusState private var focused: Bool

    private var components: BrightnessComponents { track.components(at: position) }

    var body: some View {
        HStack(spacing: 8) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.13))
                    if zoned && track.dimShare > 0 {
                        zone(from: 0, to: track.hardwareStart, width: w, style: AnyShapeStyle(Color.black.opacity(0.22)))
                    }
                    if zoned && track.boostShare > 0 {
                        zone(from: track.hardwareEnd, to: 1, width: w, style: AnyShapeStyle(Tint.yellow.color.opacity(0.16)))
                    }
                    fill(width: w)
                        .mask(alignment: .leading) { Capsule().frame(width: max(22, w * position)) }
                        .opacity(position <= 0 ? 0.35 : 1)
                    marks(width: w)
                    glyphs(width: w)
                }
                .clipShape(Capsule())
                .contentShape(Capsule())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    position = max(0, min(1, g.location.x / max(1, w)))
                })
            }
            .frame(height: 22)
            // Circular: a continuous capsule's stroke shows small spurs at its ends.
            .overlay(Capsule(style: .circular).strokeBorder(.white.opacity(focused ? 0.45 : 0), lineWidth: 1.5).allowsHitTesting(false))
            SliderValueLabel(text: valueText)
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { nudge(-1); return .handled }
        .onKeyPress(.rightArrow) { nudge(1); return .handled }
        .onHover { inside in
            if inside { module.hoveredSlider = (monitorID, .brightness) }
            else if module.hoveredSlider?.monitor == monitorID && module.hoveredSlider?.feature == .brightness { module.hoveredSlider = nil }
        }
        .help(helpText)
        .accessibilityElement()
        .accessibilityLabel(Text("Brightness"))
        .accessibilityValue(valueText)
        .accessibilityAdjustableAction { direction in nudge(direction == .increment ? 1 : -1) }
    }

    /// Whether the track has more than one range, so the ranges are told apart.
    private var zoned: Bool { [track.dimShare, track.hardwareShare, track.boostShare].filter { $0 > 0 }.count > 1 }

    /// The fill, colored by range: grey below the hardware minimum, white across the hardware
    /// range, warming up past its maximum. Masked to the slider's position.
    private func fill(width w: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            if zoned && track.dimShare > 0 {
                zone(from: 0, to: track.hardwareStart, width: w, style: AnyShapeStyle(Color.white.opacity(0.66)))
                zone(from: track.hardwareStart, to: 1, width: w, style: AnyShapeStyle(Color.white.opacity(0.92)))
            } else {
                Rectangle().fill(.white.opacity(0.92))
            }
            if zoned && track.boostShare > 0 {
                zone(from: track.hardwareEnd, to: 1, width: w,
                     style: AnyShapeStyle(LinearGradient(colors: [.white.opacity(0.94), Color(red: 1, green: 0.8, blue: 0.36)],
                                                         startPoint: .leading, endPoint: .trailing)))
            }
        }
        .frame(width: w, alignment: .leading)
    }

    private func zone(from a: Double, to b: Double, width: CGFloat, style: AnyShapeStyle) -> some View {
        Rectangle().fill(style)
            .frame(width: max(0, CGFloat(b - a) * width))
            .offset(x: CGFloat(a) * width)
    }

    /// Thin dividers where the hardware range starts and ends.
    private func marks(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            if zoned && track.dimShare > 0 { divider(at: track.hardwareStart, width: width) }
            if zoned && track.boostShare > 0 { divider(at: track.hardwareEnd, width: width) }
        }
        .frame(maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    private func divider(at p: Double, width: CGFloat) -> some View {
        Rectangle().fill(.black.opacity(position > p ? 0.32 : 0.4)).frame(width: 1.5)
            .offset(x: CGFloat(p) * width - 0.75)
    }

    /// A moon in the dimming range, a sun in the extra-brightness range. Each is left out while the
    /// end of the fill runs through it.
    private func glyphs(width: CGFloat) -> some View {
        let fillEnd = max(22, width * position)
        return ZStack(alignment: .leading) {
            if zoned && track.dimShare > 0 && track.dimShare * width >= 22 {
                glyph("moon.fill", center: CGFloat(track.hardwareStart) * width / 2, fillEnd: fillEnd)
            }
            if zoned && track.boostShare > 0 && track.boostShare * width >= 22 {
                glyph("sun.max.fill", center: (CGFloat(track.hardwareEnd) * width + width) / 2, fillEnd: fillEnd)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func glyph(_ name: String, center: CGFloat, fillEnd: CGFloat) -> some View {
        if abs(fillEnd - center) >= 10 {
            Image(systemName: name).font(.system(size: 9, weight: .bold))
                .foregroundStyle(fillEnd > center ? Color.black.opacity(0.42) : Color.white.opacity(0.5))
                .frame(width: 14)
                .offset(x: center - 7)
        }
    }

    private var valueText: Text {
        let c = components
        if c.dim > 0 {
            return Text("−\(c.dim.formatted(.percent.precision(.fractionLength(0))))",
                        comment: "Brightness slider value while dimming in software; the placeholder is a percentage")
        }
        if c.boost > 0 {
            let k = SoftwareFactor.boost(c.boost, maxBoost: module.settings.value.maxExtraBrightness)
            return Text("\(k.formatted(.number.precision(.fractionLength(1))))×",
                        comment: "Brightness slider value with extra brightness: a multiplier such as 1.4×")
        }
        if !track.hasHardware { return Text((1.0).formatted(.percent.precision(.fractionLength(0)))) }
        return Text((c.hardware / 100).formatted(.percent.precision(.fractionLength(0))))
    }

    private var helpText: Text {
        let c = components
        if c.dim > 0 { return Text("Dimmed in software below the display's minimum") }
        if c.boost > 0 { return Text("Extra brightness from the display's HDR headroom") }
        return Text("Brightness")
    }

    private func nudge(_ direction: Double) {
        let step = Double(module.settings.value.wheelIncrement) / 100
        let share = track.hardwareShare > 0 ? track.hardwareShare : max(track.dimShare, track.boostShare)
        position = max(0, min(1, position + direction * step * share))
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
