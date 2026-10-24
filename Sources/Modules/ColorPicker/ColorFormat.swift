import Foundation

/// One named color format shown in the editor and usable as the copy format.
public struct ColorFormat: Codable, Equatable, Hashable, Identifiable, Sendable {
    /// Unique; the built-ins use their PowerToys names ("HEX", "CIELAB", …).
    public var name: String
    /// Template with `%Re`-style parameters (see `ColorFormatter`).
    public var format: String
    public var enabled: Bool
    public var builtIn: Bool

    public var id: String { name }

    public init(name: String, format: String, enabled: Bool = true, builtIn: Bool = false) {
        self.name = name
        self.format = format
        self.enabled = enabled
        self.builtIn = builtIn
    }

    /// Every built-in format in its default order. The first six are on by default (design 06).
    public static let builtIns: [ColorFormat] = [
        ColorFormat(name: "HEX", format: "#%ReX%GrX%BlX", enabled: true, builtIn: true),
        ColorFormat(name: "RGB", format: "rgb(%Re, %Gr, %Bl)", enabled: true, builtIn: true),
        ColorFormat(name: "HSL", format: "hsl(%Hu, %Sl%, %Ll%)", enabled: true, builtIn: true),
        ColorFormat(name: "OKLCH", format: "oklch(%Lop% %Oc %Ohi)", enabled: true, builtIn: true),
        ColorFormat(name: "SwiftUI", format: "Color(red: %Ref, green: %Grf, blue: %Blf)", enabled: true, builtIn: true),
        ColorFormat(name: "CMYK", format: "cmyk(%Cy%, %Ma%, %Ye%, %Bk%)", enabled: true, builtIn: true),
        ColorFormat(name: "HSV", format: "hsv(%Hu, %Sb%, %Va%)", enabled: false, builtIn: true),
        ColorFormat(name: "HSB", format: "hsb(%Hu, %Sb%, %Br%)", enabled: false, builtIn: true),
        ColorFormat(name: "HSI", format: "hsi(%Hu, %Si%, %In%)", enabled: false, builtIn: true),
        ColorFormat(name: "HWB", format: "hwb(%Hu, %Wh%, %Bn%)", enabled: false, builtIn: true),
        ColorFormat(name: "NCol", format: "%Hn, %Wh%, %Bn%", enabled: false, builtIn: true),
        ColorFormat(name: "CIELAB", format: "CIELab(%Lc, %Ca, %Cb)", enabled: false, builtIn: true),
        ColorFormat(name: "CIEXYZ", format: "XYZ(%Xv, %Yv, %Zv)", enabled: false, builtIn: true),
        ColorFormat(name: "OKLAB", format: "oklab(%Lop% %Oa %Ob)", enabled: false, builtIn: true),
        ColorFormat(name: "VEC4", format: "(%Reff, %Grff, %Blff, 1f)", enabled: false, builtIn: true),
        ColorFormat(name: "Decimal", format: "%Dr", enabled: false, builtIn: true),
        ColorFormat(name: "HEX Int", format: "0xFF%ReX%GrX%BlX", enabled: false, builtIn: true),
        ColorFormat(name: "NSColor", format: "NSColor(srgbRed: %Ref, green: %Grf, blue: %Blf, alpha: %Alf)",
                    enabled: false, builtIn: true),
        ColorFormat(name: "CSS Name", format: "%Cs", enabled: false, builtIn: true),
    ]

    /// The template a new custom format starts with.
    public static let newFormatTemplate = "new Color (R = %Re, G = %Gr, B = %Bl)"
}

extension Array where Element == ColorFormat {
    /// Keeps the user's order, toggles and custom formats, and appends built-ins added since the
    /// list was saved (stored arrays replace defaults wholesale when settings load).
    public func normalized() -> [ColorFormat] {
        var seen = Set<String>()
        var result: [ColorFormat] = []
        for f in self where seen.insert(f.name).inserted {
            if f.builtIn, let def = ColorFormat.builtIns.first(where: { $0.name == f.name }) {
                var fixed = f
                fixed.format = def.format
                result.append(fixed)
            } else if !f.builtIn {
                result.append(f)
            }
        }
        for def in ColorFormat.builtIns where !seen.contains(def.name) {
            var off = def
            off.enabled = isEmpty ? def.enabled : false
            result.append(off)
        }
        return result
    }
}

/// Expands a format template for a color, PowerToys-compatible.
///
/// Parameters are `%` plus two letters, optionally followed by one formatter character:
///
/// | Parameter | Meaning | Parameter | Meaning |
/// |---|---|---|---|
/// | `%Re` `%Gr` `%Bl` `%Al` | red, green, blue, alpha | `%Cy` `%Ma` `%Ye` `%Bk` | CMYK (percent) |
/// | `%Hu` | hue | `%Hn` | natural hue (NCol) |
/// | `%Si` `%Sl` `%Sb` | saturation HSI / HSL / HSB | `%Br` `%Va` | brightness / value |
/// | `%In` | intensity | `%Ll` | lightness (HSL) |
/// | `%Wh` `%Bn` | whiteness / blackness | `%Lc` `%Ca` `%Cb` | CIE L*, a*, b* |
/// | `%Xv` `%Yv` `%Zv` | CIE XYZ | `%Lo` `%Oa` `%Ob` | Oklab L, a, b |
/// | `%Oc` `%Oh` | Oklch chroma, hue | `%Dv` / `%Dr` | decimal BGR (Windows) / RGB |
/// | `%Na` | color name | `%Cs` | nearest CSS color name |
///
/// RGBA formatters: `b` byte (default), `h`/`H` one hex digit, `x`/`X` two hex digits,
/// `f` float `0.##`, `F` float `.##`. Real-valued parameters accept `i` (integer) and the
/// MacToys extension `p` (×100 with one decimal, for CSS-style percentages: `%Lop%`).
public enum ColorFormatter {
    private static let parameters: Set<String> = [
        "Re", "Gr", "Bl", "Al", "Cy", "Ma", "Ye", "Bk", "Hu", "Hn", "Si", "Sl", "Sb", "Br", "In", "Ll", "Va",
        "Wh", "Bn", "Lc", "Ca", "Cb", "Lo", "Oa", "Ob", "Oc", "Oh", "Xv", "Yv", "Zv", "Dr", "Dv", "Na", "Cs",
    ]

