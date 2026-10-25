import Foundation

/// Unit categories the converter knows.
enum UnitCategory: String, CaseIterable, Sendable {
    case length, mass, temperature, volume, area, speed, dataSize, duration, angle, pressure, energy, power, acceleration

    var title: String {
        switch self {
        case .length: String(localized: "Length", comment: "Unit category")
        case .mass: String(localized: "Mass", comment: "Unit category")
        case .temperature: String(localized: "Temperature", comment: "Unit category")
        case .volume: String(localized: "Volume", comment: "Unit category: liters, gallons…")
        case .area: String(localized: "Area", comment: "Unit category")
        case .speed: String(localized: "Speed", comment: "Unit category")
        case .dataSize: String(localized: "Data size", comment: "Unit category: bytes, megabytes…")
        case .duration: String(localized: "Time", comment: "Unit category: seconds, hours, days…")
        case .angle: String(localized: "Angle", comment: "Unit category")
        case .pressure: String(localized: "Pressure", comment: "Unit category")
        case .energy: String(localized: "Energy", comment: "Unit category")
        case .power: String(localized: "Power", comment: "Unit category: watts, horsepower…")
        case .acceleration: String(localized: "Acceleration", comment: "Unit category")
        }
    }
}

/// One unit: `factor` converts to the category's base unit (`base = value * factor + offset`).
struct ConversionUnit: Hashable, Sendable {
    let symbol: String
    let category: UnitCategory
    let factor: Double
    let offset: Double
    /// Lowercased names that also refer to this unit (plurals included).
    let names: [String]
    /// Symbols that are only recognized with this exact case (`MB` vs `Mb`).
    let caseSensitive: Bool

    init(_ symbol: String, _ category: UnitCategory, _ factor: Double, offset: Double = 0,
         names: [String] = [], caseSensitive: Bool = false) {
        self.symbol = symbol
        self.category = category
        self.factor = factor
        self.offset = offset
        self.names = names
        self.caseSensitive = caseSensitive
    }

    func toBase(_ v: Double) -> Double { v * factor + offset }
    func fromBase(_ v: Double) -> Double { (v - offset) / factor }
}

/// Converts `10 km to mi`, `100 f in c`, `5 sq m to sqft`, `1.5 GiB to MB`, `90 min to h`.
enum UnitConverter {
    struct Conversion: Equatable {
        let value: Double
        let from: ConversionUnit
        let result: Double
        let to: ConversionUnit
    }

    /// Parses a full request with a target unit (`to`, `in`, `as`, `=`, `->`).
    static func convert(_ text: String) -> Conversion? {
        let lower = " " + text.trimmingCharacters(in: .whitespaces) + " "
        // Try every connector position: `10 in in cm` splits at the second `in`.
        for connector in [" to ", " in ", " as ", " -> ", " → ", " = "] {
            var search = lower.startIndex..<lower.endIndex
            while let r = lower.range(of: connector, options: .caseInsensitive, range: search) {
                let left = String(lower[..<r.lowerBound])
                let right = String(lower[r.upperBound...])
                if let (value, fromCandidates) = parseQuantity(left) {
                    let toCandidates = lookup(right)
                    for from in fromCandidates {
                        if let to = toCandidates.first(where: { $0.category == from.category }) {
                            return Conversion(value: value, from: from, result: to.fromBase(from.toBase(value)), to: to)
                        }
                    }
                }
                // Overlapping occurrences: " in in " has a second " in " starting inside the first.
                search = lower.index(after: r.lowerBound)..<lower.endIndex
            }
        }
        return nil
    }

    /// A quantity without a target (`10 km`): conversions to the usual units of its category.
    static func suggestions(_ text: String) -> [Conversion] {
        guard let (value, candidates) = parseQuantity(text), let from = candidates.first else { return [] }
        let targets = (common[from.category] ?? []).compactMap { sym in units.first { $0.symbol == sym } }
        return targets.filter { $0 != from }.map {
            Conversion(value: value, from: from, result: $0.fromBase(from.toBase(value)), to: $0)
        }
    }

    /// `"10 km"`, `"10km"`, `"-40 °F"`, `"1.5e3 m"` → value and possible units.
    static func parseQuantity(_ text: String) -> (Double, [ConversionUnit])? {
        let s = text.trimmingCharacters(in: .whitespaces)
        var end = s.startIndex
        var seenDigit = false
        var i = s.startIndex
        if i < s.endIndex, s[i] == "-" || s[i] == "+" { i = s.index(after: i) }
        while i < s.endIndex {
            let c = s[i]
            if c.isNumber { seenDigit = true }
            else if c == "." || c == "_" {}
            else if (c == "e" || c == "E"), seenDigit, s.index(after: i) < s.endIndex,
                    s[s.index(after: i)].isNumber || "+-".contains(s[s.index(after: i)]) {
                // exponent; consume sign
                i = s.index(after: i)
            } else { break }
            i = s.index(after: i)
            end = i
        }
        guard seenDigit, let value = Double(s[..<end].replacingOccurrences(of: "_", with: "")) else { return nil }
        let unitText = String(s[end...])
        let found = lookup(unitText)
        return found.isEmpty ? nil : (value, found)
    }

