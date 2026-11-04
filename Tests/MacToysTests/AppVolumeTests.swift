import CoreAudio
import Foundation
import MacToysCore
import Testing
@testable import AppVolume

@Suite struct AppVolumeTests {
    // MARK: - Gain and limiter

    @Test func taperIsUnityAt100PercentAndSymmetricInDecibels() {
        #expect(Gain.amplitude(volume: 1) == 1)
        #expect(Gain.amplitude(volume: 0) == 0)
        #expect(abs(Gain.decibels(amplitude: Gain.amplitude(volume: 2)) - 12.04) < 0.01)
        #expect(abs(Gain.decibels(amplitude: Gain.amplitude(volume: 0.5)) + 12.04) < 0.01)
        let steps = stride(from: 0.0, through: 2.0, by: 0.01).map { Gain.amplitude(volume: $0) }
        #expect(zip(steps, steps.dropFirst()).allSatisfy { $0 < $1 }, "monotonic")
    }

    @Test func balanceLawKeepsCenterAtUnity() {
        #expect(Gain.balance(0) == (1, 1))
        #expect(Gain.balance(1) == (0, 1))
        #expect(Gain.balance(-1) == (1, 0))
        let (l, r) = Gain.balance(0.25)
        #expect(l == 0.75 && r == 1)
    }

    @Test func unityChainPassesSamplesBitForBit() {
        var dsp = DSPState(DSPParameters(.unity, sampleRate: 48_000), sampleRate: 48_000)
        var rng = SeededRandom(seed: 7)
        for _ in 0..<10_000 {
            let l = Float(rng.next() * 2 - 1), r = Float(rng.next() * 2 - 1)
            let (yl, yr) = dsp.process(l, r)
            #expect(yl == l)
            #expect(yr == r)
        }
        // Even samples past full scale (some apps send them) pass untouched at 100 %.
        #expect(dsp.process(1.3, -1.7) == (1.3, -1.7))
    }

    @Test func boostWithEqualizerNeverClips() {
        var s = ProcessingSettings()
        s.volume = 2
        s.eq = EQSettings(isOn: true, gains: Array(repeating: 12, count: 10), preamp: 12)
        let rate = 48_000.0
        var dsp = DSPState(DSPParameters(s, sampleRate: rate), sampleRate: rate)
        var peak: Float = 0
        for f in [40.0, 1000, 9000] {
            for n in 0..<24_000 {
                let x = Float(sin(2 * .pi * f * Double(n) / rate))
                let (l, r) = dsp.process(x, -x)
                peak = max(peak, abs(l), abs(r))
            }
        }
        var rng = SeededRandom(seed: 3)
        for _ in 0..<48_000 {
            let (l, r) = dsp.process(Float(rng.next() * 2 - 1), Float(rng.next() * 2 - 1))
            peak = max(peak, abs(l), abs(r))
        }
        #expect(peak < 1, "peak \(peak)")
        #expect(peak > 0.85, "the limiter holds loud material near full scale, not far below it")
    }

    @Test func boostLeavesQuietAudioUnlimited() {
        var s = ProcessingSettings()
        s.volume = 2   // ×4 (+12 dB)
        var dsp = DSPState(DSPParameters(s, sampleRate: 48_000), sampleRate: 48_000)
        for n in 0..<4_800 {
            let x = Float(0.1 * sin(Double(n) * 0.05))
            let (y, _) = dsp.process(x, x)
            #expect(abs(y - x * 4) < 1e-6)
        }
    }

    @Test func softClipStaysBelowFullScale() {
        #expect(SoftLimiter.softClip(0.5) == 0.5)
        #expect(SoftLimiter.softClip(-0.8) == -0.8)
        let xs = stride(from: 0.0, through: 50, by: 0.01).map(SoftLimiter.softClip)
        #expect(xs.allSatisfy { $0 < 1 })
        #expect(zip(xs, xs.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(SoftLimiter.softClip(-50) > -1)
    }

    @Test func muteGlidesToSilenceWithoutAClick() {
        var dsp = DSPState(DSPParameters(.unity, sampleRate: 48_000), sampleRate: 48_000)
        var s = ProcessingSettings()
        s.muted = true
        dsp.update(DSPParameters(s, sampleRate: 48_000))
        let first = dsp.process(1, 1).0
        #expect(first > 0.99, "no step to zero")
        var last: Float = 1
        for _ in 0..<9_600 { last = dsp.process(1, 1).0 }
        #expect(last < 0.001, "silent within 200 ms")
    }

    // MARK: - Biquads

    @Test func peakingFilterHitsItsGainAtTheCenter() {
        for (f, g, q) in [(1000.0, 6.0, 1.41), (125.0, -9.0, 1.41), (4000.0, 12.0, 0.7)] {
            let c = BiquadCoefficients.peaking(frequency: f, gain: g, q: q, sampleRate: 48_000)
            #expect(abs(c.decibels(at: f, sampleRate: 48_000) - g) < 1e-9)
            #expect(abs(c.decibels(at: f / 32, sampleRate: 48_000)) < 0.2, "far below the band ~0 dB")
        }
    }

