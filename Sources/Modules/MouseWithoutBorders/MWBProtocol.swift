import CoreGraphics
import Foundation

/// Mouse Without Borders wire protocol, version 1.
///
/// Every frame is `[u32 length][u8 version][u8 kind][payload]`, big-endian, where `length`
/// counts everything after itself. Kind 0 carries a plaintext message (only `hello` is accepted
/// in plaintext); kind 1 carries `[u64 counter][AES-GCM ciphertext][16-byte tag]`. A message
/// is `[u8 type][fields…]`; strings and blobs are length-prefixed.
enum MWBProtocol {
    static let version: UInt8 = 1
    static let serviceType = "_mactoys-mwb._tcp"
    static let defaultPort: UInt16 = 15101
    /// Largest frame accepted (file chunks are 256 KiB; clipboard images up to 8 MiB are split
    /// into the same chunked transfer as files).
    static let maxFrameLength = 1 << 21
    static let fileChunkSize = 256 * 1024
    /// Most text sent as one clipboard message.
    static let maxClipboardText = 1 << 20
    /// Most image data sent as one clipboard message.
    static let maxClipboardImage = (1 << 21) - 1024
}

enum MWBFrameKind: UInt8 {
    case plain = 0
    case sealed = 1
}

struct MWBFrame: Equatable {
    var kind: MWBFrameKind
    var payload: Data

    /// The frame on the wire, length prefix included.
    func encoded() -> Data {
        var w = BinaryWriter()
        w.u32(UInt32(payload.count + 2))
        w.u8(MWBProtocol.version)
        w.u8(kind.rawValue)
        w.raw(payload)
        return w.data
    }

    /// The two header bytes after the length, authenticated with sealed payloads.
    static func header(_ kind: MWBFrameKind) -> Data { Data([MWBProtocol.version, kind.rawValue]) }
}

enum MWBProtocolError: Error, Equatable {
    case frameTooLarge(Int)
    case unsupportedVersion(UInt8)
    case unknownFrameKind(UInt8)
    case truncated
    case unknownMessage(UInt8)
    case invalidField(String)
}

/// Splits a TCP byte stream into frames. Partial frames wait for more bytes.
struct FrameDecoder {
    private var buffer: [UInt8] = []
    private var start = 0

    var bufferedBytes: Int { buffer.count - start }

    mutating func append(_ data: Data) {
        if start > 0 && start == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            start = 0
        } else if start > 65536 {
            buffer.removeSubrange(0..<start)
            start = 0
        }
        buffer.append(contentsOf: data)
    }

    /// The next complete frame, nil when more bytes are needed. Throws on a malformed stream
    /// (the connection must then be closed).
    mutating func next() throws -> MWBFrame? {
        guard buffer.count - start >= 4 else { return nil }
        let length = Int(buffer[start]) << 24 | Int(buffer[start + 1]) << 16 | Int(buffer[start + 2]) << 8 | Int(buffer[start + 3])
        guard length >= 2 else { throw MWBProtocolError.truncated }
        guard length <= MWBProtocol.maxFrameLength else { throw MWBProtocolError.frameTooLarge(length) }
        guard buffer.count - start >= 4 + length else { return nil }
        let version = buffer[start + 4]
        guard version == MWBProtocol.version else { throw MWBProtocolError.unsupportedVersion(version) }
        guard let kind = MWBFrameKind(rawValue: buffer[start + 5]) else { throw MWBProtocolError.unknownFrameKind(buffer[start + 5]) }
        let payload = Data(buffer[(start + 6)..<(start + 4 + length)])
        start += 4 + length
        return MWBFrame(kind: kind, payload: payload)
    }
}

// MARK: - Messages

struct MWBHello: Equatable, Sendable {
    var protocolVersion: UInt16 = UInt16(MWBProtocol.version)
    var machineID: UUID
    var name: String
    /// 32 random bytes, fresh per connection; both nonces salt the session keys.
    var nonce: Data
    var listenPort: UInt16
}

struct MWBMachineInfo: Equatable, Sendable {
    var name: String
    /// Display frames in the machine's global top-left coordinates, primary first.
    var displays: [CGRect]
}

