import Foundation

/// Band layouts for 3–10 band equalizers. Centers are log-spaced and snapped to the ISO
/// third-octave series, so every layout reads in round numbers (32 Hz … 16 kHz for ten bands,
/// 100 Hz / 1 kHz / 10 kHz for three). The lowest band is a low shelf, the highest a high shelf,
/// the rest are bells as wide as the gap to their neighbors.
enum EQLayout {
    static let bandRange = 3...10
    /// dB a band or the preamp can move.
    static let gainRange: ClosedRange<Double> = -12...12

    /// ISO 266 third-octave centers (with the customary 32 and 64 for 31.5 and 63).
    static let isoCenters: [Double] = [20, 25, 32, 40, 50, 64, 80, 100, 125, 160, 200, 250, 315, 400, 500, 630, 800,
                                       1000, 1250, 1600, 2000, 2500, 3150, 4000, 5000, 6300, 8000, 10_000, 12_500,
                                       16_000, 20_000]

    enum Kind: Equatable, Sendable { case lowShelf, peak, highShelf }

    static func frequencies(count: Int) -> [Double] {
        let n = Double(min(max(count, bandRange.lowerBound), bandRange.upperBound))
        // Ten bands span 32 Hz–16 kHz; fewer bands draw in toward 100 Hz–10 kHz.
        let t = (10 - n) / 7
        let low = 32 * pow(100 / 32, t)
        let high = 16_000 * pow(10_000.0 / 16_000, t)
        let steps = n - 1
        return (0..<Int(n)).map { i in
            snap(low * pow(high / low, Double(i) / steps))
        }
    }

    static func kind(band: Int, count: Int) -> Kind {
        band == 0 ? .lowShelf : band == count - 1 ? .highShelf : .peak
    }

    /// Bell width matching the distance to the neighboring bands.
    static func q(band: Int, frequencies: [Double]) -> Double {
        guard frequencies.count > 2, band > 0, band < frequencies.count - 1 else { return 0.707 }
        let octaves = (log2(frequencies[band + 1]) - log2(frequencies[band - 1])) / 2
        let r = pow(2, octaves)
        return sqrt(r) / (r - 1)
    }

    private static func snap(_ f: Double) -> Double {
        isoCenters.min { abs(log2($0 / f)) < abs(log2($1 / f)) } ?? f
    }
}

/// A built-in equalizer curve. Defined at the ten-band centers and interpolated for other layouts.
struct EQPreset: Identifiable, Sendable {
    let id: String
    let points: [Double]

    var name: String {
        switch id {
        case "flat": String(localized: "Flat", comment: "Equalizer preset: no change")
        case "bass-boost": String(localized: "Bass Boost", comment: "Equalizer preset")
        case "bass-reducer": String(localized: "Bass Reducer", comment: "Equalizer preset")
        case "treble-boost": String(localized: "Treble Boost", comment: "Equalizer preset")
        case "treble-reducer": String(localized: "Treble Reducer", comment: "Equalizer preset")
        case "voice": String(localized: "Voice", comment: "Equalizer preset for speech, podcasts and calls")
        case "loudness": String(localized: "Loudness", comment: "Equalizer preset: fuller lows and highs at low volume")
        case "small-speakers": String(localized: "Small Speakers", comment: "Equalizer preset for laptop speakers")
        case "acoustic": String(localized: "Acoustic", comment: "Equalizer preset (music genre)")
        case "classical": String(localized: "Classical", comment: "Equalizer preset (music genre)")
        case "electronic": String(localized: "Electronic", comment: "Equalizer preset (music genre)")
        case "hip-hop": String(localized: "Hip-Hop", comment: "Equalizer preset (music genre)")
        case "jazz": String(localized: "Jazz", comment: "Equalizer preset (music genre)")
        case "pop": String(localized: "Pop", comment: "Equalizer preset (music genre)")
        case "rock": String(localized: "Rock", comment: "Equalizer preset (music genre)")
        default: id
        }
    }

    static let reference = EQLayout.frequencies(count: 10)

