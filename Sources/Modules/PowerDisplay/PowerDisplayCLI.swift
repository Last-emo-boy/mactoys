import AppKit
import Foundation
import MacToysCore

/// Command-line access to displays (`mactoys powerdisplay …`). DDC/CI runs in the calling process,
/// so it works whether or not MacToys is running; afterwards the app is told to refresh its values.
public enum PowerDisplayCLI {
    public struct Failure: Error {
        public let message: String
        public let exitCode: Int32
    }

    public struct MonitorInfo: Codable, Sendable {
        public var number: Int
        public var id: String
        public var name: String
        public var transport: String
        public var kind: String
        public var features: [String]
    }

    public struct Value: Codable, Sendable {
        public var monitor: Int
        public var id: String
        public var setting: String
        /// Percent for brightness, contrast and volume; the raw VCP value otherwise.
        public var value: Int
        public var raw: Int?
        public var maximum: Int?
        public var name: String?
    }

    public struct ProfileInfo: Codable, Sendable {
        public var id: Int
        public var name: String
        public var monitors: Int
    }

    /// Discovers displays in this process.
    public static func discover() -> [MonitorSnapshot] {
        let names = MainActor.assumeIsolated { DisplayEngine.screenNames() }
        let settings = loadSettings()
        engine.maxCompatibility = settings.maxCompatibility
        return engine.discover(names: names, cachedCapabilities: settings.monitors.compactMapValues(\.capabilities))
    }

    static let engine = DisplayEngine()

    static func loadSettings() -> PowerDisplaySettings {
        SettingsStore.shared.load("powerdisplay", default: PowerDisplaySettings())
    }

    static func notifyApp() {
        DistributedNotificationCenter.default().postNotificationName(
            SettingsStore.externalChangeNotification, object: nil, userInfo: nil, deliverImmediately: true)
    }

    public static func list() -> [MonitorInfo] {
        discover().map {
            MonitorInfo(number: $0.number, id: $0.id, name: $0.name, transport: $0.transport, kind: $0.kind.rawValue,
                        features: $0.supported.map(\.cliName))
        }
    }

    public static func profiles() -> [ProfileInfo] {
        loadSettings().profiles.map { ProfileInfo(id: $0.id, name: $0.name, monitors: $0.monitors.count) }
    }

    /// Applies a saved profile by id; linked brightness is turned off first, as in the flyout.
    public static func applyProfile(_ id: Int) throws {
        var settings = loadSettings()
        guard let profile = settings.profiles.first(where: { $0.id == id }) else {
            throw Failure(message: "no profile with id \(id); see `mactoys powerdisplay profiles`", exitCode: 2)
        }
        let monitors = discover()
        var failed = 0
        for (monitorID, feature, raw) in ProfilePlan.writes(profile, monitors: monitors) where !engine.write(feature, raw: raw, monitor: monitorID) {
            failed += 1
        }
        settings.linkedBrightness = false
        settings.lastAppliedProfile = id
        SettingsStore.shared.save(settings, id: "powerdisplay")
        notifyApp()
        if failed > 0 { throw Failure(message: "\(failed) value(s) couldn't be written", exitCode: 1) }
    }

    public static let usage = """
    Usage: mactoys powerdisplay <command> [options]

    Commands:
      list                                   Monitors with number, stable id, name and transport
      capabilities -n <n> [--setting <s>]    Discrete VCP values a monitor reports
      get -n <n> [--setting <s>]             Current values
      set -n <n[,n…]> --<setting> <value>    Set one value: --brightness 70, --contrast, --volume,
                                             --color-temperature 0xNN, --input-source 0xNN,
                                             --power-state 0xNN (needs --confirm-power-off to blank)
      up | down -n <n[,n…]> --<setting> [--step <n>]
                                             Raise or lower brightness, contrast or volume
                                             (default step: the mouse wheel increment)
      profiles                               Saved profiles with their numeric ids
      apply-profile <id>                     Apply a saved profile

    Options:
      -n, --monitor-number <n[,n…]>          1-based monitor numbers (see list)
      -i, --monitor-id <id>                  Stable monitor id; wins over -n
      --setting <s>                          brightness, contrast, volume, color-temperature,
                                             input-source, power-state, orientation
      --json                                 JSON Lines on stdout, errors as JSON on stderr
      --quiet                                No warnings
    """

