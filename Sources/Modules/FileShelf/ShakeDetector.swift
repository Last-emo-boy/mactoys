import Foundation

/// How hard a shake has to be to open a shelf.
enum ShakeSensitivity: String, Codable, CaseIterable, Sendable {
    case low, medium, high

    var title: String {
        switch self {
        case .low: String(localized: "Low", comment: "Shake sensitivity: needs a long, wide shake")
        case .medium: String(localized: "Medium", comment: "Shake sensitivity")
        case .high: String(localized: "High", comment: "Shake sensitivity: a short, small shake is enough")
        }
    }

    var tuning: ShakeDetector.Tuning {
        switch self {
        case .low: ShakeDetector.Tuning(minTravel: 60, reversals: 5, window: 0.9, maxSegmentDuration: 0.25)
        case .medium: ShakeDetector.Tuning(minTravel: 38, reversals: 4, window: 0.85, maxSegmentDuration: 0.3)
        case .high: ShakeDetector.Tuning(minTravel: 24, reversals: 3, window: 0.9, maxSegmentDuration: 0.35)
        }
    }
}

/// Recognizes a quick back-and-forth shake of the pointer from a stream of positions.
///
/// Each axis is tracked on its own: a *reversal* is counted when the pointer, having swept at
/// least `minTravel` points one way within `maxSegmentDuration`, comes back `minTravel` points the
/// other way. `reversals` of them on one axis within `window` seconds make a shake; a slow sweep
/// starts the count over. Ordinary drags — straight lines, curves, an overshoot and a correction,
/// slow sweeps, hand tremor — never get there.
///
/// `add` does a handful of comparisons and no allocation, so it can run for every drag event.
struct ShakeDetector {
    struct Tuning: Equatable, Sendable {
        /// Points the pointer must travel each way.
        var minTravel: Double
        /// Direction changes needed.
        var reversals: Int
        /// Seconds within which the reversals must happen.
        var window: TimeInterval
        /// Longest a single sweep may take; slower movement isn't shaking.
        var maxSegmentDuration: TimeInterval
    }

    var tuning: Tuning
    private var x = Axis()
    private var y = Axis()

    init(tuning: Tuning = ShakeSensitivity.medium.tuning) {
        self.tuning = tuning
    }

    /// Feeds one pointer position. Returns true when it completes a shake (the detector then resets).
    mutating func add(x px: Double, y py: Double, time: TimeInterval) -> Bool {
        let shookX = x.add(px, time, tuning)
        let shookY = y.add(py, time, tuning)
        guard shookX || shookY else { return false }
        reset()
        return true
    }

    mutating func reset() {
        x.clear()
        y.clear()
    }

    /// One axis of movement.
    private struct Axis {
        /// +1 or -1 once the pointer has swept `minTravel` one way; 0 before that.
        var direction = 0
        /// Before the first sweep: the lowest and highest recent positions, and when.
        var low = 0.0, lowTime: TimeInterval = 0
        var high = 0.0, highTime: TimeInterval = 0
        /// Where the current sweep started (the last turning point) and when.
        var anchor = 0.0
        var anchorTime: TimeInterval = 0
        /// The farthest point of the current sweep and when it was reached.
        var extreme = 0.0
        var extremeTime: TimeInterval = 0
        var started = false
        /// Times of the recent qualifying reversals, oldest first. Allocated once; only overwritten.
        var times = [TimeInterval](repeating: 0, count: 8)
        var count = 0

        mutating func clear() {
            direction = 0
            started = false
            count = 0
        }

        /// Returns true when this sample completes a shake.
        mutating func add(_ v: Double, _ t: TimeInterval, _ tuning: Tuning) -> Bool {
            guard started else {
                started = true
                low = v; lowTime = t
                high = v; highTime = t
                return false
            }
            if direction == 0 {
                // Waiting for the first decisive sweep, from a recent low or high.
                if v <= low || t - lowTime > tuning.maxSegmentDuration { low = v; lowTime = t }
                if v >= high || t - highTime > tuning.maxSegmentDuration { high = v; highTime = t }
                if v - low >= tuning.minTravel {
                    direction = 1
                    anchor = low; anchorTime = lowTime
                } else if high - v >= tuning.minTravel {
                    direction = -1
                    anchor = high; anchorTime = highTime
                } else {
                    return false
                }
                extreme = v
                extremeTime = t
                return false
            }
            let d = Double(direction)
            if (v - extreme) * d >= 0 {
                // Still going the same way.
                extreme = v
                extremeTime = t
                return false
            }
            guard (extreme - v) * d >= tuning.minTravel else { return false }
            // Turned around far enough: the sweep anchor → extreme is complete.
            let fast = extremeTime - anchorTime <= tuning.maxSegmentDuration
            anchor = extreme
            anchorTime = extremeTime
            direction = -direction
            extreme = v
            extremeTime = t
            guard fast else {
                count = 0
                return false
            }
            return record(t, tuning) >= tuning.reversals
        }

        /// Appends a reversal time and returns how many fall within the window.
        private mutating func record(_ t: TimeInterval, _ tuning: Tuning) -> Int {
            if count == times.count {
                for i in 1..<times.count { times[i - 1] = times[i] }
                count -= 1
            }
            times[count] = t
            count += 1
            var n = 0
            for i in 0..<count where t - times[i] <= tuning.window { n += 1 }
            return n
        }
    }
}