struct MWBLayoutMessage: Equatable, Sendable {
    var revision: Double
    var singleRow: Bool
    var wrap: Bool
    var slots: [MachineSlot?]
}

struct MWBMouseMove: Equatable, Sendable {
    var x: Double
    var y: Double
    var dx: Double
    var dy: Double
}

struct MWBMouseButton: Equatable, Sendable {
    /// 0 left, 1 right, 2 middle, higher for extra buttons.
    var button: UInt8
    var down: Bool
    var clickCount: UInt8
    var x: Double
    var y: Double
}

struct MWBScroll: Equatable, Sendable {
    /// Pixel deltas (vertical, horizontal).
    var dy: Double
    var dx: Double
    /// Line deltas for apps that use them.
    var lineDy: Int32
    var lineDx: Int32
    var phase: UInt8
    var momentumPhase: UInt8
    var continuous: Bool
}

struct MWBKey: Equatable, Sendable {
    var keyCode: UInt16
    var down: Bool
    var flags: UInt64
    var autorepeat: Bool
}

struct MWBMediaKey: Equatable, Sendable {
    var code: UInt8
    var down: Bool
    var autorepeat: Bool
}

struct MWBFileStart: Equatable, Sendable {
    enum Purpose: UInt8, Sendable { case clipboard = 0, send = 1 }
    var transferID: UInt32
    var name: String
    var size: UInt64
    var purpose: Purpose
}

struct MWBFileChunk: Equatable, Sendable {
    var transferID: UInt32
    var offset: UInt64
    var data: Data
}

struct MWBFileEnd: Equatable, Sendable {
    var transferID: UInt32
    var sha256: Data
}

enum MWBMessage: Equatable, Sendable {
    case hello(MWBHello)
    case authProof(Data)
    case heartbeat
    case machineInfo(MWBMachineInfo)
    case layout(MWBLayoutMessage)
    /// The sender takes control; the pointer appears at this point.
    case enter(x: Double, y: Double)
    /// The sender stops controlling this machine.
    case leave
    /// The receiver's user touched its own mouse or keyboard: give control back.
    case releaseControl
    case mouseMove(MWBMouseMove)
    case mouseButton(MWBMouseButton)
    case scroll(MWBScroll)
    case key(MWBKey)
    case mediaKey(MWBMediaKey)
    case clipboardText(String)
    case clipboardImage(Data)
    case fileStart(MWBFileStart)
    case fileChunk(MWBFileChunk)
    case fileEnd(MWBFileEnd)
    case fileCancel(UInt32)
    /// Someone is using a machine of the group: don't start the screen saver.
    case userActivity
    case lockScreen

    var type: UInt8 {
        switch self {
        case .hello: 1
        case .authProof: 2
        case .heartbeat: 3
        case .machineInfo: 4
        case .layout: 5
        case .enter: 10
        case .leave: 11
        case .releaseControl: 12
        case .mouseMove: 13
        case .mouseButton: 14
        case .scroll: 15
        case .key: 16
        case .mediaKey: 17
        case .clipboardText: 20
        case .clipboardImage: 21
        case .fileStart: 22
        case .fileChunk: 23
        case .fileEnd: 24
        case .fileCancel: 25
        case .userActivity: 30
        case .lockScreen: 31
        }
    }

