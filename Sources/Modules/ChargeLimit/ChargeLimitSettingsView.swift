import MacToysCore
import SwiftUI

struct ChargeLimitSettingsView: View {
    let module: ChargeLimitModule
    var model: ChargeLimitModel
    @State private var confirmUninstall = false

    init(module: ChargeLimitModule) {
        self.module = module
        self.model = module.model
    }

    var body: some View {
        SettingsPage(module: module) {
            ChargeHero(module: module, model: model, settings: module.settings.value)
            if let message = model.message {
                InfoBar(.error, title: Text("Something went wrong"), message: Text(verbatim: message),
                        actionTitle: Text("Dismiss")) { model.message = nil }
            }
        } content: {
            ChargeLimitSections(module: module, confirmUninstall: $confirmUninstall)
        }
        .task {
            model.refreshLocal()
            await model.refreshHelper()
        }
        .confirmationDialog("Remove the charge helper?", isPresented: $confirmUninstall) {
            Button("Remove Helper", role: .destructive) { module.uninstallHelper() }
        } message: {
            Text("Charging goes back to normal and every file the helper installed is deleted.")
        }
    }
}

/// The page's sections, below the hero (also rendered on their own by the preview scenes).
struct ChargeLimitSections: View {
    let module: ChargeLimitModule
    @Bindable var s: Persisted<ChargeLimitSettings>
    var model: ChargeLimitModel
    @Binding var confirmUninstall: Bool
    @State private var showFiles = false

    init(module: ChargeLimitModule, confirmUninstall: Binding<Bool>) {
        self.module = module
        self.s = module.settings
        self.model = module.model
        self._confirmUninstall = confirmUninstall
    }

    private var caps: ControlCapabilities { model.hardware.capabilities }
    private var usesSystem: Bool { s.value.engine == .system && model.systemLimit.available }

    var body: some View {
        if model.hardware.isSupported {
            if model.systemLimit.available { engineSection }
            if !usesSystem {
                limitSection
                protectionSection
                calibrationSection
                if model.hardware.led { ledSection }
            }
        }
        if case .noKnownKeys = model.hardware.unsupported { thisMacSection }
        if case .unexpectedFormat = model.hardware.unsupported { thisMacSection }
        healthSection
        if model.hardware.isSupported && !usesSystem {
            menuBarSection
            shortcutsSection
        }
        if model.hardware.isSupported || model.helper.isInstalled { helperSection }
    }

    // MARK: - Engine

    private var engineSection: some View {
        Section("Charge limit by") {
            Picker(selection: $s.value.engine) {
                Text("MacToys").tag(ChargeLimitSettings.Engine.macToys)
                Text("macOS", comment: "Charge limit engine: the one built into macOS").tag(ChargeLimitSettings.Engine.system)
            } label: {
                RowLabel(title: Text("Who limits charging"),
                         subtitle: usesSystem
                            ? Text("The limit built into macOS: \(ChargeText.percent(80))–\(ChargeText.percent(100)), set in Battery settings. Nothing to install.",
                                   comment: "Placeholders are the range macOS offers")
                            : Text("MacToys: any limit from \(ChargeText.percent(50)), a sailing range, discharge while plugged in and heat protection. Needs a small helper.",
                                   comment: "The placeholder is the lowest limit"))
            }
            .pickerStyle(.segmented)
            .fixedSize(horizontal: false, vertical: true)
            if usesSystem {
                LabeledContent {
                    Button("Open Battery Settings") { module.openBatterySettings() }
                } label: {
                    SystemLimitNote(limit: model.systemLimit.activeLimit)
                }
            } else if let limit = model.systemLimit.activeLimit {
                InfoBar(.warning, title: Text("macOS is limiting charging too"),
                        message: Text("Its limit is \(ChargeText.percent(limit)); the battery stops at whichever limit is lower. Turn one of them off.",
                                      comment: "The placeholder is the macOS charge limit"),
                        actionTitle: Text("Open Battery Settings")) { module.openBatterySettings() }
            }
        }
    }

