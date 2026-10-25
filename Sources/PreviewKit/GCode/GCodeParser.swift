import Foundation

/// Parses text G-code into a `GCodeToolpath`: G0/G1 lines, G2/G3 arcs (I/J or R), G90/G91,
/// M82/M83, G92, G20/G21, G28, layer changes, and slicer comments (thumbnails, time, filament).
public enum GCodeParser {
    /// Stop collecting points after this many (very large prints still preview, just not completely).
    public static let defaultPointLimit = 6_000_000

    public static func parse(_ text: String, pointLimit: Int = defaultPointLimit) -> GCodeToolpath {
        parse(Data(text.utf8), pointLimit: pointLimit)
    }

    public static func parse(_ data: Data, pointLimit: Int = defaultPointLimit) -> GCodeToolpath {
        var state = ParseState(pointLimit: pointLimit)
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var start = 0
            let n = bytes.count
            while start < n {
                var end = start
                while end < n && bytes[end] != 0x0A { end += 1 }
                state.line(bytes, start, end)
                start = end + 1
            }
        }
        state.finish()
        return state.path
    }
}

private struct ParseState {
    var path = GCodeToolpath()
    let pointLimit: Int
    var x = 0.0, y = 0.0, z = 0.0, e = 0.0
    var absolute = true
    var absoluteE = true
    var scale = 1.0
    var lastLayerZ = -Double.greatestFiniteMagnitude
    var layerHint: Int?
    var thumbnail: (width: Int, height: Int, format: GCodeThumbnail.Format, base64: String)?
    var timeSeconds: Double?

    init(pointLimit: Int) { self.pointLimit = pointLimit }

    // Word values by letter (A…Z) for the current line.
    var values = [Double](repeating: 0, count: 26)
    var present: UInt32 = 0
    var gCodes: [Double] = []
    var mCodes: [Int] = []

    func has(_ letter: Unicode.Scalar) -> Bool { present & (1 << (letter.value - 65)) != 0 }
    func value(_ letter: Unicode.Scalar) -> Double { values[Int(letter.value) - 65] }

    mutating func line(_ b: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int) {
        path.lineCount += 1
        var i = start
        while i < end && (b[i] == 0x20 || b[i] == 0x09) { i += 1 }
        guard i < end else { return }
        if b[i] == UInt8(ascii: ";") {
            comment(String(decoding: UnsafeBufferPointer(rebasing: b[(i + 1)..<end]), as: UTF8.self))
            return
        }
        if thumbnail != nil { return }
        present = 0
        gCodes.removeAll(keepingCapacity: true)
        mCodes.removeAll(keepingCapacity: true)
        while i < end {
            let c = b[i]
            if c == UInt8(ascii: ";") { break }
            if c == UInt8(ascii: "(") {
                while i < end && b[i] != UInt8(ascii: ")") { i += 1 }
                i += 1
                continue
            }
            var letter = c
            if letter >= 0x61 && letter <= 0x7A { letter -= 32 }
            guard letter >= 0x41 && letter <= 0x5A else { i += 1; continue }
            i += 1
            while i < end && (b[i] == 0x20 || b[i] == 0x09) { i += 1 }
            guard let (v, next) = number(b, i, end) else { continue }
            i = next
            let idx = Int(letter - 0x41)
            if letter == UInt8(ascii: "G") { gCodes.append(v) }
            else if letter == UInt8(ascii: "M") { mCodes.append(Int(v)) }
            else { values[idx] = v; present |= 1 << UInt32(idx) }
        }
        for m in mCodes {
            if m == 82 { absoluteE = true } else if m == 83 { absoluteE = false }
        }
        for g in gCodes { command(g) }
    }

    /// A decimal number (sign, digits, fraction) starting at `i`.
    func number(_ b: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int) -> (Double, Int)? {
        var i = start
        var negative = false
        if i < end && (b[i] == UInt8(ascii: "-") || b[i] == UInt8(ascii: "+")) { negative = b[i] == UInt8(ascii: "-"); i += 1 }
        var value = 0.0
        var digits = 0
        while i < end, b[i] >= 0x30, b[i] <= 0x39 { value = value * 10 + Double(b[i] - 0x30); i += 1; digits += 1 }
        if i < end && b[i] == UInt8(ascii: ".") {
            i += 1
            var f = 0.1
            while i < end, b[i] >= 0x30, b[i] <= 0x39 { value += Double(b[i] - 0x30) * f; f *= 0.1; i += 1; digits += 1 }
        }
        guard digits > 0 else { return nil }
        // No exponents: in "Y5E3" the E is the extrusion word, not 5×10³.
        return (negative ? -value : value, i)
    }