    @Test func shelvesReachHalfTheirGainAtTheCorner() {
        let rate = 44_100.0
        let low = BiquadCoefficients.lowShelf(frequency: 100, gain: 8, sampleRate: rate)
        #expect(abs(low.decibels(at: 100, sampleRate: rate) - 4) < 1e-6)
        #expect(abs(low.decibels(at: 10, sampleRate: rate) - 8) < 0.2)
        #expect(abs(low.decibels(at: 5000, sampleRate: rate)) < 0.1)
        let high = BiquadCoefficients.highShelf(frequency: 8000, gain: -6, sampleRate: rate)
        #expect(abs(high.decibels(at: 8000, sampleRate: rate) + 3) < 1e-6)
        #expect(abs(high.decibels(at: 100, sampleRate: rate)) < 0.1)
    }

    @Test func flatAndUnrepresentableBandsAreIdentity() {
        #expect(BiquadCoefficients.peaking(frequency: 1000, gain: 0, q: 1, sampleRate: 48_000).isIdentity)
        // A 16 kHz band on a 16 kHz Bluetooth call device is past Nyquist: left out, not unstable.
        #expect(BiquadCoefficients.highShelf(frequency: 16_000, gain: 6, sampleRate: 16_000).isIdentity)
        #expect(BiquadCoefficients.peaking(frequency: 8000, gain: 6, q: 1, sampleRate: 16_000).isIdentity)
    }

    @Test func eqResponseAtEachBandCenterMatchesThatBand() {
        for count in EQLayout.bandRange {
            let freqs = EQLayout.frequencies(count: count)
            for band in freqs.indices where EQLayout.kind(band: band, count: count) == .peak {
                var gains = Array(repeating: 0.0, count: count)
                gains[band] = 7.5
                let sections = EQCurve.coefficients(EQSettings(isOn: true, gains: gains), count: count, sampleRate: 48_000)
                let db = EQCurve.response(sections, preamp: 0, at: freqs[band], sampleRate: 48_000)
                #expect(abs(db - 7.5) < 1e-9, "\(count) bands, band \(band)")
            }
        }
    }

    @Test func filteredSineMatchesTheComputedResponse() {
        let rate = 48_000.0, f = 1000.0
        let c = BiquadCoefficients.peaking(frequency: f, gain: 6, q: 1.41, sampleRate: rate)
        var state = BiquadState()
        var energy = 0.0
        for n in 0..<48_000 {
            let y = state.process(sin(2 * .pi * f * Double(n) / rate), c)
            if n >= 24_000 { energy += y * y }
        }
        // RMS over whole cycles once the filter has settled, as an amplitude.
        let amplitude = sqrt(2 * energy / 24_000)
        #expect(abs(amplitude - c.magnitude(at: f, sampleRate: rate)) < 1e-3)
    }

    // MARK: - Equalizer layouts and presets

    @Test func bandLayoutsAreRoundAndIncreasing() {
        #expect(EQLayout.frequencies(count: 10) == [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16_000])
        #expect(EQLayout.frequencies(count: 3) == [100, 1000, 10_000])
        for n in EQLayout.bandRange {
            let f = EQLayout.frequencies(count: n)
            #expect(f.count == n)
            #expect(zip(f, f.dropFirst()).allSatisfy { $0 < $1 })
            #expect(f.allSatisfy { EQLayout.isoCenters.contains($0) })
        }
        #expect(EQLayout.kind(band: 0, count: 5) == .lowShelf)
        #expect(EQLayout.kind(band: 4, count: 5) == .highShelf)
        #expect(EQLayout.kind(band: 2, count: 5) == .peak)
        #expect(abs(EQLayout.q(band: 5, frequencies: EQLayout.frequencies(count: 10)) - sqrt(2)) < 1e-9, "one-octave bells")
    }

    @Test func presetsRoundTripThroughEveryLayout() {
        for preset in EQPreset.all {
            #expect(preset.gains(count: 10) == preset.points)
            for n in EQLayout.bandRange {
                let gains = preset.gains(count: n)
                #expect(gains.count == n)
                #expect(gains.allSatisfy { EQLayout.gainRange.contains($0) })
                // Flat is a subset of nothing else, so the first match is the preset itself.
                #expect(EQPreset.matching(gains, count: n)?.id == preset.id, "\(preset.id) at \(n) bands")
            }
            #expect(!preset.name.isEmpty)
        }
        #expect(EQPreset.matching([1, 2, 3], count: 3) == nil)
    }

    @Test func changingTheBandCountKeepsPresetsExact() throws {
        var s = AppVolumeSettings()
        let rock = try #require(EQPreset.named("rock"))
        s.apps["com.apple.Music"] = AppAudioSettings(name: "Music", eq: EQSettings(isOn: true, preset: "rock", gains: rock.points))
        var tuned = Array(repeating: 0.0, count: 10)
        tuned[5] = 6
        s.apps["com.apple.Safari"] = AppAudioSettings(name: "Safari", eq: EQSettings(isOn: true, gains: tuned))
        s.setBandCount(5)
        #expect(s.apps["com.apple.Music"]?.eq.gains == rock.gains(count: 5))
        #expect(s.apps["com.apple.Safari"]?.eq.gains.count == 5)
        s.setBandCount(10)
        #expect(s.apps["com.apple.Music"]?.eq.gains == rock.points)
        s.setBandCount(42)
        #expect(s.eqBandCount == 10)
    }

