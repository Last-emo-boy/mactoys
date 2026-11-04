import CoreGraphics
import Foundation

/// "Follow a display": other displays keep their distance to a source display's brightness level
/// (`BrightnessLevel`) as it changes, for example when the built-in display follows ambient
/// light or the brightness keys.
enum BrightnessSync {
    /// The follower's level for a source level: source + offset, kept inside what it can do.
    static func follow(source: Double, offset: Double, range: ClosedRange<Double>) -> Double {
        max(range.lowerBound, min(range.upperBound, ((source + offset) * 10).rounded() / 10))
    }

    /// The offset that keeps a follower where it is now.
    static func offset(follower: Double, source: Double) -> Double { follower - source }

    /// A follower's level range: dimming and extra brightness only where they are on.
    static func range(dimming: Bool, boost: Bool) -> ClosedRange<Double> {
        (dimming ? -100 : 0)...(boost ? 200 : 100)
    }

    /// Whether a source reading differs enough from the last one to move the followers
    /// (DisplayServices readings jitter by a fraction of a percent).
    static func moved(from old: Double?, to new: Double) -> Bool {
        guard let old else { return true }
        return abs(new - old) >= 0.5
    }
}

/// Arranging displays: which one is main, mirroring.
enum Arrangement {
    /// Origins that make `target` the main display (macOS puts the main display at 0, 0) while
    /// keeping every display where it is relative to the others.
    static func originsMakingMain(_ target: CGDirectDisplayID,
                                  bounds: [CGDirectDisplayID: CGRect]) -> [CGDirectDisplayID: CGPoint]? {
        guard let t = bounds[target] else { return nil }
        return bounds.mapValues { CGPoint(x: $0.minX - t.minX, y: $0.minY - t.minY) }
    }

    /// Displays `display` can mirror: every other active display that isn't itself mirroring it.
    static func mirrorSources(for display: CGDirectDisplayID, displays: [CGDirectDisplayID],
                              mirrorOf: [CGDirectDisplayID: CGDirectDisplayID]) -> [CGDirectDisplayID] {
        displays.filter { $0 != display && mirrorOf[$0] != display && mirrorOf[$0] == nil }
    }
}

/// CoreGraphics display arrangement. Main thread.
enum DisplayArranger {
    /// The display `id` shows a copy of (software or hardware mirroring), nil when it doesn't mirror.
    static func mirrorSource(of id: CGDirectDisplayID) -> CGDirectDisplayID? {
        let m = CGDisplayMirrorsDisplay(id)
        return m == kCGNullDirectDisplay ? nil : m
    }

    static func activeDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    @discardableResult
    static func makeMain(_ id: CGDirectDisplayID) -> Bool {
        let ids = activeDisplays()
        let bounds = Dictionary(uniqueKeysWithValues: ids.map { ($0, CGDisplayBounds($0)) })
        guard let origins = Arrangement.originsMakingMain(id, bounds: bounds) else { return false }
        return DisplayConfiguration.run { config in
            for (display, origin) in origins.sorted(by: { $0.key < $1.key }) {
                let e = CGConfigureDisplayOrigin(config, display, Int32(origin.x.rounded()), Int32(origin.y.rounded()))
                if e != .success { return e }
            }
            return .success
        }
    }

    /// Makes `id` show what `source` shows, or stops mirroring when `source` is nil.
    @discardableResult
    static func mirror(_ id: CGDirectDisplayID, of source: CGDirectDisplayID?) -> Bool {
        DisplayConfiguration.run { config in
            CGConfigureDisplayMirrorOfDisplay(config, id, source ?? kCGNullDirectDisplay)
        }
    }
}
