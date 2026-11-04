import CoreAudio
import Foundation

/// How a session treats the app's sound.
enum TapMode: Equatable, Sendable {
    /// Listens only (meters, and checking that audio capture is allowed). The app plays as usual.
    case monitor
    /// Takes over the app's output (`mutedWhenTapped`) and plays it, processed, on `deviceUID`.
    case process
}

/// One tap + aggregate device + IO proc, described as data.
struct SessionSpec: Equatable, Sendable {
    var key: String
    var name: String
    var processes: [AudioObjectID]
    var deviceUID: String
    var sampleRate: Double
    var mode: TapMode
}

enum SessionChange: Equatable, Sendable {
    case start(SessionSpec)
    case stop(String)
    /// Device, sample rate or mode changed: tear down and build again.
    case restart(SessionSpec)
    /// Only the app's processes changed (a helper started or quit): update the tap in place.
    case retarget(String, [AudioObjectID])
}

/// Decides which apps need to pass through MacToys. Everything else is left alone.
enum TapPolicy {
    /// Whether an app's settings change its sound, so it must be processed.
    static func needsProcessing(_ s: AppAudioSettings, app: AudioApp, world: AudioWorld) -> Bool {
        if s.volume != 1 || s.muted || s.balance != 0 || s.eq.isEffective { return true }
        return isRerouted(s, app: app, world: world)
    }

    /// Whether the chosen output differs from where the app plays by itself.
    static func isRerouted(_ s: AppAudioSettings, app: AudioApp, world: AudioWorld) -> Bool {
        guard let uid = s.outputUID, let target = usableOutput(world.device(uid: uid)) else { return false }
        let own = ownOutput(app, world: world) ?? world.defaultOutput
        return own?.uid != target.uid
    }

    /// Where the processed sound plays: the chosen device while it's connected, else where the app
    /// plays by itself, else the system output. Nil when that is an aggregate (multi-output) device,
    /// which can't be nested in App Volume's own aggregate: such an app is left alone rather than
    /// moved somewhere the user didn't pick.
    static func outputDevice(for s: AppAudioSettings, app: AudioApp, world: AudioWorld) -> AudioDeviceInfo? {
        if let chosen = usableOutput(world.device(uid: s.outputUID)) { return chosen }
        let own = app.outputDeviceUIDs.compactMap { world.device(uid: $0) }.filter(\.hasOutput)
        if own.count == 1 { return usableOutput(own[0]) }
        return usableOutput(world.defaultOutput)
    }

    /// The device the app plays to on its own, when it's a single real output.
    static func ownOutput(_ app: AudioApp, world: AudioWorld) -> AudioDeviceInfo? {
        let own = app.outputDeviceUIDs.compactMap { usableOutput(world.device(uid: $0)) }
        return own.count == 1 ? own[0] : nil
    }

    /// Aggregate devices can't be nested inside App Volume's own aggregate device.
    static func usableOutput(_ d: AudioDeviceInfo?) -> AudioDeviceInfo? {
        guard let d, d.hasOutput, !d.isAggregate else { return nil }
        return d
    }

    /// The session an app should have now, if any.
    static func spec(for app: AudioApp, settings s: AppAudioSettings, world: AudioWorld, processing: Bool,
                     verified: Bool, metering: Bool) -> SessionSpec? {
        guard !app.processes.isEmpty else { return nil }
        let mode: TapMode
        if processing {
            mode = verified ? .process : .monitor
        } else if metering && app.isPlaying {
            mode = .monitor
        } else {
            return nil
        }
        let device = mode == .process ? outputDevice(for: s, app: app, world: world)
            : ownOutput(app, world: world) ?? usableOutput(world.defaultOutput) ?? outputDevice(for: s, app: app, world: world)
        guard let device else { return nil }
        return SessionSpec(key: app.identity.key, name: app.name, processes: app.processes, deviceUID: device.uid,
                           sampleRate: device.sampleRate, mode: mode)
    }

    /// The steps from the running sessions to the wanted ones, in a stable order.
    static func changes(from current: [String: SessionSpec], to wanted: [String: SessionSpec]) -> [SessionChange] {
        var out: [SessionChange] = []
        for key in current.keys.sorted() where wanted[key] == nil { out.append(.stop(key)) }
        for key in wanted.keys.sorted() {
            guard let new = wanted[key] else { continue }
            guard let old = current[key] else { out.append(.start(new)); continue }
            if old.deviceUID != new.deviceUID || old.sampleRate != new.sampleRate || old.mode != new.mode {
                out.append(.restart(new))
            } else if old.processes != new.processes {
                out.append(.retarget(key, new.processes))
            }
        }
        return out
    }
}