    func encoded() -> Data {
        var w = BinaryWriter()
        w.u8(type)
        switch self {
        case .hello(let h):
            w.u16(h.protocolVersion)
            w.uuid(h.machineID)
            w.string(h.name)
            w.blob(h.nonce)
            w.u16(h.listenPort)
        case .authProof(let proof):
            w.blob(proof)
        case .heartbeat, .leave, .releaseControl, .userActivity, .lockScreen:
            break
        case .machineInfo(let m):
            w.string(m.name)
            w.u8(UInt8(min(m.displays.count, 16)))
            for d in m.displays.prefix(16) { w.rect(d) }
        case .layout(let l):
            w.f64(l.revision)
            w.bool(l.singleRow)
            w.bool(l.wrap)
            w.u8(UInt8(min(l.slots.count, 4)))
            for slot in l.slots.prefix(4) {
                if let slot {
                    w.bool(true)
                    w.uuid(slot.id)
                    w.string(slot.name)
                } else {
                    w.bool(false)
                }
            }
        case .enter(let x, let y):
            w.f64(x)
            w.f64(y)
        case .mouseMove(let m):
            w.f64(m.x); w.f64(m.y); w.f64(m.dx); w.f64(m.dy)
        case .mouseButton(let b):
            w.u8(b.button); w.bool(b.down); w.u8(b.clickCount); w.f64(b.x); w.f64(b.y)
        case .scroll(let s):
            w.f64(s.dy); w.f64(s.dx); w.i32(s.lineDy); w.i32(s.lineDx); w.u8(s.phase); w.u8(s.momentumPhase)
            w.bool(s.continuous)
        case .key(let k):
            w.u16(k.keyCode); w.bool(k.down); w.u64(k.flags); w.bool(k.autorepeat)
        case .mediaKey(let m):
            w.u8(m.code); w.bool(m.down); w.bool(m.autorepeat)
        case .clipboardText(let s):
            w.longBlob(Data(s.utf8))
        case .clipboardImage(let png):
            w.longBlob(png)
        case .fileStart(let f):
            w.u32(f.transferID); w.string(f.name); w.u64(f.size); w.u8(f.purpose.rawValue)
        case .fileChunk(let c):
            w.u32(c.transferID); w.u64(c.offset); w.longBlob(c.data)
        case .fileEnd(let e):
            w.u32(e.transferID); w.blob(e.sha256)
        case .fileCancel(let id):
            w.u32(id)
        }
        return w.data
    }

    static func decode(_ data: Data) throws -> MWBMessage {
        var r = BinaryReader(data)
        let type = try r.u8()
        let message: MWBMessage
        switch type {
        case 1:
            let version = try r.u16()
            let id = try r.uuid()
            let name = try r.string()
            let nonce = try r.blob()
            guard nonce.count == 32 else { throw MWBProtocolError.invalidField("nonce") }
            message = .hello(MWBHello(protocolVersion: version, machineID: id, name: name, nonce: nonce, listenPort: try r.u16()))
        case 2:
            let proof = try r.blob()
            guard proof.count == 32 else { throw MWBProtocolError.invalidField("proof") }
            message = .authProof(proof)
        case 3: message = .heartbeat
        case 4:
            let name = try r.string()
            let count = Int(try r.u8())
            guard count <= 16 else { throw MWBProtocolError.invalidField("displays") }
            var displays: [CGRect] = []
            for _ in 0..<count { displays.append(try r.rect()) }
            message = .machineInfo(MWBMachineInfo(name: name, displays: displays))
        case 5:
            let revision = try r.f64()
            let singleRow = try r.bool()
            let wrap = try r.bool()
            let count = Int(try r.u8())
            guard count <= 4 else { throw MWBProtocolError.invalidField("slots") }
            var slots: [MachineSlot?] = []
            for _ in 0..<count {
                if try r.bool() { slots.append(MachineSlot(id: try r.uuid(), name: try r.string())) } else { slots.append(nil) }
            }
            message = .layout(MWBLayoutMessage(revision: revision, singleRow: singleRow, wrap: wrap, slots: slots))
        case 10: message = .enter(x: try r.f64(), y: try r.f64())
        case 11: message = .leave
        case 12: message = .releaseControl
        case 13: message = .mouseMove(MWBMouseMove(x: try r.f64(), y: try r.f64(), dx: try r.f64(), dy: try r.f64()))
        case 14:
            message = .mouseButton(MWBMouseButton(button: try r.u8(), down: try r.bool(), clickCount: try r.u8(),
                                                  x: try r.f64(), y: try r.f64()))
        case 15:
            message = .scroll(MWBScroll(dy: try r.f64(), dx: try r.f64(), lineDy: try r.i32(), lineDx: try r.i32(),
                                        phase: try r.u8(), momentumPhase: try r.u8(), continuous: try r.bool()))
        case 16: message = .key(MWBKey(keyCode: try r.u16(), down: try r.bool(), flags: try r.u64(), autorepeat: try r.bool()))
        case 17: message = .mediaKey(MWBMediaKey(code: try r.u8(), down: try r.bool(), autorepeat: try r.bool()))
        case 20:
            guard let s = String(data: try r.longBlob(), encoding: .utf8) else { throw MWBProtocolError.invalidField("text") }
            message = .clipboardText(s)
        case 21: message = .clipboardImage(try r.longBlob())
        case 22:
            let id = try r.u32()
            let name = try r.string()
            let size = try r.u64()
            guard let purpose = MWBFileStart.Purpose(rawValue: try r.u8()) else { throw MWBProtocolError.invalidField("purpose") }
            message = .fileStart(MWBFileStart(transferID: id, name: name, size: size, purpose: purpose))
        case 23: message = .fileChunk(MWBFileChunk(transferID: try r.u32(), offset: try r.u64(), data: try r.longBlob()))
        case 24:
            let id = try r.u32()
            let hash = try r.blob()
            guard hash.count == 32 else { throw MWBProtocolError.invalidField("sha256") }
            message = .fileEnd(MWBFileEnd(transferID: id, sha256: hash))
        case 25: message = .fileCancel(try r.u32())
        case 30: message = .userActivity
        case 31: message = .lockScreen
        default: throw MWBProtocolError.unknownMessage(type)
        }
        guard r.isAtEnd else { throw MWBProtocolError.invalidField("trailing bytes") }
        return message
    }
}