    mutating func command(_ g: Double) {
        switch g {
        case 0, 1: linear(rapid: g == 0)
        case 2, 3: arc(clockwise: g == 2)
        case 20: scale = 25.4
        case 21: scale = 1
        case 28:
            let axes = has("X") || has("Y") || has("Z")
            if !axes || has("X") { x = 0 }
            if !axes || has("Y") { y = 0 }
            if !axes || has("Z") { z = 0 }
            addPoint(.rapid)
        case 90: absolute = true; absoluteE = true
        case 91: absolute = false; absoluteE = false
        case 92:
            let any = has("X") || has("Y") || has("Z") || has("E")
            if has("X") { x = value("X") * scale }
            if has("Y") { y = value("Y") * scale }
            if has("Z") { z = value("Z") * scale }
            if has("E") || !any { e = has("E") ? value("E") * scale : 0 }
            setCurrentPoint()
        default: break
        }
    }

    /// Target of a move along one axis.
    func target(_ letter: Unicode.Scalar, current: Double) -> Double {
        guard has(letter) else { return current }
        let v = value(letter) * scale
        return absolute ? v : current + v
    }

    /// Consumes the line's `E` word; returns whether it extrudes.
    mutating func extrusion() -> Bool {
        guard has("E") else { return false }
        let v = value("E") * scale
        let delta = absoluteE ? v - e : v
        e = absoluteE ? v : e + v
        if delta > 1e-5 { path.filamentMM += delta; return true }
        return false
    }

    mutating func linear(rapid: Bool) {
        let nx = target("X", current: x), ny = target("Y", current: y), nz = target("Z", current: z)
        let extruding = !rapid && extrusion()
        if rapid { _ = extrusion() }
        guard nx != x || ny != y || nz != z else { return }
        x = nx; y = ny; z = nz
        addPoint(extruding ? .extrude : (rapid ? .rapid : .feed))
    }

    mutating func arc(clockwise: Bool) {
        let sx = x, sy = y, sz = z
        let ex = target("X", current: x), ey = target("Y", current: y), ez = target("Z", current: z)
        let extruding = extrusion()
        var cx: Double, cy: Double
        if has("I") || has("J") {
            cx = sx + (has("I") ? value("I") * scale : 0)
            cy = sy + (has("J") ? value("J") * scale : 0)
        } else if has("R") {
            // Center from radius: the one to the right (G2) or left (G3) of the chord; negative R takes the long way.
            let r = value("R") * scale
            let dx = ex - sx, dy = ey - sy
            let d = (dx * dx + dy * dy).squareRoot()
            guard d > 0, abs(r) * 2 >= d - 1e-9 else { x = ex; y = ey; z = ez; addPoint(extruding ? .extrude : .feed); return }
            let h = (max(0, r * r - d * d / 4)).squareRoot()
            let mx = (sx + ex) / 2, my = (sy + ey) / 2
            var sign: Double = clockwise ? -1 : 1
            if r < 0 { sign = -sign }
            cx = mx - sign * h * dy / d
            cy = my + sign * h * dx / d
        } else {
            x = ex; y = ey; z = ez
            addPoint(extruding ? .extrude : .feed)
            return
        }
        let radius = ((sx - cx) * (sx - cx) + (sy - cy) * (sy - cy)).squareRoot()
        let a0 = atan2(sy - cy, sx - cx)
        var a1 = atan2(ey - cy, ex - cx)
        if clockwise { if a1 >= a0 - 1e-12 { a1 -= 2 * .pi } } else { if a1 <= a0 + 1e-12 { a1 += 2 * .pi } }
        let sweep = a1 - a0
        let segments = max(1, min(720, Int((abs(sweep) * radius / 0.4).rounded(.up))))
        let kind: GCodeToolpath.MoveKind = extruding ? .extrude : .feed
        for k in 1...segments {
            let t = Double(k) / Double(segments)
            let a = a0 + sweep * t
            if k == segments { x = ex; y = ey } else { x = cx + radius * cos(a); y = cy + radius * sin(a) }
            z = sz + (ez - sz) * t
            addPoint(kind)
        }
    }

