import Foundation
import ImageIO

/// The photo metadata variables (EXIF, TIFF, GPS, IPTC through ImageIO) usable in *Replace with*.
public enum PhotoMetadata {
    /// Token names without `$`, as in PowerToys.
    public static let tokens: [String] = [
        "CAMERA_MAKE", "CAMERA_MODEL", "LENS", "ISO", "APERTURE", "SHUTTER", "FOCAL", "FLASH",
        "WIDTH", "HEIGHT", "AUTHOR", "COPYRIGHT", "LATITUDE", "LONGITUDE", "ALTITUDE",
        "DATE_TAKEN_YYYY", "DATE_TAKEN_YY", "DATE_TAKEN_MM", "DATE_TAKEN_DD", "DATE_TAKEN_HH",
        "DATE_TAKEN_mm", "DATE_TAKEN_SS", "EXPOSURE_BIAS", "ORIENTATION", "COLOR_SPACE",
    ]

    /// Token and localized description, for the variables menu.
    public static let help: [(token: String, meaning: String)] = [
        ("$CAMERA_MAKE", String(localized: "Camera manufacturer")), ("$CAMERA_MODEL", String(localized: "Camera model")),
        ("$LENS", String(localized: "Lens model")), ("$ISO", String(localized: "ISO sensitivity")),
        ("$APERTURE", String(localized: "Aperture, e.g. f2.8", comment: "PowerRename photo variable; keep the sample value f2.8")),
        ("$SHUTTER", String(localized: "Shutter speed, e.g. 1-250s", comment: "PowerRename photo variable; keep the sample value 1-250s")),
        ("$FOCAL", String(localized: "Focal length, e.g. 35mm", comment: "PowerRename photo variable; keep the sample value 35mm")),
        ("$FLASH", String(localized: "Flash On or Off", comment: "PowerRename photo variable; the value written is the English word On or Off")),
        ("$WIDTH", String(localized: "Width in pixels")), ("$HEIGHT", String(localized: "Height in pixels")),
        ("$AUTHOR", String(localized: "Author or artist")),
        ("$COPYRIGHT", String(localized: "Copyright", comment: "PowerRename photo variable: the picture's copyright notice")),
        ("$LATITUDE", String(localized: "GPS latitude")), ("$LONGITUDE", String(localized: "GPS longitude")),
        ("$ALTITUDE", String(localized: "GPS altitude in meters")),
        ("$DATE_TAKEN_YYYY", String(localized: "Year taken")),
        ("$DATE_TAKEN_YY", String(localized: "Year taken, two digits")),
        ("$DATE_TAKEN_MM", String(localized: "Month taken")), ("$DATE_TAKEN_DD", String(localized: "Day taken")),
        ("$DATE_TAKEN_HH", String(localized: "Hour taken")), ("$DATE_TAKEN_mm", String(localized: "Minute taken")),
        ("$DATE_TAKEN_SS", String(localized: "Second taken")),
        ("$EXPOSURE_BIAS", String(localized: "Exposure compensation")),
        ("$ORIENTATION", String(localized: "Orientation (1–8)", comment: "PowerRename photo variable: the EXIF orientation number")),
        ("$COLOR_SPACE", String(localized: "Color space")),
    ]

    /// Longest first, so `$DATE_TAKEN_YYYY` wins over `$DATE_TAKEN_YY`.
    private static let byLength = tokens.sorted { $0.count > $1.count }
    static let longestToken = byLength.first?.count ?? 0

    /// The token the text (right after `$`) starts with.
    public static func match(_ text: String) -> String? {
        byLength.first { text.hasPrefix($0) }
    }