    /// Formatter characters PowerToys recognizes after a parameter (consumed even when they
    /// don't apply to that parameter).
    private static let formatters: Set<Character> = ["b", "h", "H", "x", "X", "f", "F", "p", "i", "s"]

    public static func format(_ color: ColorValue, _ template: String) -> String {
        let chars = Array(template)
        var out = ""
        var i = 0
        while i < chars.count {
            if chars[i] == "%", i + 2 < chars.count {
                let key = String(chars[i + 1]) + String(chars[i + 2])
                if parameters.contains(key) {
                    var formatter: Character?
                    var length = 3
                    if i + 3 < chars.count, formatters.contains(chars[i + 3]) {
                        formatter = chars[i + 3]
                        length = 4
                    }
                    out += value(of: key, formatter: formatter, color: color)
                    i += length
                    continue
                }
            }
            out.append(chars[i])
            i += 1
        }
        return out
    }

    private static func value(of key: String, formatter f: Character?, color c: ColorValue) -> String {
        switch key {
        case "Re": return byte(c.red, f)
        case "Gr": return byte(c.green, f)
        case "Bl": return byte(c.blue, f)
        case "Al": return byte(c.alpha, f)
        case "Cy": return percent(ColorMath.cmyk(c).cyan)
        case "Ma": return percent(ColorMath.cmyk(c).magenta)
        case "Ye": return percent(ColorMath.cmyk(c).yellow)
        case "Bk": return percent(ColorMath.cmyk(c).black)
        case "Hu": return number(round(ColorMath.hue(c)))
        case "Hn": return ColorMath.naturalHue(c)
        case "Sb": return percent(ColorMath.hsv(c).saturation)
        case "Si": return percent(ColorMath.hsi(c).saturation)
        case "Sl": return percent(ColorMath.hsl(c).saturation)
        case "Va", "Br": return percent(ColorMath.hsv(c).value)
        case "In": return percent(ColorMath.hsi(c).intensity)
        case "Ll": return percent(ColorMath.hsl(c).lightness)
        case "Wh": return percent(ColorMath.hwb(c).whiteness)
        case "Bn": return percent(ColorMath.hwb(c).blackness)
        case "Lc": return real(ColorMath.lab(c).l, f, digits: 2)
        case "Ca": return real(ColorMath.lab(c).a, f, digits: 2)
        case "Cb": return real(ColorMath.lab(c).b, f, digits: 2)
        case "Lo": return real(ColorMath.oklab(c).l, f, digits: 2)
        case "Oa": return real(ColorMath.oklab(c).a, f, digits: 2)
        case "Ob": return real(ColorMath.oklab(c).b, f, digits: 2)
        case "Oc": return real(ColorMath.oklch(c).c, f, digits: 2)
        case "Oh": return real(ColorMath.oklch(c).h, f, digits: 2)
        case "Xv": return real(ColorMath.xyz(c).x * 100, f, digits: 4)
        case "Yv": return real(ColorMath.xyz(c).y * 100, f, digits: 4)
        case "Zv": return real(ColorMath.xyz(c).z * 100, f, digits: 4)
        case "Dr": return String(Int(c.red) * 65536 + Int(c.green) * 256 + Int(c.blue))
        case "Dv": return String(Int(c.red) + Int(c.green) * 256 + Int(c.blue) * 65536)
        case "Na": return ColorNames.name(for: c)
        case "Cs": return ColorNames.nearestCSS(to: c)
        default: return ""
        }
    }

    private static func byte(_ v: UInt8, _ f: Character?) -> String {
        switch f {
        case "h": return String(v / 16, radix: 16)
        case "H": return String(v / 16, radix: 16).uppercased()
        case "x": return String(format: "%02x", v)
        case "X": return String(format: "%02X", v)
        case "f": return trimmed(Double(v) / 255, digits: 2)
        case "F":
            let s = trimmed(Double(v) / 255, digits: 2)
            return s.hasPrefix("0.") ? String(s.dropFirst()) : s
        default: return String(v)
        }
    }

    /// `0...1` → rounded whole percent (banker's rounding, as .NET's `Math.Round`).
    private static func percent(_ v: Double) -> String { number(round(v * 100)) }

    private static func real(_ v: Double, _ f: Character?, digits: Int) -> String {
        switch f {
        case "i": return number(round(v))
        case "p": return trimmed(v * 100, digits: 1)
        default: return number(round(v, digits: digits))
        }
    }

    private static func round(_ v: Double, digits: Int = 0) -> Double {
        let scale = pow(10, Double(digits))
        return (v * scale).rounded(.toNearestOrEven) / scale
    }

    /// Prints a rounded number without a trailing ".0" and never as "-0".
    static func number(_ v: Double) -> String {
        trimmed(v, digits: 6)
    }

    /// Fixed-point with at most `digits` decimals, trailing zeros removed.
    static func trimmed(_ v: Double, digits: Int) -> String {
        var s = String(format: "%.\(digits)f", v)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        if s == "-0" { s = "0" }
        return s
    }
}