    static let all: [EQPreset] = [
        EQPreset(id: "flat", points: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        EQPreset(id: "bass-boost", points: [6, 5, 4, 2, 0.5, 0, 0, 0, 0, 0]),
        EQPreset(id: "bass-reducer", points: [-6, -5, -4, -2, -0.5, 0, 0, 0, 0, 0]),
        EQPreset(id: "treble-boost", points: [0, 0, 0, 0, 0, 0.5, 2, 4, 5, 6]),
        EQPreset(id: "treble-reducer", points: [0, 0, 0, 0, 0, -0.5, -2, -4, -5, -6]),
        EQPreset(id: "voice", points: [-3, -2, -1, 1, 3, 4, 4, 3, 1, -1]),
        EQPreset(id: "loudness", points: [5, 4, 2, 0, -1, 0, 0, 1, 3, 4]),
        EQPreset(id: "small-speakers", points: [-6, -3, 1, 3, 3, 2, 1, 1, 2, 3]),
        EQPreset(id: "acoustic", points: [4, 4, 3, 1, 2, 2, 3, 3, 3, 2]),
        EQPreset(id: "classical", points: [4, 3, 2, 1, 0, 0, 0, 1, 2, 3]),
        EQPreset(id: "electronic", points: [5, 4, 1, 0, -2, 1, 0, 1, 4, 5]),
        EQPreset(id: "hip-hop", points: [5, 4, 2, 3, -1, -1, 1, -1, 2, 3]),
        EQPreset(id: "jazz", points: [4, 3, 1, 2, -1, -1, 0, 1, 3, 4]),
        EQPreset(id: "pop", points: [-1, 0, 1, 3, 4, 3, 1, 0, -1, -1]),
        EQPreset(id: "rock", points: [5, 4, 3, 1, -1, -1, 1, 3, 4, 5]),
    ]

    static func named(_ id: String?) -> EQPreset? { all.first { $0.id == id } }

    /// The preset's gains for a layout of `count` bands.
    func gains(count: Int) -> [Double] {
        EQCurve.resample(points, from: Self.reference, to: EQLayout.frequencies(count: count))
    }

    /// The built-in preset these gains are, if any.
    static func matching(_ gains: [Double], count: Int) -> EQPreset? {
        guard gains.count == count else { return nil }
        return all.first { p in zip(p.gains(count: count), gains).allSatisfy { abs($0 - $1) < 0.01 } }
    }
}

/// Curve math shared by the settings, the flyout drawing and the realtime chain.
enum EQCurve {
    /// Piecewise-linear interpolation over log frequency, held flat past either end.
    static func resample(_ gains: [Double], from source: [Double], to target: [Double]) -> [Double] {
        guard !gains.isEmpty, gains.count == source.count else { return target.map { _ in 0 } }
        if source == target { return gains }
        let x = source.map(log2)
        return target.map { f in
            let t = log2(f)
            if t <= x[0] { return gains[0] }
            if t >= x[x.count - 1] { return gains[gains.count - 1] }
            let i = (1..<x.count).first { x[$0] >= t } ?? x.count - 1
            let u = (t - x[i - 1]) / (x[i] - x[i - 1])
            return ((gains[i - 1] + (gains[i] - gains[i - 1]) * u) * 100).rounded() / 100
        }
    }

    /// Moves an app's equalizer to another band count, keeping a chosen preset exact.
    static func resample(_ eq: EQSettings, from: Int, to: Int, customPresets: [CustomEQPreset]) -> EQSettings {
        var out = eq
        if let preset = EQPreset.named(eq.preset) {
            out.gains = preset.gains(count: to)
        } else if let custom = customPresets.first(where: { $0.id == eq.preset }) {
            out.gains = resample(custom.gains, from: custom.frequencies, to: EQLayout.frequencies(count: to))
        } else {
            out.gains = resample(gains(eq, count: from), from: EQLayout.frequencies(count: from),
                                 to: EQLayout.frequencies(count: to))
        }
        return out
    }

    /// `eq.gains` with exactly `count` entries (missing bands are flat).
    static func gains(_ eq: EQSettings, count: Int) -> [Double] {
        if eq.gains.count == count { return eq.gains }
        if eq.gains.isEmpty { return Array(repeating: 0, count: count) }
        return Array((eq.gains + Array(repeating: 0, count: max(0, count - eq.gains.count))).prefix(count))
    }

    /// One section per band (identity for flat bands and bands the sample rate can't hold).
    static func coefficients(_ eq: EQSettings, count: Int, sampleRate: Double) -> [BiquadCoefficients] {
        let freqs = EQLayout.frequencies(count: count)
        let g = gains(eq, count: count)
        return freqs.indices.map { i in
            let gain = min(max(g[i], EQLayout.gainRange.lowerBound), EQLayout.gainRange.upperBound)
            switch EQLayout.kind(band: i, count: count) {
            case .lowShelf: return .lowShelf(frequency: freqs[i], gain: gain, sampleRate: sampleRate)
            case .highShelf: return .highShelf(frequency: freqs[i], gain: gain, sampleRate: sampleRate)
            case .peak:
                return .peaking(frequency: freqs[i], gain: gain, q: EQLayout.q(band: i, frequencies: freqs),
                                sampleRate: sampleRate)
            }
        }
    }

    /// The whole curve's response (preamp included) at `frequency`, in dB.
    static func response(_ sections: [BiquadCoefficients], preamp: Double, at frequency: Double,
                         sampleRate: Double) -> Double {
        sections.reduce(preamp) { $0 + ($1.isIdentity ? 0 : $1.decibels(at: frequency, sampleRate: sampleRate)) }
    }

    /// Short band label: 32, 125, 1k, 12.5k (locale-aware numbers, SI "k").
    static func label(_ frequency: Double) -> String {
        frequency < 1000
            ? Int(frequency.rounded()).formatted()
            : (frequency / 1000).formatted(.number.precision(.fractionLength(0...1))) + "k"
    }
}
