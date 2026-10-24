import CoreGraphics
import Foundation

/// Zoom and pan geometry shared by Zoom and Live Zoom.
///
/// The visible part of the screen at level `z` is `size / z` points, positioned so the point
/// under the pointer stays under the pointer: `origin = pointer × (1 − 1/z)`. Moving to an edge
/// reveals that edge, and in Live Zoom a click lands exactly on what the pointer shows.
public enum ZoomMath {
    public static let minLevel = 1.0
    public static let maxLevel = 16.0
    /// Each scroll tick or arrow press multiplies or divides by this.
    public static let stepFactor = 1.25

    /// Visible source rectangle in screen-local points (origin top-left).
    public static func sourceRect(pointer: CGPoint, screen size: CGSize, level: Double) -> CGRect {
        let z = CGFloat(clamp(level))
        let p = CGPoint(x: min(max(pointer.x, 0), size.width), y: min(max(pointer.y, 0), size.height))
        let w = size.width / z, h = size.height / z
        return CGRect(x: p.x * (1 - 1 / z), y: p.y * (1 - 1 / z), width: w, height: h)
    }

    /// Where a point on the zoomed display shows a point of the screen.
    public static func sourcePoint(forDisplay d: CGPoint, visible rect: CGRect, screen size: CGSize) -> CGPoint {
        CGPoint(x: rect.minX + d.x * rect.width / size.width, y: rect.minY + d.y * rect.height / size.height)
    }

    public static func displayPoint(forSource s: CGPoint, visible rect: CGRect, screen size: CGSize) -> CGPoint {
        CGPoint(x: (s.x - rect.minX) * size.width / rect.width, y: (s.y - rect.minY) * size.height / rect.height)
    }

    /// Frame for a layer holding the whole screen image, in a container with a y-up (Core
    /// Animation) coordinate space, so that `rect` fills the container.
    public static func layerFrame(showing rect: CGRect, screen size: CGSize) -> CGRect {
        let z = size.width / rect.width
        return CGRect(x: -rect.minX * z, y: -(size.height - rect.maxY) * z, width: size.width * z, height: size.height * z)
    }

    public static func clamp(_ level: Double) -> Double { min(max(level, minLevel), maxLevel) }

    /// The next level up or down, clamped.
    public static func step(_ level: Double, zoomIn: Bool) -> Double {
        clamp(zoomIn ? level * stepFactor : level / stepFactor)
    }

    /// Smoothstep easing for animations, `t` in `0...1`.
    public static func ease(_ t: Double) -> Double {
        let x = min(max(t, 0), 1)
        return x * x * (3 - 2 * x)
    }

    /// Interpolates zoom levels geometrically, so zooming feels even at every level.
    public static func interpolate(from a: Double, to b: Double, progress t: Double) -> Double {
        let e = ease(t)
        return exp(log(a) + (log(b) - log(a)) * e)
    }
}

/// The break timer's countdown, adjustable while running.
public struct BreakClock: Equatable, Sendable {
    public var start: Date
    public var duration: TimeInterval

    public init(start: Date, minutes: Double) {
        self.start = start
        self.duration = max(0, minutes) * 60
    }

    public func remaining(at now: Date) -> TimeInterval { duration - now.timeIntervalSince(start) }
    public func isExpired(at now: Date) -> Bool { remaining(at: now) <= 0 }

    /// Adds or removes whole minutes (↑/↓). The countdown never goes below zero remaining.
    public mutating func adjust(minutes: Int, at now: Date) {
        let elapsed = now.timeIntervalSince(start)
        duration = max(elapsed, duration + Double(minutes) * 60)
        if minutes > 0, duration < elapsed + 60 { duration = elapsed + 60 }
    }
}

/// Timer text: `09:42`, `1:05:00`, and `+00:12` after expiry.
public enum BreakTimerFormat {
    public static func clock(_ seconds: Int) -> String {
        let s = max(0, seconds)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    }

    /// What the timer shows `remaining` seconds before (negative: after) expiry.
    public static func display(remaining: TimeInterval, showElapsed: Bool) -> (text: String, expired: Bool) {
        if remaining > 0 { return (clock(Int(remaining.rounded(.up))), false) }
        return (showElapsed ? "+" + clock(Int((-remaining).rounded(.down))) : clock(0), true)
    }
}
