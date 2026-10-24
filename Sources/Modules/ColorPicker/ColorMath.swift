import Foundation
import MacToysCore

/// An 8-bit sRGB color — the unit every Color Picker format works on, exactly as captured.
/// Codes as `"#RRGGBB"` (or `"#RRGGBBAA"`) so the history file stays readable.
public struct ColorValue: Hashable, Sendable, Codable, CustomStringConvertible {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8
    public var alpha: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Rounds unit-range components to bytes.
    public init(_ rgba: RGBA) {
        func byte(_ v: Double) -> UInt8 { UInt8((max(0, min(1, v)) * 255).rounded()) }
        self.init(red: byte(rgba.red), green: byte(rgba.green), blue: byte(rgba.blue), alpha: byte(rgba.alpha))
    }

    /// Accepts `#RGB`, `#RRGGBB` and `#RRGGBBAA`, with or without `#`.
    public init?(hex: String) {
        guard let c = RGBA(hex: hex) else { return nil }
        self.init(c)
    }

    public var rgba: RGBA {
        RGBA(red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255, alpha: Double(alpha) / 255)
    }

    /// `#RRGGBB`, uppercase.
    public var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }
    public var description: String { hex }

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let v = ColorValue(hex: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad color \(s)"))
        }
        self = v
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(alpha == 255 ? hex : hex + String(format: "%02X", alpha))
    }
}

/// Color-space conversions, matching PowerToys' `ColorFormatHelper` so formats print the same values.
/// Hue is in degrees `0..<360`; other components are `0...1` unless noted.
public enum ColorMath {
    // MARK: Cylindrical spaces

    /// Hue as `System.Drawing.Color.GetHue` computes it: 0 for grays.
    public static func hue(_ c: ColorValue) -> Double {
        if c.red == c.green && c.green == c.blue { return 0 }
        let r = Double(c.red) / 255, g = Double(c.green) / 255, b = Double(c.blue) / 255
        let mx = max(r, g, b), mn = min(r, g, b)
        let delta = mx - mn
        var h: Double
        if r == mx { h = (g - b) / delta }
        else if g == mx { h = 2 + (b - r) / delta }
        else { h = 4 + (r - g) / delta }
        h *= 60
        if h < 0 { h += 360 }
        return h
    }

    private static func extremes(_ c: ColorValue) -> (min: Double, max: Double) {
        (Double(min(c.red, c.green, c.blue)) / 255, Double(max(c.red, c.green, c.blue)) / 255)
    }

    /// Hue, saturation, value (HSV and HSB are the same space).
    public static func hsv(_ c: ColorValue) -> (hue: Double, saturation: Double, value: Double) {
        let (mn, mx) = extremes(c)
        return (hue(c), mx == 0 ? 0 : (mx - mn) / mx, mx)
    }

    public static func hsl(_ c: ColorValue) -> (hue: Double, saturation: Double, lightness: Double) {
        let (mn, mx) = extremes(c)
        let l = (mx + mn) / 2
        if l == 0 || mn == mx { return (hue(c), 0, l) }
        if l <= 0.5 { return (hue(c), (mx - mn) / (mx + mn), l) }
        return (hue(c), (mx - mn) / (2 - (mx + mn)), l)
    }

    public static func hsi(_ c: ColorValue) -> (hue: Double, saturation: Double, intensity: Double) {
        if c.red == 0 && c.green == 0 && c.blue == 0 { return (0, 0, 0) }
        let i = (Double(c.red) + Double(c.green) + Double(c.blue)) / 255 / 3
        let (mn, _) = extremes(c)
        return (hue(c), 1 - mn / i, i)
    }

    public static func hwb(_ c: ColorValue) -> (hue: Double, whiteness: Double, blackness: Double) {
        let (mn, mx) = extremes(c)
        return (hue(c), mn, 1 - mx)
    }

    public static func cmyk(_ c: ColorValue) -> (cyan: Double, magenta: Double, yellow: Double, black: Double) {
        let r = Double(c.red) / 255, g = Double(c.green) / 255, b = Double(c.blue) / 255
        let k = 1 - max(r, g, b)
        if 1 - k == 0 { return (0, 0, 0, 1) }
        return ((1 - r - k) / (1 - k), (1 - g - k) / (1 - k), (1 - b - k) / (1 - k), k)
    }

    /// Natural color system hue name (`R7`, `Y40`, …): letter for the sextant, 0–100 within it.
    public static func naturalHue(_ c: ColorValue) -> String {
        let h = hue(c)
        let letters: [(Double, String)] = [(60, "R"), (120, "Y"), (180, "G"), (240, "C"), (300, "B"), (360, "M")]
        for (i, (limit, letter)) in letters.enumerated() where h < limit {
            let start = Double(i) * 60
            return letter + String(Int(((h - start) / 0.6).rounded(.toNearestOrEven)))
        }
        return "M100"
    }

    // MARK: CIE / Oklab

    public static func linear(_ v: Double) -> Double {
        v > 0.04045 ? pow((v + 0.055) / 1.055, 2.4) : v / 12.92
    }

    public static func delinear(_ v: Double) -> Double {
        v > 0.0031308 ? 1.055 * pow(v, 1 / 2.4) - 0.055 : v * 12.92
    }

