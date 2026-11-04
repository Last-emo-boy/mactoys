import CoreAudio
import Foundation

/// The state of one session as the backend reports it.
enum SessionStatus: Equatable, Sendable {
    case starting
    /// `heardAudio`: at least one non-zero sample arrived since the session started.
    case running(heardAudio: Bool)
    case failed(String)
}

/// Builds and tears down tap sessions. The HAL implementation does the work on a queue of its own;
/// tests use a recording mock.
@MainActor
protocol TapBackend: AnyObject {
    func start(_ spec: SessionSpec, settings: ProcessingSettings)
    func stop(_ key: String)
    func retarget(_ key: String, processes: [AudioObjectID])
    func update(_ key: String, settings: ProcessingSettings)
    func status(_ key: String) -> SessionStatus
}

/// Keeps the running sessions in line with what the apps, devices and settings call for, and
/// works out whether macOS lets MacToys hear system audio.
///
/// There is no API to ask about the System Audio Recording permission, and a refused tap simply
/// delivers silence — while a `mutedWhenTapped` tap still silences the app. So an app is only
/// taken over once MacToys has heard real audio: until then it gets a listening (unmuted) tap and
/// keeps playing as it does. A processing tap that hears nothing for a few seconds while its app
/// plays goes back to listening, so a refused or revoked permission never leaves an app silent.
@MainActor
final class TapController {
    struct Inputs {
        var apps: [AudioApp]
        var world: AudioWorld
        var settings: AppVolumeSettings
    }

    enum Capture: Equatable, Sendable {
        /// Nothing heard yet this session.
        case unknown
        /// Audio arrived: capture is allowed.
        case granted
        /// Listening taps stayed silent while their apps played: capture is probably not allowed.
        case silent
    }

    private(set) var capture: Capture = .unknown
    private(set) var sessions: [String: SessionSpec] = [:]
    /// Apps whose session couldn't be built, with the reason.
    private(set) var failures: [String: String] = [:]
    /// Listen to every playing app (the flyout's level meters).
    var metering = false
    /// Called after `capture` or `failures` change.
    var onStateChange: (() -> Void)?

    let backend: TapBackend
    /// A session outlives its app's last sound this long, so pausing and resuming doesn't rebuild it.
    var idleTimeout: TimeInterval = 20
    /// A processing session stays this long after its app is back to normal (sliders pass through 100 %).
    var releaseDelay: TimeInterval = 1.5
    /// A processing session that hears nothing this long while its app plays goes back to listening.
    var verifyTimeout: TimeInterval = 6
    /// Listening sessions silent this long, before anything was ever heard, mean capture is likely refused.
    var silentAfter: TimeInterval = 5
    /// Silent listening sessions are rebuilt this often until something is heard (picks up a permission
    /// granted in System Settings).
    var probeRestart: TimeInterval = 8
    /// A session that failed to build isn't tried again with the same spec for this long.
    var failureBackoff: TimeInterval = 10

    private var inputs: Inputs?
    private var started: [String: Date] = [:]
    private var lastPlaying: [String: Date] = [:]
    private var lastNeeded: [String: Date] = [:]
    /// Processing apps that must be heard (through a listening tap) before they're taken over.
    private var unverified: Set<String> = []
    private var failedSpecs: [String: (spec: SessionSpec, at: Date)] = [:]
    private var applied: [String: ProcessingSettings] = [:]
    /// Apps whose settings call for processing, as of the last reconcile.
    private var needsTakeover: Set<String> = []
    /// True while an app waits (in a listening session) to be taken over: worth checking health
    /// more often than once a second, so its settings apply as soon as its audio arrives.
    private(set) var settling = false

    init(backend: TapBackend) {
        self.backend = backend
    }

    // MARK: - Reconcile