    /// All units a string can name, exact-case symbols first.
    static func lookup(_ raw: String) -> [ConversionUnit] {
        var t = raw.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return [] }
        t = t.replacingOccurrences(of: "²", with: "2").replacingOccurrences(of: "³", with: "3")
            .replacingOccurrences(of: "^2", with: "2").replacingOccurrences(of: "^3", with: "3")
            .replacingOccurrences(of: "°", with: "").replacingOccurrences(of: "º", with: "")
        let lower = t.lowercased()
        var keys = [lower]
        // "sq m", "square meters", "cubic feet", "sqm".
        for (prefix, suffix) in [("square ", "2"), ("sq ", "2"), ("sq", "2"), ("cubic ", "3"), ("cu ", "3")]
        where lower.hasPrefix(prefix) && lower.count > prefix.count {
            keys.append(String(lower.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) + suffix)
        }
        if lower.hasPrefix("degrees ") { keys.append(String(lower.dropFirst(8))) }
        if lower.hasPrefix("deg ") { keys.append(String(lower.dropFirst(4))) }
        var result: [ConversionUnit] = []
        for u in units where u.symbol == t { result.append(u) }
        for key in keys {
            for u in units where !result.contains(u) {
                if (!u.caseSensitive && u.symbol.lowercased() == key) || u.names.contains(key) { result.append(u) }
            }
        }
        return result
    }

    /// The units listed for a quantity without a target.
    static let common: [UnitCategory: [String]] = [
        .length: ["m", "km", "cm", "mm", "mi", "ft", "in", "yd"],
        .mass: ["kg", "g", "lb", "oz", "st"],
        .temperature: ["°C", "°F", "K"],
        .volume: ["l", "ml", "gal", "qt", "cup", "fl oz"],
        .area: ["m²", "km²", "ft²", "ha", "ac"],
        .speed: ["km/h", "m/s", "mph", "kn"],
        .dataSize: ["B", "KB", "MB", "GB", "KiB", "MiB", "GiB"],
        .duration: ["s", "min", "h", "d", "wk"],
        .angle: ["deg", "rad", "grad", "turn"],
        .pressure: ["Pa", "kPa", "bar", "psi", "atm"],
        .energy: ["J", "kJ", "cal", "kcal", "kWh"],
        .power: ["W", "kW", "hp"],
        .acceleration: ["m/s²", "ft/s²", "g₀"],
    ]

    static let units: [ConversionUnit] = {
        var u: [ConversionUnit] = []
        func add(_ symbol: String, _ c: UnitCategory, _ f: Double, offset: Double = 0, _ names: [String] = [],
                 caseSensitive: Bool = false) {
            u.append(ConversionUnit(symbol, c, f, offset: offset, names: names, caseSensitive: caseSensitive))
        }
        // Length (base: metre)
        add("nm", .length, 1e-9, ["nanometer", "nanometers", "nanometre", "nanometres"])
        add("µm", .length, 1e-6, ["um", "micrometer", "micrometers", "micron", "microns"])
        add("mm", .length, 1e-3, ["millimeter", "millimeters", "millimetre", "millimetres"])
        add("cm", .length, 1e-2, ["centimeter", "centimeters", "centimetre", "centimetres"])
        add("dm", .length, 0.1, ["decimeter", "decimeters"])
        add("m", .length, 1, ["meter", "meters", "metre", "metres"])
        add("km", .length, 1000, ["kilometer", "kilometers", "kilometre", "kilometres", "kms"])
        add("in", .length, 0.0254, ["inch", "inches", "\""])
        add("ft", .length, 0.3048, ["foot", "feet", "'"])
        add("yd", .length, 0.9144, ["yard", "yards"])
        add("mi", .length, 1609.344, ["mile", "miles"])
        add("nmi", .length, 1852, ["nautical mile", "nautical miles"])
        add("au", .length, 149_597_870_700, ["astronomical unit", "astronomical units"])
        add("ly", .length, 9_460_730_472_580_800, ["light year", "light years", "lightyear", "lightyears"])
        // Mass (base: kilogram)
        add("mg", .mass, 1e-6, ["milligram", "milligrams"])
        add("g", .mass, 1e-3, ["gram", "grams", "gr"])
        add("kg", .mass, 1, ["kilogram", "kilograms", "kilo", "kilos", "kgs"])
        add("t", .mass, 1000, ["tonne", "tonnes", "metric ton", "metric tons"])
        add("oz", .mass, 0.028349523125, ["ounce", "ounces"])
        add("lb", .mass, 0.45359237, ["lbs", "pound", "pounds"])
        add("st", .mass, 6.35029318, ["stone", "stones"])
        add("ton", .mass, 907.18474, ["short ton", "short tons", "us ton", "tons"])
        add("ct", .mass, 0.0002, ["carat", "carats"])
        // Temperature (base: kelvin)
        add("°C", .temperature, 1, offset: 273.15, ["c", "celsius", "degc", "centigrade"])
        add("°F", .temperature, 5.0 / 9, offset: 273.15 - 32 * 5.0 / 9, ["f", "fahrenheit", "degf"])
        add("K", .temperature, 1, ["k", "kelvin", "kelvins"])
        // Volume (base: litre)
        add("ml", .volume, 1e-3, ["milliliter", "milliliters", "millilitre", "millilitres", "cc", "cm3"])
        add("cl", .volume, 1e-2, ["centiliter", "centiliters"])
        add("dl", .volume, 0.1, ["deciliter", "deciliters"])
        add("l", .volume, 1, ["liter", "liters", "litre", "litres", "dm3"])
        add("m³", .volume, 1000, ["m3", "cubic meter", "cubic meters", "cubic metre"])
        add("tsp", .volume, 0.00492892159375, ["teaspoon", "teaspoons"])
        add("tbsp", .volume, 0.01478676478125, ["tablespoon", "tablespoons"])
        add("fl oz", .volume, 0.0295735295625, ["floz", "fluid ounce", "fluid ounces", "fl. oz"])
        add("cup", .volume, 0.2365882365, ["cups"])
        add("pt", .volume, 0.473176473, ["pint", "pints"])
        add("qt", .volume, 0.946352946, ["quart", "quarts"])
        add("gal", .volume, 3.785411784, ["gallon", "gallons", "us gallon"])
        add("imp gal", .volume, 4.54609, ["imperial gallon", "imperial gallons", "uk gallon"])
        add("ft³", .volume, 28.316846592, ["ft3", "cubic foot", "cubic feet"])
        add("in³", .volume, 0.016387064, ["in3", "cubic inch", "cubic inches"])
        // Area (base: square metre)
        add("mm²", .area, 1e-6, ["mm2"])
        add("cm²", .area, 1e-4, ["cm2"])
        add("m²", .area, 1, ["m2", "square meter", "square meters", "square metre", "square metres"])
        add("km²", .area, 1e6, ["km2", "square kilometer", "square kilometers"])
        add("ha", .area, 1e4, ["hectare", "hectares"])
        add("a", .area, 100, ["are", "ares"], caseSensitive: true)
        add("in²", .area, 0.00064516, ["in2", "square inch", "square inches"])
        add("ft²", .area, 0.09290304, ["ft2", "square foot", "square feet"])
        add("yd²", .area, 0.83612736, ["yd2", "square yard", "square yards"])
        add("ac", .area, 4046.8564224, ["acre", "acres"])
        add("mi²", .area, 2_589_988.110336, ["mi2", "square mile", "square miles"])
        // Speed (base: metre per second)
        add("m/s", .speed, 1, ["mps", "meters per second", "metres per second"])
        add("km/h", .speed, 1 / 3.6, ["kmh", "kph", "kmph", "kilometers per hour", "kilometres per hour"])
        add("mph", .speed, 0.44704, ["mi/h", "miles per hour"])
        add("kn", .speed, 1852.0 / 3600, ["kt", "kts", "knot", "knots"])
        add("ft/s", .speed, 0.3048, ["fps", "feet per second"])
        add("mach", .speed, 340.29, ["ma"])
        add("c₀", .speed, 299_792_458, ["speed of light", "lightspeed"])
        // Data size (base: byte)
        add("bit", .dataSize, 0.125, ["bits", "b"], caseSensitive: true)
        add("B", .dataSize, 1, ["byte", "bytes"], caseSensitive: true)
        add("KB", .dataSize, 1e3, ["kb", "kilobyte", "kilobytes"], caseSensitive: true)
        add("MB", .dataSize, 1e6, ["mb", "megabyte", "megabytes"], caseSensitive: true)
        add("GB", .dataSize, 1e9, ["gb", "gigabyte", "gigabytes"], caseSensitive: true)
        add("TB", .dataSize, 1e12, ["tb", "terabyte", "terabytes"], caseSensitive: true)
        add("PB", .dataSize, 1e15, ["pb", "petabyte", "petabytes"], caseSensitive: true)
        add("KiB", .dataSize, 1024, ["kib", "kibibyte", "kibibytes"])
        add("MiB", .dataSize, 1_048_576, ["mib", "mebibyte", "mebibytes"])
        add("GiB", .dataSize, 1_073_741_824, ["gib", "gibibyte", "gibibytes"])
        add("TiB", .dataSize, 1_099_511_627_776, ["tib", "tebibyte", "tebibytes"])
        add("Kb", .dataSize, 125, ["kbit", "kilobit", "kilobits"], caseSensitive: true)
        add("Mb", .dataSize, 125_000, ["mbit", "megabit", "megabits"], caseSensitive: true)
        add("Gb", .dataSize, 125_000_000, ["gbit", "gigabit", "gigabits"], caseSensitive: true)
        add("Tb", .dataSize, 125_000_000_000, ["tbit", "terabit", "terabits"], caseSensitive: true)
        // Duration (base: second)
        add("ns", .duration, 1e-9, ["nanosecond", "nanoseconds"])
        add("µs", .duration, 1e-6, ["us", "microsecond", "microseconds"])
        add("ms", .duration, 1e-3, ["millisecond", "milliseconds", "msec"])
        add("s", .duration, 1, ["sec", "secs", "second", "seconds"])
        add("min", .duration, 60, ["mins", "minute", "minutes"])
        add("h", .duration, 3600, ["hr", "hrs", "hour", "hours"])
        add("d", .duration, 86400, ["day", "days"])
        add("wk", .duration, 604_800, ["w", "week", "weeks"])
        add("mo", .duration, 2_629_746, ["month", "months"])
        add("yr", .duration, 31_556_952, ["y", "year", "years"])
        add("decade", .duration, 315_569_520, ["decades"])
        add("century", .duration, 3_155_695_200, ["centuries"])
        // Angle (base: radian)
        add("deg", .angle, .pi / 180, ["degree", "degrees", "°"])
        add("rad", .angle, 1, ["radian", "radians"])
        add("grad", .angle, .pi / 200, ["gon", "gradian", "gradians"])
        add("turn", .angle, 2 * .pi, ["turns", "revolution", "revolutions", "rev"])
        add("arcmin", .angle, .pi / 10800, ["arcminute", "arcminutes"])
        add("arcsec", .angle, .pi / 648_000, ["arcsecond", "arcseconds"])
        // Pressure (base: pascal)
        add("Pa", .pressure, 1, ["pa", "pascal", "pascals"])
        add("hPa", .pressure, 100, ["hpa", "hectopascal", "hectopascals"])
        add("kPa", .pressure, 1000, ["kpa", "kilopascal", "kilopascals"])
        add("MPa", .pressure, 1e6, ["mpa", "megapascal"])
        add("bar", .pressure, 1e5, ["bars"])
        add("mbar", .pressure, 100, ["millibar", "millibars"])
        add("psi", .pressure, 6894.757293168, ["pounds per square inch"])
        add("atm", .pressure, 101_325, ["atmosphere", "atmospheres"])
        add("mmHg", .pressure, 133.322387415, ["mmhg", "torr"])
        // Energy (base: joule)
        add("J", .energy, 1, ["j", "joule", "joules"])
        add("kJ", .energy, 1000, ["kj", "kilojoule", "kilojoules"])
        add("cal", .energy, 4.184, ["calorie", "calories"])
        add("kcal", .energy, 4184, ["kilocalorie", "kilocalories", "cal_it"])
        add("Wh", .energy, 3600, ["wh", "watt hour", "watt hours"])
        add("kWh", .energy, 3_600_000, ["kwh", "kilowatt hour", "kilowatt hours"])
        add("eV", .energy, 1.602176634e-19, ["ev", "electronvolt", "electronvolts"])
        add("BTU", .energy, 1055.05585262, ["btu", "btus"])
        // Power (base: watt)
        add("W", .power, 1, ["w", "watt", "watts"])
        add("kW", .power, 1000, ["kw", "kilowatt", "kilowatts"])
        add("MW", .power, 1e6, ["megawatt", "megawatts"], caseSensitive: true)
        add("hp", .power, 745.69987158227022, ["horsepower"])
        add("PS", .power, 735.49875, ["metric horsepower"], caseSensitive: true)
        // Acceleration (base: metre per second squared)
        add("m/s²", .acceleration, 1, ["m/s2", "mps2"])
        add("ft/s²", .acceleration, 0.3048, ["ft/s2"])
        add("g₀", .acceleration, 9.80665, ["gee", "g-force", "gforce", "standard gravity"])
        return u
    }()

    /// Up to 10 significant digits, trimmed: `6.213711922`.
    static func format(_ v: Double) -> String {
        if v == 0 { return "0" }
        let magnitude = Swift.abs(v)
        if magnitude >= 1e15 || magnitude < 1e-9 { return CalcFormatter.decimal(v) }
        var s = String(format: "%.10g", v)
        if s.contains("e") { return CalcFormatter.decimal(v) }
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }
}
