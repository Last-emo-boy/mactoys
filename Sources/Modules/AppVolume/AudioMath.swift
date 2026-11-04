import Foundation

/// Volume taper and balance law. Pure functions; the realtime chain and the tests share them.
enum Gain {
    /// The amplitude factor for a slider volume (1 = 100 %). Squared, so the slider feels even:
    /// 50 % is −12 dB, 200 % is +12 dB, and 100 % is exactly unity.
    static func amplitude(volume: Double) -> Double {
        let v = max(0, volume)
        return v * v
    }

    static func decibels(amplitude: Double) -> Double {
        amplitude > 0 ? 20 * log10(amplitude) : -.infinity
    }

    static func amplitude(decibels: Double) -> Double {
        pow(10, decibels / 20)
    }

    /// Classic balance: centered leaves both sides alone; moving right fades the left side out.
    static func balance(_ value: Double) -> (left: Double, right: Double) {
        let b = min(max(value, -1), 1)
        return (b > 0 ? 1 - b : 1, b < 0 ? 1 + b : 1)
    }
}

/// A peak limiter without lookahead and a soft clipper behind it. Boosted audio is pulled down
/// to just under full scale instead of clipping; quiet audio passes unchanged.
struct SoftLimiter: Sendable {
    /// −1 dBFS: where the limiter starts to act.
    static let threshold = 0.891_250_938
    /// Gain reduction now (1 = none).
    private(set) var envelope = 1.0
    private let release: Double

    /// - Parameter releaseTime: seconds for the gain to recover after a peak.
    init(sampleRate: Double, releaseTime: Double = 0.12) {
        release = 1 - exp(-1 / (max(1, sampleRate) * releaseTime))
    }

    mutating func process(_ l: Double, _ r: Double) -> (Double, Double) {
        let peak = max(abs(l), abs(r))
        let target = peak > Self.threshold ? Self.threshold / peak : 1
        // Instant attack, smooth release.
        envelope = target < envelope ? target : envelope + (target - envelope) * release
        return (Self.softClip(l * envelope), Self.softClip(r * envelope))
    }

    mutating func reset() { envelope = 1 }

    /// Unchanged below the threshold, then bends smoothly toward (but never reaches) full scale.
    static func softClip(_ x: Double) -> Double {
        let t = threshold
        let m = abs(x)
        guard m > t else { return x }
        // tanh rounds to exactly 1 for large inputs; keep a hair of headroom.
        let bent = min(t + (1 - t) * tanh((m - t) / (1 - t)), 0.999_99)
        return x < 0 ? -bent : bent
    }
}

/// Coefficients of one second-order section, normalized so a0 = 1 (Audio EQ Cookbook forms).
struct BiquadCoefficients: Equatable, Sendable {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0

    static let identity = BiquadCoefficients()

    var isIdentity: Bool { self == .identity }

    private init(b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double) {
        self.b0 = b0 / a0
        self.b1 = b1 / a0
        self.b2 = b2 / a0
        self.a1 = a1 / a0
        self.a2 = a2 / a0
    }

    init() {}

    /// A bell around `frequency`; `gain` dB at its center.
    static func peaking(frequency: Double, gain: Double, q: Double, sampleRate: Double) -> BiquadCoefficients {
        guard gain != 0, let w0 = omega(frequency, sampleRate) else { return .identity }
        let a = pow(10, gain / 40)
        let alpha = sin(w0) / (2 * max(q, 0.05))
        let cosw = cos(w0)
        return BiquadCoefficients(b0: 1 + alpha * a, b1: -2 * cosw, b2: 1 - alpha * a,
                                  a0: 1 + alpha / a, a1: -2 * cosw, a2: 1 - alpha / a)
    }

    /// Lifts or cuts everything below `frequency`; half of `gain` at `frequency` itself.
    static func lowShelf(frequency: Double, gain: Double, slope: Double = 1, sampleRate: Double) -> BiquadCoefficients {
        guard gain != 0, let w0 = omega(frequency, sampleRate) else { return .identity }
        let a = pow(10, gain / 40)
        let cosw = cos(w0)
        let alpha = sin(w0) / 2 * sqrt((a + 1 / a) * (1 / slope - 1) + 2)
        let k = 2 * sqrt(a) * alpha
        return BiquadCoefficients(b0: a * ((a + 1) - (a - 1) * cosw + k),
                                  b1: 2 * a * ((a - 1) - (a + 1) * cosw),
                                  b2: a * ((a + 1) - (a - 1) * cosw - k),
                                  a0: (a + 1) + (a - 1) * cosw + k,
                                  a1: -2 * ((a - 1) + (a + 1) * cosw),
                                  a2: (a + 1) + (a - 1) * cosw - k)
    }

    /// Lifts or cuts everything above `frequency`; half of `gain` at `frequency` itself.
    static func highShelf(frequency: Double, gain: Double, slope: Double = 1, sampleRate: Double) -> BiquadCoefficients {
        guard gain != 0, let w0 = omega(frequency, sampleRate) else { return .identity }
        let a = pow(10, gain / 40)
        let cosw = cos(w0)
        let alpha = sin(w0) / 2 * sqrt((a + 1 / a) * (1 / slope - 1) + 2)
        let k = 2 * sqrt(a) * alpha
        return BiquadCoefficients(b0: a * ((a + 1) + (a - 1) * cosw + k),
                                  b1: -2 * a * ((a - 1) + (a + 1) * cosw),
                                  b2: a * ((a + 1) + (a - 1) * cosw - k),
                                  a0: (a + 1) - (a - 1) * cosw + k,
                                  a1: 2 * ((a - 1) - (a + 1) * cosw),
                                  a2: (a + 1) - (a - 1) * cosw - k)
    }

    /// Normalized angular frequency, or nil when `frequency` can't be represented at this rate
    /// (at or above about Nyquist): such a band is left out instead of turning unstable.
    private static func omega(_ frequency: Double, _ sampleRate: Double) -> Double? {
        guard sampleRate > 0, frequency > 0, frequency < sampleRate * 0.49 else { return nil }
        return 2 * .pi * frequency / sampleRate
    }

    /// Magnitude of the response at `frequency` (linear).
    func magnitude(at frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * .pi * frequency / sampleRate
        let c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w)
        // H(e^jw) = (b0 + b1 e^-jw + b2 e^-2jw) / (1 + a1 e^-jw + a2 e^-2jw)
        let nr = b0 + b1 * c1 + b2 * c2, ni = -(b1 * s1 + b2 * s2)
        let dr = 1 + a1 * c1 + a2 * c2, di = -(a1 * s1 + a2 * s2)
        return sqrt((nr * nr + ni * ni) / (dr * dr + di * di))
    }

    func decibels(at frequency: Double, sampleRate: Double) -> Double {
        20 * log10(magnitude(at: frequency, sampleRate: sampleRate))
    }
}

/// Filter memory for one channel of one section (transposed direct form II, in Double).
struct BiquadState: Sendable {
    var z1 = 0.0, z2 = 0.0

    mutating func process(_ x: Double, _ c: BiquadCoefficients) -> Double {
        let y = c.b0 * x + z1
        z1 = c.b1 * x - c.a1 * y + z2
        z2 = c.b2 * x - c.a2 * y
        return y
    }
}
