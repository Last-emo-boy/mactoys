import CoreGraphics
import CoreVideo
import Foundation

/// Anything edge detection can read: a frozen capture or a live frame. Pixels are 32-bit
/// words in any channel order; they are only ever compared with each other.
public protocol PixelSource {
    var width: Int { get }
    var height: Int { get }
    func pixel(_ x: Int, _ y: Int) -> UInt32
}

/// A frozen capture as packed 32-bit pixels (RGBA, origin top-left).
public struct PixelBuffer: PixelSource {
    public let width: Int
    public let height: Int
    public let pixels: [UInt32]

    public init(width: Int, height: Int, pixels: [UInt32]) {
        precondition(pixels.count == width * height, "pixel count must match the size")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// Redraws an image into 8-bit RGBA.
    public init?(image: CGImage) {
        let w = image.width, h = image.height
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var words = [UInt32](repeating: 0, count: w * h)
        let drawn = words.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        self.init(width: w, height: h, pixels: words)
    }

    public func pixel(_ x: Int, _ y: Int) -> UInt32 { pixels[y * width + x] }
}

/// A locked BGRA `CVPixelBuffer` frame; only valid inside `LiveFrame.read`.
public struct LiveFrame: PixelSource {
    public let width: Int
    public let height: Int
    private let base: UnsafeRawPointer
    private let bytesPerRow: Int

    public func pixel(_ x: Int, _ y: Int) -> UInt32 {
        base.load(fromByteOffset: y * bytesPerRow + x * 4, as: UInt32.self)
    }

    /// Locks the buffer for reading and hands a pixel source to `body`.
    public static func read<T>(_ buffer: CVPixelBuffer, _ body: (LiveFrame) -> T) -> T? {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let frame = LiveFrame(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
                              base: UnsafeRawPointer(base), bytesPerRow: CVPixelBufferGetBytesPerRow(buffer))
        return body(frame)
    }
}

/// Inclusive pixel bounds: `width == right - left + 1`.
public struct PixelRect: Equatable, Sendable {
    public var left: Int
    public var top: Int
    public var right: Int
    public var bottom: Int

    public init(left: Int, top: Int, right: Int, bottom: Int) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }

    public var width: Int { right - left + 1 }
    public var height: Int { bottom - top + 1 }

    /// The pixels covered by a drag between two pixel positions (either order).
    public static func spanning(_ ax: Int, _ ay: Int, _ bx: Int, _ by: Int) -> PixelRect {
        PixelRect(left: min(ax, bx), top: min(ay, by), right: max(ax, bx), bottom: max(ay, by))
    }
}

/// Screen Ruler's edge detection, as PowerToys does it: from the start pixel, walk outward in
/// each direction until a pixel differs from the *start* pixel by more than the tolerance.
public enum EdgeDetector {
    /// Whether two pixels are within `tolerance`. Per channel: every channel differs by at most
    /// the tolerance. Otherwise: the summed channel differences are at most the tolerance.
    @inline(__always)
    public static func close(_ a: UInt32, _ b: UInt32, tolerance: Int, perChannel: Bool) -> Bool {
        var sum = 0
        var shift: UInt32 = 0
        while shift < 32 {
            let ca = Int((a >> shift) & 0xFF), cb = Int((b >> shift) & 0xFF)
            let d = abs(ca - cb)
            if perChannel {
                if d > tolerance { return false }
            } else {
                sum += d
            }
            shift += 8
        }
        return perChannel || sum <= tolerance
    }

