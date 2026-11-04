import MacToysCore
import SwiftUI

/// The settings page hero: the battery with the range it is kept in, what Charge Limit is doing, and
/// the actions that matter right now.
struct ChargeHero: View {
    let module: ChargeLimitModule
    var model: ChargeLimitModel
    var settings: ChargeLimitSettings

    var body: some View {
        let display = ChargeDisplay.of(model, settings: settings)
        HeroCard(tint: .green) {
            HStack(alignment: .center, spacing: 26) {
                gauge(display)
                    .frame(width: 236, height: 104)
                VStack(alignment: .leading, spacing: 8) {
                    content(display)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .animation(.smooth(duration: 0.35), value: display)
        }
    }

    // MARK: Gauge

    @ViewBuilder
    private func gauge(_ display: ChargeDisplay) -> some View {
        let level = model.battery?.percent ?? 0
        switch display {
        case .live(let status):
            let c = status.config
            BatteryGauge(level: level, range: c.isLimiting || status.state == .calibrating ? c.lower...c.upper : nil,
                         fill: gaugeFill(status.state, level: level),
                         bolt: model.battery?.isCharging == true)
        case .needsHelper, .helperProblem:
            BatteryGauge(level: level, range: settings.lowerLimit...settings.upperLimit,
                         fill: Tint.green.color.opacity(0.75), bolt: model.battery?.isCharging == true)
        case .systemEngine:
            let limit = model.systemLimit.activeLimit
            BatteryGauge(level: level, range: limit.map { $0...$0 }, fill: Tint.green.color,
                         bolt: model.battery?.isCharging == true)
        case .unsupported:
            BatteryGauge(level: level, range: nil, fill: Tint.graphite.color, bolt: model.battery?.isCharging == true)
        }
    }

    private func gaugeFill(_ state: ChargeState, level: Int) -> Color {
        if level < 20 && state != .chargingToLimit { return Tint.red.color }
        switch state {
        case .discharging: return Tint.orange.color
        case .toppingUp, .full: return Tint.blue.color
        case .heatPaused: return Tint.orange.color
        case .paused, .asleep, .onBattery: return Tint.graphite.color
        default: return Tint.green.color
        }
    }

    // MARK: Text and actions

    @ViewBuilder
    private func content(_ display: ChargeDisplay) -> some View {
        switch display {
        case .live(let status):
            let c = status.config
            StatePill(title: ChargeText.title(status.state, percent: model.battery?.percent, config: c),
                      symbol: ChargeText.symbol(status.state, percent: model.battery?.percent, config: c),
                      tint: ChargeText.tint(status.state))
            if let p = model.battery?.percent { BigPercent(value: p) }
            Text(verbatim: ChargeText.headline(status.state, config: c))
                .font(.system(size: 14, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: ChargeText.detail(status.state, config: c, battery: model.battery, hardware: model.hardware))
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = status.lastError {
                Label { Text("Last write failed: \(error)", comment: "The placeholder is a technical error (English)") } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if c.calibration == nil {
                    if c.topUp {
                        Button("Cancel Top Up") { module.setTopUp(false) }
                    } else {
                        Button { module.setTopUp(true) } label: {
                            Label("Top Up to \(ChargeText.percent(100))", systemImage: "battery.100percent.bolt")
                        }
                        .help("Charges to full once, before a trip. The limit returns when you unplug.")
                    }
                }
                if c.paused {
                    Button { module.resume() } label: { Label("Resume", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent).tint(Tint.green.color)
                } else {
                    Button { module.pause() } label: { Label("Pause", systemImage: "pause.fill") }
                        .help("Charge normally until you resume.")
                }
            }
            .controlSize(.regular)
            .padding(.top, 2)
        case .needsHelper:
            StatePill(title: String(localized: "Supported on this Mac"), symbol: "checkmark.circle.fill", tint: Tint.green.color)
            Text("Install the helper to start")
                .font(.system(size: 17, weight: .semibold))
            Text("A small helper that runs as root switches charging on and off. macOS asks for your password once; you can remove it here at any time.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button { module.installHelper() } label: { Text("Install Helper…") }
                    .buttonStyle(.borderedProminent).tint(Tint.green.color)
                    .disabled(model.task != nil)
                if model.task == .installing { ProgressView().controlSize(.small) }
            }
            .padding(.top, 2)
        case .helperProblem:
            let outdated = { if case .outdated = model.helper { true } else { false } }()
            StatePill(title: outdated ? String(localized: "Update needed") : String(localized: "Not responding"),
                      symbol: "exclamationmark.triangle.fill", tint: Tint.orange.color)
            (outdated ? Text("The helper is out of date") : Text("The helper isn't responding"))
                .font(.system(size: 17, weight: .semibold))
            (outdated
                ? Text("MacToys installs the version that matches this app. Charging stays normal until then.")
                : Text("If you turned MacToys off in System Settings › General › Login Items & Extensions, turn it back on, or reinstall the helper."))
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button { module.installHelper() } label: { outdated ? Text("Update Helper…") : Text("Reinstall Helper…") }
                    .buttonStyle(.borderedProminent).tint(Tint.green.color)
                    .disabled(model.task != nil)
                if model.task != nil { ProgressView().controlSize(.small) }
            }
            .padding(.top, 2)
        case .systemEngine:
            StatePill(title: String(localized: "macOS charge limit"), symbol: "apple.logo", tint: Tint.graphite.color)
            if let limit = model.systemLimit.activeLimit {
                Text("macOS limits charging to \(ChargeText.percent(limit))", comment: "The placeholder is a percentage")
                    .font(.system(size: 17, weight: .semibold))
            } else {
                Text("macOS manages charging")
                    .font(.system(size: 17, weight: .semibold))
            }
            Text("Set the limit in System Settings › Battery › Charging. MacToys leaves charging alone.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Battery Settings") { module.openBatterySettings() }
                .padding(.top, 2)
        case .unsupported(let reason):
            StatePill(title: String(localized: "Not supported on this Mac"), symbol: "xmark.circle.fill", tint: Tint.graphite.color)
            Text("Charge Limit can't switch charging here")
                .font(.system(size: 17, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: ChargeText.unsupportedReason(reason))
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.systemLimit.available {
                SystemLimitNote(limit: model.systemLimit.activeLimit)
                Button("Open Battery Settings") { module.openBatterySettings() }
                    .padding(.top, 2)
            }
        }
    }
}

/// "macOS has its own charge limit…" (with the current value when known).
struct SystemLimitNote: View {
    let limit: Int?

    var body: some View {
        Group {
            if let limit {
                Text("macOS has its own charge limit in Battery settings, set to \(ChargeText.percent(limit)) now.",
                     comment: "The placeholder is the current macOS charge limit")
            } else {
                Text("macOS has its own charge limit (\(ChargeText.percent(80))–\(ChargeText.percent(100))) in Battery settings.",
                     comment: "Placeholders are the range macOS offers")
            }
        }
        .font(.system(size: 12, weight: .medium))
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A small tinted capsule: icon + state.
struct StatePill: View {
    let title: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10.5, weight: .bold))
            Text(verbatim: title).font(.system(size: 11.5, weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 3.5)
        .background(Capsule().fill(tint.opacity(0.13)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.22), lineWidth: 0.5))
        .fixedSize()
        .contentTransition(.opacity)
    }
}

/// "78 %" with the number large and the sign small, in the locale's order.
struct BigPercent: View {
    let value: Int
    var size: CGFloat = 40

    var body: some View {
        let text = ChargeText.percent(value)
        let number = Font.system(size: size, weight: .semibold, design: .rounded).monospacedDigit()
        let sign = Font.system(size: size * 0.55, weight: .semibold, design: .rounded)
        let composed: Text
        if let r = text.range(of: "%") {
            composed = Text(verbatim: String(text[..<r.lowerBound])).font(number)
                + Text(verbatim: "%").font(sign).foregroundStyle(.secondary)
                + Text(verbatim: String(text[r.upperBound...])).font(number)
        } else {
            composed = Text(verbatim: text).font(number)
        }
        return composed
            .contentTransition(.numericText(value: Double(value)))
            .lineLimit(1)
    }
}

// MARK: - Health

/// Maximum capacity, cycle count and temperature.
struct BatteryHealthCard: View {
    let battery: BatterySnapshot?

    var body: some View {
        if let b = battery {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    HealthTile(symbol: "heart.fill", tint: .green, title: Text("Maximum capacity"),
                               value: b.healthPercent.map { ChargeText.percent($0) } ?? "—",
                               detail: capacityText(b), fraction: b.healthPercent.map { Double($0) / 100 })
                    HealthTile(symbol: "arrow.triangle.2.circlepath", tint: .blue, title: Text("Cycle count"),
                               value: b.cycleCount.map { $0.formatted() } ?? "—",
                               detail: b.designCycleCount.map { String(localized: "of \($0.formatted()) designed", comment: "Battery cycle count detail; the placeholder is a number") },
                               fraction: cycleFraction(b))
                    HealthTile(symbol: "thermometer.medium", tint: temperatureTint(b.temperature), title: Text("Temperature"),
                               value: b.temperature.map { ChargeText.temperature($0) } ?? "—",
                               detail: temperatureWord(b.temperature), fraction: b.temperature.map { min(1, max(0, ($0 - 15) / 30)) })
                }
                Text(verbatim: conditionLine(b))
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            ContentUnavailableView {
                Label("No battery", systemImage: "powerplug")
            } description: {
                Text("This Mac runs on mains power only.")
            }
        }
    }

    private func capacityText(_ b: BatterySnapshot) -> String? {
        guard let full = b.fullChargeCapacity, let design = b.designCapacity else { return nil }
        return String(localized: "\(full.formatted()) of \(design.formatted()) mAh", comment: "Battery capacity detail; placeholders are milliamp-hours")
    }

    private func cycleFraction(_ b: BatterySnapshot) -> Double? {
        guard let c = b.cycleCount, let d = b.designCycleCount, d > 0 else { return nil }
        return min(1, Double(c) / Double(d))
    }

    private func temperatureTint(_ t: Double?) -> Tint {
        guard let t else { return .graphite }
        return t >= 40 ? .red : t >= 35 ? .orange : .teal
    }

    private func temperatureWord(_ t: Double?) -> String? {
        guard let t else { return nil }
        if t >= 40 { return String(localized: "Hot", comment: "Battery temperature") }
        if t >= 35 { return String(localized: "Warm", comment: "Battery temperature") }
        return String(localized: "Normal range", comment: "Battery temperature: within the usual range")
    }

    private func conditionLine(_ b: BatterySnapshot) -> String {
        let condition = (b.healthPercent ?? 100) >= 80
            ? String(localized: "Condition: Normal", comment: "Battery condition")
            : String(localized: "Condition: below \(ChargeText.percent(80)) of its design capacity; consider a service",
                     comment: "Battery condition; the placeholder is a percentage")
        guard let w = b.batteryWatts, abs(w) >= 0.5 else { return condition }
        let watts = Measurement(value: abs(w), unit: UnitPower.watts).formatted(.measurement(width: .abbreviated, numberFormatStyle: .number.precision(.fractionLength(1))))
        return w > 0
            ? String(localized: "\(condition) · charging at \(watts)", comment: "Battery line; placeholders are the condition and a power")
            : String(localized: "\(condition) · supplying \(watts)", comment: "Battery line; placeholders are the condition and a power")
    }
}

private struct HealthTile: View {
    let symbol: String
    let tint: Tint
    let title: Text
    let value: String
    let detail: String?
    let fraction: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint.color)
                    .frame(width: 20, height: 20)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(tint.color.opacity(0.14)))
                title.font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.85)
            }
            Text(verbatim: value)
                .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                .lineLimit(1)
            if let fraction {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule().fill(tint.color).frame(width: max(4, geo.size.width * fraction))
                    }
                }
                .frame(height: 4)
            }
            Text(verbatim: detail ?? " ")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.85)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
    }
}
