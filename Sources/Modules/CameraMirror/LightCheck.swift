import Foundation

/// What the light check says about the picture.
enum LightHint: String, Equatable, Sendable {
    case good, aBitDark, tooDark, backlit, tooBright

    var title: String {
        switch self {
        case .good: String(localized: "Good light", comment: "Camera Mirror light check")
        case .aBitDark: String(localized: "A bit dark", comment: "Camera Mirror light check: the face is underexposed")
        case .tooDark: String(localized: "Too dark", comment: "Camera Mirror light check")
        case .backlit: String(localized: "Light is behind you", comment: "Camera Mirror light check: backlit face")
        case .tooBright: String(localized: "Very bright", comment: "Camera Mirror light check: overexposed")
        }
    }

    /// A short tip for the help tag.
    var advice: String {
        switch self {
        case .good: String(localized: "Your face is well lit.")
        case .aBitDark, .tooDark: String(localized: "Turn on a light in front of you, or face a window.")
        case .backlit: String(localized: "A window or lamp behind you darkens your face. Turn toward the light.")
        case .tooBright: String(localized: "Move away from direct light or lower the lamp.")
        }
    }

    var symbol: String {
        switch self {
        case .good: "sun.max.fill"
        case .aBitDark: "sun.min.fill"
        case .tooDark: "moon.fill"
        case .backlit: "person.and.background.dotted"
        case .tooBright: "sun.max.trianglebadge.exclamationmark.fill"
        }
    }
}

/// Average brightness (0…1) of the whole frame, the middle where a face usually is, and the border.
struct LightSample: Equatable, Sendable {
    var mean: Double
    var center: Double
    var edges: Double
}

enum LightCheck {
    /// Thresholds on gamma-encoded luma (0 black … 1 white).
    static let tooDarkCenter = 0.12
    static let darkCenter = 0.30
    static let backlitDifference = 0.22
    static let backlitEdges = 0.5
    static let brightCenter = 0.92

    /// The hint for one sample.
    static func assess(_ s: LightSample) -> LightHint {
        if s.center < tooDarkCenter && s.mean < tooDarkCenter + 0.05 { return .tooDark }
        if s.edges - s.center > backlitDifference && s.edges > backlitEdges { return .backlit }
        if s.center < darkCenter { return .aBitDark }
        if s.center > brightCenter { return .tooBright }
        return .good
    }

    /// Luma statistics of a 32-bit BGRA buffer, reading every `step`-th pixel (cheap enough for
    /// one frame a second). Center = middle 40 % × 50 %; edges = outer 15 % band.
    static func sample(bgra base: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int, step: Int = 4) -> LightSample {
        guard width > 0, height > 0 else { return LightSample(mean: 0, center: 0, edges: 0) }
        let stride = max(1, step)
        let cx0 = Int(Double(width) * 0.3), cx1 = Int(Double(width) * 0.7)
        let cy0 = Int(Double(height) * 0.2), cy1 = Int(Double(height) * 0.7)
        let ex = Int(Double(width) * 0.15), ey = Int(Double(height) * 0.15)
        var all = 0.0, center = 0.0, edges = 0.0
        var nAll = 0, nCenter = 0, nEdges = 0
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var y = 0
        while y < height {
            let row = bytes + y * bytesPerRow
            var x = 0
            while x < width {
                let p = row + x * 4
                let luma = (0.0722 * Double(p[0]) + 0.7152 * Double(p[1]) + 0.2126 * Double(p[2])) / 255
                all += luma
                nAll += 1
                if x >= cx0 && x < cx1 && y >= cy0 && y < cy1 { center += luma; nCenter += 1 }
                if x < ex || x >= width - ex || y < ey || y >= height - ey { edges += luma; nEdges += 1 }
                x += stride
            }
            y += stride
        }
        return LightSample(mean: all / Double(max(1, nAll)), center: center / Double(max(1, nCenter)),
                           edges: edges / Double(max(1, nEdges)))
    }
}

/// Smooths samples over time so the hint doesn't flicker as you move: values are averaged and
/// a new hint must hold for two samples in a row before it is shown.
struct LightMeter: Sendable {
    private(set) var hint: LightHint = .good
    private var smoothed: LightSample?
    private var candidate: LightHint?
    var smoothing = 0.4

    /// Adds a sample; returns the hint to show.
    @discardableResult
    mutating func add(_ s: LightSample) -> LightHint {
        let a = smoothing
        let next = smoothed.map {
            LightSample(mean: $0.mean + (s.mean - $0.mean) * a, center: $0.center + (s.center - $0.center) * a,
                        edges: $0.edges + (s.edges - $0.edges) * a)
        } ?? s
        smoothed = next
        let assessed = LightCheck.assess(next)
        if assessed == hint {
            candidate = nil
        } else if candidate == assessed {
            hint = assessed
            candidate = nil
        } else {
            candidate = assessed
        }
        return hint
    }

    mutating func reset() {
        hint = .good
        smoothed = nil
        candidate = nil
    }
}