    /// The last pixels in each direction still close to the pixel at (`x`, `y`). The start is
    /// clamped one pixel inside the border, so the result always spans at least that pixel.
    public static func edges<S: PixelSource>(in source: S, x: Int, y: Int, tolerance: Int,
                                             perChannel: Bool) -> PixelRect {
        let w = source.width, h = source.height
        guard w > 0, h > 0 else { return PixelRect(left: 0, top: 0, right: 0, bottom: 0) }
        let cx = w > 2 ? min(max(x, 1), w - 2) : min(max(x, 0), w - 1)
        let cy = h > 2 ? min(max(y, 1), h - 2) : min(max(y, 0), h - 1)
        let start = source.pixel(cx, cy)
        let t = max(0, tolerance)

        func walk(_ dx: Int, _ dy: Int) -> Int {
            var px = cx, py = cy
            while true {
                let nx = px + dx, ny = py + dy
                if nx < 0 || ny < 0 || nx >= w || ny >= h { return dx != 0 ? px : py }
                if !close(start, source.pixel(nx, ny), tolerance: t, perChannel: perChannel) {
                    return dx != 0 ? px : py
                }
                px = nx
                py = ny
            }
        }
        return PixelRect(left: walk(-1, 0), top: walk(0, -1), right: walk(1, 0), bottom: walk(0, 1))
    }
}

/// The extra unit shown next to pixels.
public enum RulerUnit: String, Codable, CaseIterable, Sendable, Identifiable {
    case none, points, inches, centimeters, millimeters
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .none: "Show only pixels"
        case .points: "Points (device-independent)"
        case .inches: "Inches"
        case .centimeters: "Centimeters"
        case .millimeters: "Millimeters"
        }
    }
    public var abbreviation: String {
        switch self {
        case .none: "px"
        case .points: "pt"
        case .inches: "in"
        case .centimeters: "cm"
        case .millimeters: "mm"
        }
    }
}

/// How pixels of one display convert to other units.
public struct DisplayMetrics: Equatable, Sendable {
    /// Capture pixels per point (the display's backing scale).
    public var pixelsPerPoint: Double
    /// Capture pixels per physical inch; 0 when the display doesn't report its size.
    public var pixelsPerInch: Double

    public init(pixelsPerPoint: Double, pixelsPerInch: Double) {
        self.pixelsPerPoint = pixelsPerPoint
        self.pixelsPerInch = pixelsPerInch
    }

    /// From the display's physical width in millimeters and its width in capture pixels.
    public init(pixelsPerPoint: Double, pixelWidth: Double, physicalWidthMM: Double) {
        self.init(pixelsPerPoint: pixelsPerPoint,
                  pixelsPerInch: physicalWidthMM > 0 ? pixelWidth / (physicalWidthMM / 25.4) : 0)
    }

    /// Converts a pixel length. Without a physical size, inches fall back to 72 points per inch.
    public func convert(_ pixels: Double, to unit: RulerUnit) -> Double {
        let ppi = pixelsPerInch > 0 ? pixelsPerInch : 72 * pixelsPerPoint
        switch unit {
        case .none: return pixels
        case .points: return pixels / pixelsPerPoint
        case .inches: return pixels / ppi
        case .centimeters: return pixels / ppi * 2.54
        case .millimeters: return pixels / ppi * 25.4
        }
    }
}

/// Measurement text for labels and the clipboard.
public enum MeasurementText {
    /// `"236 × 250 px"`, `"236 px"` …; with an extra unit a second line such as `"118 × 125 pt"`.
    public static func label(width: Int?, height: Int?, extra: RulerUnit, metrics: DisplayMetrics) -> String {
        var text = join(width.map(Double.init), height.map(Double.init), unit: .none, metrics: metrics) + " px"
        if extra != .none {
            text += "\n" + join(width.map(Double.init), height.map(Double.init), unit: extra, metrics: metrics) + " " + extra.abbreviation
        }
        return text
    }

    /// What a click copies: pixels only, without a unit (`"236 × 250"`), as PowerToys does.
    public static func clipboard(width: Int?, height: Int?) -> String {
        [width, height].compactMap { $0 }.map(String.init).joined(separator: " × ")
    }

    private static func join(_ w: Double?, _ h: Double?, unit: RulerUnit, metrics: DisplayMetrics) -> String {
        [w, h].compactMap { $0 }.map { number(metrics.convert($0, to: unit)) }.joined(separator: " × ")
    }

    /// Four significant digits like `%.4g`, never in exponent form for screen-sized values.
    public static func number(_ v: Double) -> String {
        if v == v.rounded() && abs(v) < 1e7 { return String(Int(v)) }
        let digits = max(0, 3 - Int(floor(log10(abs(v)))))
        var s = String(format: "%.\(digits)f", v)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }
}
