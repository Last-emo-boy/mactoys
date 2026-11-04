import AppKit
import MacToysCore
import SwiftUI

/// The flyout window: a key-capable glass panel under the menu bar that grows downward.
@MainActor
final class AppVolumeFlyoutPanel: FloatingPanel {
    static let width: CGFloat = 360
    private var pinnedTop: CGFloat?

    init(module: AppVolumeModule) {
        super.init(size: CGSize(width: Self.width, height: 320))
        let maxHeight = max(360, (NSScreen.main?.visibleFrame.height ?? 800) - 40)
        // The hosting view's size follows the fixed-size content, so the panel tracks its height.
        contentView = NSHostingView(rootView: AppVolumeFlyout(module: module, maxHeight: maxHeight)
            .fixedSize(horizontal: false, vertical: true))
        hasShadow = true
    }

    /// Shows the panel under a status item button, or at the top right of the screen under the pointer.
    func present(below button: NSStatusBarButton?) {
        let width = Self.width
        let height = max(160, contentView?.fittingSize.height ?? frame.height)
        let origin: CGPoint
        if let button, let window = button.window {
            let r = window.convertToScreen(button.convert(button.bounds, to: nil))
            let vf = (window.screen ?? NSScreen.main)?.visibleFrame ?? r
            let x = min(max(r.midX - width / 2, vf.minX + 8), vf.maxX - width - 8)
            pinnedTop = r.minY - 6
            origin = CGPoint(x: x, y: r.minY - 6 - height)
        } else {
            let vf = (NSScreen.underMouse ?? NSScreen.main)?.visibleFrame ?? .zero
            pinnedTop = vf.maxY - 8
            origin = CGPoint(x: vf.maxX - width - 12, y: vf.maxY - 8 - height)
        }
        setFrame(CGRect(origin: origin, size: CGSize(width: width, height: height)), display: true)
        let animate = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        alphaValue = animate ? 0 : 1
        NSApp.activate()
        makeKeyAndOrderFront(nil)
        if animate {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                animator().alphaValue = 1
            }
        }
    }

    /// Content height changes (expanding a row, a device list) keep the top edge where it is.
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var r = frameRect
        if let top = pinnedTop { r.origin.y = top - r.height }
        super.setFrame(r, display: flag)
    }
}

/// The App Volume flyout: system output and input, then every app playing sound.
struct AppVolumeFlyout: View {
    let module: AppVolumeModule
    @Bindable var settings: Persisted<AppVolumeSettings>
    var store: AppVolumeStore
    var maxHeight: CGFloat
    @State private var expanded: String?
    @State private var outputOpen: Bool
    @State private var inputOpen: Bool

    init(module: AppVolumeModule, maxHeight: CGFloat = 720, expanded: String? = nil,
         outputOpen: Bool = false, inputOpen: Bool = false) {
        self.module = module
        self.settings = module.settings
        self.store = module.store
        self.maxHeight = maxHeight
        _expanded = State(initialValue: expanded)
        _outputOpen = State(initialValue: outputOpen)
        _inputOpen = State(initialValue: inputOpen)
    }

