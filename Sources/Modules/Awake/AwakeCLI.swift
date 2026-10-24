import AppKit
import Foundation
import MacToysCore

/// Awake's state as reported to the command line.
public struct AwakeStatus: Codable, Sendable {
    /// `off`, `indefinite`, `timed` or `until`.
    public var mode: String
    public var keepScreenOn: Bool
    public var allowDisplaySleepWhenLocked: Bool
    /// End of a timed or until session.
    public var expiresAt: Date?
    public var remainingSeconds: Int?
    /// "1 h 12 min left · screen stays on".
    public var description: String
    /// Whether the Awake utility is enabled in MacToys.
    public var enabled: Bool
    /// Whether MacToys is running (assertions are only held while it runs).
    public var appRunning: Bool
}

/// Out-of-process API used by the `mactoys` command-line tool. Changes are written to Awake's
/// settings file and announced with `SettingsStore.externalChangeNotification`; the running app
/// picks them up and holds the power assertions.
public enum AwakeCLI {
    public enum Mode: Sendable {
        case off, indefinite
        case timed(seconds: Int)
        case until(Date)
    }

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
        public let exitCode: Int32
    }

    public static func status(now: Date = Date()) -> AwakeStatus {
        let s = AwakeSchedule.restored(SettingsStore.shared.load("awake", default: AwakeSettings()), now: now)
        return AwakeStatus(mode: s.mode.rawValue, keepScreenOn: s.keepScreenOn,
                           allowDisplaySleepWhenLocked: s.allowDisplaySleepWhenLocked,
                           expiresAt: AwakeSchedule.expiry(of: s),
                           remainingSeconds: AwakeSchedule.remaining(s, now: now).map { Int($0.rounded()) },
                           description: AwakeSchedule.describe(s, now: now),
                           enabled: isEnabled, appRunning: appRunning)
    }

    /// Changes the mode and/or the screen option, then tells the running app. With `whileProcess`,
    /// Awake turns off when that process exits (PowerToys `--pid`); without a mode it keeps awake indefinitely.
    public static func set(_ mode: Mode?, keepScreenOn: Bool? = nil, allowDisplaySleepWhenLocked: Bool? = nil,
                           whileProcess pid: Int32? = nil, now: Date = Date()) {
        var s = AwakeSchedule.restored(SettingsStore.shared.load("awake", default: AwakeSettings()), now: now)
        if mode != nil || pid != nil { s.boundProcess = pid }
        let mode = mode ?? (pid != nil ? .indefinite : nil)
        switch mode {
        case .off?: s.mode = .off; s.timedExpiresAt = nil
        case .indefinite?: s.mode = .indefinite; s.lastActiveMode = .indefinite
        case .timed(let seconds)?: AwakeSchedule.startTimed(&s, seconds: seconds, now: now)
        case .until(let date)?: AwakeSchedule.startUntil(&s, date: date, now: now)
        case nil: break
        }
        if let keepScreenOn { s.keepScreenOn = keepScreenOn }
        if let allowDisplaySleepWhenLocked { s.allowDisplaySleepWhenLocked = allowDisplaySleepWhenLocked }
        SettingsStore.shared.save(s, id: "awake")
        DistributedNotificationCenter.default().postNotificationName(
            SettingsStore.externalChangeNotification, object: nil, userInfo: nil, deliverImmediately: true)
    }

    static var isEnabled: Bool {
        SettingsStore.shared.load("general", default: GeneralSettings()).enabled["awake"] ?? true
    }

    static var appRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Paths.bundleIdentifier).isEmpty
    }

    public static let usage = """
    Usage: mactoys awake [command] [options]

    Commands:
      status                 Show the current mode (default)
      off                    Follow the system's sleep settings
      on, indefinite         Keep awake until turned off
      for <duration>         Keep awake for 30m, 1h30m, 1:30, 2h or 90 (minutes)
      until <time|date>      Keep awake until 23:30, "2026-10-25 17:00" or an ISO 8601 date

    Options:
      --screen on|off        Keep the screen on while awake (alias --display-on true|false)
      --locked-sleep on|off  Let the displays sleep while the screen is locked
      --time-limit <sec>     Same as `for`, in seconds
      --expire-at <date>     Same as `until`
      --pid <pid>            Stay awake only while that process runs (indefinitely unless a mode is given)
      --use-parent-pid       Stay awake only while the calling shell (or script) runs
      --json                 Print the resulting status as JSON
    """

    /// Runs `mactoys awake …` and returns the process exit code
    /// (0 ok, 1 failed, 2 invalid arguments, 3 Awake or MacToys not running).
    public static func run(_ arguments: [String]) -> Int32 {
        do {
            let request = try parse(arguments, now: Date())
            if request.help { print(usage); return 0 }
            if request.mode != nil || request.screen != nil || request.lockedSleep != nil || request.pid != nil {
                set(request.mode, keepScreenOn: request.screen, allowDisplaySleepWhenLocked: request.lockedSleep,
                    whileProcess: request.pid)
            }
            let st = status()
            if request.json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                let data = (try? encoder.encode(st)) ?? Data("{}".utf8)
                print(String(decoding: data, as: UTF8.self))
            } else {
                print("Awake: \(st.description)")
            }
            if !st.enabled || !st.appRunning {
                let why = st.enabled ? "MacToys isn't running" : "Awake is turned off in MacToys"
                FileHandle.standardError.write(Data("warning: \(why); the mode applies once it runs.\n".utf8))
                return request.mode == nil && request.pid == nil ? 0 : 3
            }
            return 0
        } catch let failure as Failure {
            FileHandle.standardError.write(Data("mactoys awake: \(failure.description)\n".utf8))
            return failure.exitCode
        } catch {
            FileHandle.standardError.write(Data("mactoys awake: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    struct Request {
        var mode: Mode?
        var screen: Bool?
        var lockedSleep: Bool?
        var pid: Int32?
        var json = false
        var help = false
    }

    static func parse(_ arguments: [String], now: Date) throws -> Request {
        var r = Request()
        var args = arguments[...]
        func bad(_ message: String) -> Failure { Failure(description: message, exitCode: 2) }
        func next(_ name: String) throws -> String {
            guard let v = args.popFirst() else { throw bad("\(name) needs a value") }
            return v
        }
        func bool(_ v: String) throws -> Bool {
            switch v.lowercased() {
            case "on", "true", "yes", "1": return true
            case "off", "false", "no", "0": return false
            default: throw bad("expected on or off, got \(v)")
            }
        }
        while let raw = args.popFirst() {
            // Accept both `--opt value` and `--opt=value`.
            var arg = raw
            if raw.hasPrefix("--"), let eq = raw.firstIndex(of: "=") {
                arg = String(raw[..<eq])
                args.insert(String(raw[raw.index(after: eq)...]), at: args.startIndex)
            }
            switch arg {
            case "status": break
            case "-h", "--help", "help": r.help = true
            case "--json": r.json = true
            case "off", "disable": r.mode = .off
            case "on", "indefinite", "enable": r.mode = .indefinite
            case "for", "timed":
                let v = try next(arg)
                guard let seconds = AwakeSchedule.parseDuration(v) else { throw bad("can't read duration \(v)") }
                r.mode = .timed(seconds: seconds)
            case "--time-limit":
                let v = try next(arg)
                guard let seconds = Int(v), seconds > 0 else { throw bad("--time-limit takes seconds") }
                r.mode = .timed(seconds: seconds)
            case "until", "--expire-at":
                let v = try next(arg)
                guard let date = AwakeSchedule.parseDate(v, now: now) else { throw bad("can't read date \(v)") }
                guard date > now else { throw bad("\(v) is in the past") }
                r.mode = .until(date)
            case "--screen", "--display-on": r.screen = try bool(try next(arg))
            case "--locked-sleep": r.lockedSleep = try bool(try next(arg))
            case "--pid":
                let v = try next(arg)
                guard let pid = Int32(v), pid > 0, kill(pid, 0) == 0 || errno == EPERM else { throw bad("no running process \(v)") }
                r.pid = pid
            case "--use-parent-pid": r.pid = getppid()
            default: throw bad("unknown argument \(raw)\n\n\(usage)")
            }
        }
        return r
    }
}
