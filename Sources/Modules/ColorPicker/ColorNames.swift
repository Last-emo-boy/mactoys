import Foundation

/// Human color names: PowerToys' coarse "Light Green / Green / Dark Green" buckets (`%Na`)
/// and the nearest CSS named color (`%Cs`).
public enum ColorNames {
    // MARK: PowerToys buckets

    // Hue limits (hue scaled to 0…255) for each of the 23 buckets at five saturation levels;
    // 0 means the bucket does not exist at that saturation. Ported from PowerToys' ColorNameHelper.
    private static let hueLimits: [[Int]] = [
        [8, 0, 0, 44, 0, 0, 0, 63, 0, 0, 122, 0, 134, 0, 0, 0, 0, 166, 176, 241, 0, 256, 0],      // sat 20–75
        [0, 10, 0, 32, 46, 0, 0, 0, 61, 0, 106, 0, 136, 144, 0, 0, 0, 158, 166, 241, 0, 0, 256],   // sat 75–115
        [0, 8, 0, 0, 39, 46, 0, 0, 0, 71, 120, 0, 131, 144, 0, 0, 163, 0, 177, 211, 249, 0, 256],  // sat 115–150
        [0, 11, 26, 0, 0, 38, 45, 0, 0, 56, 100, 121, 129, 0, 140, 0, 180, 0, 0, 224, 241, 0, 256], // sat 150–240
        [0, 13, 27, 0, 0, 36, 45, 0, 0, 59, 118, 0, 127, 136, 142, 0, 185, 0, 0, 216, 239, 0, 256], // sat 240–255
    ]
    private static let lumLow = [130, 100, 115, 100, 100, 100, 110, 75, 100, 90, 100, 100, 100, 100, 80, 100,
                                 100, 100, 100, 100, 100, 100, 100]
    private static let lumHigh = [170, 170, 170, 155, 170, 170, 170, 170, 170, 115, 170, 170, 170, 170, 170,
                                  170, 170, 170, 150, 150, 170, 140, 165]
    private static let light = ["Coral", "Rose", "Light Orange", "Tan", "Tan", "Light Yellow", "Light Yellow", "Tan",
                                "Light Green", "Lime", "Light Green", "Light Green", "Aqua", "Sky Blue",
                                "Light Turquoise", "Pale Blue", "Light Blue", "Ice Blue", "Periwinkle", "Lavender",
                                "Pink", "Tan", "Rose"]
    private static let mid = ["Coral", "Red", "Orange", "Brown", "Tan", "Gold", "Yellow", "Olive Green", "Olive Green",
                              "Green", "Green", "Bright Green", "Teal", "Aqua", "Turquoise", "Pale Blue", "Blue",
                              "Blue Gray", "Indigo", "Purple", "Pink", "Brown", "Red"]
    private static let dark = ["Brown", "Dark Red", "Brown", "Brown", "Brown", "Dark Yellow", "Dark Yellow", "Brown",
                               "Dark Green", "Dark Green", "Dark Green", "Dark Green", "Dark Teal", "Dark Teal",
                               "Dark Teal", "Dark Blue", "Dark Blue", "Blue Gray", "Indigo", "Dark Purple", "Plum",
                               "Brown", "Dark Red"]

    /// A high-level name such as "Light Green", "Green" or "Dark Green".
    public static func name(for c: ColorValue) -> String {
        let (h, s, l) = ColorMath.hsl(c)
        let hue = (h == 0 ? 0 : h / 360) * 255
        let sat = s * 255
        let lum = l * 255
        if lum > 240 { return "White" }
        if lum < 20 { return "Black" }
        if sat <= 20 {
            if lum > 170 { return "Light Gray" }
            return lum > 100 ? "Gray" : "Dark Gray"
        }
        let level: Int
        switch sat {
        case ...75: level = 0
        case ...115: level = 1
        case ...150: level = 2
        case ...240: level = 3
        default: level = 4
        }
        guard let index = hueLimits[level].firstIndex(where: { hue < Double($0) }) else { return "" }
        if lum > Double(lumHigh[index]) { return light[index] }
        if lum < Double(lumLow[index]) { return dark[index] }
        return mid[index]
    }

    /// `name(for:)` in the user's language, for display. The `%Na` format parameter keeps the
    /// English name, like every other format output.
    public static func displayName(for c: ColorValue) -> String {
        localized(name(for: c))
    }