    var body: some View {
        GlassPanel(cornerRadius: 18) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    if store.capture == .silent { permissionCard.transition(.opacity) }
                    devicesCard
                    appsSection
                }
                .padding(14)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.never)
            .frame(maxHeight: maxHeight)
            .foregroundStyle(.white)
        }
        .frame(width: AppVolumeFlyoutPanel.width)
        .animation(.snappy(duration: 0.22), value: expanded)
        .animation(.snappy(duration: 0.22), value: outputOpen)
        .animation(.snappy(duration: 0.22), value: inputOpen)
        .animation(.smooth(duration: 0.25), value: store.rows.map(\.id))
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("App Volume").font(.system(size: 15, weight: .bold))
            Spacer()
            let adjusted = store.processing.count
            if adjusted > 0 {
                Text("\(adjusted) adjusted", comment: "App Volume flyout: number of apps whose sound MacToys changes right now")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Button { module.showSettings() } label: {
                Image(systemName: "gearshape").font(.system(size: 12, weight: .medium))
                    .frame(width: 28, height: 26)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help("App Volume Settings")
        }
    }

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.orange)
                Text("App Volume can't hear any apps").font(.system(size: 13, weight: .semibold))
            }
            Text("Allow MacToys in System Settings › Privacy & Security › Screen & System Audio Recording, under System Audio Recording Only. Until then, apps play as usual.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Open Privacy & Security") { module.openPrivacySettings() }
                    .buttonStyle(GlassButtonStyle(prominent: .orange))
                Button("Try Again") { module.retryCapture() }
                    .buttonStyle(GlassButtonStyle())
            }
            .padding(.top, 2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.orange.opacity(0.14)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.orange.opacity(0.3)))
    }

    // MARK: Devices

    private var devicesCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            DeviceSection(module: module, input: false, open: $outputOpen)
            if settings.value.showInputDevice {
                Rectangle().fill(.white.opacity(0.08)).frame(height: 1).padding(.vertical, 11)
                DeviceSection(module: module, input: true, open: $inputOpen)
            }
        }
        .flyoutCard()
    }

    // MARK: Apps

    private var appsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Apps").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if store.playingCount > 0 {
                    Text("\(store.playingCount) playing", comment: "App Volume flyout: number of apps playing sound")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .padding(.horizontal, 4)
            if store.rows.isEmpty {
                emptyState
            } else {
                VStack(spacing: 8) {
                    ForEach(store.rows) { row in
                        AppRowView(module: module, row: row, expanded: $expanded)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "waveform").font(.system(size: 22, weight: .medium)).foregroundStyle(.secondary)
                .symbolRenderingMode(.hierarchical)
            Text("Nothing is playing").font(.system(size: 13, weight: .semibold))
            Text("Apps appear here while they play sound. Pin an app to keep it listed.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .padding(.horizontal, 12)
        .flyoutCard(padding: 0)
    }
}

/// System output or input: the device, its volume and mute, and (opened) the device list.
private struct DeviceSection: View {
    let module: AppVolumeModule
    let input: Bool
    @Binding var open: Bool

    var body: some View {
        let store = module.store
        let device = input ? store.world.defaultInput : store.world.defaultOutput
        let controls = input ? store.input : store.output
        let devices = input ? store.world.inputDevices : store.world.outputDevices
        VStack(alignment: .leading, spacing: 9) {
            Button { open.toggle() } label: {
                HStack(spacing: 9) {
                    Image(systemName: DeviceSymbol.name(for: device, input: input))
                        .font(.system(size: 13, weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                        .frame(width: 20)
                    Text(verbatim: device?.name ?? "—").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 6)
                    (input ? Text("Input", comment: "Flyout: the system's sound input device")
                        : Text("Output", comment: "Flyout: the system's sound output device"))
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(input ? Text("Choose input device") : Text("Choose output device"))

            HStack(spacing: 6) {
                MuteButton(muted: controls.muted, input: input, enabled: controls.canMute) {
                    module.setSystemMuted(!controls.muted, input: input)
                }
                VolumeSlider(value: Binding(get: { Double(controls.volume ?? 0) },
                                            set: { module.setSystemVolume(Float($0), input: input) }),
                             dimmed: controls.muted, height: 18,
                             label: input ? Text("Input volume") : Text("Output volume"),
                             onHover: { module.hover(input ? .input : .output, $0) })
                    .disabled(!controls.canSetVolume)
                    .opacity(controls.canSetVolume ? 1 : 0.4)
                Text(verbatim: controls.volume.map { Double($0).formatted(.percent.precision(.fractionLength(0))) } ?? "—")
                    .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 38, alignment: .trailing)
            }
            if !controls.canSetVolume, device != nil {
                (input ? Text("This input has no volume control.")
                    : Text("This device has no volume control. Use the volume on the device itself."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if open {
                VStack(spacing: 2) {
                    ForEach(devices) { d in
                        DeviceRow(device: d, input: input, selected: d.uid == device?.uid) {
                            module.setDefaultDevice(d, input: input)
                        }
                    }
                }
                .padding(.top, 2)
                .transition(.opacity.combined(with: .move(edge: .top)))
                if !input { outputDetails(controls) }
            }
        }
    }

    @ViewBuilder
    private func outputDetails(_ controls: DeviceControls) -> some View {
        if let balance = controls.balance {
            HStack(spacing: 10) {
                Text("Balance").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize()
                CenteredSlider(value: Binding(get: { Double(balance) * 2 - 1 }, set: { module.setOutputBalance(Float(($0 + 1) / 2)) }),
                               leading: Text("L", comment: "Balance slider: left side"),
                               trailing: Text("R", comment: "Balance slider: right side"),
                               label: Text("Output balance"), valueText: BalanceText.describe)
            }
            .padding(.top, 4)
        }
        if controls.sampleRates.count > 1, let current = module.store.world.defaultOutput?.sampleRate {
            HStack {
                Text("Sample rate").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    ForEach(controls.sampleRates, id: \.self) { rate in
                        Button { module.setOutputSampleRate(rate) } label: {
                            if rate == current { Label(Self.rate(rate), systemImage: "checkmark") } else { Text(verbatim: Self.rate(rate)) }
                        }
                    }
                } label: {
                    PillLabel(text: Text(verbatim: Self.rate(current)))
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            }
        }
    }

    static func rate(_ hz: Double) -> String {
        Measurement(value: hz / 1000, unit: UnitFrequency.kilohertz)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided,
                                    numberFormatStyle: .number.precision(.fractionLength(0...1))))
    }
}

private struct DeviceRow: View {
    let device: AudioDeviceInfo
    let input: Bool
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: DeviceSymbol.name(for: device, input: input))
                    .font(.system(size: 12))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                    .frame(width: 20)
                Text(verbatim: device.name).font(.system(size: 12.5)).lineLimit(1)
                Spacer(minLength: 6)
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(selected ? 0.1 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// One app: icon, name, meter, mute, volume; opened, its output, balance and equalizer.
struct AppRowView: View {
    let module: AppVolumeModule
    let row: AppRow
    @Binding var expanded: String?

    var body: some View {
        let key = row.id
        let s = module.settings.value.settings(for: key)
        let isOpen = expanded == key
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                AppIconView(identity: row.identity, size: 32)
                    .saturation(row.state == .notRunning ? 0 : 1)
                    .opacity(row.state == .notRunning ? 0.55 : 1)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(verbatim: row.identity.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        badges(s)
                        Spacer(minLength: 6)
                        trailing
                    }
                    HStack(spacing: 6) {
                        MuteButton(muted: s.muted) { module.toggleMute(key) }
                        VolumeSlider(value: Binding(get: { module.appSettings(key).volume }, set: { module.setVolume(key, $0) }),
                                     maximum: module.settings.value.maxVolume, dimmed: s.muted, height: 18,
                                     label: Text("Volume of \(row.identity.name)", comment: "Accessibility label; the placeholder is an app name"),
                                     onHover: { module.hover(.app(key), $0) })
                        Text(verbatim: s.volume.formatted(.percent.precision(.fractionLength(0))))
                            .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                            .foregroundStyle(s.volume > 1 ? AnyShapeStyle(Color(nsColor: Tint.purple.nsColor.blended(withFraction: 0.45, of: .white) ?? .systemPurple))
                                             : AnyShapeStyle(.secondary))
                            .frame(minWidth: 38, alignment: .trailing)
                    }
                }
                Button { expanded = isOpen ? nil : key } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .frame(width: 20, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isOpen ? Text("Hide options") : Text("Output, balance and equalizer"))
                .accessibilityLabel(isOpen ? Text("Hide options") : Text("Output, balance and equalizer"))
            }
            if let failure = module.store.failures[key] {
                Label { Text(verbatim: failure) } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if isOpen {
                AppDetailView(module: module, key: key)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .flyoutCard(padding: 10, highlighted: isOpen)
    }

    @ViewBuilder
    private var trailing: some View {
        switch row.state {
        case .playing:
            if module.settings.value.showMeters { LevelMeter(levels: module.levels, key: row.id) }
        case .quiet:
            Text("Not playing", comment: "App Volume: the app is running but silent").font(.system(size: 11)).foregroundStyle(.tertiary)
        case .notRunning:
            Text("Not running", comment: "App Volume: a pinned app that isn't open").font(.system(size: 11)).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func badges(_ s: AppAudioSettings) -> some View {
        let world = module.store.world
        HStack(spacing: 4) {
            if s.outputUID != nil {
                let device = world.device(uid: s.outputUID)
                Image(systemName: DeviceSymbol.name(for: device))
                    .help(Text(verbatim: device?.name ?? s.outputName ?? ""))
            }
            if s.eq.isEffective {
                Image(systemName: "slider.vertical.3").help(Text("Equalizer on"))
            }
            if s.balance != 0 {
                Image(systemName: s.balance < 0 ? "l.circle" : "r.circle").help(Text(verbatim: BalanceText.describe(s.balance)))
            }
            if module.settings.value.isPinned(row.id) {
                Image(systemName: "pin.fill").help(Text("Pinned"))
            }
        }
        .font(.system(size: 9.5, weight: .semibold))
        .foregroundStyle(.secondary)
    }
}

/// An app's output device, balance and equalizer.
struct AppDetailView: View {
    let module: AppVolumeModule
    let key: String

    var body: some View {
        let s = module.settings.value.settings(for: key)
        let bandCount = module.settings.value.eqBandCount
        VStack(alignment: .leading, spacing: 12) {
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
            detailRow(Text("Output", comment: "App Volume: the device an app plays to")) { outputMenu(s) }
            detailRow(Text("Balance")) {
                CenteredSlider(value: Binding(get: { module.appSettings(key).balance }, set: { module.setBalance(key, $0) }),
                               leading: Text("L", comment: "Balance slider: left side"),
                               trailing: Text("R", comment: "Balance slider: right side"),
                               label: Text("Balance"), valueText: BalanceText.describe)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Toggle(isOn: Binding(get: { s.eq.isOn }, set: { on in
                        var eq = module.appSettings(key).eq
                        eq.isOn = on
                        if eq.gains.isEmpty { eq.gains = Array(repeating: 0, count: bandCount) }
                        module.setEQ(key, eq)
                    })) {
                        Text("Equalizer").font(.system(size: 12.5, weight: .semibold))
                    }
                    .toggleStyle(.adaptiveSwitch)
                    .controlSize(.mini)
                    Spacer()
                    presetMenu(s)
                }
                EQCurveView(eq: s.eq, bandCount: bandCount) { gains in
                    var eq = module.appSettings(key).eq
                    eq.gains = gains
                    eq.isOn = true
                    eq.preset = EQPreset.matching(gains, count: bandCount)?.id
                    module.setEQ(key, eq)
                }
                HStack(spacing: 10) {
                    Text("Preamp", comment: "Equalizer: gain before the bands").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize()
                    CenteredSlider(value: Binding(get: { module.appSettings(key).eq.preamp }, set: { v in
                        var eq = module.appSettings(key).eq
                        eq.preamp = v
                        if v != 0 { eq.isOn = true }
                        if eq.gains.isEmpty { eq.gains = Array(repeating: 0, count: bandCount) }
                        module.setEQ(key, eq)
                    }), range: EQLayout.gainRange, step: 0.5, label: Text("Preamp"), valueText: EQCurveView.dB)
                    Text(verbatim: EQCurveView.dB(s.eq.preamp))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 44, alignment: .trailing)
                }
            }
            HStack(spacing: 14) {
                let pinned = module.settings.value.isPinned(key)
                Button { module.togglePin(key) } label: {
                    pinned ? Label("Unpin", systemImage: "pin.slash") : Label("Keep in List", systemImage: "pin")
                }
                Spacer()
                Button { module.resetApp(key) } label: { Label("Reset", systemImage: "arrow.counterclockwise") }
                    .disabled(!s.isAdjusted && s.eq.gains.allSatisfy { $0 == 0 })
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
        }
    }

    private func detailRow<Content: View>(_ label: Text, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            label.font(.system(size: 12)).foregroundStyle(.secondary).frame(minWidth: 54, alignment: .leading).fixedSize()
            content()
        }
    }

    private func outputMenu(_ s: AppAudioSettings) -> some View {
        let world = module.store.world
        let chosen = world.device(uid: s.outputUID)
        let devices = world.outputDevices.filter { TapPolicy.usableOutput($0) != nil }
        let title: String = if s.outputUID == nil {
            String(localized: "System Output", comment: "App Volume: the app follows the system's output device")
        } else if let chosen {
            chosen.name
        } else {
            String(localized: "\(s.outputName ?? "?") (not connected)", comment: "App Volume: the chosen output device is unplugged; the placeholder is its name")
        }
        return HStack {
            Menu {
                Button { module.setOutput(key, nil) } label: {
                    let name = String(localized: "System Output (\(world.defaultOutput?.name ?? "—"))",
                                      comment: "App Volume menu item; the placeholder is the current system output device")
                    if s.outputUID == nil { Label(name, systemImage: "checkmark") } else { Text(verbatim: name) }
                }
                Divider()
                ForEach(devices) { d in
                    Button { module.setOutput(key, d) } label: {
                        if d.uid == s.outputUID { Label(d.name, systemImage: "checkmark") } else { Text(verbatim: d.name) }
                    }
                }
            } label: {
                PillLabel(symbol: DeviceSymbol.name(for: chosen ?? (s.outputUID == nil ? world.defaultOutput : nil)),
                          text: Text(verbatim: title))
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            Spacer(minLength: 0)
        }
    }

    private func presetMenu(_ s: AppAudioSettings) -> some View {
        let custom = module.settings.value.customPresets
        let name = EQPreset.named(s.eq.preset)?.name ?? custom.first { $0.id == s.eq.preset }?.name
            ?? String(localized: "Custom", comment: "Equalizer: a hand-tuned curve that isn't a saved preset")
        return Menu {
            ForEach(EQPreset.all) { p in
                Button { module.applyPreset(key, id: p.id) } label: {
                    if s.eq.preset == p.id { Label(p.name, systemImage: "checkmark") } else { Text(verbatim: p.name) }
                }
            }
            if !custom.isEmpty {
                Divider()
                ForEach(custom) { p in
                    Button { module.applyPreset(key, id: p.id) } label: {
                        if s.eq.preset == p.id { Label(p.name, systemImage: "checkmark") } else { Text(verbatim: p.name) }
                    }
                }
            }
            Divider()
            Button("Save as Preset…") { module.promptPresetName(for: key) }
        } label: {
            PillLabel(text: Text(verbatim: name))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }
}