    /// Reads the variables of an image file; empty for anything ImageIO can't read.
    public static func read(_ url: URL) -> [String: String] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else { return [:] }
        return values(from: props)
    }

    /// Builds the variables from an ImageIO property dictionary.
    public static func values(from props: [String: Any]) -> [String: String] {
        let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let exifAux = props[kCGImagePropertyExifAuxDictionary as String] as? [String: Any] ?? [:]
        let gps = props[kCGImagePropertyGPSDictionary as String] as? [String: Any] ?? [:]
        let iptc = props[kCGImagePropertyIPTCDictionary as String] as? [String: Any] ?? [:]
        var v: [String: String] = [:]
        func set(_ key: String, _ value: String?) {
            if let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty { v[key] = value }
        }
        func number(_ any: Any?) -> Double? {
            if let n = any as? NSNumber { return n.doubleValue }
            if let a = any as? [NSNumber], let first = a.first { return first.doubleValue }
            return nil
        }
        set("CAMERA_MAKE", tiff[kCGImagePropertyTIFFMake as String] as? String)
        set("CAMERA_MODEL", tiff[kCGImagePropertyTIFFModel as String] as? String)
        set("LENS", exif[kCGImagePropertyExifLensModel as String] as? String
            ?? exifAux[kCGImagePropertyExifAuxLensModel as String] as? String)
        if let iso = number(exif[kCGImagePropertyExifISOSpeedRatings as String]) { set("ISO", String(Int(iso))) }
        if let f = number(exif[kCGImagePropertyExifFNumber as String]) { set("APERTURE", "f" + trim(f, digits: 1)) }
        if let t = number(exif[kCGImagePropertyExifExposureTime as String]), t > 0 {
            set("SHUTTER", t >= 1 ? trim(t, digits: 1) + "s" : "1-\(Int((1 / t).rounded()))s")
        }
        if let focal = number(exif[kCGImagePropertyExifFocalLength as String]) { set("FOCAL", trim(focal, digits: 1) + "mm") }
        if let flash = number(exif[kCGImagePropertyExifFlash as String]) { set("FLASH", Int(flash) & 1 == 1 ? "On" : "Off") }
        if let w = number(props[kCGImagePropertyPixelWidth as String]) { set("WIDTH", String(Int(w))) }
        if let h = number(props[kCGImagePropertyPixelHeight as String]) { set("HEIGHT", String(Int(h))) }
        set("AUTHOR", tiff[kCGImagePropertyTIFFArtist as String] as? String
            ?? (iptc[kCGImagePropertyIPTCByline as String] as? [String])?.first)
        set("COPYRIGHT", tiff[kCGImagePropertyTIFFCopyright as String] as? String
            ?? iptc[kCGImagePropertyIPTCCopyrightNotice as String] as? String)
        if let lat = number(gps[kCGImagePropertyGPSLatitude as String]) {
            let south = (gps[kCGImagePropertyGPSLatitudeRef as String] as? String)?.uppercased() == "S"
            set("LATITUDE", trim(south ? -lat : lat, digits: 6))
        }
        if let lon = number(gps[kCGImagePropertyGPSLongitude as String]) {
            let west = (gps[kCGImagePropertyGPSLongitudeRef as String] as? String)?.uppercased() == "W"
            set("LONGITUDE", trim(west ? -lon : lon, digits: 6))
        }
        if let alt = number(gps[kCGImagePropertyGPSAltitude as String]) {
            let below = number(gps[kCGImagePropertyGPSAltitudeRef as String]) == 1
            set("ALTITUDE", trim(below ? -alt : alt, digits: 1) + "m")
        }
        if let taken = (exif[kCGImagePropertyExifDateTimeOriginal as String] as? String)
            ?? (tiff[kCGImagePropertyTIFFDateTime as String] as? String) {
            // "yyyy:MM:dd HH:mm:ss"
            let parts = taken.split(whereSeparator: { $0 == ":" || $0 == " " }).map(String.init)
            if parts.count >= 6, parts[0].count == 4 {
                set("DATE_TAKEN_YYYY", parts[0])
                set("DATE_TAKEN_YY", String(parts[0].suffix(2)))
                set("DATE_TAKEN_MM", parts[1])
                set("DATE_TAKEN_DD", parts[2])
                set("DATE_TAKEN_HH", parts[3])
                set("DATE_TAKEN_mm", parts[4])
                set("DATE_TAKEN_SS", String(parts[5].prefix(2)))
            }
        }
        if let bias = number(exif[kCGImagePropertyExifExposureBiasValue as String]) {
            set("EXPOSURE_BIAS", (bias > 0 ? "+" : "") + trim(bias, digits: 1) + "EV")
        }
        if let o = number(props[kCGImagePropertyOrientation as String]) { set("ORIENTATION", String(Int(o))) }
        if let cs = number(exif[kCGImagePropertyExifColorSpace as String]) {
            set("COLOR_SPACE", Int(cs) == 1 ? "sRGB" : "Uncalibrated")
        } else {
            set("COLOR_SPACE", props[kCGImagePropertyProfileName as String] as? String)
        }
        return v
    }

    /// `2.80` → "2.8", `50.0` → "50".
    static func trim(_ value: Double, digits: Int) -> String {
        var s = String(format: "%.\(digits)f", value)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s == "-0" ? "0" : s
    }
}
