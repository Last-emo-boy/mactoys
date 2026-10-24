import CoreGraphics
import Foundation

/// Decoder for the Quite OK Image format (https://qoiformat.org/qoi-specification.pdf).
public enum QOI {
    public struct Header: Equatable, Sendable {
        public var width: Int
        public var height: Int
        /// 3 = RGB, 4 = RGBA.
        public var channels: Int
        /// 0 = sRGB with linear alpha, 1 = all channels linear.
        public var colorspace: Int
    }

    public enum DecodeError: Error, Equatable {
        case notQOI, invalidHeader, truncated, tooLarge
    }

    /// Images larger than this many pixels are refused (the reference decoder's limit).
    public static let maxPixels = 400_000_000

    public static func header(_ data: Data) throws -> Header {
        guard data.count >= 14 else { throw DecodeError.notQOI }
        return try data.withUnsafeBytes { raw -> Header in
            let b = raw.bindMemory(to: UInt8.self)
            guard b[0] == 0x71, b[1] == 0x6F, b[2] == 0x69, b[3] == 0x66 else { throw DecodeError.notQOI }
            func u32(_ o: Int) -> Int { Int(b[o]) << 24 | Int(b[o + 1]) << 16 | Int(b[o + 2]) << 8 | Int(b[o + 3]) }
            let h = Header(width: u32(4), height: u32(8), channels: Int(b[12]), colorspace: Int(b[13]))
            guard h.width > 0, h.height > 0, h.channels == 3 || h.channels == 4, h.colorspace <= 1 else {
                throw DecodeError.invalidHeader
            }
            guard h.width.multipliedReportingOverflow(by: h.height).overflow == false,
                  h.width * h.height <= maxPixels else { throw DecodeError.tooLarge }
            return h
        }
    }

    /// Decodes to RGBA8 pixels (4 bytes per pixel, unpremultiplied), whatever the file's channel count.
    public static func decodeRGBA(_ data: Data) throws -> (Header, [UInt8]) {
        let h = try header(data)
        let pixelCount = h.width * h.height
        var out = [UInt8](repeating: 0, count: pixelCount * 4)
        try data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            let chunksEnd = bytes.count - 8          // end marker: 7 × 0x00, 0x01
            guard chunksEnd >= 14 else { throw DecodeError.truncated }
            var index = [UInt8](repeating: 0, count: 64 * 4)
            var r: UInt8 = 0, g: UInt8 = 0, b: UInt8 = 0, a: UInt8 = 255
            var p = 14
            var run = 0
            for px in 0..<pixelCount {
                if run > 0 {
                    run -= 1
                } else if p < chunksEnd {
                    let b1 = bytes[p]
                    p += 1
                    if b1 == 0xFE {                                   // QOI_OP_RGB
                        guard p + 3 <= bytes.count else { throw DecodeError.truncated }
                        r = bytes[p]; g = bytes[p + 1]; b = bytes[p + 2]
                        p += 3
                    } else if b1 == 0xFF {                            // QOI_OP_RGBA
                        guard p + 4 <= bytes.count else { throw DecodeError.truncated }
                        r = bytes[p]; g = bytes[p + 1]; b = bytes[p + 2]; a = bytes[p + 3]
                        p += 4
                    } else {
                        switch b1 >> 6 {
                        case 0:                                         // QOI_OP_INDEX
                            let i = Int(b1) * 4
                            r = index[i]; g = index[i + 1]; b = index[i + 2]; a = index[i + 3]
                        case 1:                                         // QOI_OP_DIFF
                            r = r &+ ((b1 >> 4) & 0x03) &- 2
                            g = g &+ ((b1 >> 2) & 0x03) &- 2
                            b = b &+ (b1 & 0x03) &- 2
                        case 2:                                         // QOI_OP_LUMA
                            guard p < bytes.count else { throw DecodeError.truncated }
                            let b2 = bytes[p]
                            p += 1
                            let vg = (b1 & 0x3F) &- 32
                            r = r &+ vg &- 8 &+ ((b2 >> 4) & 0x0F)
                            g = g &+ vg
                            b = b &+ vg &- 8 &+ (b2 & 0x0F)
                        default:                                        // QOI_OP_RUN
                            run = Int(b1 & 0x3F)
                        }
                    }
                    let slot = (Int(r) * 3 + Int(g) * 5 + Int(b) * 7 + Int(a) * 11) % 64 * 4
                    index[slot] = r; index[slot + 1] = g; index[slot + 2] = b; index[slot + 3] = a
                }
                // Past the last chunk the previous pixel repeats, as in the reference decoder.
                let o = px * 4
                out[o] = r; out[o + 1] = g; out[o + 2] = b; out[o + 3] = h.channels == 4 ? a : 255
            }
        }
        return (h, out)
    }

    /// Decodes into a `CGImage`.
    public static func image(_ data: Data) throws -> CGImage {
        let (h, pixels) = try decodeRGBA(data)
        let space = h.colorspace == 1 ? CGColorSpace(name: CGColorSpace.linearSRGB) : CGColorSpace(name: CGColorSpace.sRGB)
        let alpha: CGImageAlphaInfo = h.channels == 4 ? .last : .noneSkipLast
        guard let colorSpace = space,
              let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: h.width, height: h.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: h.width * 4, space: colorSpace,
                                  bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw DecodeError.invalidHeader }
        return image
    }
}
