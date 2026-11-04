import Darwin
import Foundation
import IOKit
import IOKit.pwr_mgt
import MacToysCore

/// The root helper: `mactoys charge-helper --owner-uid <uid>` (hidden subcommand), run by launchd from
/// its root-owned copy in /Library/PrivilegedHelperTools. It reads the battery, runs `ChargeController`
/// and flips the whitelisted SMC switches. It restores normal charging when it starts (after a crash),
/// stops, the Mac goes to sleep, a write fails or the battery falls below the floor.
public enum ChargeHelper {
    public static let subcommand = HelperPaths.subcommand

    /// Returns only on errors and for `--restore`; the daemon itself runs until launchd stops it.
    @MainActor
    public static func run(_ args: [String]) -> Int32 {
        guard let parsed = HelperArguments.parse(args) else {
            FileHandle.standardError.write(Data("usage: mactoys charge-helper --owner-uid <uid> | --restore\n".utf8))
            return 64
        }
        guard geteuid() == 0 else {
            FileHandle.standardError.write(Data("mactoys: the charge helper runs as root, installed from MacToys › Charge Limit\n".utf8))
            return 77
        }
        guard let exe = HelperSelfCheck.executablePath else { return 78 }
        if let problem = HelperSelfCheck.problem(executable: exe, info: HelperSelfCheck.lstatInfo) {
            Log.for("chargelimit").error("Refusing to run: \(problem, privacy: .public)")
            FileHandle.standardError.write(Data("mactoys: refusing to run the charge helper: \(problem)\n".utf8))
            return 78
        }
        switch parsed {
        case .restore:
            HelperDaemon(ownerUID: 0).restoreAndForget()
            return 0
        case .run(let uid):
            signal(SIGPIPE, SIG_IGN)
            let daemon = HelperDaemon(ownerUID: uid)
            daemon.start()
            withExtendedLifetime(daemon) { RunLoop.main.run() }
            return 0
        }
    }
}

/// The helper's persisted state.
struct HelperStateFile: Codable, Equatable {
    var config = ChargeConfig()
    /// Charge Limit set a MagSafe LED color, so it must hand the LED back to macOS when it stops.
    var ledTouched = false
}

@MainActor
final class HelperDaemon {
    private let ownerUID: uid_t
    private let smc: SMCConnection?
    private let hardware: ChargeHardware
    private var state = HelperStateFile()
    private var memory = ChargeMemory()
    /// What the switches are known to be set to (nil: unknown).
    private var applied: ChargeDecision?
    private var lastDecision: ChargeDecision?
    private var lastBattery: BatterySnapshot?
    private var lastError: String?
    private var failures = 0
    private var asleep = false
    /// Set by uninstall: the files are gone, so nothing may limit charging or write state again.
    private var removed = false
    private var timer: Timer?
    private var server: HelperSocketServer?
    private var signalSources: [DispatchSourceSignal] = []
    private var powerPort: IONotificationPortRef?
    private var powerNotifier: io_object_t = 0
    fileprivate var rootPowerPort: io_connect_t = 0
    private let powerSources: PowerSourceWatcher
    private let log = Log.for("chargelimit")

    init(ownerUID: uid_t) {
        self.ownerUID = ownerUID
        smc = SMCConnection()
        let smc = self.smc
        hardware = ChargeHardware.detect(smcAvailable: smc != nil, batteryPresent: BatteryReader.hasBattery) {
            smc?.keyInfo($0.rawValue)
        }
        powerSources = PowerSourceWatcher()
    }

    /// `--restore`: one restore, nothing else.
    func restoreAndForget() {
        state = loadState()
        restore()
        saveState()
    }

    func start() {
        state = loadState()
        log.notice("charge helper \(HelperProtocol.version) starting; hardware \(self.hardware.keyNames.joined(separator: " "), privacy: .public)")
        // Whatever a previous run left behind (crash, kill -9), start from normal charging.
        restore()
        saveState()
        installSignalHandlers()
        installPowerNotifications()
        powerSources.onChange = { [weak self] in self?.tick() }
        powerSources.start()
        let server = HelperSocketServer(path: HelperPaths.socket, ownerUID: ownerUID) { [weak self] line in
            self?.respond(to: line) ?? HelperResponse.failure("stopping").encoded()
        }
        do {
            try server.start()
            self.server = server
        } catch {
            log.error("Could not open the helper socket: \(String(describing: error), privacy: .public)")
        }
        tick()
    }