    // MARK: - Limit

    private var limitSection: some View {
        Section {
            SliderRow(label: RowLabel(title: Text("Charge limit"),
                                      subtitle: Text("Charging stops here. Between \(ChargeText.percent(50)) and \(ChargeText.percent(80)) is gentlest for the battery.",
                                                     comment: "Placeholders are percentages")),
                      value: Binding(get: { Double(s.value.upperLimit) }, set: { module.setUpperLimit(Int($0.rounded())) }),
                      in: Double(ChargePolicy.upperRange.lowerBound)...Double(ChargePolicy.upperRange.upperBound),
                      format: { ChargeText.percent(Int($0.rounded())) })
            if caps.chargingSwitch {
                SliderRow(label: RowLabel(title: Text("Sailing range"),
                                          subtitle: s.value.sailingRange == 0
                                            ? Text("Charging resumes as soon as the battery drops below the limit.")
                                            : Text("Charging resumes only at \(ChargeText.percent(s.value.lowerLimit)), so the battery isn't topped up every few minutes.",
                                                   comment: "The placeholder is the lower bound")),
                          value: Binding(get: { Double(s.value.sailingRange) }, set: { s.value.sailingRange = Int($0.rounded()) }),
                          in: Double(ChargePolicy.sailingRange.lowerBound)...Double(ChargePolicy.sailingRange.upperBound),
                          format: { ChargeText.percent(Int($0.rounded())) })
            }
            Toggle(isOn: $s.value.dischargeToLimit) {
                RowLabel(title: Text("Discharge to the limit while plugged in"),
                         subtitle: caps.adapterSwitch
                            ? Text("Above the limit, your Mac runs from its battery until it is down to the limit, then switches back to the adapter.")
                            : Text("This Mac can't switch its adapter off. Unplug it to bring the battery down to the limit."))
            }
            .disabled(!caps.adapterSwitch)
        } header: {
            Text("Limit")
        } footer: {
            Text("The limit keeps working when MacToys is closed. Turning Charge Limit off gives charging back to macOS.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
    }

    // MARK: - Protection

    private var protectionSection: some View {
        Section("Protection") {
            Toggle(isOn: $s.value.heatProtection) {
                RowLabel(title: Text("Heat protection"),
                         subtitle: caps.chargingSwitch
                            ? Text("Pauses charging while the battery is too warm, at least five minutes at a time.")
                            : Text("This Mac keeps its limit in firmware and can't pause charging below it."))
            }
            .disabled(!caps.chargingSwitch)
            if s.value.heatProtection && caps.chargingSwitch {
                SliderRow(label: RowLabel(title: Text("Pause above"),
                                          subtitle: Text("\(ChargeText.temperature(35, digits: 0)) suits most rooms; lower values may stop charging on warm days.",
                                                         comment: "The placeholder is a temperature")),
                          value: Binding(get: { Double(s.value.maxTemperature) }, set: { s.value.maxTemperature = Int($0.rounded()) }),
                          in: Double(ChargePolicy.temperatureRange.lowerBound)...Double(ChargePolicy.temperatureRange.upperBound),
                          format: { ChargeText.temperature($0, digits: 0) })
            }
            SafetyRow(symbol: "moon.fill", title: Text("While your Mac sleeps it charges normally"),
                      detail: Text("Charge Limit can't watch the battery during sleep, so it hands charging back to macOS and applies the limit again when your Mac wakes."))
            SafetyRow(symbol: "shield.lefthalf.filled", title: Text("Normal charging whenever something is off"),
                      detail: Text("Below \(ChargeText.percent(ChargePolicy.floor)), after a failed switch, when the helper stops or crashes, and on uninstall, charging goes back to normal.",
                                   comment: "The placeholder is the hard floor percentage"))
        }
    }

    // MARK: - Calibration

    private var calibrationSection: some View {
        Section("Calibration") {
            let phase = model.config?.calibration
            VStack(alignment: .leading, spacing: 10) {
                RowLabel(title: Text("Recalibrate the battery gauge"),
                         subtitle: Text("Use it when the percentage jumps or your Mac shuts down early. It takes a few hours; once every month or two is plenty."))
                HStack(spacing: 8) {
                    CalibrationStep(number: 1, title: Text("Charge to \(ChargeText.percent(100))", comment: "Calibration step"),
                                    state: stepState(.chargeToFull, current: phase))
                    CalibrationStep(number: 2, title: caps.adapterSwitch
                                        ? Text("Run down to \(ChargeText.percent(ChargePolicy.calibrationTarget))", comment: "Calibration step")
                                        : Text("Unplug, run down to \(ChargeText.percent(ChargePolicy.calibrationTarget))", comment: "Calibration step"),
                                    state: stepState(.dischargeToTarget, current: phase))
                    CalibrationStep(number: 3, title: Text("Back to \(ChargeText.percent(s.value.upperLimit))", comment: "Calibration step: charge back to the limit"),
                                    state: stepState(.chargeToLimit, current: phase))
                }
                HStack(spacing: 10) {
                    if phase != nil {
                        Button("Stop Calibration") { module.setCalibration(false) }
                    } else {
                        Button("Start Calibration") { module.setCalibration(true) }
                            .disabled(!model.helper.isRunning)
                    }
                    if let date = model.config?.lastCalibrated {
                        Text("Last calibrated \(date.formatted(date: .abbreviated, time: .omitted))",
                             comment: "The placeholder is a date")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func stepState(_ step: CalibrationPhase, current: CalibrationPhase?) -> CalibrationStep.Progress {
        guard let current else { return .waiting }
        if step == current { return .active }
        return step.step < current.step ? .done : .waiting
    }

    // MARK: - LED

    private var ledSection: some View {
        Section("MagSafe") {
            Picker(selection: $s.value.ledMode) {
                ForEach(LEDMode.allCases) { Text(verbatim: $0.title).tag($0) }
            } label: {
                RowLabel(title: Text("Connector light"), subtitle: ledSubtitle)
            }
        }
    }

    private var ledSubtitle: Text {
        switch s.value.ledMode {
        case .system: Text("macOS shows orange while charging and green when the battery is full.")
        case .limitState: Text("Green at the limit, orange while charging or discharging toward it.")
        case .off: Text("The light on the connector stays off.")
        }
    }

    // MARK: - This Mac (unsupported)

    private var thisMacSection: some View {
        Section("This Mac") {
            LabeledContent {
                Text(verbatim: (model.hardware.keyNames + model.hardware.unexpected).joined(separator: " · "))
                    .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            } label: {
                RowLabel("Power controller switches found",
                         subtitle: "Charge Limit needs CHTE or CH0B (Apple silicon) or BCLM (Intel) to switch charging. It only read these; nothing was changed.")
            }
        }
    }

    // MARK: - Health

    private var healthSection: some View {
        Section("Battery health") {
            BatteryHealthCard(battery: model.battery)
                .padding(.vertical, 4)
        }
    }

    // MARK: - Menu bar and shortcuts

    private var menuBarSection: some View {
        Section("Menu bar") {
            Toggle(isOn: $s.value.showMenuBarItem) {
                RowLabel("Show Charge Limit in the menu bar", subtitle: "A battery with the limit marked; click it for the limit, top up and pause.")
            }
            Toggle(isOn: $s.value.showPercentInMenuBar) {
                RowLabel("Show the percentage", subtitle: "Next to the battery.")
            }
            .disabled(!s.value.showMenuBarItem)
        }
    }

    private var shortcutsSection: some View {
        Section("Shortcuts") {
            ShortcutRow("Pause or resume", subtitle: "Charges normally until you press it again.", shortcut: $s.value.toggleShortcut)
            ShortcutRow("Top up", subtitle: "Charges to full once; the limit returns when you unplug.", shortcut: $s.value.topUpShortcut)
        }
    }

    // MARK: - Helper

    private var helperSection: some View {
        Section("Helper") {
            LabeledContent {
                HStack(spacing: 8) {
                    if model.task != nil { ProgressView().controlSize(.small) }
                    switch model.helper {
                    case .notInstalled:
                        Button("Install Helper…") { module.installHelper() }
                            .disabled(model.task != nil || !model.hardware.isSupported)
                    case .outdated:
                        Button("Update Helper…") { module.installHelper() }.disabled(model.task != nil)
                        Button("Remove…") { confirmUninstall = true }.disabled(model.task != nil)
                    case .notResponding:
                        Button("Reinstall…") { module.installHelper() }.disabled(model.task != nil || !model.hardware.isSupported)
                        Button("Remove…") { confirmUninstall = true }.disabled(model.task != nil)
                    case .running:
                        Button("Remove…") { confirmUninstall = true }.disabled(model.task != nil)
                    }
                }
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Circle().fill(helperDot).frame(width: 8, height: 8).padding(.top, 5)
                    RowLabel(title: helperTitle, subtitle: helperSubtitle)
                }
            }
            if model.hardware.isSupported {
                LabeledContent {
                    Text(verbatim: model.hardware.keyNames.joined(separator: " · "))
                        .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
                } label: {
                    RowLabel("Supported on this Mac", subtitle: "Charge Limit only ever writes these switches, after checking their format.")
                }
            }
            DisclosureGroup(isExpanded: $showFiles) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(HelperPaths.installed, id: \.self) { path in
                        Text(verbatim: path).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            } label: {
                Text("Installed files").font(.system(size: 12.5))
            }
        }
    }

    private var helperDot: Color {
        switch model.helper {
        case .running: Tint.green.color
        case .outdated: Tint.orange.color
        case .notResponding: Tint.red.color
        case .notInstalled: Color.secondary.opacity(0.5)
        }
    }

    private var helperTitle: Text {
        switch model.helper {
        case .running(let status): Text("Running · version \(status.version)", comment: "Charge helper status; the placeholder is a number")
        case .outdated(let status): Text("Out of date · version \(status.version)", comment: "Charge helper status; the placeholder is a number")
        case .notResponding: Text("Installed, not responding")
        case .notInstalled: Text("Not installed", comment: "Charge helper status")
        }
    }

    private var helperSubtitle: Text {
        switch model.helper {
        case .running:
            Text("Runs as root from /Library/PrivilegedHelperTools and switches charging. Only you can talk to it.")
        case .outdated:
            Text("MacToys installs the matching version when you update.")
        case .notResponding:
            Text("It may still be starting, or it was turned off in System Settings › General › Login Items & Extensions.")
        case .notInstalled:
            Text("Needed to switch charging; macOS asks for your password once.")
        }
    }
}

/// One numbered calibration step.
private struct CalibrationStep: View {
    enum Progress { case waiting, active, done }

    let number: Int
    let title: Text
    let state: Progress

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().fill(state == .waiting ? Color.primary.opacity(0.07) : Tint.purple.color.opacity(state == .done ? 1 : 0.16))
                if state == .done {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                } else {
                    Text(verbatim: number.formatted())
                        .font(.system(size: 11, weight: .bold).monospacedDigit())
                        .foregroundStyle(state == .active ? Tint.purple.color : .secondary)
                }
            }
            .frame(width: 22, height: 22)
            title
                .font(.system(size: 12, weight: state == .active ? .semibold : .regular))
                .foregroundStyle(state == .waiting ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(state == .active ? Tint.purple.color.opacity(0.08) : Color.primary.opacity(0.035)))
    }
}

/// An explanation row with an icon (no control).
private struct SafetyRow: View {
    let symbol: String
    let title: Text
    let detail: Text

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Tint.green.color)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Tint.green.color.opacity(0.12)))
            RowLabel(title: title, subtitle: detail)
            Spacer(minLength: 0)
        }
    }
}