    private static func localized(_ name: String) -> String {
        switch name {
        case "White": String(localized: "White", comment: "Color name")
        case "Black": String(localized: "Black", comment: "Color name")
        case "Light Gray": String(localized: "Light Gray", comment: "Color name")
        case "Gray": String(localized: "Gray", comment: "Color name")
        case "Dark Gray": String(localized: "Dark Gray", comment: "Color name")
        case "Coral": String(localized: "Coral", comment: "Color name")
        case "Rose": String(localized: "Rose", comment: "Color name (pinkish red)")
        case "Light Orange": String(localized: "Light Orange", comment: "Color name")
        case "Tan": String(localized: "Tan", comment: "Color name (light brown)")
        case "Light Yellow": String(localized: "Light Yellow", comment: "Color name")
        case "Light Green": String(localized: "Light Green", comment: "Color name")
        case "Lime": String(localized: "Lime", comment: "Color name (yellowish green)")
        case "Aqua": String(localized: "Aqua", comment: "Color name (greenish blue)")
        case "Sky Blue": String(localized: "Sky Blue", comment: "Color name")
        case "Light Turquoise": String(localized: "Light Turquoise", comment: "Color name")
        case "Pale Blue": String(localized: "Pale Blue", comment: "Color name")
        case "Light Blue": String(localized: "Light Blue", comment: "Color name")
        case "Ice Blue": String(localized: "Ice Blue", comment: "Color name")
        case "Periwinkle": String(localized: "Periwinkle", comment: "Color name (lavender blue)")
        case "Lavender": String(localized: "Lavender", comment: "Color name")
        case "Pink": String(localized: "Pink", comment: "Color name")
        case "Red": String(localized: "Red", comment: "Color name")
        case "Orange": String(localized: "Orange", comment: "Color name")
        case "Brown": String(localized: "Brown", comment: "Color name")
        case "Gold": String(localized: "Gold", comment: "Color name")
        case "Yellow": String(localized: "Yellow", comment: "Color name")
        case "Olive Green": String(localized: "Olive Green", comment: "Color name")
        case "Green": String(localized: "Green", comment: "Color name")
        case "Bright Green": String(localized: "Bright Green", comment: "Color name")
        case "Teal": String(localized: "Teal", comment: "Color name (dark cyan)")
        case "Turquoise": String(localized: "Turquoise", comment: "Color name")
        case "Blue": String(localized: "Blue", comment: "Color name")
        case "Blue Gray": String(localized: "Blue Gray", comment: "Color name")
        case "Indigo": String(localized: "Indigo", comment: "Color name")
        case "Purple": String(localized: "Purple", comment: "Color name")
        case "Dark Red": String(localized: "Dark Red", comment: "Color name")
        case "Dark Yellow": String(localized: "Dark Yellow", comment: "Color name")
        case "Dark Green": String(localized: "Dark Green", comment: "Color name")
        case "Dark Teal": String(localized: "Dark Teal", comment: "Color name")
        case "Dark Blue": String(localized: "Dark Blue", comment: "Color name")
        case "Dark Purple": String(localized: "Dark Purple", comment: "Color name")
        case "Plum": String(localized: "Plum", comment: "Color name (dark purple)")
        default: name
        }
    }

    // MARK: CSS named colors

