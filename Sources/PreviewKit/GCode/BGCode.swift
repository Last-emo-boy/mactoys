import Compression
import Foundation

/// Prusa binary G-code (`.bgcode`, libbgcode format v1): thumbnails, metadata and the G-code itself
/// (deflate or heatshrink compressed, optionally MeatPack encoded).
public enum BGCode {
    public enum DecodeError: Error, Equatable {
        case notBGCode, truncated, unsupported(String)
    }

    public struct File: Sendable {
        public var version: Int
        public var thumbnails: [GCodeThumbnail] = []
        /// Key/value pairs from the file, printer, print and slicer metadata blocks.
        public var metadata: [String: String] = [:]
        /// Decoded G-code text (when requested).
        public var gcode = Data()
    }

    enum BlockType: UInt16 { case fileMetadata = 0, gcode, slicerMetadata, printerMetadata, printMetadata, thumbnail }

    public static func isBGCode(_ data: Data) -> Bool {
        data.count >= 10 && data.prefix(4) == Data("GCDE".utf8)
    }

    /// Reads the blocks. With `decodeGCode: false` only metadata and thumbnails are read (fast).
    public static func parse(_ data: Data, decodeGCode: Bool = true) throws -> File {
        guard isBGCode(data) else { throw DecodeError.notBGCode }
        let bytes = [UInt8](data)
        func u16(_ o: Int) -> Int { Int(bytes[o]) | Int(bytes[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { Int(bytes[o]) | Int(bytes[o + 1]) << 8 | Int(bytes[o + 2]) << 16 | Int(bytes[o + 3]) << 24 }
        var file = File(version: u32(4))
        let checksumSize = u16(8) == 1 ? 4 : 0
        var p = 10
        while p + 8 <= bytes.count {
            let type = u16(p), compression = u16(p + 2), uncompressed = u32(p + 4)
            var header = 8
            var size = uncompressed
            if compression != 0 {
                guard p + 12 <= bytes.count else { throw DecodeError.truncated }
                size = u32(p + 8)
                header = 12
            }
            let paramSize = type == Int(BlockType.thumbnail.rawValue) ? 6 : 2
            let dataStart = p + header + paramSize
            let dataEnd = dataStart + size
            guard dataEnd <= bytes.count else { throw DecodeError.truncated }
            let params = p + header
            let payload = bytes[dataStart..<dataEnd]
            switch BlockType(rawValue: UInt16(type)) {
            case .thumbnail:
                let format: GCodeThumbnail.Format
                switch u16(params) {
                case 1: format = .jpg
                case 2: format = .qoi
                default: format = .png
                }
                if let raw = try? decompress(Array(payload), compression: compression, size: uncompressed) {
                    file.thumbnails.append(GCodeThumbnail(width: u16(params + 2), height: u16(params + 4), format: format, data: Data(raw)))
                }
            case .gcode:
                if decodeGCode {
                    let raw = try decompress(Array(payload), compression: compression, size: uncompressed)
                    let encoding = u16(params)
                    file.gcode.append(contentsOf: encoding == 0 ? raw : MeatPack.decode(raw))
                }
            case .fileMetadata, .slicerMetadata, .printerMetadata, .printMetadata:
                if let raw = try? decompress(Array(payload), compression: compression, size: uncompressed) {
                    for line in String(decoding: raw, as: UTF8.self).split(separator: "\n") {
                        guard let eq = line.firstIndex(of: "=") else { continue }
                        let key = line[..<eq].trimmingCharacters(in: .whitespaces)
                        let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                        if file.metadata[key] == nil { file.metadata[key] = value }
                    }
                }
            case nil:
                break
            }
            p = dataEnd + checksumSize
        }
        return file
    }

    static func decompress(_ input: [UInt8], compression: Int, size: Int) throws -> [UInt8] {
        switch compression {
        case 0: return input
        case 1: return try inflate(input, size: size)
        case 2: return Heatshrink.decode(input, windowBits: 11, lookaheadBits: 4, outputSize: size)
        case 3: return Heatshrink.decode(input, windowBits: 12, lookaheadBits: 4, outputSize: size)
        default: throw DecodeError.unsupported("compression \(compression)")
        }
    }

    /// zlib-wrapped deflate (libbgcode uses `deflateInit`): skip the 2-byte header, inflate the raw stream.
    static func inflate(_ input: [UInt8], size: Int) throws -> [UInt8] {
        var body = input[...]
        if input.count >= 2, input[0] & 0x0F == 8, (Int(input[0]) << 8 | Int(input[1])) % 31 == 0 { body = input.dropFirst(2) }
        guard !body.isEmpty, size > 0 else { return [] }
        var out = [UInt8](repeating: 0, count: size)
        let written = body.withUnsafeBufferPointer { src -> Int in
            out.withUnsafeMutableBufferPointer { dst -> Int in
                guard let s = src.baseAddress, let d = dst.baseAddress else { return 0 }
                return compression_decode_buffer(d, dst.count, s, src.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { throw DecodeError.unsupported("deflate") }
        return Array(out.prefix(written))
    }

    /// A toolpath with thumbnails and metadata from the binary file.
    public static func toolpath(_ data: Data, pointLimit: Int = GCodeParser.defaultPointLimit) throws -> GCodeToolpath {
        let file = try parse(data)
        var path = GCodeParser.parse(file.gcode, pointLimit: pointLimit)
        path.thumbnails = file.thumbnails + path.thumbnails
        if path.estimatedTime == nil {
            path.estimatedTime = file.metadata["estimated printing time (normal mode)"] ?? file.metadata["estimated printing time"]
        }
        if let mm = file.metadata["filament used [mm]"].flatMap(Double.init), mm > 0 { path.filamentMM = mm }
        if path.slicer == nil, let producer = file.metadata["Producer"] { path.slicer = producer }
        return path
    }
}

/// Heatshrink LZSS decoder (bit-exact with atomicobject/heatshrink): a 1 tag bit selects a literal
/// byte, 0 a back-reference of `windowBits` offset and `lookaheadBits` length, MSB first.
enum Heatshrink {
    static func decode(_ input: [UInt8], windowBits: Int, lookaheadBits: Int, outputSize: Int) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(outputSize)
        var bitPos = 0
        let totalBits = input.count * 8
        func bits(_ count: Int) -> Int? {
            guard bitPos + count <= totalBits else { return nil }
            var v = 0
            for _ in 0..<count {
                let byte = input[bitPos >> 3]
                v = v << 1 | Int((byte >> (7 - UInt8(bitPos & 7))) & 1)
                bitPos += 1
            }
            return v
        }
        while out.count < outputSize, let tag = bits(1) {
            if tag == 1 {
                guard let literal = bits(8) else { break }
                out.append(UInt8(literal))
            } else {
                guard let index = bits(windowBits), let count = bits(lookaheadBits) else { break }
                let offset = index + 1
                for _ in 0...count {
                    let from = out.count - offset
                    out.append(from >= 0 ? out[from] : 0)
                    if out.count == outputSize { break }
                }
            }
        }
        return out
    }
}

/// MeatPack decoder (as libbgcode's `MeatPack::unbinarize`): common G-code characters packed into
/// 4-bit codes, 0b1111 escaping a full byte, and `0xFF 0xFF <cmd>` control sequences.
enum MeatPack {
    static func decode(_ src: [UInt8]) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(src.count * 2)
        var packing = false
        var noSpaces = false
        var commandPending = false
        var signalCount = 0
        var fullCharQueue = 0
        var charBuffer: UInt8 = 0

        func table(_ code: UInt8) -> UInt8 {
            switch code {
            case 0...9: return 0x30 + code
            case 10: return UInt8(ascii: ".")
            case 11: return noSpaces ? UInt8(ascii: "E") : UInt8(ascii: " ")
            case 12: return 0x0A
            case 13: return UInt8(ascii: "G")
            case 14: return UInt8(ascii: "X")
            default: return 0
            }
        }

        func emit(_ c: UInt8) {
            // Collapse blank lines, as the reference does.
            if c == 0x0A, out.last == 0x0A { return }
            out.append(c)
        }

        func receive(_ c: UInt8) {
            guard packing else { emit(c); return }
            if fullCharQueue > 0 {
                emit(c)
                if charBuffer > 0 { emit(charBuffer); charBuffer = 0 }
                fullCharQueue -= 1
                return
            }
            let firstFull = c & 0x0F == 0x0F
            let secondFull = c & 0xF0 == 0xF0
            let first = table(c & 0x0F), second = table(c >> 4)
            if firstFull {
                fullCharQueue += 1
                if secondFull { fullCharQueue += 1 } else { charBuffer = second }
            } else {
                emit(first)
                if first != 0x0A {
                    if secondFull { fullCharQueue += 1 } else { emit(second) }
                }
            }
        }

        for byte in src {
            if byte == 0xFF {
                if signalCount > 0 { commandPending = true; signalCount = 0 } else { signalCount += 1 }
                continue
            }
            if commandPending {
                switch byte {
                case 251: packing = true
                case 250, 249: packing = false
                case 247: noSpaces = true
                case 246: noSpaces = false
                default: break
                }
                commandPending = false
                continue
            }
            if signalCount > 0 { receive(0xFF); signalCount = 0 }
            receive(byte)
        }
        return out
    }
}
