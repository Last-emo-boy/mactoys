import AppKit
import MacToysCore
import SwiftUI

/// Sample states for `MacToys --snapshot … --only chargelimit`.
@MainActor
enum ChargePreviews {
    static var scenes: [PreviewScene] {
        let heroSize = CGSize(width: 780, height: 290)
        return [
            PreviewScene("hero-charging", size: heroSize, wallpaper: false) {
                hero(percent: 64, charging: true, state: .chargingToLimit)
            },
            PreviewScene("hero-sailing", size: heroSize, wallpaper: false) {
                hero(percent: 78, charging: false, state: .holding)
            },
            PreviewScene("hero-discharging", size: heroSize, wallpaper: false) {
                hero(percent: 91, charging: false, amperage: -1.9, state: .discharging) { $0.dischargeToLimit = true }
            },
            PreviewScene("hero-topup", size: heroSize, wallpaper: false) {
                hero(percent: 94, charging: true, state: .toppingUp) { $0.topUp = true }
            },
            PreviewScene("hero-heat", size: heroSize, wallpaper: false) {
                hero(percent: 71, charging: false, temperature: 38.6, state: .heatPaused) {
                    $0.heatProtection = true
                    $0.maxTemperature = 37
                }
            },
            PreviewScene("hero-calibrating", size: heroSize, wallpaper: false) {
                hero(percent: 46, charging: false, amperage: -2.2, state: .calibrating) { $0.calibration = .dischargeToTarget }
            },
            PreviewScene("hero-helper-missing", size: heroSize, wallpaper: false) {
                page(model: ChargeLimitModel(sample: battery(72, charging: true), hardware: hardware, helper: .notInstalled))
            },
            PreviewScene("hero-unsupported", size: CGSize(width: 780, height: 310), wallpaper: false) {
                page(model: ChargeLimitModel(sample: battery(80, charging: false),
                                             hardware: ChargeHardware(chargingSwitch: nil, adapterSwitch: .chie, led: true),
                                             systemLimit: SystemChargeLimit(available: true, activeLimit: 80), helper: .notInstalled))
            },
            PreviewScene("health", size: CGSize(width: 780, height: 260), wallpaper: false) {
                AnyView(Form {
                    Section("Battery health") { BatteryHealthCard(battery: battery(78, charging: false)).padding(.vertical, 4) }
                }
                .formStyle(.grouped).scrollContentBackground(.hidden).scrollDisabled(true))
            },
            PreviewScene("settings", size: CGSize(width: 780, height: 1790), wallpaper: false) {
                let m = module(percent: 78, charging: false, state: .holding, systemLimit: SystemChargeLimit(available: true, activeLimit: nil)) {
                    $0.heatProtection = true
                    $0.lastCalibrated = Date(timeIntervalSince1970: 1_788_000_000)
                }
                m.settings.update { $0.showMenuBarItem = true }
                return AnyView(Form { ChargeLimitSections(module: m, confirmUninstall: .constant(false)) }
                    .formStyle(.grouped).scrollContentBackground(.hidden).scrollDisabled(true))
            },
            PreviewScene("menubar", size: CGSize(width: 600, height: 470)) {
                AnyView(MenuBarScene(module: module(percent: 78, charging: false, state: .holding) { _ in }))
            },
        ]
    }

    static let hardware = ChargeHardware(chargingSwitch: .chte, adapterSwitch: .chie, led: true)

    static func battery(_ percent: Int, charging: Bool, temperature: Double = 31.4, amperage: Double? = nil) -> BatterySnapshot {
        BatterySnapshot(percent: percent, isCharging: charging, adapterConnected: true, fullyCharged: false,
                        cycleCount: 212, designCycleCount: 1000, designCapacity: 8579, fullChargeCapacity: 7894,
                        temperature: temperature, voltage: 12.6, amperage: amperage ?? (charging ? 3.4 : 0),
                        adapterName: "140W USB-C Power Adapter", adapterWatts: 140)
    }

    private static func module(percent: Int, charging: Bool, temperature: Double = 31.4, amperage: Double? = nil,
                               state: ChargeState, systemLimit: SystemChargeLimit = .unavailable,
                               configure: (inout ChargeConfig) -> Void) -> ChargeLimitModule {
        var config = ChargeConfig()
        configure(&config)
        let status = HelperStatus(config: config, state: state, charging: charging ? .allow : .inhibit,
                                  adapter: state == .discharging ? .disabled : .enabled, percent: percent,
                                  adapterConnected: true, hardware: hardware,
                                  updated: Date(timeIntervalSince1970: 1_793_801_711))
        let model = ChargeLimitModel(sample: battery(percent, charging: charging, temperature: temperature, amperage: amperage),
                                     hardware: hardware, systemLimit: systemLimit, helper: .running(status))
        let m = makeModule(model)
        m.settings.update {
            $0.upperLimit = config.upper
            $0.sailingRange = config.upper - config.lower
            $0.dischargeToLimit = config.dischargeToLimit
            $0.heatProtection = config.heatProtection
            $0.maxTemperature = config.maxTemperature
        }
        return m
    }

    private static func makeModule(_ model: ChargeLimitModel) -> ChargeLimitModule {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mactoys-preview-\(UUID().uuidString)")
        return ChargeLimitModule(store: SettingsStore(directory: dir), model: model)
    }

    private static func hero(percent: Int, charging: Bool, temperature: Double = 31.4, amperage: Double? = nil,
                             state: ChargeState, configure: (inout ChargeConfig) -> Void = { _ in }) -> AnyView {
        let m = module(percent: percent, charging: charging, temperature: temperature, amperage: amperage,
                       state: state, configure: configure)
        return heroPage(m)
    }

    private static func page(model: ChargeLimitModel) -> AnyView {
        heroPage(makeModule(model))
    }

    /// The hero as it sits on the settings page.
    private static func heroPage(_ m: ChargeLimitModule) -> AnyView {
        AnyView(Form {
            Section { ChargeHero(module: m, model: m.model, settings: m.settings.value).padding(.vertical, 6) }
                .listRowBackground(Color.clear)
        }
        .formStyle(.grouped).scrollContentBackground(.hidden).scrollDisabled(true))
    }
}

/// A slice of the menu bar with the Charge Limit item and its flyout open below it.
private struct MenuBarScene: View {
    let module: ChargeLimitModule

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 16) {
                Spacer()
                Image(systemName: "wifi").font(.system(size: 13, weight: .medium))
                Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .medium))
                HStack(spacing: 5) {
                    Text(verbatim: ChargeText.percent(78)).font(.system(size: 13).monospacedDigit())
                    Image(nsImage: ChargeMenuIcon.image(level: 78, limit: 80, charging: false))
                        .renderingMode(.template)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.white.opacity(0.22)))
                Image(systemName: "switch.2").font(.system(size: 13, weight: .medium))
                Text(verbatim: PreviewScene.menuBarClock(hour: 22, minute: 41)).font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 26)
            .background(.black.opacity(0.18))
            ChargeFlyout(module: module)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.trailing, 92)
            Spacer(minLength: 0)
        }
    }
}
