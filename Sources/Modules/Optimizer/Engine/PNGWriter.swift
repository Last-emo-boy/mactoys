import Foundation
import zlib

/// Writes palette (indexed-color) PNGs, which ImageIO can't produce with transparency.
///
/// Chunks: IHDR, sRGB or iCCP (the color profile), pHYs (resolution, so Retina screenshots keep
/// their point size), PLTE, tRNS (only entries up to the last translucent one), IDAT, IEND.
/// Small palettes use 1, 2 or 4 bits per pixel. Rows use filter type None, which suits palette data,
/// and are deflated at level 9.
enum PNGWriter {
    enum Failure: Error { case compression(Int32) }

    struct ColorProfile: Sendable {
        /// Write the small sRGB chunk instead of a full profile.
        var isSRGB: Bool
        var iccData: Data?
        var name = "ICC Profile"
    }

    /// - Parameters:
    ///   - palette: premultiplied entries; written un-premultiplied, translucent entries first.
    ///   - indices: one index per pixel, row by row.
    static func indexed(width: Int, height: Int, palette: [PaletteColor], indices: [UInt8],
                        profile: ColorProfile?, dpi: Double?) throws -> Data {
        precondition(!palette.isEmpty && palette.count <= 256 && indices.count == width * height)
        let (ordered, remap) = orderForTransparency(palette, used: indices)
        let depth = bitDepth(forColors: ordered.count)

        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var ihdr = Data()
        ihdr.appendBE(UInt32(width))
        ihdr.appendBE(UInt32(height))
        ihdr.append(contentsOf: [UInt8(depth), 3, 0, 0, 0])   // depth, palette color, deflate, filter 0, no interlace
        appendChunk("IHDR", ihdr, to: &png)

        if let profile {
            if profile.isSRGB {
                appendChunk("sRGB", Data([0]), to: &png)   // perceptual intent
            } else if let icc = profile.iccData {
                var iccp = Data(profile.name.utf8.prefix(79))
                iccp.append(contentsOf: [0, 0])                // name terminator, deflate
                iccp.append(try deflate(icc))
                appendChunk("iCCP", iccp, to: &png)
            }
        }
        if let dpi, dpi > 0 {
            var phys = Data()
            let perMeter = UInt32((dpi / 0.0254).rounded())
            phys.appendBE(perMeter)
            phys.appendBE(perMeter)
            phys.append(1)                                     // unit: meter
            appendChunk("pHYs", phys, to: &png)
        }

        var plte = Data(capacity: ordered.count * 3)
        var trns = Data()
        for c in ordered {
            let s = c.straight
            plte.append(contentsOf: [s.r, s.g, s.b])
            if s.a < 255 { trns.append(s.a) }
        }
        appendChunk("PLTE", plte, to: &png)
        if !trns.isEmpty { appendChunk("tRNS", trns, to: &png) }

        appendChunk("IDAT", try deflate(packRows(width: width, height: height, indices: indices, remap: remap, depth: depth)), to: &png)
        appendChunk("IEND", Data(), to: &png)
        return png
    }

    /// 1, 2, 4 or 8 bits per pixel.
    static func bitDepth(forColors n: Int) -> Int {
        switch n {
        case ...2: 1
        case ...4: 2
        case ...16: 4
        default: 8
        }
    }

    /// Drops unused entries and puts translucent ones first (tRNS then stays short).
    /// Returns the new palette and a table old index → new index.
    static func orderForTransparency(_ palette: [PaletteColor], used indices: [UInt8]) -> ([PaletteColor], [UInt8]) {
        var usage = [Int](repeating: 0, count: palette.count)
        for i in indices { usage[Int(i)] += 1 }
        let order = palette.indices.filter { usage[$0] > 0 }.sorted { a, b in
            let ta = palette[a].a < 255, tb = palette[b].a < 255
            if ta != tb { return ta }
            return usage[a] != usage[b] ? usage[a] > usage[b] : a < b
        }
        var remap = [UInt8](repeating: 0, count: palette.count)
        for (new, old) in order.enumerated() { remap[old] = UInt8(new) }
        return (order.map { palette[$0] }, remap)
    }

    /// Scanlines with a leading filter byte (None) and pixels packed most significant bits first.
    static func packRows(width: Int, height: Int, indices: [UInt8], remap: [UInt8], depth: Int) -> Data {
        let perByte = 8 / depth
        let rowBytes = (width + perByte - 1) / perByte
        var out = [UInt8](repeating: 0, count: (rowBytes + 1) * height)
        indices.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for y in 0..<height {
                    let row = y * (rowBytes + 1)
                    dst[row] = 0
                    let base = y * width
                    if depth == 8 {
                        for x in 0..<width { dst[row + 1 + x] = remap[Int(src[base + x])] }
                    } else {
                        for x in 0..<width {
                            let v = remap[Int(src[base + x])]
                            let shift = 8 - depth * (x % perByte + 1)
                            dst[row + 1 + x / perByte] |= v << shift
                        }
                    }
                }
            }
        }
        return Data(out)
    }

    /// zlib-wrapped deflate at maximum compression (the format of IDAT and iCCP data).
    static func deflate(_ input: Data) throws -> Data {
        var stream = z_stream()
        var status = deflateInit2_(&stream, 9, Z_DEFLATED, 15, 9, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { throw Failure.compression(status) }
        defer { deflateEnd(&stream) }
        var output = Data(count: Int(deflateBound(&stream, uLong(input.count))))
        let produced: Int = input.withUnsafeBytes { src in
            output.withUnsafeMutableBytes { dst in
                stream.next_in = UnsafeMutablePointer(mutating: src.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(input.count)
                stream.next_out = dst.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(dst.count)
                status = zlib.deflate(&stream, Z_FINISH)
                return Int(stream.total_out)
            }
        }
        guard status == Z_STREAM_END else { throw Failure.compression(status) }
        return output.prefix(produced)
    }

    private static func appendChunk(_ type: String, _ data: Data, to png: inout Data) {
        png.appendBE(UInt32(data.count))
        var body = Data(type.utf8)
        body.append(data)
        png.append(body)
        let crc = body.withUnsafeBytes { raw in
            crc32(0, raw.bindMemory(to: Bytef.self).baseAddress, uInt(body.count))
        }
        png.appendBE(UInt32(crc))
    }
}

private extension Data {
    mutating func appendBE(_ v: UInt32) {
        append(contentsOf: [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
    }
}