    mutating func addPoint(_ kind: GCodeToolpath.MoveKind) {
        guard !path.truncated else { return }
        guard path.kinds.count < pointLimit else { path.truncated = true; return }
        if kind == .extrude {
            path.hasExtrusion = true
            if z > lastLayerZ + 0.01 { path.layerCount += 1; lastLayerZ = z }
        }
        path.xs.append(Float(x)); path.ys.append(Float(y)); path.zs.append(Float(z))
        path.kinds.append(kind)
    }

    /// G92 moves the coordinate origin: start a fresh point there without drawing a move.
    mutating func setCurrentPoint() {
        guard !path.truncated, path.kinds.count < pointLimit else { return }
        path.xs.append(Float(x)); path.ys.append(Float(y)); path.zs.append(Float(z))
        path.kinds.append(.rapid)
    }

    // MARK: Comments

    mutating func comment(_ raw: String) {
        let c = raw.trimmingCharacters(in: .whitespaces)
        if var t = thumbnail {
            if c.hasPrefix("thumbnail") && c.hasSuffix("end") {
                if let data = Data(base64Encoded: t.base64, options: .ignoreUnknownCharacters) {
                    path.thumbnails.append(GCodeThumbnail(width: t.width, height: t.height, format: t.format, data: data))
                }
                thumbnail = nil
            } else {
                t.base64 += c
                thumbnail = t
            }
            return
        }
        if c.hasPrefix("thumbnail") && c.contains(" begin") {
            // "thumbnail begin 300x300 12345", "thumbnail_JPG begin …", "thumbnail_QOI begin …"
            let format: GCodeThumbnail.Format = c.hasPrefix("thumbnail_JPG") ? .jpg : c.hasPrefix("thumbnail_QOI") ? .qoi : .png
            let parts = c.split(separator: " ")
            let dims = parts.first { $0.contains("x") && $0.first?.isNumber == true }?.split(separator: "x").compactMap { Int($0) } ?? []
            thumbnail = (dims.first ?? 0, dims.count > 1 ? dims[1] : 0, format, "")
            return
        }
        let lower = c.lowercased()
        if path.slicer == nil, lower.hasPrefix("generated by ") || lower.hasPrefix("generated with ") {
            let name = c.dropFirst(lower.hasPrefix("generated by ") ? 13 : 15)
            path.slicer = name.components(separatedBy: " on ").first.map { $0.replacingOccurrences(of: "_SteamEngine", with: "") }
        } else if lower.hasPrefix("time:"), let s = Double(c.dropFirst(5).trimmingCharacters(in: .whitespaces)) {
            timeSeconds = s
        } else if lower.hasPrefix("estimated printing time"), path.estimatedTime == nil, lower.contains("normal") || !lower.contains("silent"),
                  let eq = c.firstIndex(of: "=") {
            path.estimatedTime = c[c.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        } else if lower.hasPrefix("layer_count:"), let n = Int(c.dropFirst(12)) {
            layerHint = n
        }
    }

    mutating func finish() {
        if path.estimatedTime == nil, let s = timeSeconds { path.estimatedTime = GCodeParser.duration(s) }
        if let hint = layerHint, path.layerCount == 0 || abs(hint - path.layerCount) > 1 { path.layerCount = hint }
    }
}

extension GCodeParser {
    /// "1h 2m" style, in the user's language: days–hours–minutes, hours–minutes, or minutes–seconds.
    static func duration(_ seconds: Double, locale: Locale = .current) -> String {
        let total = Int(seconds.rounded())
        let units: Set<Duration.UnitsFormatStyle.Unit> = total >= 86400 ? [.days, .hours, .minutes]
            : total >= 3600 ? [.hours, .minutes] : total >= 60 ? [.minutes, .seconds] : [.seconds]
        return Duration.seconds(total).formatted(.units(allowed: units, width: .narrow, zeroValueUnits: .show(length: 1),
                                                        fractionalPart: .hide(rounded: .down)).locale(locale))
    }
}
