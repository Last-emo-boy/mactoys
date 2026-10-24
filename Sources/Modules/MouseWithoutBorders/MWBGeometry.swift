import CoreGraphics
import Foundation
import MacToysCore

/// One machine placed in the matrix.
public struct MachineSlot: Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

/// Up to four machines in one row or a 2×2 grid. Slots 0 1 2 3 read left to right
/// (in a grid: 0 1 on top, 2 3 below). The layout is shared by every machine of the group;
/// the highest revision wins.
public struct MachineLayout: Codable, Equatable, Sendable {
    public static let slotCount = 4

    public var slots: [MachineSlot?] = [nil, nil, nil, nil]
    public var singleRow = true
    /// Seconds since 1970 of the last edit.
    public var revision: Double = 0

    public init() {}

    public enum Direction: CaseIterable, Sendable { case left, right, up, down }

    public var machines: [MachineSlot] { slots.compactMap { $0 } }

    public func index(of id: UUID) -> Int? { slots.firstIndex { $0?.id == id } }

    public func contains(_ id: UUID) -> Bool { index(of: id) != nil }

    /// Pads or trims to four slots.
    public var normalized: MachineLayout {
        var l = self
        if l.slots.count < Self.slotCount { l.slots += Array(repeating: nil, count: Self.slotCount - l.slots.count) }
        if l.slots.count > Self.slotCount { l.slots = Array(l.slots.prefix(Self.slotCount)) }
        return l
    }

    /// Puts a machine in the first free slot; false when the matrix is full.
    @discardableResult
    public mutating func add(_ slot: MachineSlot) -> Bool {
        self = normalized
        if let i = index(of: slot.id) { slots[i] = slot; return true }
        guard let free = slots.firstIndex(where: { $0 == nil }) else { return false }
        slots[free] = slot
        return true
    }

    public mutating func remove(_ id: UUID) {
        if let i = index(of: id) { slots[i] = nil }
    }

    /// Moves the machine in `from` to slot `to`, swapping with whatever is there.
    public mutating func move(from: Int, to: Int) {
        self = normalized
        guard slots.indices.contains(from), slots.indices.contains(to) else { return }
        slots.swapAt(from, to)
    }

    /// The machine you reach by leaving `id`'s screen in `direction`, or nil.
    ///
    /// In one row empty slots are skipped and only left/right lead anywhere; with `wrap` the ends
    /// connect. In a grid each row and column has two slots: the neighbor is the other slot of the
    /// row (left/right) or column (up/down) when you move toward it, or always with `wrap`.
    public func neighbor(of id: UUID, _ direction: Direction, wrap: Bool) -> UUID? {
        let l = normalized
        guard let i = l.index(of: id) else { return nil }
        if l.singleRow {
            let filled = l.slots.compactMap { $0 }
            guard filled.count > 1, let pos = filled.firstIndex(where: { $0.id == id }) else { return nil }
            switch direction {
            case .left:
                if pos > 0 { return filled[pos - 1].id }
                return wrap ? filled[filled.count - 1].id : nil
            case .right:
                if pos < filled.count - 1 { return filled[pos + 1].id }
                return wrap ? filled[0].id : nil
            case .up, .down:
                return nil
            }
        }
        let row = i / 2, col = i % 2
        let target: Int?
        switch direction {
        case .left: target = col == 1 ? row * 2 : (wrap ? row * 2 + 1 : nil)
        case .right: target = col == 0 ? row * 2 + 1 : (wrap ? row * 2 : nil)
        case .up: target = row == 1 ? col : (wrap ? 2 + col : nil)
        case .down: target = row == 0 ? 2 + col : (wrap ? col : nil)
        }
        guard let t = target, t != i, let slot = l.slots[t] else { return nil }
        return slot.id
    }
}

/// Edge crossing math, in each machine's global top-left coordinates.
enum EdgeMath {
    typealias Direction = MachineLayout.Direction

