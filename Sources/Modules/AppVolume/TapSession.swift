import CoreAudio
import Foundation
import MacToysCore
import os
import Synchronization

/// Peak levels since the last read, per channel (linear 0…1+).
struct StereoLevel: Equatable, Sendable {
    var left: Float = 0
    var right: Float = 0
    static let silent = StereoLevel()
}

/// The realtime half of a session, called on the HAL's IO thread for every buffer.
///
/// Nothing here allocates, locks (parameters arrive through a try-lock) or calls into Objective-C;
/// levels and the "heard audio" flag go back through atomics.
final class TapRenderer: @unchecked Sendable {
    let mode: TapMode
    let sampleRate: Double
    private let tapChannels: Int
    private let tapInterleaved: Bool
    private let preferredStereo: (Int, Int)
    /// IO thread only.
    private var dsp: DSPState
    private let pending = OSAllocatedUnfairLock<DSPParameters?>(initialState: nil)
    private let peakL = Atomic<UInt32>(0)
    private let peakR = Atomic<UInt32>(0)
    private let heard = Atomic<Bool>(false)

    init(mode: TapMode, sampleRate: Double, parameters: DSPParameters, tapChannels: Int, tapInterleaved: Bool,
         preferredStereo: (Int, Int)) {
        self.mode = mode
        self.sampleRate = sampleRate
        self.tapChannels = tapChannels
        self.tapInterleaved = tapInterleaved
        self.preferredStereo = preferredStereo
        dsp = DSPState(parameters, sampleRate: sampleRate)
    }

    /// Any thread. Picked up at the start of the next buffer.
    func setParameters(_ p: DSPParameters) {
        pending.withLock { $0 = p }
    }

    var heardAudio: Bool { heard.load(ordering: .relaxed) }

    /// Peaks since the previous call.
    func takeLevel() -> StereoLevel {
        StereoLevel(left: Float(bitPattern: peakL.exchange(0, ordering: .relaxed)),
                    right: Float(bitPattern: peakR.exchange(0, ordering: .relaxed)))
    }

    func render(_ input: UnsafePointer<AudioBufferList>, _ output: UnsafeMutablePointer<AudioBufferList>) {
        if let p = pending.withLockIfAvailable({ state -> DSPParameters? in
            defer { state = nil }
            return state
        }) ?? nil {
            dsp.update(p)
        }
        let outs = UnsafeMutableAudioBufferListPointer(output)
        for b in outs {
            if let data = b.mData { memset(data, 0, Int(b.mDataByteSize)) }
        }
        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let (li, ri) = ChannelMap.tapInput(bufferCount: ins.count, channels: { Int(ins[$0].mNumberChannels) },
                                                 tapChannels: tapChannels, tapInterleaved: tapInterleaved),
              let srcL = ins[li.buffer].mData?.assumingMemoryBound(to: Float.self),
              let srcR = ins[ri.buffer].mData?.assumingMemoryBound(to: Float.self) else { return }
        let inFrames = min(Int(ins[li.buffer].mDataByteSize) / (4 * li.stride), Int(ins[ri.buffer].mDataByteSize) / (4 * ri.stride))
        var pl: Float = 0, pr: Float = 0
        var nonZero = false

        if mode == .monitor {
            for f in 0..<inFrames {
                let l = abs(srcL[f * li.stride + li.channel]), r = abs(srcR[f * ri.stride + ri.channel])
                if l > pl { pl = l }
                if r > pr { pr = r }
            }
            nonZero = pl > 0 || pr > 0
        } else {
            guard let (lo, ro) = ChannelMap.stereoOutput(preferred: preferredStereo, bufferCount: outs.count,
                                                         channels: { Int(outs[$0].mNumberChannels) }),
                  let dstL = outs[lo.buffer].mData?.assumingMemoryBound(to: Float.self),
                  let dstR = outs[ro.buffer].mData?.assumingMemoryBound(to: Float.self) else { return }
            let outFrames = min(Int(outs[lo.buffer].mDataByteSize) / (4 * lo.stride), Int(outs[ro.buffer].mDataByteSize) / (4 * ro.stride))
            let mono = lo == ro
            for f in 0..<min(inFrames, outFrames) {
                let l = srcL[f * li.stride + li.channel], r = srcR[f * ri.stride + ri.channel]
                if l != 0 || r != 0 { nonZero = true }
                let (yl, yr) = dsp.process(l, r)
                if mono {
                    dstL[f * lo.stride + lo.channel] = (yl + yr) * 0.5
                } else {
                    dstL[f * lo.stride + lo.channel] = yl
                    dstR[f * ro.stride + ro.channel] = yr
                }
                if abs(yl) > pl { pl = abs(yl) }
                if abs(yr) > pr { pr = abs(yr) }
            }
            dsp.flushDenormals()
        }
        if nonZero && !heard.load(ordering: .relaxed) { heard.store(true, ordering: .relaxed) }
        peakL.max(pl.bitPattern, ordering: .relaxed)
        peakR.max(pr.bitPattern, ordering: .relaxed)
    }
}

