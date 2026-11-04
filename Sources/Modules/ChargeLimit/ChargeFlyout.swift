import MacToysCore
import SwiftUI

/// The menu bar flyout: the battery, the limit slider and the quick actions, on dark glass.
struct ChargeFlyout: View {
    let module: ChargeLimitModule
    @Bindable var settings: Persisted<ChargeLimitSettings>
    var model: ChargeLimitModel

    init(module: ChargeLimitModule) {
        self.module = module
        self.settings = module.settings
        self.model = module.model
    }

    var body: some View {
        let display = ChargeDisplay.of(model, settings: settings.value)
        GlassPanel(cornerRadius: 18) {
            VStack(alignment: .leading, spacing: 12) {
                header(display)
                summary(display)
                if case .live(let status) = display {
                    controls(status)
                }
                Divider().opacity(0.5)
                footer
            }
            .padding(14)
            .foregroundStyle(.white)
        }
        .frame(width: ChargeFlyoutPanel.width)
        .animation(.smooth(duration: 0.3), value: display)
    }

    private func header(_ display: ChargeDisplay) -> some View {
        HStack(spacing: 8) {
            Text("Charge Limit").font(.system(size: 15, weight: .bold))
            Spacer()
            if case .live(let status) = display {
                StatePill(title: ChargeText.title(status.state, percent: model.battery?.percent, config: status.config),
                          symbol: ChargeText.symbol(status.state, percent: model.battery?.percent, config: status.config),
                          tint: ChargeText.tint(status.state).mix(with: .white, by: 0.25))
            }
            Button {
                ModuleRegistry.shared.showSettings?(module.info.id)
            } label: {
                Image(systemName: "gearshape").font(.system(size: 12, weight: .medium))
                    .frame(width: 26, height: 24)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help("Charge Limit settings")
        }
    }

    @ViewBuilder
    private func summary(_ display: ChargeDisplay) -> some View {
        let level = model.battery?.percent ?? 0
        HStack(alignment: .center, spacing: 14) {
            switch display {
            case .live(let status):
                BatteryGauge(level: level, range: status.config.isLimiting ? status.config.lower...status.config.upper : nil,
                             fill: status.state == .discharging ? Tint.orange.color
                                : status.state == .toppingUp || status.state == .full ? Tint.blue.color : Tint.green.color,
                             bolt: model.battery?.isCharging == true)
                    .frame(width: 132, height: 60)
                VStack(alignment: .leading, spacing: 3) {
                    BigPercent(value: level, size: 30)
                    Text(verbatim: ChargeText.headline(status.state, config: status.config))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
            default:
                BatteryGauge(level: level, range: nil, fill: Tint.graphite.color, bolt: model.battery?.isCharging == true, labels: false)
                    .frame(width: 96, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    BigPercent(value: level, size: 26)
                    Text(verbatim: ChargeText.statusLine(model: model, settings: settings.value))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        if case .live(let status) = display {
            Text(verbatim: ChargeText.detail(status.state, config: status.config, battery: model.battery, hardware: model.hardware))
                .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Button("Open Charge Limit Settings…") { ModuleRegistry.shared.showSettings?(module.info.id) }
                .buttonStyle(.link)
                .font(.system(size: 12, weight: .semibold))
        }
    }

    private func controls(_ status: HelperStatus) -> some View {
        let c = status.config
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Limit").font(.system(size: 12.5, weight: .medium))
                Slider(value: Binding(get: { Double(settings.value.upperLimit) }, set: { module.setUpperLimit(Int($0.rounded())) }),
                       in: Double(ChargePolicy.upperRange.lowerBound)...Double(ChargePolicy.upperRange.upperBound))
                    .controlSize(.small)
                    .tint(Tint.green.color)
                Text(verbatim: ChargeText.percent(settings.value.upperLimit))
                    .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                    .frame(minWidth: 40, alignment: .trailing)
            }
            .disabled(c.paused || c.calibration != nil)
            HStack(spacing: 8) {
                FlyoutChip(title: Text("Top Up"), symbol: "battery.100percent.bolt", isOn: c.topUp,
                           tint: Tint.blue.color) { module.setTopUp(!c.topUp) }
                    .disabled(c.calibration != nil)
                if model.hardware.capabilities.adapterSwitch {
                    FlyoutChip(title: Text("Discharge"), symbol: "arrow.down.circle", isOn: settings.value.dischargeToLimit,
                               tint: Tint.orange.color) { settings.value.dischargeToLimit.toggle() }
                }
                FlyoutChip(title: c.paused ? Text("Resume") : Text("Pause"), symbol: c.paused ? "play.fill" : "pause.fill",
                           isOn: c.paused, tint: Tint.graphite.color) { c.paused ? module.resume() : module.pause() }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if let b = model.battery {
                Image(systemName: "heart.fill").font(.system(size: 10)).foregroundStyle(Tint.green.color)
                Text(verbatim: footerLine(b))
                    .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1).minimumScaleFactor(0.85)
            }
            Spacer(minLength: 0)
        }
    }

    private func footerLine(_ b: BatterySnapshot) -> String {
        var parts: [String] = []
        if let h = b.healthPercent { parts.append(String(localized: "Health \(ChargeText.percent(h))", comment: "Flyout footer: maximum capacity")) }
        if let c = b.cycleCount { parts.append(String(localized: "\(c) cycles", comment: "Flyout footer: battery cycle count")) }
        if let t = b.temperature { parts.append(ChargeText.temperature(t)) }
        return parts.joined(separator: " · ")
    }
}

/// A toggle-like chip in the flyout.
private struct FlyoutChip: View {
    let title: Text
    let symbol: String
    let isOn: Bool
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11.5, weight: .semibold))
                title.font(.system(size: 12, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(isOn ? tint.opacity(0.55) : .white.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.white.opacity(isOn ? 0.25 : 0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
