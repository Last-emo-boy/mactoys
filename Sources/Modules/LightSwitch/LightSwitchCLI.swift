import AppKit
import Foundation
import MacToysCore

/// Light Switch state for the command line (`mactoys lightswitch status --json`).
public struct LightSwitchStatus: Codable, Sendable {
    /// `light` or `dark`.
    public var systemTheme: String
    /// `off`, `fixed-hours`, `sunset-to-sunrise` or `follow-night-shift`.
    public var scheduleMode: String
    /// A manual switch is holding until the next scheduled change.
    public var manualOverride: Bool
    /// The theme the schedule asks for now (nil without a schedule).
    public var scheduledTheme: String?
    public var nextChange: Date?
    public var nextTheme: String?
    public var sunrise: Date?
    public var sunset: Date?
    /// System Settings › Appearance is set to Auto.
    public var automaticAppearance: Bool
    public var enabled: Bool
    public var appRunning: Bool
}

/// Out-of-process API for the `mactoys` tool. Theme changes are sent to the running app
/// (`mactoys://lightswitch/dark`), which owns the Automation permission and the override state;
/// schedule changes are written to the settings file and announced.
public enum LightSwitchCLI {
    public enum ExitCode: Int32 {
        case ok = 0, failed = 1, invalidArguments = 2, unavailable = 3, timedOut = 4
    }

    public struct Failure: Error {
        public let code: ExitCode
        public let message: String
    }

    static func load() -> LightSwitchSettings {
        SettingsStore.shared.load("lightswitch", default: LightSwitchSettings())
    }

    public static func status(now: Date = Date()) -> LightSwitchStatus {
        let s = load()
        let source = LightSwitchSchedule.source(for: s, nightShift: s.scheduleMode == .followNightShift ? NightShiftSchedule.current() : nil)
        let plan = LightSwitchSchedule.plan(source, now: now)
        var sunrise: Date?, sunset: Date?
        if let lat = s.latitude, let lon = s.longitude {
            let t = SolarCalculator.sunTimes(on: now, latitude: lat, longitude: lon)
            sunrise = t.sunrise
            sunset = t.sunset
        }
        return LightSwitchStatus(
            systemTheme: SystemAppearance.current.rawValue, scheduleMode: s.scheduleMode.cliName,
            manualOverride: (s.manualOverrideUntil ?? .distantPast) > now,
            scheduledTheme: plan?.appearance.rawValue, nextChange: plan?.nextChange,
            nextTheme: plan.flatMap { $0.nextChange == nil ? nil : $0.appearance.opposite.rawValue },
            sunrise: sunrise, sunset: sunset, automaticAppearance: SystemAppearance.isAutomatic,
            enabled: isEnabled, appRunning: appRunning)
    }

    static var isEnabled: Bool {
        SettingsStore.shared.load("general", default: GeneralSettings()).enabled["lightswitch"] ?? false
    }