// MARK: - Binary encoding

struct BinaryWriter {
    private(set) var data = Data()

    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func bool(_ v: Bool) { u8(v ? 1 : 0) }
    mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    mutating func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
    mutating func f64(_ v: Double) { u64(v.bitPattern) }
    mutating func raw(_ d: Data) { data.append(d) }

    mutating func uuid(_ id: UUID) {
        withUnsafeBytes(of: id.uuid) { data.append(contentsOf: $0) }
    }

    /// Up to 64 KiB, u16 length.
    mutating func blob(_ d: Data) {
        let n = min(d.count, Int(UInt16.max))
        u16(UInt16(n))
        data.append(d.prefix(n))
    }

    /// u32 length.
    mutating func longBlob(_ d: Data) {
        u32(UInt32(d.count))
        data.append(d)
    }

    mutating func string(_ s: String) { blob(Data(s.utf8)) }

    mutating func rect(_ r: CGRect) {
        f64(Double(r.minX)); f64(Double(r.minY)); f64(Double(r.width)); f64(Double(r.height))
    }
}

struct BinaryReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ data: Data) { bytes = [UInt8](data) }

    var isAtEnd: Bool { offset == bytes.count }

    private mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
        guard n >= 0, bytes.count - offset >= n else { throw MWBProtocolError.truncated }
        defer { offset += n }
        return bytes[offset..<(offset + n)]
    }

    mutating func u8() throws -> UInt8 { try take(1).first ?? 0 }

    mutating func bool() throws -> Bool {
        switch try u8() {
        case 0: return false
        case 1: return true
        default: throw MWBProtocolError.invalidField("bool")
        }
    }

    mutating func u16() throws -> UInt16 { try take(2).reduce(0) { $0 << 8 | UInt16($1) } }
    mutating func u32() throws -> UInt32 { try take(4).reduce(0) { $0 << 8 | UInt32($1) } }
    mutating func u64() throws -> UInt64 { try take(8).reduce(0) { $0 << 8 | UInt64($1) } }
    mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }

    mutating func f64() throws -> Double {
        let v = Double(bitPattern: try u64())
        guard v.isFinite else { throw MWBProtocolError.invalidField("number") }
        return v
    }

    mutating func uuid() throws -> UUID {
        let b = Array(try take(16))
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    mutating func blob() throws -> Data { Data(try take(Int(try u16()))) }

    mutating func longBlob() throws -> Data {
        let n = Int(try u32())
        guard n <= MWBProtocol.maxFrameLength else { throw MWBProtocolError.frameTooLarge(n) }
        return Data(try take(n))
    }

    mutating func string() throws -> String {
        guard let s = String(data: try blob(), encoding: .utf8) else { throw MWBProtocolError.invalidField("string") }
        return s
    }

    mutating func rect() throws -> CGRect {
        let x = try f64(), y = try f64(), w = try f64(), h = try f64()
        guard w >= 0, h >= 0, w < 100_000, h < 100_000 else { throw MWBProtocolError.invalidField("rect") }
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
