import CoreAudio
import Foundation

/// Who a sound belongs to: an app (helpers and web content folded into it), or a system service.
struct AppIdentity: Hashable, Sendable {
    enum Kind: Hashable, Sendable { case app, systemSounds, webContent, process }

    /// Settings key: the owning app's bundle identifier, or a stable stand-in.
    var key: String
    var name: String
    /// The owning `.app` bundle, for its icon.
    var bundlePath: String?
    var kind: Kind = .app

    static let systemSoundsKey = "com.apple.systemsounds"
    static let webContentKey = "com.apple.WebKit"
}

/// An audio output device as the HAL describes it.
struct AudioDeviceInfo: Equatable, Identifiable, Sendable {
    var id: AudioObjectID
    var uid: String
    var name: String
    var outputChannels = 0
    var inputChannels = 0
    var sampleRate: Double = 48_000
    var transport: UInt32 = 0
    /// The selected data source, e.g. "Headphones" on the built-in output.
    var dataSource: String?
    var isAggregate: Bool { transport == kAudioDeviceTransportTypeAggregate || transport == kAudioDeviceTransportTypeAutoAggregate }
    var hasOutput: Bool { outputChannels > 0 }
    var hasInput: Bool { inputChannels > 0 }
}

/// One process the HAL knows about.
struct AudioProcessInfo: Equatable, Sendable {
    var objectID: AudioObjectID
    var pid: pid_t
    var bundleID: String
    var isRunningOutput: Bool
    /// UIDs of the devices this process plays to.
    var outputDeviceUIDs: [String]
    var owner: AppIdentity
}

/// Everything App Volume decides from: processes, devices and the system defaults.
struct AudioWorld: Equatable, Sendable {
    var processes: [AudioProcessInfo] = []
    var devices: [AudioDeviceInfo] = []
    var defaultOutputUID: String?
    var defaultInputUID: String?

    var outputDevices: [AudioDeviceInfo] { devices.filter(\.hasOutput) }
    var inputDevices: [AudioDeviceInfo] { devices.filter(\.hasInput) }
    func device(uid: String?) -> AudioDeviceInfo? { uid.flatMap { u in devices.first { $0.uid == u } } }
    var defaultOutput: AudioDeviceInfo? { device(uid: defaultOutputUID) }
    var defaultInput: AudioDeviceInfo? { device(uid: defaultInputUID) }
}

/// The processes of one app, merged.
struct AudioApp: Equatable, Identifiable, Sendable {
    var identity: AppIdentity
    /// HAL process objects, sorted.
    var processes: [AudioObjectID]
    var isPlaying: Bool
    /// Devices the playing processes send to, in first-seen order.
    var outputDeviceUIDs: [String]

    var id: String { identity.key }
    var name: String { identity.name }
}

enum AppGrouper {
    /// Folds processes into apps, keeping the first-seen order of apps.
    static func group(_ processes: [AudioProcessInfo]) -> [AudioApp] {
        var order: [String] = []
        var apps: [String: AudioApp] = [:]
        for p in processes {
            let key = p.owner.key
            if var app = apps[key] {
                app.processes.append(p.objectID)
                app.isPlaying = app.isPlaying || p.isRunningOutput
                if p.isRunningOutput {
                    for uid in p.outputDeviceUIDs where !app.outputDeviceUIDs.contains(uid) { app.outputDeviceUIDs.append(uid) }
                }
                // Prefer the identity of the app's own process (it has the real bundle path).
                if app.identity.bundlePath == nil, p.owner.bundlePath != nil { app.identity = p.owner }
                apps[key] = app
            } else {
                order.append(key)
                apps[key] = AudioApp(identity: p.owner, processes: [p.objectID], isPlaying: p.isRunningOutput,
                                     outputDeviceUIDs: p.isRunningOutput ? p.outputDeviceUIDs : [])
            }
        }
        return order.compactMap { key in
            apps[key].map { var a = $0; a.processes.sort(); return a }
        }
    }
}

/// A running app as LaunchServices lists it.
struct RunningAppInfo: Equatable, Sendable {
    var bundleID: String
    var name: String
    var bundlePath: String?
}

/// Works out which app a sound-producing process belongs to, with public information only:
/// helpers live inside their app's bundle, WebKit's media process names itself after its app,
/// and a few system daemons play on behalf of an app.
enum OwnerResolver {
    struct Process {
        var bundleID: String
        /// Executable path (from `proc_pidpath`).
        var executablePath: String?
        /// The name LaunchServices shows for the process, e.g. "Safari Graphics and Media".
        var displayName: String?
        /// Short process name (`proc_name`).
        var processName: String
    }

    /// Daemons that play sound for an app or for the system.
    static let daemonOwners: [String: String] = [
        "com.apple.avconferenced": "com.apple.FaceTime",
        "com.apple.telephonyutilities.callservicesd": "com.apple.FaceTime",
        "com.apple.assistantd": "com.apple.Siri",
        "com.apple.sirittsd": "com.apple.Siri",
        "com.apple.CoreSpeech": "com.apple.Siri",
    ]