/// Why a session couldn't be built.
struct TapError: Error, CustomStringConvertible {
    enum Stage: String { case tap, format, device, aggregate, ioProc, start }
    let stage: Stage
    let status: OSStatus

    var description: String { "\(stage.rawValue) (\(status))" }

    /// For the flyout and settings page.
    var message: String {
        switch stage {
        case .device: String(localized: "The output device isn't available.")
        case .format: String(localized: "This app's audio format isn't supported.")
        default: String(localized: "macOS didn't let MacToys take this app's sound (error \(Int(status))).",
                        comment: "App Volume error; the number is a Core Audio status code")
        }
    }
}

/// One app's process tap, private aggregate device (tap + output device) and IO proc.
///
/// Built and torn down on the backend's queue; `apply` may be called from any thread.
final class TapSession: @unchecked Sendable {
    let spec: SessionSpec
    let renderer: TapRenderer
    private let description: CATapDescription
    private let tapID: AudioObjectID
    private let aggregateID: AudioObjectID
    private var procID: AudioDeviceIOProcID?
    private static let log = Log.for("appvolume")

    private init(spec: SessionSpec, renderer: TapRenderer, description: CATapDescription, tapID: AudioObjectID,
                 aggregateID: AudioObjectID) {
        self.spec = spec
        self.renderer = renderer
        self.description = description
        self.tapID = tapID
        self.aggregateID = aggregateID
    }

    static func make(_ spec: SessionSpec, settings: ProcessingSettings) throws -> TapSession {
        func check(_ status: OSStatus, _ stage: TapError.Stage) throws {
            if status != noErr { throw TapError(stage: stage, status: status) }
        }
        guard let device = HAL.deviceID(uid: spec.deviceUID) else { throw TapError(stage: .device, status: 0) }

        let description = CATapDescription(stereoMixdownOfProcesses: spec.processes)
        description.name = "MacToys App Volume (\(spec.name))"
        description.isPrivate = true
        // mutedWhenTapped: the app is only silenced while this tap is read, so if MacToys stops or
        // crashes the app plays to its own device again.
        description.muteBehavior = spec.mode == .process ? .mutedWhenTapped : .unmuted

        var tapID = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tapID), .tap)
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        var procID: AudioDeviceIOProcID?
        do {
            guard let format = HAL.get(tapID, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription()) else {
                throw TapError(stage: .format, status: 0)
            }
            guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  format.mBitsPerChannel == 32, format.mChannelsPerFrame > 0 else {
                throw TapError(stage: .format, status: OSStatus(bitPattern: format.mFormatID))
            }
            let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0

            let composition: [String: Any] = [
                kAudioAggregateDeviceNameKey: "MacToys App Volume",
                kAudioAggregateDeviceUIDKey: HAL.aggregatePrefix + UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: spec.deviceUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: spec.deviceUID]],
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString,
                                                   kAudioSubTapDriftCompensationKey: true]],
            ]
            try check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregateID), .aggregate)

            let rate = HAL.float64(aggregateID, kAudioDevicePropertyNominalSampleRate) ?? spec.sampleRate
            let renderer = TapRenderer(mode: spec.mode, sampleRate: rate,
                                       parameters: DSPParameters(settings, sampleRate: rate),
                                       tapChannels: Int(format.mChannelsPerFrame), tapInterleaved: interleaved,
                                       preferredStereo: HAL.preferredStereo(device))
            try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, input, _, output, _ in
                renderer.render(input, output)
            }, .ioProc)
            try check(AudioDeviceStart(aggregateID, procID), .start)

            let session = TapSession(spec: spec, renderer: renderer, description: description, tapID: tapID,
                                     aggregateID: aggregateID)
            session.procID = procID
            log.info("tap \(spec.mode == .process ? "processing" : "listening", privacy: .public) \(spec.key, privacy: .public) → \(spec.deviceUID, privacy: .public) @ \(rate) Hz, tap \(format.mChannelsPerFrame) ch \(format.mSampleRate) Hz")
            return session
        } catch {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
            AudioHardwareDestroyProcessTap(tapID)
            log.error("tap \(spec.key, privacy: .public) failed at \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    func apply(_ settings: ProcessingSettings) {
        renderer.setParameters(DSPParameters(settings, sampleRate: renderer.sampleRate))
    }

    /// Points the tap at a new set of processes in place. False when the HAL refuses (rebuild instead).
    func retarget(_ processes: [AudioObjectID]) -> Bool {
        description.processes = processes
        var a = HAL.address(kAudioTapPropertyDescription)
        var ref = description
        let status = withUnsafeMutablePointer(to: &ref) {
            AudioObjectSetPropertyData(tapID, &a, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), $0)
        }
        if status != noErr { Self.log.error("retarget \(self.spec.key, privacy: .public) failed: \(status)") }
        return status == noErr
    }

    /// Stops IO and destroys the aggregate device and the tap. The app plays to its own device again.
    func invalidate() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            self.procID = nil
        }
        AudioHardwareDestroyAggregateDevice(aggregateID)
        AudioHardwareDestroyProcessTap(tapID)
        Self.log.info("tap \(self.spec.key, privacy: .public) closed")
    }
}

