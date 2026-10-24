import AppKit
import SwiftUI

/// A color that round-trips through JSON as `#RRGGBBAA`.
public struct RGBA: Codable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Accepts `#RGB`, `#RRGGBB`, `#RRGGBBAA` (with or without `#`).
    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        if s.count == 6 {
            self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
                      blue: Double(v & 0xFF) / 255, alpha: 1)
        } else {
            self.init(red: Double((v >> 24) & 0xFF) / 255, green: Double((v >> 16) & 0xFF) / 255,
                      blue: Double((v >> 8) & 0xFF) / 255, alpha: Double(v & 0xFF) / 255)
        }
    }

    public init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? color
        self.init(red: Double(c.redComponent), green: Double(c.greenComponent),
                  blue: Double(c.blueComponent), alpha: Double(c.alphaComponent))
    }

    /// `#RRGGBB`, or `#RRGGBBAA` when not opaque.
    public var hex: String {
        func b(_ v: Double) -> String { String(format: "%02X", Int((max(0, min(1, v)) * 255).rounded())) }
        return "#" + b(red) + b(green) + b(blue) + (alpha < 0.999 ? b(alpha) : "")
    }

    public var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
    public var cgColor: CGColor { nsColor.cgColor }
    public var color: Color { Color(nsColor: nsColor) }

    public func withAlpha(_ a: Double) -> RGBA { RGBA(red: red, green: green, blue: blue, alpha: a) }

    public static let white = RGBA(red: 1, green: 1, blue: 1)
    public static let black = RGBA(red: 0, green: 0, blue: 0)
    public static let accent = RGBA(hex: "#0A84FF")!
}

extension RGBA {
    /// Binding adapter for SwiftUI `ColorPicker`.
    public static func binding(_ source: Binding<RGBA>) -> Binding<Color> {
        Binding(
            get: { source.wrappedValue.color },
            set: { source.wrappedValue = RGBA(NSColor($0)) }
        )
    }
}