    static let systemSoundProcesses: Set<String> = ["systemsoundserverd", "com.apple.systemsoundserverd", "com.apple.PowerChime"]

    /// - Parameter bundleInfo: the bundle id and display name of an `.app` at a path that isn't running.
    static func identity(of p: Process, running: [RunningAppInfo],
                         bundleInfo: (String) -> (id: String, name: String)? = { _ in nil }) -> AppIdentity {
        if systemSoundProcesses.contains(p.bundleID) || systemSoundProcesses.contains(p.processName) {
            return AppIdentity(key: AppIdentity.systemSoundsKey,
                               name: String(localized: "System Sounds", comment: "App Volume: alerts and other sounds macOS plays"),
                               kind: .systemSounds)
        }
        if let ownerID = daemonOwners[p.bundleID] {
            let app = running.first { $0.bundleID == ownerID }
            return AppIdentity(key: ownerID, name: app?.name ?? ownerID.split(separator: ".").last.map(String.init) ?? ownerID,
                               bundlePath: app?.bundlePath)
        }
        // A helper inside an app bundle belongs to the outermost app.
        if let path = p.executablePath, let outer = outermostApp(path) {
            if let app = running.first(where: { $0.bundlePath.map(standardized) == outer }) {
                return AppIdentity(key: app.bundleID, name: app.name, bundlePath: outer)
            }
            if let info = bundleInfo(outer) {
                return AppIdentity(key: info.id, name: info.name, bundlePath: outer)
            }
        }
        // WebKit's media process: "Safari Graphics and Media" → Safari.
        if p.bundleID.hasPrefix("com.apple.WebKit") {
            if let name = p.displayName,
               let app = running.filter({ !$0.name.isEmpty && name.hasPrefix($0.name) && $0.bundleID != p.bundleID })
                .max(by: { $0.name.count < $1.name.count }) {
                return AppIdentity(key: app.bundleID, name: app.name, bundlePath: app.bundlePath)
            }
            return AppIdentity(key: AppIdentity.webContentKey,
                               name: String(localized: "Web Content", comment: "App Volume: sound from web pages whose app is unknown"),
                               kind: .webContent)
        }
        // com.example.App.helper → com.example.App
        if let app = running.filter({ p.bundleID.hasPrefix($0.bundleID + ".") }).max(by: { $0.bundleID.count < $1.bundleID.count }) {
            return AppIdentity(key: app.bundleID, name: app.name, bundlePath: app.bundlePath)
        }
        if let app = running.first(where: { $0.bundleID == p.bundleID && !p.bundleID.isEmpty }) {
            return AppIdentity(key: app.bundleID, name: app.name, bundlePath: app.bundlePath)
        }
        let name = p.displayName ?? p.processName
        return AppIdentity(key: p.bundleID.isEmpty ? "process:" + p.processName : p.bundleID,
                           name: name.isEmpty ? p.bundleID : name, kind: .process)
    }

    /// `/Applications/Foo.app/Contents/Frameworks/Foo Helper.app/Contents/MacOS/Foo Helper` → `/Applications/Foo.app`.
    static func outermostApp(_ path: String) -> String? {
        let parts = standardized(path).split(separator: "/", omittingEmptySubsequences: false)
        guard let i = parts.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return parts[...i].joined(separator: "/")
    }

    private static func standardized(_ path: String) -> String {
        // The same bundle can be seen through /System/Volumes/Data or a symlinked path.
        var p = (path as NSString).standardizingPath
        if p.hasPrefix("/System/Volumes/Data/") { p.removeFirst("/System/Volumes/Data".count) }
        return p
    }
}

/// SF Symbols for devices, by transport and name.
enum DeviceSymbol {
    static func name(for device: AudioDeviceInfo?, input: Bool = false) -> String {
        guard let device else { return input ? "mic" : "speaker.wave.2" }
        let name = device.name.lowercased()
        let source = device.dataSource?.lowercased() ?? ""
        if input {
            switch device.transport {
            case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
                return name.contains("airpods") ? "airpods" : "headphones"
            case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless: return "iphone"
            case kAudioDeviceTransportTypeBuiltIn: return "laptopcomputer"
            default: return "mic"
            }
        }
        if name.contains("airpods max") { return "airpods.max" }
        if name.contains("airpods pro") { return "airpods.pro" }
        if name.contains("airpods") { return "airpods" }
        if name.contains("homepod") { return "homepod" }
        switch device.transport {
        case kAudioDeviceTransportTypeBuiltIn:
            return source.contains("headphone") || name.contains("headphone") ? "headphones" : "laptopcomputer"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return name.contains("speaker") ? "hifispeaker" : "headphones"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "tv"
        case kAudioDeviceTransportTypeAirPlay: return "airplay.audio"
        case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeFireWire, kAudioDeviceTransportTypeThunderbolt,
             kAudioDeviceTransportTypePCI:
            return name.contains("headphone") || name.contains("headset") ? "headphones" : "hifispeaker"
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: return "hifispeaker.2"
        case kAudioDeviceTransportTypeVirtual: return "waveform"
        default: return "speaker.wave.2"
        }
    }
}