    /// The CSS Color Module Level 4 named colors (spelling aliases such as `grey` and `cyan` are omitted).
    public static let css: [(name: String, hex: UInt32)] = [
        ("aliceblue", 0xF0F8FF), ("antiquewhite", 0xFAEBD7), ("aqua", 0x00FFFF), ("aquamarine", 0x7FFFD4),
        ("azure", 0xF0FFFF), ("beige", 0xF5F5DC), ("bisque", 0xFFE4C4), ("black", 0x000000),
        ("blanchedalmond", 0xFFEBCD), ("blue", 0x0000FF), ("blueviolet", 0x8A2BE2), ("brown", 0xA52A2A),
        ("burlywood", 0xDEB887), ("cadetblue", 0x5F9EA0), ("chartreuse", 0x7FFF00), ("chocolate", 0xD2691E),
        ("coral", 0xFF7F50), ("cornflowerblue", 0x6495ED), ("cornsilk", 0xFFF8DC), ("crimson", 0xDC143C),
        ("darkblue", 0x00008B), ("darkcyan", 0x008B8B), ("darkgoldenrod", 0xB8860B), ("darkgray", 0xA9A9A9),
        ("darkgreen", 0x006400), ("darkkhaki", 0xBDB76B), ("darkmagenta", 0x8B008B),
        ("darkolivegreen", 0x556B2F), ("darkorange", 0xFF8C00), ("darkorchid", 0x9932CC), ("darkred", 0x8B0000),
        ("darksalmon", 0xE9967A), ("darkseagreen", 0x8FBC8F), ("darkslateblue", 0x483D8B),
        ("darkslategray", 0x2F4F4F), ("darkturquoise", 0x00CED1), ("darkviolet", 0x9400D3),
        ("deeppink", 0xFF1493), ("deepskyblue", 0x00BFFF), ("dimgray", 0x696969), ("dodgerblue", 0x1E90FF),
        ("firebrick", 0xB22222), ("floralwhite", 0xFFFAF0), ("forestgreen", 0x228B22), ("fuchsia", 0xFF00FF),
        ("gainsboro", 0xDCDCDC), ("ghostwhite", 0xF8F8FF), ("gold", 0xFFD700), ("goldenrod", 0xDAA520),
        ("gray", 0x808080), ("green", 0x008000), ("greenyellow", 0xADFF2F), ("honeydew", 0xF0FFF0),
        ("hotpink", 0xFF69B4), ("indianred", 0xCD5C5C), ("indigo", 0x4B0082), ("ivory", 0xFFFFF0),
        ("khaki", 0xF0E68C), ("lavender", 0xE6E6FA), ("lavenderblush", 0xFFF0F5), ("lawngreen", 0x7CFC00),
        ("lemonchiffon", 0xFFFACD), ("lightblue", 0xADD8E6), ("lightcoral", 0xF08080), ("lightcyan", 0xE0FFFF),
        ("lightgoldenrodyellow", 0xFAFAD2), ("lightgray", 0xD3D3D3), ("lightgreen", 0x90EE90),
        ("lightpink", 0xFFB6C1), ("lightsalmon", 0xFFA07A), ("lightseagreen", 0x20B2AA),
        ("lightskyblue", 0x87CEFA), ("lightslategray", 0x778899), ("lightsteelblue", 0xB0C4DE),
        ("lightyellow", 0xFFFFE0), ("lime", 0x00FF00), ("limegreen", 0x32CD32), ("linen", 0xFAF0E6),
        ("maroon", 0x800000), ("mediumaquamarine", 0x66CDAA), ("mediumblue", 0x0000CD),
        ("mediumorchid", 0xBA55D3), ("mediumpurple", 0x9370DB), ("mediumseagreen", 0x3CB371),
        ("mediumslateblue", 0x7B68EE), ("mediumspringgreen", 0x00FA9A), ("mediumturquoise", 0x48D1CC),
        ("mediumvioletred", 0xC71585), ("midnightblue", 0x191970), ("mintcream", 0xF5FFFA),
        ("mistyrose", 0xFFE4E1), ("moccasin", 0xFFE4B5), ("navajowhite", 0xFFDEAD), ("navy", 0x000080),
        ("oldlace", 0xFDF5E6), ("olive", 0x808000), ("olivedrab", 0x6B8E23), ("orange", 0xFFA500),
        ("orangered", 0xFF4500), ("orchid", 0xDA70D6), ("palegoldenrod", 0xEEE8AA), ("palegreen", 0x98FB98),
        ("paleturquoise", 0xAFEEEE), ("palevioletred", 0xDB7093), ("papayawhip", 0xFFEFD5),
        ("peachpuff", 0xFFDAB9), ("peru", 0xCD853F), ("pink", 0xFFC0CB), ("plum", 0xDDA0DD),
        ("powderblue", 0xB0E0E6), ("purple", 0x800080), ("rebeccapurple", 0x663399), ("red", 0xFF0000),
        ("rosybrown", 0xBC8F8F), ("royalblue", 0x4169E1), ("saddlebrown", 0x8B4513), ("salmon", 0xFA8072),
        ("sandybrown", 0xF4A460), ("seagreen", 0x2E8B57), ("seashell", 0xFFF5EE), ("sienna", 0xA0522D),
        ("silver", 0xC0C0C0), ("skyblue", 0x87CEEB), ("slateblue", 0x6A5ACD), ("slategray", 0x708090),
        ("snow", 0xFFFAFA), ("springgreen", 0x00FF7F), ("steelblue", 0x4682B4), ("tan", 0xD2B48C),
        ("teal", 0x008080), ("thistle", 0xD8BFD8), ("tomato", 0xFF6347), ("turquoise", 0x40E0D0),
        ("violet", 0xEE82EE), ("wheat", 0xF5DEB3), ("white", 0xFFFFFF), ("whitesmoke", 0xF5F5F5),
        ("yellow", 0xFFFF00), ("yellowgreen", 0x9ACD32),
    ]

    private static let cssOklab: [(name: String, lab: (Double, Double, Double))] = css.map { entry in
        let c = ColorValue(red: UInt8((entry.hex >> 16) & 0xFF), green: UInt8((entry.hex >> 8) & 0xFF),
                           blue: UInt8(entry.hex & 0xFF))
        return (entry.name, ColorMath.oklab(c))
    }

    /// The CSS named color closest to `c` (Euclidean distance in Oklab, which tracks perceived difference).
    public static func nearestCSS(to c: ColorValue) -> String {
        let (l, a, b) = ColorMath.oklab(c)
        var best = ""
        var bestDistance = Double.infinity
        for entry in cssOklab {
            let dl = entry.lab.0 - l, da = entry.lab.1 - a, db = entry.lab.2 - b
            let d = dl * dl + da * da + db * db
            if d < bestDistance { bestDistance = d; best = entry.name }
        }
        return best
    }
}
