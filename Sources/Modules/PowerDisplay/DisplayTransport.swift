import CoreGraphics
import Darwin
import Foundation
import IOKit
import MacToysCore

/// `IOAVService` I²C access (IOKit, not in public headers): the DDC/CI transport on Apple silicon.
enum IOAVService {
    typealias CreateWithService = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    typealias ReadI2C = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    typealias WriteI2C = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    struct Functions {
        let create: CreateWithService
        let read: ReadI2C
        let write: WriteI2C
    }

    /// Nil on Intel Macs and if Apple removes the symbols.
    static let functions: Functions? = {
        guard let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
              let c = dlsym(iokit, "IOAVServiceCreateWithService"),
              let r = dlsym(iokit, "IOAVServiceReadI2C"),
              let w = dlsym(iokit, "IOAVServiceWriteI2C") else { return nil }
        return Functions(create: unsafeBitCast(c, to: CreateWithService.self),
                         read: unsafeBitCast(r, to: ReadI2C.self),
                         write: unsafeBitCast(w, to: WriteI2C.self))
    }()
}

/// One display's DDC/CI channel. Not thread-safe: use from one queue at a time.
final class DDCChannel: @unchecked Sendable {
    struct Timing: Sendable {
        var writeDelay: useconds_t = 10_000
        var writeCycles = 2
        var readDelay: useconds_t = 50_000
        var retries = 3
        var retryDelay: useconds_t = 20_000

        /// Slower, more patient timing for displays that miss requests (max compatibility mode).
        static let patient = Timing(writeDelay: 20_000, writeCycles: 3, readDelay: 90_000, retries: 5, retryDelay: 40_000)
    }

    private let service: CFTypeRef
    private let fns: IOAVService.Functions
    var timing: Timing
    private var readSeed = DDCPacket.requestSeed

    init(service: CFTypeRef, functions: IOAVService.Functions, timing: Timing) {
        self.service = service
        self.fns = functions
        self.timing = timing
    }

    private func send(_ packet: [UInt8], cycles: Int) -> Bool {
        var ok = false
        var bytes = packet
        for _ in 0..<max(1, cycles) {
            usleep(timing.writeDelay)
            let status = bytes.withUnsafeMutableBytes { buf -> IOReturn in
                guard let base = buf.baseAddress else { return kIOReturnBadArgument }
                return fns.write(service, DDCPacket.chipAddress, UInt32(DDCPacket.sourceAddress), base, UInt32(buf.count))
            }
            if status == kIOReturnSuccess { ok = true }
        }
        return ok
    }

    private func receive(_ count: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = bytes.withUnsafeMutableBytes { buf -> IOReturn in
            guard let base = buf.baseAddress else { return kIOReturnBadArgument }
            return fns.read(service, DDCPacket.chipAddress, UInt32(DDCPacket.sourceAddress), base, UInt32(buf.count))
        }
        return status == kIOReturnSuccess ? bytes : nil
    }

    func setVCP(_ code: UInt8, _ value: UInt16) -> Bool {
        for attempt in 0..<timing.retries {
            if attempt > 0 { usleep(timing.retryDelay) }
            if send(DDCPacket.setVCP(code, value: value), cycles: timing.writeCycles) { return true }
        }
        return false
    }

    /// Reads a VCP feature, trying both Get-request checksum conventions and remembering the one that works.
    func getVCP(_ code: UInt8) -> VCPReply? {
        for seed in [readSeed, readSeed == DDCPacket.requestSeed ? DDCPacket.legacyReadSeed : DDCPacket.requestSeed] {
            for attempt in 0..<timing.retries {
                if attempt > 0 { usleep(timing.retryDelay) }
                guard send(DDCPacket.getVCP(code, seed: seed), cycles: 1) else { continue }
                usleep(timing.readDelay)
                if let bytes = receive(DDCPacket.vcpReplyLength), let reply = DDCPacket.parseVCPReply(bytes, code: code) {
                    readSeed = seed
                    return reply
                }
            }
        }
        return nil
    }

    /// Reads the MCCS capabilities string fragment by fragment (up to 4 KB).
    func capabilitiesString() -> String? {
        var data: [UInt8] = []
        var offset: UInt16 = 0
        var failures = 0
        while offset < 4096 {
            guard send(DDCPacket.capabilitiesRequest(offset: offset), cycles: 1) else { return nil }
            usleep(timing.readDelay)
            guard let bytes = receive(DDCPacket.capabilitiesReplyLength),
                  let fragment = DDCPacket.parseCapabilitiesReply(bytes, offset: offset) else {
                failures += 1
                if failures > timing.retries { break }
                usleep(timing.retryDelay)
                continue
            }
            failures = 0
            if fragment.isEmpty { break }
            data += fragment
            offset += UInt16(fragment.count)
            if fragment.contains(0) { break }
        }
        let text = String(decoding: data.filter { $0 != 0 }, as: UTF8.self)
        return text.contains("(") ? text : nil
    }
}

/// Built-in (and Apple external) display brightness through the private DisplayServices framework.
enum DisplayServices {
    typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    typealias Set = @convention(c) (CGDirectDisplayID, Float) -> Int32
    typealias Can = @convention(c) (CGDirectDisplayID) -> Bool

    private struct Functions {
        let get: Get
        let set: Set
        let can: Can?
    }

    private static let functions: Functions? = {
        guard let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW),
              let g = dlsym(h, "DisplayServicesGetBrightness"),
              let s = dlsym(h, "DisplayServicesSetBrightness") else { return nil }
        let c = dlsym(h, "DisplayServicesCanChangeBrightness")
        return Functions(get: unsafeBitCast(g, to: Get.self), set: unsafeBitCast(s, to: Set.self),
                         can: c.map { unsafeBitCast($0, to: Can.self) })
    }()

    static func canChangeBrightness(_ id: CGDirectDisplayID) -> Bool {
        guard let f = functions else { return false }
        if let can = f.can { return can(id) }
        var v: Float = 0
        return f.get(id, &v) == 0
    }

    /// 0…1.
    static func brightness(_ id: CGDirectDisplayID) -> Float? {
        guard let f = functions else { return nil }
        var v: Float = 0
        return f.get(id, &v) == 0 ? v : nil
    }

    @discardableResult
    static func setBrightness(_ id: CGDirectDisplayID, _ value: Float) -> Bool {
        guard let f = functions else { return false }
        return f.set(id, max(0, min(1, value))) == 0
    }
}