/// `TapBackend` over real Core Audio. HAL calls that create or destroy objects talk to coreaudiod
/// and can take tens of milliseconds, so they run on a serial queue of their own, in order.
@MainActor
final class HALTapBackend: TapBackend {
    private let queue = DispatchQueue(label: "com.w33d.mactoys.appvolume.taps", qos: .userInitiated)
    private var live: [String: TapSession] = [:]
    private var specs: [String: SessionSpec] = [:]
    private var tokens: [String: UUID] = [:]
    private var latest: [String: ProcessingSettings] = [:]
    private var errors: [String: String] = [:]

    func start(_ spec: SessionSpec, settings: ProcessingSettings) {
        let token = UUID()
        tokens[spec.key] = token
        specs[spec.key] = spec
        latest[spec.key] = settings
        errors[spec.key] = nil
        queue.async { [weak self] in
            let result = Result { try TapSession.make(spec, settings: settings) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.tokens[spec.key] == token else {
                        if case .success(let session) = result { self?.queue.async { session.invalidate() } ?? session.invalidate() }
                        return
                    }
                    switch result {
                    case .success(let session):
                        self.live[spec.key] = session
                        if let s = self.latest[spec.key], s != settings { session.apply(s) }
                    case .failure(let error):
                        self.errors[spec.key] = (error as? TapError)?.message ?? error.localizedDescription
                    }
                }
            }
        }
    }

    func stop(_ key: String) {
        tokens[key] = nil
        specs[key] = nil
        latest[key] = nil
        errors[key] = nil
        if let session = live.removeValue(forKey: key) {
            queue.async { session.invalidate() }
        }
    }

    func retarget(_ key: String, processes: [AudioObjectID]) {
        guard var spec = specs[key] else { return }
        spec.processes = processes
        specs[key] = spec
        guard let session = live[key] else { return }
        let token = tokens[key]
        queue.async { [weak self] in
            guard !session.retarget(processes) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // In-place update refused: build the session again with the new processes.
                    guard let self, self.tokens[key] == token, let settings = self.latest[key] else { return }
                    self.stop(key)
                    self.start(spec, settings: settings)
                }
            }
        }
    }

    func update(_ key: String, settings: ProcessingSettings) {
        latest[key] = settings
        live[key]?.apply(settings)
    }

    func status(_ key: String) -> SessionStatus {
        if let error = errors[key] { return .failed(error) }
        guard let session = live[key] else { return .starting }
        return .running(heardAudio: session.renderer.heardAudio)
    }

    /// Peaks since the last call, for every live session.
    func takeLevels() -> [String: StereoLevel] {
        live.mapValues { $0.renderer.takeLevel() }
    }
}