    static var appRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Paths.bundleIdentifier).isEmpty
    }

    /// Asks the running app to switch, then waits up to `timeout` for the appearance to change.
    public static func setTheme(_ target: Appearance?, timeout: TimeInterval = 6) throws -> Appearance {
        guard isEnabled else { throw Failure(code: .unavailable, message: "Light Switch is turned off. Turn it on in MacToys Settings.") }
        guard appRunning else { throw Failure(code: .unavailable, message: "MacToys isn't running.") }
        let before = SystemAppearance.current
        let want = target ?? before.opposite
        let cmd = AppCommand(module: "lightswitch", action: target?.rawValue ?? "toggle")
        let open = Shell.run("/usr/bin/open", ["-g", cmd.url.absoluteString])
        guard open.ok else { throw Failure(code: .failed, message: open.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if want == before && target != nil { return want }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if SystemAppearance.current == want { return want }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw Failure(code: .timedOut, message: "Timed out waiting for the appearance to change. It may still change; run `status` before retrying. If macOS asked about System Events, allow it.")
    }

    /// Turns the schedule on (with `mode`, or keeping the current one) or off.
    public static func setSchedule(enabled: Bool, mode: ScheduleMode?) throws {
        var s = load()
        if enabled {
            if let mode {
                guard mode != .off else { throw Failure(code: .invalidArguments, message: "use `schedule disable` to turn the schedule off") }
                s.scheduleMode = mode
            } else if s.scheduleMode == .off {
                throw Failure(code: .invalidArguments, message: "the schedule is off; pass --mode fixed-hours, sunset-to-sunrise or follow-night-shift")
            }
            if s.scheduleMode == .sunsetToSunrise && !s.hasLocation {
                throw Failure(code: .invalidArguments, message: "sunset-to-sunrise needs a location; set one in MacToys Settings › Light Switch")
            }
        } else {
            s.scheduleMode = .off
        }
        s.manualOverrideUntil = nil
        SettingsStore.shared.save(s, id: "lightswitch")
        DistributedNotificationCenter.default().postNotificationName(
            SettingsStore.externalChangeNotification, object: nil, userInfo: nil, deliverImmediately: true)
    }

    public static let usage = """
    Usage: mactoys lightswitch <command> [--json]

    Commands:
      status                              Show the theme, schedule and override state
      light | dark                        Switch now (held until the next scheduled change)
      toggle                              Switch to the other theme, like ⌃⌥⇧D
      schedule enable [--mode <mode>]     Turn the schedule on: fixed-hours, sunset-to-sunrise, follow-night-shift
      schedule disable                    Turn the schedule off (manual only)

    Exit codes: 0 ok, 1 failed, 2 invalid arguments, 3 Light Switch or MacToys not running, 4 timed out.
    """

    /// Runs `mactoys lightswitch …`; returns the exit code.
    public static func run(_ arguments: [String]) -> Int32 {
        let json = arguments.contains("--json")
        let args = arguments.filter { $0 != "--json" }
        do {
            switch args.first ?? "status" {
            case "-h", "--help", "help":
                print(usage)
                return 0
            case "--version":
                print("1")
                return 0
            case "status":
                break
            case "light": _ = try setTheme(.light)
            case "dark": _ = try setTheme(.dark)
            case "toggle": _ = try setTheme(nil)
            case "schedule":
                let rest = Array(args.dropFirst())
                switch rest.first {
                case "enable":
                    var mode: ScheduleMode?
                    if let i = rest.firstIndex(where: { $0 == "--mode" || $0.hasPrefix("--mode=") }) {
                        let value = rest[i].hasPrefix("--mode=") ? String(rest[i].dropFirst(7)) : (i + 1 < rest.count ? rest[i + 1] : "")
                        guard let m = ScheduleMode(cliName: value) else {
                            throw Failure(code: .invalidArguments, message: "unknown mode \(value)")
                        }
                        mode = m
                    }
                    try setSchedule(enabled: true, mode: mode)
                case "disable":
                    try setSchedule(enabled: false, mode: nil)
                default:
                    throw Failure(code: .invalidArguments, message: "expected `schedule enable` or `schedule disable`")
                }
            default:
                throw Failure(code: .invalidArguments, message: "unknown command \(args.first ?? "")\n\n\(usage)")
            }
            emit(status(), json: json)
            return ExitCode.ok.rawValue
        } catch let failure as Failure {
            emit(failure, json: json)
            return failure.code.rawValue
        } catch {
            emit(Failure(code: .failed, message: error.localizedDescription), json: json)
            return ExitCode.failed.rawValue
        }
    }

    private struct Envelope<State: Encodable>: Encodable {
        struct ErrorInfo: Encodable { let code: Int32; let message: String }
        let version = 1
        let success: Bool
        let state: State?
        let error: ErrorInfo?
    }

    private static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    private static func emit(_ st: LightSwitchStatus, json: Bool) {
        if json {
            print(encode(Envelope(success: true, state: st, error: nil)))
            return
        }
        var lines = ["Theme: \(st.systemTheme)", "Schedule: \(st.scheduleMode)"]
        if st.manualOverride { lines.append("Manual override until the next scheduled change") }
        if let next = st.nextChange, let theme = st.nextTheme {
            lines.append("Next: \(theme) at \(next.formatted(date: .abbreviated, time: .shortened))")
        }
        if !st.enabled { lines.append("Light Switch is turned off in MacToys") }
        print(lines.joined(separator: "\n"))
    }

    private static func emit(_ failure: Failure, json: Bool) {
        if json {
            let envelope = Envelope<LightSwitchStatus>(success: false, state: nil,
                                                       error: .init(code: failure.code.rawValue, message: failure.message))
            print(encode(envelope))   // like PowerToys: one JSON object on stdout, errors included
        } else {
            FileHandle.standardError.write(Data("mactoys lightswitch: \(failure.message)\n".utf8))
        }
    }
}