    /// Whether the pointer at `p`, moving by `delta`, pushes against an outer edge of the desktop
    /// (no display beyond it there). Returns the direction and the display being left.
    static func exit(from p: CGPoint, delta: CGVector, displays: [CGRect]) -> (Direction, CGRect)? {
        guard let cur = displays.first(where: { $0.contains(p) })
            ?? displays.min(by: { $0.distance(to: p) < $1.distance(to: p) }) else { return nil }
        func open(_ q: CGPoint) -> Bool { !displays.contains { $0.contains(q) } }
        if delta.dx > 0, p.x >= cur.maxX - 1, open(CGPoint(x: cur.maxX + 0.5, y: p.y)) { return (.right, cur) }
        if delta.dx < 0, p.x < cur.minX + 1, open(CGPoint(x: cur.minX - 0.5, y: p.y)) { return (.left, cur) }
        if delta.dy > 0, p.y >= cur.maxY - 1, open(CGPoint(x: p.x, y: cur.maxY + 0.5)) { return (.down, cur) }
        if delta.dy < 0, p.y < cur.minY + 1, open(CGPoint(x: p.x, y: cur.minY - 0.5)) { return (.up, cur) }
        return nil
    }

    /// Whether `p` is within `margin` of a corner along the edge being crossed.
    static func nearCorner(_ p: CGPoint, of display: CGRect, direction: Direction, margin: CGFloat = 40) -> Bool {
        switch direction {
        case .left, .right: return p.y - display.minY < margin || display.maxY - p.y < margin
        case .up, .down: return p.x - display.minX < margin || display.maxX - p.x < margin
        }
    }

    /// Where the pointer appears on the next machine. The position along the edge is kept as a
    /// fraction of the display being left and mapped onto the span of the next machine's displays
    /// on the opposite side, so screens of different sizes line up proportionally.
    static func entryPoint(exit p: CGPoint, from display: CGRect, direction: Direction, into displays: [CGRect]) -> CGPoint {
        let union = displays.reduce(CGRect.null) { $0.union($1) }
        guard !union.isNull, !displays.isEmpty else { return p }
        let horizontal = direction == .left || direction == .right
        let fraction: CGFloat = horizontal
            ? (display.height > 0 ? (p.y - display.minY) / display.height : 0.5)
            : (display.width > 0 ? (p.x - display.minX) / display.width : 0.5)
        let f = min(max(fraction, 0), 1)
        // Displays on the side the pointer comes in from.
        let edge: [CGRect]
        switch direction {
        case .right: edge = displays.filter { abs($0.minX - union.minX) < 1 }
        case .left: edge = displays.filter { abs($0.maxX - union.maxX) < 1 }
        case .down: edge = displays.filter { abs($0.minY - union.minY) < 1 }
        case .up: edge = displays.filter { abs($0.maxY - union.maxY) < 1 }
        }
        let span = edge.reduce(CGRect.null) { $0.union($1) }
        if horizontal {
            let y = span.minY + f * span.height
            let target = edge.first { $0.minY <= y && y < $0.maxY } ?? edge.min { abs($0.midY - y) < abs($1.midY - y) } ?? union
            let cy = min(max(y, target.minY), target.maxY - 1)
            return CGPoint(x: direction == .right ? target.minX + 1 : target.maxX - 2, y: cy)
        } else {
            let x = span.minX + f * span.width
            let target = edge.first { $0.minX <= x && x < $0.maxX } ?? edge.min { abs($0.midX - x) < abs($1.midX - x) } ?? union
            let cx = min(max(x, target.minX), target.maxX - 1)
            return CGPoint(x: cx, y: direction == .down ? target.minY + 1 : target.maxY - 2)
        }
    }