    func reconcile(_ inputs: Inputs, now: Date) {
        self.inputs = inputs
        let world = inputs.world
        let bandCount = inputs.settings.eqBandCount
        var wanted: [String: SessionSpec] = [:]
        var wantedSettings: [String: ProcessingSettings] = [:]
        var blocked: [String: String] = [:]
        var takeover: Set<String> = []

        for app in inputs.apps where !inputs.settings.isExcluded(app.identity) {
            let key = app.identity.key
            if app.isPlaying { lastPlaying[key] = now }
            let s = inputs.settings.settings(for: key)
            let needed = TapPolicy.needsProcessing(s, app: app, world: world)
            if needed { lastNeeded[key] = now; takeover.insert(key) }
            let active = app.isPlaying || lastPlaying[key].map { now.timeIntervalSince($0) < idleTimeout } ?? false
            guard active else { continue }
            let verified = capture == .granted && !unverified.contains(key)

            var spec = TapPolicy.spec(for: app, settings: s, world: world, processing: needed, verified: verified,
                                      metering: metering)
            // Back at 100 %: keep the processing session a moment (sliders often pass through 100 %),
            // unless it would have to move to another device anyway.
            if !needed, let current = sessions[key], current.mode == .process,
               let t = lastNeeded[key], now.timeIntervalSince(t) < releaseDelay,
               let kept = TapPolicy.spec(for: app, settings: s, world: world, processing: true, verified: true, metering: false),
               kept.deviceUID == current.deviceUID {
                spec = kept
            }
            guard let spec else {
                if needed, TapPolicy.outputDevice(for: s, app: app, world: world) == nil {
                    blocked[key] = String(localized: "App Volume can't change sound sent to a multi-output or aggregate device.")
                }
                continue
            }
            if let failed = failedSpecs[key], failed.spec == spec, now.timeIntervalSince(failed.at) < failureBackoff { continue }
            wanted[key] = spec
            wantedSettings[key] = ProcessingSettings(s, bandCount: bandCount)
        }

        needsTakeover = takeover
        for change in TapPolicy.changes(from: sessions, to: wanted) {
            switch change {
            case .stop(let key):
                backend.stop(key)
                sessions[key] = nil
                started[key] = nil
                applied[key] = nil
            case .start(let spec), .restart(let spec):
                if case .restart = change { backend.stop(spec.key) }
                let settings = wantedSettings[spec.key] ?? .unity
                backend.start(spec, settings: spec.mode == .process ? settings : .unity)
                sessions[spec.key] = spec
                started[spec.key] = now
                applied[spec.key] = spec.mode == .process ? settings : nil
            case .retarget(let key, let processes):
                backend.retarget(key, processes: processes)
                sessions[key]?.processes = processes
            }
        }
        for (key, spec) in sessions where spec.mode == .process {
            guard let s = wantedSettings[key], applied[key] != s else { continue }
            backend.update(key, settings: s)
            applied[key] = s
        }
        // Forget timestamps of apps that are gone.
        let present = Set(inputs.apps.map(\.identity.key))
        for key in lastPlaying.keys where !present.contains(key) && sessions[key] == nil {
            lastPlaying[key] = nil
            lastNeeded[key] = nil
        }
        // A failure shows while the app still needs processing; blocked apps get their reason.
        var nextFailures = failures.filter { takeover.contains($0.key) && blocked[$0.key] == nil && failedSpecs[$0.key] != nil }
        nextFailures.merge(blocked) { _, new in new }
        if nextFailures != failures {
            failures = nextFailures
            onStateChange?()
        }
        settling = sessions.values.contains { $0.mode == .monitor && needsTakeover.contains($0.key) }
    }


    /// Checks session health (call about once a second), then reconciles again.
    func tick(now: Date) {
        guard let inputs else { return }
        let playing = Set(inputs.apps.filter(\.isPlaying).map(\.identity.key))
        var changed = false
        for (key, spec) in sessions {
            let age = started[key].map { now.timeIntervalSince($0) } ?? 0
            switch backend.status(key) {
            case .starting:
                break
            case .failed(let message):
                backend.stop(key)
                sessions[key] = nil
                started[key] = nil
                applied[key] = nil
                failedSpecs[key] = (spec, now)
                if failures[key] != message { failures[key] = message; changed = true }
            case .running(let heard):
                if failures.removeValue(forKey: key) != nil { changed = true }
                failedSpecs[key] = nil
                if heard {
                    if capture != .granted { capture = .granted; changed = true }
                    unverified.remove(key)
                    continue
                }
                guard playing.contains(key) else { continue }
                if spec.mode == .process, age >= verifyTimeout {
                    // Taken over but nothing arrives: give the app its own output back while we listen.
                    unverified.insert(key)
                } else if spec.mode == .monitor, capture != .granted {
                    if age >= silentAfter, capture == .unknown { capture = .silent; changed = true }
                    if age >= probeRestart {
                        backend.stop(key)
                        sessions[key] = nil
                        started[key] = nil
                    }
                }
            }
        }
        if changed { onStateChange?() }
        reconcile(inputs, now: now)
    }

    /// Asks again after the user changed the permission: listening sessions start over.
    func retry(now: Date) {
        capture = .unknown
        unverified.removeAll()
        failedSpecs.removeAll()
        for (key, spec) in sessions where spec.mode == .monitor {
            backend.stop(key)
            sessions[key] = nil
            started[key] = nil
        }
        onStateChange?()
        if let inputs { reconcile(inputs, now: now) }
    }

    /// Tears every session down. Apps play straight to their devices again.
    func stopAll() {
        for key in sessions.keys.sorted() { backend.stop(key) }
        sessions.removeAll()
        started.removeAll()
        applied.removeAll()
        lastPlaying.removeAll()
        lastNeeded.removeAll()
        unverified.removeAll()
        failedSpecs.removeAll()
        failures.removeAll()
        needsTakeover.removeAll()
        settling = false
        inputs = nil
    }

    /// Whether the app's sound goes through MacToys right now.
    func isProcessing(_ key: String) -> Bool { sessions[key]?.mode == .process }
}
