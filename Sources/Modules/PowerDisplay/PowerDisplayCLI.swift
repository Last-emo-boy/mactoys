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
    static func discover() -> [MonitorSnapshot] {
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
      modes [-n <n[,n…]>]                    Resolutions grouped by aspect ratio: * current,
                                             HiDPI, native, ★ favorite, refresh rates
      set-mode -n <n> <W>x<H>[@<Hz>] [--hidpi|--no-hidpi]
                                             Switch resolution (also --refresh <Hz>,
                                             --mode-id <id>); applies at once, no prompt
      dim [-n <n[,n…]>] <0-100|off>          Software dimming below the hardware minimum
                                             (needs MacToys running; lasts while it runs)
      pip -n <n> [--close]                   Picture in picture of a display (needs
                                             MacToys running and Screen Recording)

    Options:
      -n, --monitor-number <n[,n…]>          1-based monitor numbers (see list)
      -i, --monitor-id <id>                  Stable monitor id; wins over -n
      --setting <s>                          brightness, contrast, volume, color-temperature,
                                             input-source, power-state, orientation
      --refresh <Hz>, --hidpi, --no-hidpi, --mode-id <id>
                                             set-mode choices
      --level <0-100>                        dim level (or as the last argument)
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
            case "modes":
                try printModes(&opts)
            case "set-mode":
                try setMode(&opts)
            case "dim":
                try dim(&opts)
            case "pip":
                try pip(&opts)
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
        var refresh: Double?
        var hiDPI: Bool?
        var modeID: Int32?
        var level: String?
        var close = false
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
                case "--refresh":
                    guard let hz = Double(try value(arg).lowercased().replacingOccurrences(of: "hz", with: "")), hz > 0 else {
                        throw Failure(message: "--refresh takes a rate in Hz, e.g. 60 or 59.94", exitCode: 2)
                    }
                    o.refresh = hz
                case "--hidpi": o.hiDPI = true
                case "--no-hidpi": o.hiDPI = false
                case "--mode-id":
                    guard let id = Int32(try value(arg)) else { throw Failure(message: "--mode-id takes a number from `modes --json`", exitCode: 2) }
                    o.modeID = id
                case "--level": o.level = try value(arg)
                case "--close": o.close = true
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
            if single || !["get", "modes"].contains(o.command) { throw Failure(message: "pass --monitor-number or --monitor-id", exitCode: 2) }
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

    // MARK: - Resolution, dimming, picture in picture

    /// A display as `list` numbers it, without the slow DDC probing `discover` does.
    struct LightMonitor {
        var number: Int
        var id: String
        var name: String
        var displayID: CGDirectDisplayID
        var builtIn: Bool
    }

    static func lightMonitors() -> [LightMonitor] {
        let names = MainActor.assumeIsolated { DisplayEngine.screenNames() }
        let displays = DisplayEngine.onlineDisplays(names: names)
        let ids = DisplayEngine.stableIDs(displays)
        return displays.enumerated().map { i, d in
            LightMonitor(number: i + 1, id: ids[i], name: d.name.isEmpty ? "Display \(i + 1)" : d.name,
                         displayID: d.id, builtIn: d.isBuiltIn)
        }
    }

    static func lightTargets(_ o: Options, single: Bool, allByDefault: Bool) throws -> [LightMonitor] {
        let all = lightMonitors()
        if let id = o.id {
            guard let m = all.first(where: { $0.id == id }) else { throw Failure(message: "no monitor with id \(id)", exitCode: 2) }
            return [m]
        }
        guard !o.numbers.isEmpty else {
            if allByDefault && !single { return all }
            throw Failure(message: "pass --monitor-number or --monitor-id", exitCode: 2)
        }
        if single && o.numbers.count > 1 { throw Failure(message: "\(o.command) takes one monitor", exitCode: 2) }
        return try o.numbers.map { n in
            guard let m = all.first(where: { $0.number == n }) else { throw Failure(message: "no monitor \(n); see `list`", exitCode: 2) }
            return m
        }
    }

    public struct ModeLine: Codable, Sendable {
        public var monitor: Int
        public var id: String
        public var aspect: String
        public var width: Int
        public var height: Int
        public var pixelWidth: Int
        public var pixelHeight: Int
        public var hidpi: Bool
        public var native: Bool
        public var current: Bool
        public var favorite: Bool
        public var refreshRates: [Double]
        public var modeIDs: [Int32]
    }

    /// Refresh rates as the command line prints them: `60`, `59.94`.
    static func rateText(_ rate: Double) -> String { String(format: "%g", RefreshFormat.rounded(rate)) }

    static func modeText(_ m: DisplayModeInfo) -> String {
        "\(m.width)x\(m.height)\(m.isHiDPI ? " HiDPI" : "")\(m.refreshRate > 0 ? " @ \(rateText(m.refreshRate)) Hz" : "")"
    }

    static func printModes(_ o: inout Options) throws {
        let settings = loadSettings()
        for m in try lightTargets(o, single: false, allByDefault: true) {
            let catalog = DisplayModeReader.catalog(m.displayID, favorites: settings.prefs(m.id).favoriteModes,
                                                    hideLowResolutionDuplicates: false)
            if o.json {
                for g in catalog.groups {
                    for e in g.entries {
                        emit(ModeLine(monitor: m.number, id: m.id, aspect: g.aspect.title(locale: Locale(identifier: "en_US_POSIX")),
                                      width: e.key.width, height: e.key.height, pixelWidth: e.key.pixelWidth,
                                      pixelHeight: e.key.pixelHeight, hidpi: e.isHiDPI, native: e.isNative, current: e.isCurrent,
                                      favorite: e.isFavorite, refreshRates: e.refreshRates.map(RefreshFormat.rounded),
                                      modeIDs: e.modes.map(\.modeID)))
                    }
                }
                continue
            }
            print("\(m.number)  \(m.name)\(catalog.current.map { "  (current \(modeText($0)))" } ?? "")")
            if catalog.isEmpty { print("   no modes reported") }
            for g in catalog.groups {
                print("   \(g.aspect.title(locale: Locale(identifier: "en_US_POSIX")))")
                for e in g.entries {
                    let size = "\(e.key.width)x\(e.key.height)".padding(toLength: 11, withPad: " ", startingAt: 0)
                    var tags: [String] = []
                    if e.isHiDPI { tags.append("HiDPI") }
                    if e.isNative { tags.append("native") }
                    let rates = e.refreshRates.filter { $0 > 0 }.map(rateText).joined(separator: ", ")
                    let line = "   \(e.isCurrent ? "*" : " ") \(size) \(tags.joined(separator: " ").padding(toLength: 12, withPad: " ", startingAt: 0))"
                        + (rates.isEmpty ? "" : " \(rates) Hz") + (e.isFavorite ? "  ★" : "")
                    print(line)
                }
            }
        }
    }

    static func setMode(_ o: inout Options) throws {
        guard let m = try lightTargets(o, single: true, allByDefault: false).first else { return }
        var request: ModeRequest
        if let text = o.positional.first {
            guard let r = ModeRequest.parse(text) else {
                throw Failure(message: "can't read \(text); use <width>x<height>[@<Hz>], e.g. 2560x1440@60", exitCode: 2)
            }
            request = r
        } else if o.modeID != nil {
            request = ModeRequest()
        } else {
            throw Failure(message: "set-mode needs <width>x<height>[@<Hz>] or --mode-id", exitCode: 2)
        }
        if let id = o.modeID { request.modeID = id }
        if let hz = o.refresh { request.refresh = hz }
        if let h = o.hiDPI { request.hiDPI = h }
        let catalog = DisplayModeReader.catalog(m.displayID, favorites: [], hideLowResolutionDuplicates: false)
        guard let mode = catalog.match(request) else {
            throw Failure(message: "\(m.name) has no such mode; see `mactoys powerdisplay modes -n \(m.number)`", exitCode: 1)
        }
        if mode != catalog.current {
            guard DisplayModeReader.apply(mode, to: m.displayID) else {
                throw Failure(message: "macOS refused to switch \(m.name) to \(modeText(mode))", exitCode: 1)
            }
            notifyApp()
        }
        if o.json {
            struct Line: Codable { var monitor: Int; var id: String; var width: Int; var height: Int; var hidpi: Bool; var refreshRate: Double; var modeID: Int32 }
            emit(Line(monitor: m.number, id: m.id, width: mode.width, height: mode.height, hidpi: mode.isHiDPI,
                      refreshRate: RefreshFormat.rounded(mode.refreshRate), modeID: mode.modeID))
        } else {
            print("\(m.number) \(m.name): \(modeText(mode))")
        }
    }

    /// `off`, or 0…100.
    static func parseDimLevel(_ text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "%", with: "")
        if t == "off" { return 0 }
        guard let n = Int(t), (0...100).contains(n) else { return nil }
        return n
    }

    static func dim(_ o: inout Options) throws {
        guard let text = o.level ?? o.positional.last, let level = parseDimLevel(text) else {
            throw Failure(message: "dim takes a level from 0 to 100, or off", exitCode: 2)
        }
        let targets: [String] = o.id != nil || !o.numbers.isEmpty
            ? try lightTargets(o, single: false, allByDefault: false).map(\.id) : ["all"]
        try requireApp()
        for t in targets {
            sendToApp(AppCommand(module: "powerdisplay", action: "dim", parameters: ["monitor": t, "level": "\(level)"]))
        }
        if !o.json && !o.quiet { print(level == 0 ? "Software dimming off." : "Software dimming \(level)%.") }
    }

    static func pip(_ o: inout Options) throws {
        guard let m = try lightTargets(o, single: true, allByDefault: false).first else { return }
        try requireApp()
        var params = ["monitor": m.id]
        if o.close { params["close"] = "1" }
        sendToApp(AppCommand(module: "powerdisplay", action: "pip", parameters: params))
    }

    /// Software dimming and picture in picture live in the app: the window server undoes a color
    /// table when the process that set it exits, and PiP is a window.
    static func requireApp() throws {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: Paths.bundleIdentifier).isEmpty else {
            throw Failure(message: "MacToys isn't running; open it first (software dimming and picture in picture live in the app)", exitCode: 1)
        }
        let general = SettingsStore.shared.load("general", default: GeneralSettings())
        guard general.enabled["powerdisplay"] == true else {
            throw Failure(message: "Power Display is off; turn it on with `mactoys modules enable powerdisplay`", exitCode: 1)
        }
    }

    static func sendToApp(_ command: AppCommand) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Paths.bundleIdentifier) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        let semaphore = DispatchSemaphore(value: 0)
        NSWorkspace.shared.open([command.url], withApplicationAt: app, configuration: config) { _, error in
            if let error { FileHandle.standardError.write(Data("mactoys powerdisplay: \(error.localizedDescription)\n".utf8)) }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 10)
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