    /// Runs `mactoys powerdisplay …`; returns the exit code (0 ok, 1 failed, 2 invalid arguments).
    public static func run(_ arguments: [String]) -> Int32 {
        var json = false
        do {
            var opts = try Options.parse(arguments)
            json = opts.json
            switch opts.command {
            case "help", "-h", "--help", "-?":
                print(usage)
            case "list":
                let monitors = list()
                if json { monitors.forEach { emit($0) } } else {
                    if monitors.isEmpty { print("No displays found.") }
                    for m in monitors {
                        print("\(m.number)  \(m.name)  [\(m.transport)]  id \(m.id)  \(m.features.joined(separator: ", "))")
                    }
                }
            case "profiles":
                let list = profiles()
                if json { list.forEach { emit($0) } } else {
                    if list.isEmpty { print("No profiles saved.") }
                    for p in list { print("\(p.id)  \(p.name)  (\(p.monitors) monitor\(p.monitors == 1 ? "" : "s"))") }
                }
            case "apply-profile":
                guard let id = opts.positional.first.flatMap({ Int($0) }) else {
                    throw Failure(message: "apply-profile needs a profile id", exitCode: 2)
                }
                try applyProfile(id)
                if !json { print("Applied profile \(id).") }
            case "capabilities":
                let monitors = try targets(&opts, single: true)
                for m in monitors { try printCapabilities(m, setting: opts.setting, json: json) }
            case "get":
                for m in try targets(&opts, single: false) { try printValues(m, setting: opts.setting, json: json) }
            case "set":
                try set(&opts)
            case "up", "down":
                try nudge(&opts, up: opts.command == "up")
            default:
                throw Failure(message: "unknown command \(opts.command)\n\n\(usage)", exitCode: 2)
            }
            return 0
        } catch let f as Failure {
            if json {
                let line = "{\"error\":{\"code\":\(f.exitCode),\"message\":\(jsonString(f.message))}}\n"
                FileHandle.standardError.write(Data(line.utf8))
            } else {
                FileHandle.standardError.write(Data("mactoys powerdisplay: \(f.message)\n".utf8))
            }
            return f.exitCode
        } catch {
            FileHandle.standardError.write(Data("mactoys powerdisplay: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    struct Options {
        var command = "list"
        var numbers: [Int] = []
        var id: String?
        var setting: String?
        var values: [(DisplayFeature, String)] = []
        var orientation: String?
        var step: Int?
        var confirmPowerOff = false
        var json = false
        var quiet = false
        var positional: [String] = []

        static func parse(_ arguments: [String]) throws -> Options {
            var o = Options()
            var args = arguments[...]
            if let first = args.first, !first.hasPrefix("-") { o.command = first; args = args.dropFirst() }
            func value(_ name: String) throws -> String {
                guard let v = args.popFirst() else { throw Failure(message: "\(name) needs a value", exitCode: 2) }
                return v
            }
            while let raw = args.popFirst() {
                var arg = raw
                if raw.hasPrefix("--"), let eq = raw.firstIndex(of: "=") {
                    arg = String(raw[..<eq])
                    args.insert(String(raw[raw.index(after: eq)...]), at: args.startIndex)
                }
                switch arg {
                case "-n", "--monitor-number":
                    let list = try value(arg).split(separator: ",").map { Int($0.trimmingCharacters(in: .whitespaces)) }
                    guard !list.isEmpty, list.allSatisfy({ ($0 ?? 0) > 0 }) else { throw Failure(message: "bad monitor number", exitCode: 2) }
                    o.numbers = list.compactMap { $0 }
                case "-i", "--monitor-id": o.id = try value(arg)
                case "--setting": o.setting = try value(arg).lowercased()
                case "--step":
                    guard let s = Int(try value(arg)), s > 0 else { throw Failure(message: "--step takes a positive number", exitCode: 2) }
                    o.step = s
                case "--orientation": o.orientation = try value(arg)
                case "--confirm-power-off": o.confirmPowerOff = true
                case "--json": o.json = true
                case "--quiet": o.quiet = true
                case "-h", "--help", "-?": o.command = "help"
                default:
                    if arg.hasPrefix("--"), let f = DisplayFeature(cliName: String(arg.dropFirst(2))) {
                        // `up`/`down` take a bare feature flag; `set` takes a value.
                        if let next = args.first, !next.hasPrefix("-") { o.values.append((f, next)); args = args.dropFirst() }
                        else { o.values.append((f, "")) }
                    } else if !arg.hasPrefix("-") {
                        o.positional.append(arg)
                    } else {
                        throw Failure(message: "unknown option \(raw)", exitCode: 2)
                    }
                }
            }
            return o
        }
    }

    static func targets(_ o: inout Options, single: Bool) throws -> [MonitorSnapshot] {
        let all = discover()
        if let id = o.id {
            guard let m = all.first(where: { $0.id == id }) else { throw Failure(message: "no monitor with id \(id)", exitCode: 2) }
            return [m]
        }
        guard !o.numbers.isEmpty else {
            if single || o.command != "get" { throw Failure(message: "pass --monitor-number or --monitor-id", exitCode: 2) }
            return all
        }
        if single && o.numbers.count > 1 { throw Failure(message: "\(o.command) takes one monitor", exitCode: 2) }
        return try o.numbers.map { n in
            guard let m = all.first(where: { $0.number == n }) else { throw Failure(message: "no monitor \(n); see `list`", exitCode: 2) }
            return m
        }
    }

    static func printCapabilities(_ m: MonitorSnapshot, setting: String?, json: Bool) throws {
        let features: [DisplayFeature]
        if let setting {
            guard let f = DisplayFeature(cliName: setting), !f.isContinuous else {
                throw Failure(message: "capabilities --setting takes color-temperature, input-source or power-state", exitCode: 2)
            }
            features = [f]
        } else {
            features = [.colorTemperature, .inputSource, .powerState]
        }
        let names = loadSettings()
        for f in features {
            let values = m.options[f] ?? []
            if json {
                struct Line: Codable { var monitor: Int; var id: String; var setting: String; var values: [Int]; var names: [String] }
                emit(Line(monitor: m.number, id: m.id, setting: f.cliName, values: values.map(Int.init),
                          names: values.map { names.valueName(f, $0, monitor: m.id) }))
            } else {
                let list = values.map { "\(MCCS.hex(Int($0))) \(names.valueName(f, $0, monitor: m.id))" }
                print("\(m.number) \(f.cliName): \(list.isEmpty ? "not supported" : list.joined(separator: ", "))")
            }
        }
        if !json, let caps = m.capabilities { print("\(m.number) vcp: \(caps.codes.map { MCCS.hex(Int($0)) }.joined(separator: " "))") }
    }

    static func printValues(_ m: MonitorSnapshot, setting: String?, json: Bool) throws {
        let names = loadSettings()
        if setting == "orientation" {
            if json { emit(Value(monitor: m.number, id: m.id, setting: "orientation", value: m.rotation)) }
            else { print("\(m.number) orientation: \(m.rotation)") }
            return
        }
        let features: [DisplayFeature]
        if let setting {
            guard let f = DisplayFeature(cliName: setting) else { throw Failure(message: "unknown setting \(setting)", exitCode: 2) }
            features = [f]
        } else {
            features = m.supported
        }
        for f in features {
            guard let r = engine.read(f, monitor: m.id) ?? m.readings[f] else {
                if setting != nil { throw Failure(message: "\(m.name) doesn't support \(f.cliName)", exitCode: 1) }
                continue
            }
            let v = Value(monitor: m.number, id: m.id, setting: f.cliName,
                          value: f.isContinuous ? Int(VCPScale.percent(raw: r.current, maximum: r.maximum)) : Int(r.current),
                          raw: Int(r.current), maximum: Int(r.maximum),
                          name: f.isContinuous ? nil : names.valueName(f, r.current, monitor: m.id))
            if json { emit(v) } else {
                print("\(m.number) \(f.cliName): \(f.isContinuous ? "\(v.value)%" : "\(MCCS.hex(v.value)) \(v.name ?? "")")")
            }
        }
    }

    static func parseValue(_ text: String) -> Int? {
        let t = text.lowercased()
        if t.hasPrefix("0x") { return Int(t.dropFirst(2), radix: 16) }
        return Int(t)
    }

    static func set(_ o: inout Options) throws {
        if o.orientation != nil {
            throw Failure(message: "macOS has no public API to rotate displays; use System Settings › Displays › Rotation", exitCode: 1)
        }
        guard o.values.count == 1, let (feature, text) = o.values.first, let n = parseValue(text) else {
            throw Failure(message: "set takes exactly one value, e.g. --brightness 70", exitCode: 2)
        }
        if feature == .powerState && n != 0x01 && !o.confirmPowerOff {
            throw Failure(message: "--power-state \(text) blanks the display; add --confirm-power-off", exitCode: 2)
        }
        if feature.isContinuous && !(0...100).contains(n) {
            throw Failure(message: "\(feature.cliName) is a percentage, 0–100", exitCode: 2)
        }
        let monitors = try targets(&o, single: false)
        var failed: [String] = []
        for m in monitors {
            guard let r = m.readings[feature] else {
                if !o.quiet { FileHandle.standardError.write(Data("warning: \(m.name) doesn't support \(feature.cliName)\n".utf8)) }
                failed.append(m.name)
                continue
            }
            let raw = feature.isContinuous ? VCPScale.raw(percent: Double(n), maximum: r.maximum) : UInt16(clamping: n)
            if !engine.write(feature, raw: raw, monitor: m.id) { failed.append(m.name) }
            else if o.json { emit(Value(monitor: m.number, id: m.id, setting: feature.cliName, value: n, raw: Int(raw), maximum: Int(r.maximum))) }
        }
        notifyApp()
        if !failed.isEmpty { throw Failure(message: "couldn't set \(feature.cliName) on \(failed.joined(separator: ", "))", exitCode: 1) }
    }

    static func nudge(_ o: inout Options, up: Bool) throws {
        guard o.values.count == 1, let feature = o.values.first?.0, feature.isContinuous else {
            throw Failure(message: "\(o.command) takes one of --brightness, --contrast or --volume", exitCode: 2)
        }
        let step = o.step ?? (o.values.first.flatMap { Int($0.1) }) ?? loadSettings().wheelIncrement
        let monitors = try targets(&o, single: false)
        var failed: [String] = []
        for m in monitors {
            guard let r = engine.read(feature, monitor: m.id) ?? m.readings[feature] else { failed.append(m.name); continue }
            let percent = VCPScale.percent(raw: r.current, maximum: r.maximum) + Double(up ? step : -step)
            let raw = VCPScale.raw(percent: percent, maximum: r.maximum)
            if engine.write(feature, raw: raw, monitor: m.id) {
                let now = Int(VCPScale.percent(raw: raw, maximum: r.maximum))
                if o.json { emit(Value(monitor: m.number, id: m.id, setting: feature.cliName, value: now, raw: Int(raw), maximum: Int(r.maximum))) }
                else if !o.quiet { print("\(m.number) \(feature.cliName): \(now)%") }
            } else {
                failed.append(m.name)
            }
        }
        notifyApp()
        if !failed.isEmpty { throw Failure(message: "couldn't change \(feature.cliName) on \(failed.joined(separator: ", "))", exitCode: 1) }
    }

    static func emit<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(value) { print(String(decoding: data, as: UTF8.self)) }
    }

    static func jsonString(_ s: String) -> String {
        (try? JSONEncoder().encode(s)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
    }
}