    // MARK: - Control loop

    func tick() {
        timer?.invalidate()
        timer = nil
        guard hardware.isSupported, !removed else { return }
        guard let battery = BatteryReader.read() else {
            restore()
            schedule(ChargeController.unplugged)
            return
        }
        lastBattery = battery
        let inputs = ChargeInputs(percent: battery.percent, adapterConnected: battery.adapterConnected,
                                  isCharging: battery.isCharging, fullyCharged: battery.fullyCharged,
                                  temperature: battery.temperature ?? smc?.batteryTemperature(), asleep: asleep, now: Date())
        let before = state.config
        let decision = ChargeController.step(config: &state.config, memory: &memory, inputs: inputs,
                                             capabilities: hardware.capabilities)
        lastDecision = decision
        apply(decision)
        if state.config != before { saveState() }
        schedule(decision.nextCheck)
    }

    private func schedule(_ seconds: TimeInterval) {
        timer?.invalidate()
        let t = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = min(5, seconds / 5)
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func apply(_ decision: ChargeDecision) {
        guard let smc else { return }
        let writes = hardware.writes(for: decision, since: applied)
        guard !writes.isEmpty else { applied = decision; return }
        if writes.contains(where: { $0.key == .aclc && $0.bytes != WhitelistedWrite.led(.system).bytes }), !state.ledTouched {
            state.ledTouched = true
            saveState()
        }
        do {
            for write in writes {
                try smc.perform(write)
                log.info("wrote \(write.description, privacy: .public)")
            }
            applied = decision
            failures = 0
            if decision.led == .system, hardware.led, writes.contains(where: { $0.key == .aclc }) {
                state.ledTouched = false
                saveState()
            }
        } catch {
            failures += 1
            lastError = String(describing: error)
            log.error("Write failed (\(self.failures)): \(String(describing: error), privacy: .public); restoring normal charging")
            restore()
            if failures >= 3 {
                // Something is wrong with this Mac's switches: stay out of the way until the user resumes.
                state.config.paused = true
                saveState()
            }
        }
    }

    /// Normal charging, best effort: every restore write is tried even when one fails.
    func restore() {
        guard let smc, hardware.isSupported else { applied = nil; return }
        var ok = true
        for write in hardware.restoreWrites(resetLED: state.ledTouched) {
            do { try smc.perform(write) } catch {
                ok = false
                log.error("Restore write \(write.description, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
        if ok {
            applied = .normal(.paused)
            state.ledTouched = false
        } else {
            applied = nil
        }
    }

    // MARK: - Requests

    private func respond(to line: Data) -> Data {
        guard !removed else { return HelperResponse.failure("the helper is being removed").encoded() }
        do {
            let request = try HelperRequest.decode(line)
            return handle(request).encoded()
        } catch let e as HelperProtocolError {
            return HelperResponse.failure(e.description).encoded()
        } catch {
            return HelperResponse.failure("malformed request").encoded()
        }
    }

    private func handle(_ request: HelperRequest) -> HelperResponse {
        let caps = hardware.capabilities
        switch request {
        case .status:
            return HelperResponse(ok: true, status: status)
        case .uninstall:
            return uninstall()
        default:
            break
        }
        guard hardware.isSupported else { return .failure("Charge Limit isn't supported on this Mac") }
        var c = state.config
        switch request {
        case let .setLimit(lower, upper):
            c.upper = upper
            c.lower = caps.chargingSwitch ? lower : upper
        case .setDischarge(let on):
            guard !on || caps.adapterSwitch else { return .failure("This Mac can't run from its battery while plugged in") }
            c.dischargeToLimit = on
        case let .setHeat(enabled, maxCelsius):
            guard !enabled || caps.chargingSwitch else { return .failure("Heat protection needs a charging switch") }
            c.heatProtection = enabled
            c.maxTemperature = maxCelsius
        case .setLED(let mode):
            guard mode == .system || caps.led else { return .failure("This Mac has no MagSafe LED control") }
            c.led = mode
        case .pause:
            c.paused = true
            c.topUp = false
            c.calibration = nil
        case .resume:
            c.paused = false
            failures = 0
            lastError = nil
        case .topUp(let on):
            c.topUp = on
            if on { c.paused = false; c.calibration = nil }
        case .calibrate(let on):
            c.calibration = on ? .chargeToFull : nil
            if on { c.paused = false; c.topUp = false }
        case .status, .uninstall:
            break
        }
        state.config = c.sanitized()
        saveState()
        tick()
        return HelperResponse(ok: true, status: status)
    }

    private var status: HelperStatus {
        HelperStatus(config: state.config, state: lastDecision?.state ?? .paused,
                     charging: applied?.charging ?? .allow, adapter: applied?.adapter ?? .enabled,
                     percent: lastBattery?.percent, adapterConnected: lastBattery?.adapterConnected ?? false,
                     hardware: hardware, lastError: lastError)
    }

    /// Restores normal charging, deletes every installed file, then asks launchd to remove the job.
    private func uninstall() -> HelperResponse {
        log.notice("Uninstalling the charge helper")
        removed = true
        timer?.invalidate()
        timer = nil
        restore()
        let fm = FileManager.default
        for path in [HelperPaths.launchDaemon, HelperPaths.helper, HelperPaths.stateDirectory] {
            do { if fm.fileExists(atPath: path) { try fm.removeItem(atPath: path) } } catch {
                log.error("Could not remove \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        rmdir((HelperPaths.stateDirectory as NSString).deletingLastPathComponent)
        var response = HelperResponse(ok: true, status: status)
        response.status?.config.paused = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MainActor.assumeIsolated {
                self.server?.stop()
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                p.arguments = ["bootout", "system/\(HelperPaths.label)"]
                try? p.run()
                // launchd stops the job (SIGTERM, which restores again); exit anyway if it doesn't.
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exit(0) }
            }
        }
        return response
    }

    // MARK: - Persistence

    private func loadState() -> HelperStateFile {
        // Only trust a root-owned file nobody else can write.
        guard let info = HelperSelfCheck.lstatInfo(HelperPaths.stateFile), !info.isSymlink, info.owner == 0,
              info.mode & 0o022 == 0,
              let data = FileManager.default.contents(atPath: HelperPaths.stateFile),
              var loaded = try? HelperJSON.decoder.decode(HelperStateFile.self, from: data) else { return HelperStateFile() }
        loaded.config = loaded.config.sanitized()
        return loaded
    }

    private func saveState() {
        // After uninstall, saving would recreate the deleted state directory.
        guard !removed else { return }
        let url = URL(fileURLWithPath: HelperPaths.stateFile)
        do {
            try FileManager.default.createDirectory(atPath: HelperPaths.stateDirectory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o755])
            try HelperJSON.line(state).write(to: url, options: .atomic)
            chmod(url.path, 0o644)
        } catch {
            log.error("Could not save helper state: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - System events

    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    self?.log.notice("charge helper stopping (signal \(sig))")
                    self?.shutDown()
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func shutDown() -> Never {
        timer?.invalidate()
        restore()
        saveState()
        server?.stop()
        exit(0)
    }

    private func installPowerNotifications() {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        rootPowerPort = IORegisterForSystemPower(refcon, &powerPort, { refcon, _, messageType, messageArgument in
            guard let refcon else { return }
            let daemon = Unmanaged<HelperDaemon>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { daemon.power(messageType, argument: messageArgument) }
        }, &powerNotifier)
        guard rootPowerPort != 0, let port = powerPort else {
            log.error("Could not register for sleep notifications")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .commonModes)
    }

    private func power(_ message: UInt32, argument: UnsafeMutableRawPointer?) {
        switch message {
        case SleepMessage.canSleep:
            IOAllowPowerChange(rootPowerPort, Int(bitPattern: argument))
        case SleepMessage.willSleep:
            // The helper can't watch the battery while the Mac sleeps: charge normally until it wakes.
            asleep = true
            tick()
            timer?.invalidate()
            timer = nil
            IOAllowPowerChange(rootPowerPort, Int(bitPattern: argument))
        case SleepMessage.hasPoweredOn:
            asleep = false
            schedule(2)
        default:
            break
        }
    }
}

/// IOKit sleep messages (`iokit_common_msg` values from IOMessage.h, which Swift doesn't import).
enum SleepMessage {
    static let canSleep: UInt32 = 0xE000_0270
    static let willSleep: UInt32 = 0xE000_0280
    static let hasPoweredOn: UInt32 = 0xE000_0300
}