    @Test func customPresetsRoundTrip() throws {
        let preset = CustomEQPreset(name: "Late Night", frequencies: EQLayout.frequencies(count: 10),
                                    gains: [3, 2, 0, 0, -1, 0, 1, 2, 0, -2], preamp: -1.5)
        var s = AppVolumeSettings()
        s.customPresets = [preset]
        s.apps["com.apple.TV"] = AppAudioSettings(name: "TV", eq: EQSettings(isOn: true, preset: preset.id, gains: preset.gains, preamp: -1.5))
        let decoded = try JSONDecoder().decode(AppVolumeSettings.self, from: JSONEncoder().encode(s))
        #expect(decoded == s)
        s.setBandCount(7)
        #expect(s.apps["com.apple.TV"]?.eq.gains == EQCurve.resample(preset.gains, from: preset.frequencies,
                                                                       to: EQLayout.frequencies(count: 7)))
    }

    @Test func resampleInterpolatesOnALogAxisAndHoldsTheEnds() {
        let out = EQCurve.resample([0, 12], from: [100, 400], to: [50, 100, 200, 400, 800])
        #expect(out == [0, 0, 6, 12, 12])
    }

    // MARK: - Settings per app

    @Test @MainActor func settingsPersistPerBundleIdentifier() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("appvolume-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        let first = Persisted("appvolume", default: AppVolumeSettings(), store: store)
        first.update { s in
            s.update("com.apple.Music", name: "Music") { $0.volume = 0.4; $0.outputUID = "AirPods"; $0.outputName = "AirPods Pro" }
            s.update("us.zoom.xos", name: "Zoom") { $0.muted = true }
        }
        first.flush()
        let second = Persisted("appvolume", default: AppVolumeSettings(), store: store)
        let music = try #require(second.value.apps["com.apple.Music"])
        #expect(music.volume == 0.4 && music.outputUID == "AirPods" && music.name == "Music")
        #expect(second.value.apps["us.zoom.xos"]?.muted == true)
        #expect(second.value.settings(for: "com.apple.Safari") == AppAudioSettings(volume: 1))
    }

    @Test func entriesBackAtTheDefaultsAreForgotten() {
        var s = AppVolumeSettings()
        s.update("com.apple.Music", name: "Music") { $0.volume = 0.5 }
        #expect(s.apps["com.apple.Music"] != nil)
        s.update("com.apple.Music", name: "Music") { $0.volume = 1 }
        #expect(s.apps["com.apple.Music"] == nil)
        // Pinned apps keep an entry so their name is known while they aren't running.
        s.pinnedApps = ["com.apple.Music"]
        s.update("com.apple.Music", name: "Music") { $0.volume = 1 }
        #expect(s.apps["com.apple.Music"]?.name == "Music")
        // A tuned curve is remembered even while the equalizer is off.
        s.update("com.apple.Safari", name: "Safari") { $0.eq = EQSettings(isOn: false, gains: [3, 0, 0]) }
        #expect(s.apps["com.apple.Safari"] != nil)
        // Volumes are clamped to the allowed range.
        s.maxVolume = 1.5
        s.update("com.apple.TV", name: "TV") { $0.volume = 9; $0.balance = -4 }
        #expect(s.apps["com.apple.TV"]?.volume == 1.5)
        #expect(s.apps["com.apple.TV"]?.balance == -1)
    }

    @Test func olderSavedEntriesStillLoad() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("appvolume-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        try Data(#"{"apps":{"com.apple.Music":{"volume":0.3}},"showMeters":false}"#.utf8).write(to: store.url(for: "appvolume"))
        let s = store.load("appvolume", default: AppVolumeSettings())
        #expect(s.apps["com.apple.Music"]?.volume == 0.3)
        #expect(s.apps["com.apple.Music"]?.eq == EQSettings())
        #expect(s.showMeters == false)
    }

    @Test func exclusionsMatchBundleIdentifiersAndNames() {
        var s = AppVolumeSettings()
        s.excludedApps = ["com.apple.logic10", "ableton"]
        #expect(s.isExcluded(AppIdentity(key: "com.apple.logic10", name: "Logic Pro")))
        #expect(s.isExcluded(AppIdentity(key: "com.ableton.live", name: "Ableton Live 12")))
        #expect(!s.isExcluded(AppIdentity(key: "com.apple.Music", name: "Music")))
    }

    // MARK: - Which apps need a tap

    static let speakers = AudioDeviceInfo(id: 10, uid: "speakers", name: "MacBook Pro Speakers", outputChannels: 2,
                                          transport: kAudioDeviceTransportTypeBuiltIn)
    static let headphones = AudioDeviceInfo(id: 11, uid: "headphones", name: "AirPods Pro", outputChannels: 2,
                                            sampleRate: 48_000, transport: kAudioDeviceTransportTypeBluetooth)
    static let display = AudioDeviceInfo(id: 12, uid: "display", name: "Studio Display", outputChannels: 2,
                                         sampleRate: 44_100, transport: kAudioDeviceTransportTypeUSB)
    static let multiOutput = AudioDeviceInfo(id: 13, uid: "multi", name: "Multi-Output Device", outputChannels: 2,
                                             transport: kAudioDeviceTransportTypeAggregate)

    static func app(_ key: String, playing: Bool = true, on devices: [String] = ["speakers"],
                    processes: [AudioObjectID] = [100]) -> AudioApp {
        AudioApp(identity: AppIdentity(key: key, name: key), processes: processes, isPlaying: playing,
                 outputDeviceUIDs: playing ? devices : [])
    }

    static func world(default output: String = "speakers", devices: [AudioDeviceInfo]? = nil) -> AudioWorld {
        AudioWorld(devices: devices ?? [speakers, headphones, display, multiOutput], defaultOutputUID: output)
    }

    @Test func onlyChangedAppsNeedProcessing() {
        let w = Self.world()
        let music = Self.app("music")
        #expect(!TapPolicy.needsProcessing(AppAudioSettings(), app: music, world: w))
        #expect(TapPolicy.needsProcessing(AppAudioSettings(volume: 0.99), app: music, world: w))
        #expect(TapPolicy.needsProcessing(AppAudioSettings(volume: 1.2), app: music, world: w))
        #expect(TapPolicy.needsProcessing(AppAudioSettings(muted: true), app: music, world: w))
        #expect(TapPolicy.needsProcessing(AppAudioSettings(balance: -0.3), app: music, world: w))
        #expect(TapPolicy.needsProcessing(AppAudioSettings(eq: EQSettings(isOn: true, gains: [0, 3, 0])), app: music, world: w))
        // An equalizer that is on but flat, or tuned but off, changes nothing.
        #expect(!TapPolicy.needsProcessing(AppAudioSettings(eq: EQSettings(isOn: true, gains: [0, 0, 0])), app: music, world: w))
        #expect(!TapPolicy.needsProcessing(AppAudioSettings(eq: EQSettings(isOn: false, gains: [6, 0, 0])), app: music, world: w))
    }

    @Test func reroutingNeedsATapOnlyWhenTheDeviceDiffers() {
        let w = Self.world()
        let music = Self.app("music")
        #expect(TapPolicy.needsProcessing(AppAudioSettings(outputUID: "headphones"), app: music, world: w))
        #expect(!TapPolicy.needsProcessing(AppAudioSettings(outputUID: "speakers"), app: music, world: w), "already there")
        #expect(!TapPolicy.needsProcessing(AppAudioSettings(outputUID: "unplugged"), app: music, world: w),
                "a disconnected choice leaves the app alone")
        #expect(!TapPolicy.needsProcessing(AppAudioSettings(outputUID: "multi"), app: music, world: w),
                "aggregate devices can't be nested")
        // An app that picked the display itself, sent back to the speakers.
        let tv = Self.app("tv", on: ["display"])
        #expect(TapPolicy.needsProcessing(AppAudioSettings(outputUID: "speakers"), app: tv, world: w))
    }

    @Test func processedSoundPlaysOnTheChosenOrOwnDevice() {
        let w = Self.world()
        #expect(TapPolicy.outputDevice(for: AppAudioSettings(outputUID: "headphones"), app: Self.app("a"), world: w)?.uid == "headphones")
        #expect(TapPolicy.outputDevice(for: AppAudioSettings(volume: 0.5), app: Self.app("a", on: ["display"]), world: w)?.uid == "display",
                "an app that plays to its own device stays there")
        #expect(TapPolicy.outputDevice(for: AppAudioSettings(outputUID: "gone"), app: Self.app("a", playing: false), world: w)?.uid == "speakers",
                "a disconnected choice falls back to the system output")
    }

    @Test func sessionChangesAreMinimal() {
        let a = SessionSpec(key: "a", name: "A", processes: [1], deviceUID: "speakers", sampleRate: 48_000, mode: .process)
        var moved = a
        moved.deviceUID = "headphones"
        var helper = a
        helper.processes = [1, 2]
        var renamed = a
        renamed.name = "A2"
        let b = SessionSpec(key: "b", name: "B", processes: [3], deviceUID: "speakers", sampleRate: 48_000, mode: .monitor)
        #expect(TapPolicy.changes(from: ["a": a], to: ["a": a]).isEmpty)
        #expect(TapPolicy.changes(from: ["a": a], to: ["a": renamed]).isEmpty)
        #expect(TapPolicy.changes(from: ["a": a], to: ["a": moved]) == [.restart(moved)])
        #expect(TapPolicy.changes(from: ["a": a], to: ["a": helper]) == [.retarget("a", [1, 2])])
        #expect(TapPolicy.changes(from: ["a": a], to: ["b": b]) == [.stop("a"), .start(b)])
    }

    // MARK: - Controller (device changes, permission, lifecycle)

    @MainActor
    final class MockBackend: TapBackend {
        var log: [String] = []
        var live: [String: SessionSpec] = [:]
        var heard: Set<String> = []
        var failing: Set<String> = []
        var settings: [String: ProcessingSettings] = [:]

        func start(_ spec: SessionSpec, settings: ProcessingSettings) {
            log.append("start \(spec.key) \(spec.mode == .process ? "process" : "monitor") \(spec.deviceUID)")
            live[spec.key] = spec
            self.settings[spec.key] = settings
        }
        func stop(_ key: String) {
            log.append("stop \(key)")
            live[key] = nil
            heard.remove(key)
        }
        func retarget(_ key: String, processes: [AudioObjectID]) {
            log.append("retarget \(key) \(processes)")
            live[key]?.processes = processes
        }
        func update(_ key: String, settings: ProcessingSettings) {
            log.append("update \(key)")
            self.settings[key] = settings
        }
        func status(_ key: String) -> SessionStatus {
            if failing.contains(key) { return .failed("nope") }
            return live[key] == nil ? .starting : .running(heardAudio: heard.contains(key))
        }
        func take() -> [String] { defer { log.removeAll() }; return log }
    }

    @MainActor
    struct Harness {
        let backend = MockBackend()
        let controller: TapController
        var settings = AppVolumeSettings()
        var apps: [AudioApp] = []
        var world = AppVolumeTests.world()
        var now = Date(timeIntervalSince1970: 1_000_000)

        init() { controller = TapController(backend: backend) }

        mutating func reconcile() {
            controller.reconcile(.init(apps: apps, world: world, settings: settings), now: now)
        }

        mutating func advance(_ seconds: TimeInterval) {
            now += seconds
            controller.tick(now: now)
        }

        /// Gets an app to a verified, processing session.
        mutating func grant(_ key: String) {
            reconcile()
            backend.heard.insert(key)
            advance(1)
            backend.heard.insert(key)
        }
    }

    @Test @MainActor func appsAreHeardBeforeTheyAreTakenOver() {
        var h = Harness()
        h.apps = [Self.app("music")]
        h.reconcile()
        #expect(h.backend.take().isEmpty, "untouched apps get no tap")
        h.settings.update("music", name: "Music") { $0.volume = 0.5 }
        h.reconcile()
        #expect(h.backend.take() == ["start music monitor speakers"], "capture not confirmed yet: listen only")
        h.backend.heard.insert("music")
        h.advance(1)
        #expect(h.controller.capture == .granted)
        #expect(h.backend.take() == ["stop music", "start music process speakers"])
        #expect(h.backend.settings["music"]?.volume == 0.5)
        h.settings.update("music", name: "Music") { $0.volume = 0.7 }
        h.reconcile()
        #expect(h.backend.take() == ["update music"])
        #expect(h.backend.settings["music"]?.volume == 0.7)
    }

    @Test @MainActor func defaultOutputSwitchMovesFollowingAppsOnly() {
        var h = Harness()
        h.settings.update("music", name: "Music") { $0.volume = 0.5 }
        h.settings.update("zoom", name: "Zoom") { $0.outputUID = "headphones" }
        h.apps = [Self.app("music", processes: [1]), Self.app("zoom", processes: [2])]
        h.grant("music")
        h.backend.heard.insert("zoom")
        h.advance(1)
        _ = h.backend.take()
        #expect(h.backend.live["music"]?.deviceUID == "speakers")
        #expect(h.backend.live["zoom"]?.deviceUID == "headphones")
        // The user picks the display as system output; apps that follow it move with it.
        h.world.defaultOutputUID = "display"
        h.apps = [Self.app("music", on: ["display"], processes: [1]), Self.app("zoom", on: ["display"], processes: [2])]
        h.reconcile()
        #expect(h.backend.take() == ["stop music", "start music process display"])
        #expect(h.backend.live["zoom"]?.deviceUID == "headphones")
    }

    @Test @MainActor func unpluggedHeadphonesFallBackAndComeBack() {
        var h = Harness()
        h.settings.update("zoom", name: "Zoom") { $0.outputUID = "headphones" }
        h.apps = [Self.app("zoom")]
        h.grant("zoom")
        #expect(h.backend.live["zoom"]?.deviceUID == "headphones")
        _ = h.backend.take()
        // Headphones gone: the choice can't be honored, so the app plays to its own device untouched.
        h.world.devices.removeAll { $0.uid == "headphones" }
        h.reconcile()
        #expect(h.backend.take() == ["stop zoom"])
        // Unplugged while also turned down: it keeps being processed, on the speakers.
        h.settings.update("zoom", name: "Zoom") { $0.volume = 0.6 }
        h.reconcile()
        #expect(h.backend.take() == ["start zoom process speakers"])
        h.world.devices.append(Self.headphones)
        h.reconcile()
        #expect(h.backend.take() == ["stop zoom", "start zoom process headphones"])
        #expect(h.settings.apps["zoom"]?.outputUID == "headphones", "the choice itself is kept")
    }

    @Test @MainActor func sampleRateChangesRebuildTheSession() {
        var h = Harness()
        h.settings.update("music", name: "Music") { $0.volume = 0.5 }
        h.apps = [Self.app("music")]
        h.grant("music")
        _ = h.backend.take()
        h.world.devices[0].sampleRate = 96_000
        h.reconcile()
        #expect(h.backend.take() == ["stop music", "start music process speakers"])
        #expect(h.backend.live["music"]?.sampleRate == 96_000)
    }

    @Test @MainActor func helpersJoinTheTapInPlace() {
        var h = Harness()
        h.settings.update("chrome", name: "Chrome") { $0.volume = 0.5 }
        h.apps = [Self.app("chrome", processes: [5])]
        h.grant("chrome")
        _ = h.backend.take()
        h.apps = [Self.app("chrome", processes: [5, 9])]
        h.reconcile()
        #expect(h.backend.take() == ["retarget chrome [5, 9]"])
    }

    @Test @MainActor func quitAndIdleAppsLoseTheirTap() {
        var h = Harness()
        h.settings.update("music", name: "Music") { $0.volume = 0.5 }
        h.apps = [Self.app("music")]
        h.grant("music")
        _ = h.backend.take()
        // Paused: kept a while so resuming doesn't rebuild.
        h.apps = [Self.app("music", playing: false)]
        h.reconcile()
        h.advance(5)
        #expect(h.backend.take().isEmpty)
        h.advance(h.controller.idleTimeout)
        #expect(h.backend.take() == ["stop music"])
        // Plays again: back, already verified.
        h.apps = [Self.app("music")]
        h.reconcile()
        #expect(h.backend.take() == ["start music process speakers"])
        // Quit.
        h.apps = []
        h.reconcile()
        #expect(h.backend.take() == ["stop music"])
    }

    @Test @MainActor func backAtDefaultsReleasesAfterAMoment() {
        var h = Harness()
        h.settings.update("music", name: "Music") { $0.volume = 0.5 }
        h.apps = [Self.app("music")]
        h.grant("music")
        _ = h.backend.take()
        h.settings.update("music", name: "Music") { $0.volume = 1 }
        h.reconcile()
        #expect(h.backend.take() == ["update music"], "dragging through 100 % keeps the session, at unity")
        #expect(h.backend.settings["music"] == ProcessingSettings(AppAudioSettings(), bandCount: 10))
        h.advance(2)
        #expect(h.backend.take() == ["stop music"])
    }

    @Test @MainActor func silentTakeoverGivesTheAppItsSoundBack() {
        var h = Harness()
        h.settings.update("music", name: "Music") { $0.volume = 0.5 }
        h.settings.update("zoom", name: "Zoom") { $0.volume = 0.5 }
        h.apps = [Self.app("music", processes: [1]), Self.app("zoom", processes: [2])]
        h.grant("music")
        h.advance(1)
        _ = h.backend.take()
        #expect(h.backend.live["zoom"]?.mode == .process)
        // Zoom's processing tap never delivers audio (e.g. permission revoked): it must not stay silenced.
        h.advance(h.controller.verifyTimeout)
        #expect(h.backend.take() == ["stop zoom", "start zoom monitor speakers"])
        h.backend.heard.insert("zoom")
        h.advance(1)
        #expect(h.backend.take() == ["stop zoom", "start zoom process speakers"])
        #expect(h.backend.live["music"]?.mode == .process, "a session that heard audio once stays")
    }

    @Test @MainActor func silentProbesReportMissingPermissionAndRetry() {
        var h = Harness()
        h.settings.update("music", name: "Music") { $0.muted = true }
        h.apps = [Self.app("music")]
        h.reconcile()
        #expect(h.backend.take() == ["start music monitor speakers"])
        h.advance(h.controller.silentAfter)
        #expect(h.controller.capture == .silent)
        #expect(h.backend.live["music"]?.mode == .monitor, "never takes over while nothing is heard")
        h.advance(h.controller.probeRestart - h.controller.silentAfter)
        #expect(h.backend.take() == ["stop music", "start music monitor speakers"], "probes restart to pick up a new permission")
        h.controller.retry(now: h.now)
        #expect(h.controller.capture == .unknown)
        h.backend.heard.insert("music")
        h.advance(1)
        #expect(h.controller.capture == .granted)
        #expect(h.backend.live["music"]?.mode == .process)
    }

    @Test @MainActor func metersListenToPlayingAppsOnly() {
        var h = Harness()
        h.apps = [Self.app("music", processes: [1]), Self.app("safari", playing: false, processes: [2])]
        h.controller.metering = true
        h.reconcile()
        #expect(h.backend.take() == ["start music monitor speakers"])
        h.controller.metering = false
        h.reconcile()
        #expect(h.backend.take() == ["stop music"])
    }

    @Test @MainActor func excludedAppsAreNeverTapped() {
        var h = Harness()
        h.settings.excludedApps = ["logic"]
        h.settings.update("com.apple.logic10", name: "Logic Pro") { $0.volume = 0.3 }
        h.apps = [AudioApp(identity: AppIdentity(key: "com.apple.logic10", name: "Logic Pro"), processes: [1],
                           isPlaying: true, outputDeviceUIDs: ["speakers"])]
        h.controller.metering = true
        h.reconcile()
        #expect(h.backend.take().isEmpty)
    }

    @Test @MainActor func appsOnAnAggregateDeviceAreLeftAloneWithAReason() {
        var h = Harness()
        h.world.defaultOutputUID = "multi"
        h.settings.update("music", name: "Music") { $0.volume = 0.5 }
        h.apps = [Self.app("music", on: ["multi"])]
        h.reconcile()
        #expect(h.backend.take().isEmpty, "never moved to a device the user didn't pick")
        #expect(h.controller.failures["music"] != nil)
        // Sent to a real device explicitly, it works.
        h.settings.update("music", name: "Music") { $0.outputUID = "headphones" }
        h.reconcile()
        #expect(h.backend.take() == ["start music monitor headphones"])
        #expect(h.controller.failures["music"] == nil)
    }

    @Test @MainActor func failedSessionsBackOffAndStopAllCleansUp() {
        var h = Harness()
        h.settings.update("music", name: "Music") { $0.volume = 0.5 }
        h.apps = [Self.app("music")]
        h.reconcile()
        h.backend.failing.insert("music")
        h.advance(1)
        #expect(h.controller.failures["music"] == "nope")
        #expect(h.backend.take() == ["start music monitor speakers", "stop music"])
        h.advance(1)
        #expect(h.backend.take().isEmpty, "not retried right away")
        h.backend.failing.removeAll()
        h.advance(h.controller.failureBackoff)
        #expect(h.backend.take() == ["start music monitor speakers"])
        h.controller.stopAll()
        #expect(h.backend.take() == ["stop music"])
        #expect(h.backend.live.isEmpty)
    }

    // MARK: - Owners, grouping, lists

    @Test func helpersBelongToTheirApp() {
        let running = [RunningAppInfo(bundleID: "com.bytedance.macos.feishu", name: "Lark", bundlePath: "/Applications/Lark.app"),
                       RunningAppInfo(bundleID: "com.apple.Safari", name: "Safari", bundlePath: "/Applications/Safari.app"),
                       RunningAppInfo(bundleID: "com.google.Chrome", name: "Google Chrome", bundlePath: "/Applications/Google Chrome.app")]
        let helper = OwnerResolver.Process(
            bundleID: "com.bytedance.macos.feishu.helper",
            executablePath: "/Applications/Lark.app/Contents/Frameworks/Lark Framework.framework/Helpers/Lark Helper.app/Contents/MacOS/Lark Helper",
            displayName: "Lark Helper", processName: "Lark Helper")
        #expect(OwnerResolver.identity(of: helper, running: running).key == "com.bytedance.macos.feishu")

        let web = OwnerResolver.Process(
            bundleID: "com.apple.WebKit.GPU",
            executablePath: "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU",
            displayName: "Safari Graphics and Media", processName: "com.apple.WebKit.GPU")
        #expect(OwnerResolver.identity(of: web, running: running).key == "com.apple.Safari")
        var orphan = web
        orphan.displayName = "Some Widget Graphics and Media"
        #expect(OwnerResolver.identity(of: orphan, running: running).kind == .webContent)

        let prefixed = OwnerResolver.Process(bundleID: "com.google.Chrome.helper.Renderer", executablePath: nil,
                                             displayName: nil, processName: "Google Chrome Helper")
        #expect(OwnerResolver.identity(of: prefixed, running: running).key == "com.google.Chrome")

        let alerts = OwnerResolver.Process(bundleID: "systemsoundserverd", executablePath: "/usr/sbin/systemsoundserverd",
                                           displayName: nil, processName: "systemsoundserverd")
        #expect(OwnerResolver.identity(of: alerts, running: running).kind == .systemSounds)

        let facetime = OwnerResolver.Process(bundleID: "com.apple.avconferenced", executablePath: "/usr/libexec/avconferenced",
                                             displayName: nil, processName: "avconferenced")
        #expect(OwnerResolver.identity(of: facetime, running: running).key == "com.apple.FaceTime")

        let notRunning = OwnerResolver.Process(bundleID: "com.example.player", executablePath: "/Applications/Player.app/Contents/MacOS/Player",
                                               displayName: nil, processName: "Player")
        let id = OwnerResolver.identity(of: notRunning, running: running) { _ in ("com.example.player", "Player") }
        #expect(id.key == "com.example.player" && id.bundlePath == "/Applications/Player.app")

        let daemon = OwnerResolver.Process(bundleID: "", executablePath: "/usr/libexec/thing", displayName: nil, processName: "thing")
        #expect(OwnerResolver.identity(of: daemon, running: running).key == "process:thing")
    }

    @Test func processesGroupIntoApps() {
        let safari = AppIdentity(key: "com.apple.Safari", name: "Safari", bundlePath: "/Applications/Safari.app")
        let music = AppIdentity(key: "com.apple.Music", name: "Music")
        let list = [
            AudioProcessInfo(objectID: 9, pid: 90, bundleID: "com.apple.WebKit.GPU", isRunningOutput: true, outputDeviceUIDs: ["speakers"],
                             owner: AppIdentity(key: "com.apple.Safari", name: "Safari")),
            AudioProcessInfo(objectID: 3, pid: 30, bundleID: "com.apple.Music", isRunningOutput: false, outputDeviceUIDs: [], owner: music),
            AudioProcessInfo(objectID: 4, pid: 40, bundleID: "com.apple.Safari", isRunningOutput: false, outputDeviceUIDs: [], owner: safari),
        ]
        let apps = AppGrouper.group(list)
        #expect(apps.map(\.identity.key) == ["com.apple.Safari", "com.apple.Music"])
        #expect(apps[0].processes == [4, 9])
        #expect(apps[0].isPlaying)
        #expect(apps[0].identity.bundlePath == "/Applications/Safari.app")
        #expect(apps[0].outputDeviceUIDs == ["speakers"])
        #expect(!apps[1].isPlaying)
    }

    @Test func outermostAppBundle() {
        #expect(OwnerResolver.outermostApp("/Applications/Foo.app/Contents/Frameworks/Foo Helper.app/Contents/MacOS/Foo Helper") == "/Applications/Foo.app")
        #expect(OwnerResolver.outermostApp("/System/Volumes/Data/Applications/Foo.app/Contents/MacOS/Foo") == "/Applications/Foo.app")
        #expect(OwnerResolver.outermostApp("/usr/libexec/avconferenced") == nil)
    }

    @Test func flyoutListsPinnedThenPlayingInFirstPlayedOrder() {
        var s = AppVolumeSettings()
        s.pinnedApps = ["podcasts", "gone"]
        s.apps["gone"] = AppAudioSettings(name: "Old Player")
        s.lingerSeconds = 30
        let now = Date(timeIntervalSince1970: 1000)
        let apps = [Self.app("safari"), Self.app("music"), Self.app("podcasts", playing: false),
                    Self.app("paused", playing: false), Self.app("stale", playing: false)]
        let rows = FlyoutList.rows(apps: apps, settings: s,
                                   firstPlayed: ["music": now - 100, "safari": now - 50, "paused": now - 10, "stale": now - 500],
                                   lastPlayed: ["paused": now - 10, "stale": now - 400], now: now)
        #expect(rows.map(\.id) == ["podcasts", "gone", "music", "safari", "paused"])
        #expect(rows.map(\.state) == [.quiet, .notRunning, .playing, .playing, .quiet])
        #expect(rows[1].identity.name == "Old Player")
    }

    // MARK: - Channels

    @Test func channelsAreFoundAcrossBuffers() {
        let counts = [2, 2, 4]
        let channels: (Int) -> Int = { counts[$0] }
        #expect(ChannelMap.locate(deviceChannel: 1, bufferCount: 3, channels: channels) == ChannelLocator(buffer: 0, channel: 0, stride: 2))
        #expect(ChannelMap.locate(deviceChannel: 4, bufferCount: 3, channels: channels) == ChannelLocator(buffer: 1, channel: 1, stride: 2))
        #expect(ChannelMap.locate(deviceChannel: 7, bufferCount: 3, channels: channels) == ChannelLocator(buffer: 2, channel: 2, stride: 4))
        #expect(ChannelMap.locate(deviceChannel: 9, bufferCount: 3, channels: channels) == nil)
        // An interface whose speakers sit on 3/4.
        let out = ChannelMap.stereoOutput(preferred: (3, 4), bufferCount: 3, channels: channels)
        #expect(out?.0 == ChannelLocator(buffer: 1, channel: 0, stride: 2))
        #expect(out?.1 == ChannelLocator(buffer: 1, channel: 1, stride: 2))
        // A mono device: both sides land on its one channel.
        let mono = ChannelMap.stereoOutput(preferred: (1, 2), bufferCount: 1, channels: { _ in 1 })
        #expect(mono?.0 == mono?.1)
    }

    @Test func tapBuffersComeAfterTheDevicesInputs() {
        // Output device with a 1-channel mic input, then an interleaved stereo tap.
        let counts = [1, 2]
        let (l, r) = ChannelMap.tapInput(bufferCount: 2, channels: { counts[$0] }, tapChannels: 2, tapInterleaved: true)!
        #expect(l == ChannelLocator(buffer: 1, channel: 0, stride: 2))
        #expect(r == ChannelLocator(buffer: 1, channel: 1, stride: 2))
        // Deinterleaved stereo tap: one buffer per channel.
        let split = [1, 1, 1]
        let (dl, dr) = ChannelMap.tapInput(bufferCount: 3, channels: { split[$0] }, tapChannels: 2, tapInterleaved: false)!
        #expect(dl.buffer == 1 && dr.buffer == 2)
        #expect(ChannelMap.tapInput(bufferCount: 0, channels: { _ in 0 }, tapChannels: 2, tapInterleaved: true) == nil)
    }

    // MARK: - Small things

    @Test func meterScaleCoversSixtyDecibels() {
        #expect(LevelStore.scale(1) == 1)
        #expect(LevelStore.scale(0) == 0)
        #expect(abs(LevelStore.scale(0.001) - 0) < 1e-6)
        #expect(abs(LevelStore.scale(0.0316) - 0.5) < 0.01)
    }

    @Test func deviceSymbols() {
        #expect(DeviceSymbol.name(for: Self.headphones) == "airpods.pro")
        #expect(DeviceSymbol.name(for: Self.speakers) == "laptopcomputer")
        var builtIn = Self.speakers
        builtIn.dataSource = "Headphones"
        #expect(DeviceSymbol.name(for: builtIn) == "headphones")
        #expect(DeviceSymbol.name(for: nil) == "speaker.wave.2")
    }

    @Test func bandLabelsAreShort() {
        #expect(EQCurve.label(32) == 32.formatted())
        #expect(EQCurve.label(16_000).hasSuffix("k"))
    }
}

/// Deterministic noise for the DSP tests.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }
    mutating func next() -> Double {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Double(state % 1_000_000) / 1_000_000
    }
}