    /// CIE XYZ (D65), each `0...~1`.
    public static func xyz(_ c: ColorValue) -> (x: Double, y: Double, z: Double) {
        let r = linear(Double(c.red) / 255), g = linear(Double(c.green) / 255), b = linear(Double(c.blue) / 255)
        return (r * 0.41239079926595948 + g * 0.35758433938387796 + b * 0.18048078840183429,
                r * 0.21263900587151036 + g * 0.71516867876775593 + b * 0.07219231536073372,
                r * 0.01933081871559185 + g * 0.11919477979462599 + b * 0.95053215224966058)
    }

    /// CIE L*a*b* relative to the sRGB (D65) white point: L `0...100`, a/b roughly `-128...127`.
    public static func lab(_ c: ColorValue) -> (l: Double, a: Double, b: Double) {
        let (x, y, z) = xyz(c)
        let xn = 0.9504559270516717, yn = 1.0, zn = 1.0890577507598784
        let delta = 6.0 / 29
        let m = (1.0 / 3) * pow(delta, -2)
        let t = pow(delta, 3)
        func f(_ v: Double) -> Double { v > t ? pow(v, 1.0 / 3) : v * m + 16.0 / 116 }
        let fx = f(x / xn), fy = f(y / yn), fz = f(z / zn)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    /// Oklab: L `0...1`, a/b roughly `-0.5...0.5`.
    public static func oklab(_ c: ColorValue) -> (l: Double, a: Double, b: Double) {
        let r = linear(Double(c.red) / 255), g = linear(Double(c.green) / 255), b = linear(Double(c.blue) / 255)
        let l = 0.41222147079999993 * r + 0.5363325363 * g + 0.0514459929 * b
        let m = 0.2119034981999999 * r + 0.6806995450999999 * g + 0.1073969566 * b
        let s = 0.08830246189999998 * r + 0.2817188376 * g + 0.6299787005000002 * b
        let l_ = cbrt(l), m_ = cbrt(m), s_ = cbrt(s)
        return (0.2104542553 * l_ + 0.793617785 * m_ - 0.0040720468 * s_,
                1.9779984951 * l_ - 2.428592205 * m_ + 0.4505937099 * s_,
                0.0259040371 * l_ + 0.7827717662 * m_ - 0.808675766 * s_)
    }

    /// Oklch: lightness `0...1`, chroma `0...~0.4`, hue degrees (0 for achromatic colors).
    public static func oklch(_ c: ColorValue) -> (l: Double, c: Double, h: Double) {
        let (l, a, b) = oklab(c)
        let chroma = (a * a + b * b).squareRoot()
        let roundedChroma = (chroma * 1000).rounded() / 1000
        let h = roundedChroma == 0 ? 0 : (atan2(b, a) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        return (l, chroma, h)
    }

    // MARK: Inverse conversions (editor sliders, shades)

    /// HSV → sRGB bytes. `h` in degrees, `s`/`v` in `0...1`.
    public static func fromHSV(hue h: Double, saturation s: Double, value v: Double, alpha: UInt8 = 255) -> ColorValue {
        let s = max(0, min(1, s)), v = max(0, min(1, v))
        let hh = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let i = Int(hh.rounded(.down))
        let f = hh - Double(i)
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        let (r, g, b): (Double, Double, Double)
        switch i {
        case 0: (r, g, b) = (v, t, p)
        case 1: (r, g, b) = (q, v, p)
        case 2: (r, g, b) = (p, v, t)
        case 3: (r, g, b) = (p, q, v)
        case 4: (r, g, b) = (t, p, v)
        default: (r, g, b) = (v, p, q)
        }
        return ColorValue(red: byte(r), green: byte(g), blue: byte(b), alpha: alpha)
    }

    /// HSL → sRGB bytes. `h` in degrees, `s`/`l` in `0...1`.
    public static func fromHSL(hue h: Double, saturation s: Double, lightness l: Double, alpha: UInt8 = 255) -> ColorValue {
        let s = max(0, min(1, s)), l = max(0, min(1, l))
        let c = (1 - abs(2 * l - 1)) * s
        let hh = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let x = c * (1 - abs(hh.truncatingRemainder(dividingBy: 2) - 1))
        let (r1, g1, b1): (Double, Double, Double)
        switch Int(hh.rounded(.down)) {
        case 0: (r1, g1, b1) = (c, x, 0)
        case 1: (r1, g1, b1) = (x, c, 0)
        case 2: (r1, g1, b1) = (0, c, x)
        case 3: (r1, g1, b1) = (0, x, c)
        case 4: (r1, g1, b1) = (x, 0, c)
        default: (r1, g1, b1) = (c, 0, x)
        }
        let m = l - c / 2
        return ColorValue(red: byte(r1 + m), green: byte(g1 + m), blue: byte(b1 + m), alpha: alpha)
    }

    /// Five related colors, darkest first, with `color` in the middle (the editor's shade bar).
    /// Darker shades step toward black and lighter ones toward white in thirds of the remaining
    /// lightness, so even very light or dark colors get distinct neighbors.
    public static func shades(of color: ColorValue) -> [ColorValue] {
        let (h, s, l) = hsl(color)
        return [-2.0, -1, 0, 1, 2].map { k in
            if k == 0 { return color }
            let target = k < 0 ? l + k * l / 3 : l + k * (1 - l) / 3
            return fromHSL(hue: h, saturation: s, lightness: target, alpha: color.alpha)
        }
    }

    private static func byte(_ v: Double) -> UInt8 { UInt8((max(0, min(1, v)) * 255).rounded()) }
}
