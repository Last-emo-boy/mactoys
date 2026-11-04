import Foundation
import MacToysCore
import Observation

/// The helper as MacToys sees it.
public enum HelperState: Equatable, Sendable {
    case notInstalled
    /// Files are there but nothing answers (still starting, crashed, or turned off in Login Items).
    case notResponding
    case running(HelperStatus)
    /// Answers, but with another protocol version: MacToys reinstalls it.
    case outdated(HelperStatus)

    public var status: HelperStatus? {
        switch self {
        case .running(let s), .outdated(let s): s
        case .notInstalled, .notResponding: nil
        }
    }

    public var isInstalled: Bool { self != .notInstalled }

    /// The version handshake: a helper that reports another protocol version is outdated (also when it
    /// is newer, after MacToys was downgraded): this app's version is the one to run.
    public static func classify(_ status: HelperStatus) -> HelperState {
        status.version == HelperProtocol.version ? .running(status) : .outdated(status)
    }
    public var isRunning: Bool { if case .running = self { true } else { false } }
}

/// What a helper install or removal is doing right now.
public enum HelperTask: Equatable, Sendable {
    case installing, uninstalling
}

/// Live state for the settings page, the flyout and the menu bar item. Reading the battery and the SMC
/// needs no privileges; nothing here writes to the SMC.
@MainActor
@Observable
public final class ChargeLimitModel {
    public var battery: BatterySnapshot?
    public var hardware: ChargeHardware
    public var systemLimit: SystemChargeLimit
    public var helper: HelperState
    public var task: HelperTask?
    /// The last install, removal or request error, already localized.
    public var message: String?

    /// False for preview models filled with sample values: they never read this Mac or talk to the helper.
    @ObservationIgnored let live: Bool
    @ObservationIgnored private var smc: SMCConnection?
    @ObservationIgnored private var probed = false

    /// A live model; `refreshLocal()` reads this Mac.
    public init() {
        live = true
        battery = nil
        hardware = ChargeHardware(chargingSwitch: nil, adapterSwitch: nil, led: false)
        systemLimit = .unavailable
        helper = HelperClient.isInstalled ? .notResponding : .notInstalled
    }

    /// A model filled with sample values (previews).
    init(sample battery: BatterySnapshot?, hardware: ChargeHardware, systemLimit: SystemChargeLimit = .unavailable,
         helper: HelperState) {
        live = false
        self.battery = battery
        self.hardware = hardware
        self.systemLimit = systemLimit
        self.helper = helper
    }

    /// Reads the battery (and, once, the charging hardware and macOS's own limit).
    public func refreshLocal() {
        guard live else { return }
        if !probed {
            probed = true
            smc = SMCConnection()
            let smc = self.smc
            hardware = ChargeHardware.detect(smcAvailable: smc != nil, batteryPresent: BatteryReader.hasBattery) {
                smc?.keyInfo($0.rawValue)
            }
        }
        let limit = SystemChargeLimit.detect()
        if limit != systemLimit { systemLimit = limit }
        var b = BatteryReader.read()
        if b != nil, b?.temperature == nil { b?.temperature = smc?.batteryTemperature() }
        if b != battery { battery = b }
    }

    /// Asks the helper for its status.
    public func refreshHelper() async {
        guard live else { return }
        guard HelperClient.isInstalled else {
            if helper != .notInstalled { helper = .notInstalled }
            return
        }
        do {
            let response = try await HelperClient.send(.status)
            guard let status = response.status else { helper = .notResponding; return }
            let next = HelperState.classify(status)
            if next != helper { helper = next }
        } catch {
            if helper != .notResponding { helper = .notResponding }
        }
    }

    /// Sends one request; on success the returned status replaces the current one.
    @discardableResult
    public func send(_ request: HelperRequest) async -> Bool {
        guard live else { return false }
        do {
            let response = try await HelperClient.send(request)
            if let status = response.status { helper = HelperState.classify(status) }
            if !response.ok {
                message = response.error.map { String(localized: "The charge helper refused: \($0)",
                                                      comment: "Error banner; the placeholder is the helper's reason (English)") }
                return false
            }
            return true
        } catch {
            helper = HelperClient.isInstalled ? .notResponding : .notInstalled
            return false
        }
    }

    // MARK: - Derived

    public var status: HelperStatus? { helper.status }
    public var config: ChargeConfig? { status?.config }

    /// Charge Limit is switching charging right now.
    public var isLimiting: Bool {
        guard let config, helper.isRunning else { return false }
        return !config.paused
    }
}
