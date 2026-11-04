import Foundation

/// The part of an app's settings the realtime chain applies.
struct ProcessingSettings: Equatable, Sendable {
    var volume: Double = 1
    var muted = false
    var balance: Double = 0
    var eq = EQSettings()
    var bandCount = 10

    static let unity = ProcessingSettings()

    init() {}

    init(_ s: AppAudioSettings, bandCount: Int) {
        volume = s.volume
        muted = s.muted
        balance = s.balance
        eq = s.eq
        self.bandCount = bandCount
    }
}

/// Precomputed, fixed-size parameters handed to the IO thread (no heap storage, so copying
/// them there never allocates).
struct DSPParameters: Sendable {
    static let maxBands = 10

    /// Target amplitude (taper applied; 0 when muted).
    var gain = 1.0
    var left = 1.0
    var right = 1.0
    var preamp = 1.0
    /// Sections in use; 0 bypasses the equalizer.
    var bandCount = 0
    var bands = InlineArray<10, BiquadCoefficients>(repeating: .identity)
    /// Whether the limiter runs: only when something can push the level up.
    var limit = false

    init() {}

    init(_ s: ProcessingSettings, sampleRate: Double) {
        gain = s.muted ? 0 : Gain.amplitude(volume: s.volume)
        (left, right) = Gain.balance(s.balance)
        if s.eq.isEffective {
            preamp = Gain.amplitude(decibels: min(max(s.eq.preamp, EQLayout.gainRange.lowerBound), EQLayout.gainRange.upperBound))
            let sections = EQCurve.coefficients(s.eq, count: s.bandCount, sampleRate: sampleRate)
            for (i, c) in sections.prefix(Self.maxBands).enumerated() { bands[i] = c }
            bandCount = min(sections.count, Self.maxBands)
        }
        limit = gain > 1 || bandCount > 0
    }
}

/// Gain (smoothed against zipper noise), balance, equalizer and limiter for one stereo stream.
/// Plain value type so tests run it offline; the IO thread owns one inside each tap session.
///
/// At 100 % with the balance centered and the equalizer off every sample passes bit for bit.
struct DSPState: Sendable {
    private(set) var params: DSPParameters
    private var gain: Double
    private var left: Double
    private var right: Double
    private var stateL = InlineArray<10, BiquadState>(repeating: BiquadState())
    private var stateR = InlineArray<10, BiquadState>(repeating: BiquadState())
    private var limiter: SoftLimiter
    private let smoothing: Double

    init(_ params: DSPParameters, sampleRate: Double) {
        self.params = params
        gain = params.gain
        left = params.left
        right = params.right
        limiter = SoftLimiter(sampleRate: sampleRate)
        // ~15 ms one-pole glide toward new targets.
        smoothing = 1 - exp(-1 / (max(1, sampleRate) * 0.015))
    }

    /// New targets; filter memory carries over so changing one band doesn't click.
    mutating func update(_ p: DSPParameters) {
        if p.bandCount != params.bandCount {
            stateL = InlineArray(repeating: BiquadState())
            stateR = InlineArray(repeating: BiquadState())
        }
        if !p.limit { limiter.reset() }
        params = p
    }

    @inline(__always)
    mutating func process(_ l: Float, _ r: Float) -> (Float, Float) {
        let k = smoothing
        Self.glide(&gain, params.gain, k)
        Self.glide(&left, params.left, k)
        Self.glide(&right, params.right, k)
        var x = Double(l) * gain * left
        var y = Double(r) * gain * right
        let n = params.bandCount
        if n > 0 {
            x *= params.preamp
            y *= params.preamp
            for i in 0..<n {
                let c = params.bands[i]
                x = stateL[i].process(x, c)
                y = stateR[i].process(y, c)
            }
        }
        if params.limit { (x, y) = limiter.process(x, y) }
        return (Float(x), Float(y))
    }

    /// Zeroes filter memory that has decayed into subnormal range (slow on Intel), once per buffer.
    mutating func flushDenormals() {
        for i in 0..<params.bandCount {
            if abs(stateL[i].z1) < 1e-30 { stateL[i].z1 = 0 }
            if abs(stateL[i].z2) < 1e-30 { stateL[i].z2 = 0 }
            if abs(stateR[i].z1) < 1e-30 { stateR[i].z1 = 0 }
            if abs(stateR[i].z2) < 1e-30 { stateR[i].z2 = 0 }
        }
    }

    @inline(__always)
    private static func glide(_ v: inout Double, _ target: Double, _ k: Double) {
        let d = target - v
        v = abs(d) < 1e-7 ? target : v + d * k
    }
}

/// Where one channel lives in an `AudioBufferList`.
struct ChannelLocator: Equatable, Sendable {
    var buffer: Int
    /// Offset of the channel's first sample in the buffer.
    var channel: Int
    /// Samples between frames (the buffer's channel count).
    var stride: Int
}

/// Finds channels in buffer lists. Taking the channel counts as a closure keeps the IO thread
/// allocation-free while tests pass plain arrays.
enum ChannelMap {
    /// The buffer and offset of 1-based device channel `deviceChannel` (as in
    /// `kAudioDevicePropertyPreferredChannelsForStereo`).
    static func locate(deviceChannel: Int, bufferCount: Int, channels: (Int) -> Int) -> ChannelLocator? {
        guard deviceChannel > 0 else { return nil }
        var first = 1
        for b in 0..<bufferCount {
            let n = channels(b)
            if deviceChannel < first + n { return ChannelLocator(buffer: b, channel: deviceChannel - first, stride: max(1, n)) }
            first += n
        }
        return nil
    }

    /// Left and right of the stereo pair, falling back to channels 1 and 2, then to one channel for both.
    static func stereoOutput(preferred: (Int, Int), bufferCount: Int,
                             channels: (Int) -> Int) -> (ChannelLocator, ChannelLocator)? {
        if let l = locate(deviceChannel: preferred.0, bufferCount: bufferCount, channels: channels),
           let r = locate(deviceChannel: preferred.1, bufferCount: bufferCount, channels: channels) {
            return (l, r)
        }
        guard let l = locate(deviceChannel: 1, bufferCount: bufferCount, channels: channels) else { return nil }
        return (l, locate(deviceChannel: 2, bufferCount: bufferCount, channels: channels) ?? l)
    }

    /// The tap's left and right in an aggregate device's input list. Taps come after the input
    /// streams of the aggregate's sub-devices, so the tap's buffers are the last ones.
    static func tapInput(bufferCount: Int, channels: (Int) -> Int, tapChannels: Int,
                         tapInterleaved: Bool) -> (ChannelLocator, ChannelLocator)? {
        let tapBuffers = tapInterleaved ? 1 : max(1, tapChannels)
        let first = bufferCount - tapBuffers
        guard first >= 0 else { return nil }
        let n = max(1, channels(first))
        if tapInterleaved || tapChannels <= 1 {
            return (ChannelLocator(buffer: first, channel: 0, stride: n),
                    ChannelLocator(buffer: first, channel: n > 1 ? 1 : 0, stride: n))
        }
        return (ChannelLocator(buffer: first, channel: 0, stride: n),
                ChannelLocator(buffer: first + 1, channel: 0, stride: max(1, channels(first + 1))))
    }
}