    /// Moves a virtual pointer on another machine by `delta`, keeping it on its displays (it slides
    /// along an edge rather than stopping), and reports when it pushes past an outer edge.
    static func move(_ p: CGPoint, by delta: CGVector, within displays: [CGRect]) -> (point: CGPoint, exit: (Direction, CGRect)?) {
        guard !displays.isEmpty else { return (p, nil) }
        let target = CGPoint(x: p.x + delta.dx, y: p.y + delta.dy)
        let q: CGPoint
        if displays.contains(where: { $0.contains(target) }) {
            q = target
        } else if displays.contains(where: { $0.contains(CGPoint(x: target.x, y: p.y)) }) {
            q = clamp(CGPoint(x: target.x, y: target.y), toDisplayAt: CGPoint(x: target.x, y: p.y), displays)
        } else if displays.contains(where: { $0.contains(CGPoint(x: p.x, y: target.y)) }) {
            q = clamp(CGPoint(x: target.x, y: target.y), toDisplayAt: CGPoint(x: p.x, y: target.y), displays)
        } else {
            q = clamp(target, toDisplayAt: p, displays)
        }
        return (q, exit(from: q, delta: delta, displays: displays))
    }

    private static func clamp(_ p: CGPoint, toDisplayAt anchor: CGPoint, _ displays: [CGRect]) -> CGPoint {
        let d = displays.first { $0.contains(anchor) } ?? displays.min { $0.distance(to: anchor) < $1.distance(to: anchor) } ?? .zero
        return CGPoint(x: min(max(p.x, d.minX), d.maxX - 1), y: min(max(p.y, d.minY), d.maxY - 1))
    }
}

/// IPv4/IPv6 "same subnet" checks for the Same subnet only option.
enum Subnet {
    struct Interface: Equatable {
        var address: [UInt8]
        var mask: [UInt8]
    }

    /// Parses dotted IPv4 or colon IPv6 text (zone suffixes like `%en0` are dropped).
    static func parse(_ text: String) -> [UInt8]? {
        let host = text.split(separator: "%").first.map(String.init) ?? text
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 { return withUnsafeBytes(of: v4) { Array($0) } }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, host, &v6) == 1 {
            let bytes = withUnsafeBytes(of: v6) { Array($0) }
            // IPv4-mapped IPv6 (::ffff:a.b.c.d) compares as IPv4.
            if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xFF && bytes[11] == 0xFF { return Array(bytes[12...]) }
            return bytes
        }
        return nil
    }

    /// Whether `remote` is on the same network as one of the interfaces. Loopback and IPv6
    /// link-local addresses always count as local.
    static func isLocal(_ remote: [UInt8], interfaces: [Interface]) -> Bool {
        if remote.count == 4 && remote[0] == 127 { return true }
        if remote.count == 16 {
            if remote == [UInt8](repeating: 0, count: 15) + [1] { return true }
            if remote[0] == 0xFE && remote[1] & 0xC0 == 0x80 { return true }
        }
        return interfaces.contains { i in
            guard i.address.count == remote.count, i.mask.count == remote.count else { return false }
            return zip(zip(i.address, i.mask), remote).allSatisfy { pair, r in pair.0 & pair.1 == r & pair.1 }
        }
    }

    /// This Mac's interface addresses and masks.
    static func localInterfaces() -> [Interface] {
        var result: [Interface] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            guard let addr = ifa.pointee.ifa_addr, let mask = ifa.pointee.ifa_netmask else { continue }
            switch Int32(addr.pointee.sa_family) {
            case AF_INET:
                let a = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin_addr) { Array($0) } }
                let m = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin_addr) { Array($0) } }
                result.append(Interface(address: a, mask: m))
            case AF_INET6:
                let a = addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) } }
                let m = mask.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) } }
                result.append(Interface(address: a, mask: m))
            default:
                break
            }
        }
        return result
    }

    /// Non-loopback IPv4 addresses, for showing "this Mac" in settings.
    static func localIPv4Addresses() -> [String] {
        localInterfaces().filter { $0.address.count == 4 && $0.address[0] != 127 && $0.address[0] != 169 }
            .map { $0.address.map(String.init).joined(separator: ".") }
    }
}
