import AppKit
import CoreGraphics
import Foundation
import IOKit
import MacToysCore

/// A control the flyout offers.
enum DisplayFeature: String, Codable, CaseIterable, Sendable {
    case brightness, contrast, volume, inputSource, colorTemperature, powerState

    var vcp: UInt8 {
        switch self {
        case .brightness: MCCS.brightness
        case .contrast: MCCS.contrast
        case .volume: MCCS.volume
        case .inputSource: MCCS.inputSource
        case .colorTemperature: MCCS.colorPreset
        case .powerState: MCCS.powerMode
        }
    }

    var isContinuous: Bool { self == .brightness || self == .contrast || self == .volume }

    var title: String {
        switch self {
        case .brightness: String(localized: "Brightness")
        case .contrast: String(localized: "Contrast")
        case .volume: String(localized: "Volume")
        case .inputSource: String(localized: "Input", comment: "Monitor input source")
        case .colorTemperature: String(localized: "Color temperature")
        case .powerState: String(localized: "powerdisplay.power", defaultValue: "Power", comment: "Monitor control: power state (on, standby, off)")
        }
    }

    var symbol: String {
        switch self {
        case .brightness: "sun.max"
        case .contrast: "circle.righthalf.filled"
        case .volume: "speaker.wave.2"
        case .inputSource: "cable.connector.horizontal"
        case .colorTemperature: "thermometer.medium"
        case .powerState: "power"
        }
    }

    /// The CLI name: `brightness`, `contrast`, `volume`, `input-source`, `color-temperature`, `power-state`.
    var cliName: String {
        switch self {
        case .inputSource: "input-source"
        case .colorTemperature: "color-temperature"
        case .powerState: "power-state"
        default: rawValue
        }
    }

    init?(cliName: String) {
        guard let f = DisplayFeature.allCases.first(where: { $0.cliName == cliName.lowercased() }) else { return nil }
        self = f
    }
}

/// How MacToys talks to a display.
enum MonitorKind: String, Codable, Sendable {
    /// The built-in panel, through DisplayServices.
    case builtIn
    /// Apple external displays (Studio Display, Pro Display XDR, UltraFine), through DisplayServices.
    case appleNative
    /// DDC/CI over IOAVService.
    case ddc
    /// No supported channel (DisplayLink, AirPlay, Sidecar, Intel Macs…).
    case unsupported
}

struct FeatureReading: Codable, Equatable, Sendable {
    var current: UInt16
    var maximum: UInt16
}

/// Everything known about one connected display after discovery.
struct MonitorSnapshot: Sendable, Identifiable {
    /// Stable across reconnects: `vendor-model-serial` (plus `#n` for identical twins).
    var id: String
    /// 1-based, built-in first, then left to right.
    var number: Int
    var name: String
    var displayID: CGDirectDisplayID
    var kind: MonitorKind
    /// English, for the command line ("DDC/CI · DisplayPort"); `transportTitle` for the UI.
    var transport: String
    var capabilities: DDCCapabilities?
    var readings: [DisplayFeature: FeatureReading]
    /// Discrete values for input source, color preset and power state.
    var options: [DisplayFeature: [UInt16]]
    /// Degrees, read-only (macOS has no public API to rotate a display).
    var rotation: Int
    /// `name` is the "Display 2" fallback: macOS gave no name.
    var isUnnamed = false

    var supported: [DisplayFeature] { DisplayFeature.allCases.filter { readings[$0] != nil } }

    /// `transport`, localized.
    var transportTitle: String {
        switch kind {
        case .builtIn: String(localized: "Built-in", comment: "How a display is connected")
        case .appleNative: String(localized: "Apple display", comment: "How a display is connected")
        case .ddc: transport   // protocol and port names
        case .unsupported: String(localized: "Not supported", comment: "How a display is connected: MacToys can't control it")
        }
    }
}

/// Discovers displays and reads or writes their controls. Synchronous and not thread-safe:
/// the app drives it from one serial queue, the CLI from its main thread.
final class DisplayEngine: @unchecked Sendable {
    private struct Endpoint {
        var displayID: CGDirectDisplayID
        var kind: MonitorKind
        var channel: DDCChannel?
    }

    private var endpoints: [String: Endpoint] = [:]
    private let log = Log.for("powerdisplay")
    var maxCompatibility = false

    /// Finds displays, matches DDC services to them and reads their current values.
    /// `names` comes from `NSScreen` on the main thread (`DisplayEngine.screenNames()`);
    /// `cachedCapabilities` (monitor id → capabilities string) avoids re-reading slow strings.
    func discover(names: [CGDirectDisplayID: String], cachedCapabilities: [String: String],
                  readCapabilities: Bool = true) -> [MonitorSnapshot] {
        let displays = Self.onlineDisplays(names: names)
        let avServices = Self.externalAVServices()
        let assignment = Self.match(displays: displays.filter { !$0.isBuiltIn }, services: avServices)
        var result: [MonitorSnapshot] = []
        var newEndpoints: [String: Endpoint] = [:]
        var seenIDs: [String: Int] = [:]
        let timing = maxCompatibility ? DDCChannel.Timing.patient : DDCChannel.Timing()

        for (index, d) in displays.enumerated() {
            var id = d.baseID
            seenIDs[id, default: 0] += 1
            if let n = seenIDs[id], n > 1 { id += "#\(n)" }
            var snapshot = MonitorSnapshot(id: id, number: index + 1, name: d.name, displayID: d.id, kind: .unsupported,
                                           transport: "Not supported", capabilities: nil, readings: [:], options: [:],
                                           rotation: Int(CGDisplayRotation(d.id)))
            if d.isBuiltIn || DisplayServices.canChangeBrightness(d.id) {
                snapshot.kind = d.isBuiltIn ? .builtIn : .appleNative
                snapshot.transport = d.isBuiltIn ? "Built-in" : "Apple display"
                if let b = DisplayServices.brightness(d.id) {
                    snapshot.readings[.brightness] = FeatureReading(current: UInt16((b * 100).rounded()), maximum: 100)
                }
                newEndpoints[id] = Endpoint(displayID: d.id, kind: snapshot.kind, channel: nil)
            } else if let service = assignment[d.id], let fns = IOAVService.functions {
                let channel = DDCChannel(service: service.service, functions: fns, timing: timing)
                snapshot.kind = .ddc
                snapshot.transport = service.transport.map { "DDC/CI · \($0)" } ?? "DDC/CI"
                if snapshot.name.isEmpty, let n = service.productName { snapshot.name = n }
                var caps: DDCCapabilities?
                if let cached = cachedCapabilities[id], !cached.isEmpty {
                    caps = DDCCapabilities.parse(cached)
                } else if readCapabilities && !maxCompatibility, let raw = channel.capabilitiesString() {
                    caps = DDCCapabilities.parse(raw)
                }
                snapshot.capabilities = caps
                probe(channel, capabilities: maxCompatibility ? nil : caps, into: &snapshot)
                newEndpoints[id] = Endpoint(displayID: d.id, kind: .ddc, channel: channel)
            }
            if snapshot.name.isEmpty {
                snapshot.name = "Display \(index + 1)"
                snapshot.isUnnamed = true
            }
            result.append(snapshot)
        }
        endpoints = newEndpoints
        return result
    }

    /// Reads every flyout feature. With capabilities, only listed codes are tried; without, all are probed.
    private func probe(_ channel: DDCChannel, capabilities: DDCCapabilities?, into snapshot: inout MonitorSnapshot) {
        for feature in DisplayFeature.allCases {
            if let caps = capabilities, !caps.supports(feature.vcp) { continue }
            guard let reply = channel.getVCP(feature.vcp), reply.supported else { continue }
            if feature.isContinuous && reply.maximum == 0 { continue }
            snapshot.readings[feature] = FeatureReading(current: reply.current, maximum: reply.maximum)
            if !feature.isContinuous {
                var values = capabilities?.vcp[feature.vcp] ?? []
                if values.isEmpty { values = Self.defaultOptions(feature) }
                let current = feature == .inputSource ? reply.current & 0xFF : reply.current
                if !values.contains(current) { values.append(current) }
                snapshot.options[feature] = values.sorted()
                snapshot.readings[feature]?.current = current
            }
        }
    }

    static func defaultOptions(_ feature: DisplayFeature) -> [UInt16] {
        switch feature {
        case .colorTemperature: [0x01, 0x02, 0x05, 0x06, 0x08]
        case .powerState: [0x01, 0x04, 0x05]
        default: []
        }
    }

    func read(_ feature: DisplayFeature, monitor id: String) -> FeatureReading? {
        guard let e = endpoints[id] else { return nil }
        if e.kind == .builtIn || e.kind == .appleNative {
            guard feature == .brightness, let b = DisplayServices.brightness(e.displayID) else { return nil }
            return FeatureReading(current: UInt16((b * 100).rounded()), maximum: 100)
        }
        guard let reply = e.channel?.getVCP(feature.vcp), reply.supported else { return nil }
        return FeatureReading(current: feature == .inputSource ? reply.current & 0xFF : reply.current, maximum: reply.maximum)
    }

    @discardableResult
    func write(_ feature: DisplayFeature, raw: UInt16, monitor id: String) -> Bool {
        guard let e = endpoints[id] else { return false }
        if e.kind == .builtIn || e.kind == .appleNative {
            guard feature == .brightness else { return false }
            return DisplayServices.setBrightness(e.displayID, Float(raw) / 100)
        }
        guard let channel = e.channel else { return false }
        let ok = channel.setVCP(feature.vcp, raw)
        if !ok { log.error("DDC write \(feature.rawValue, privacy: .public)=\(raw) failed on \(id, privacy: .public)") }
        return ok
    }

    /// Reads (or re-reads) a display's capabilities string.
    func readCapabilities(monitor id: String) -> DDCCapabilities? {
        guard let channel = endpoints[id]?.channel, let raw = channel.capabilitiesString() else { return nil }
        return DDCCapabilities.parse(raw)
    }

    // MARK: - Displays

    struct OnlineDisplay {
        var id: CGDirectDisplayID
        var name: String
        var isBuiltIn: Bool
        var vendor: UInt32, model: UInt32, serial: UInt32
        var bounds: CGRect
        var baseID: String { "\(vendor)-\(model)-\(serial)" }
    }

    /// Display names as System Settings shows them. Main thread only.
    @MainActor
    static func screenNames() -> [CGDirectDisplayID: String] {
        Dictionary(NSScreen.screens.map { ($0.displayID, $0.localizedName) }, uniquingKeysWith: { a, _ in a })
    }

    static func onlineDisplays(names: [CGDirectDisplayID: String]) -> [OnlineDisplay] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        let list = ids.prefix(Int(count)).compactMap { id -> OnlineDisplay? in
            // Skip the secondary members of a hardware mirror set; they share the primary's controls.
            if CGDisplayIsInHWMirrorSet(id) != 0 && CGDisplayMirrorsDisplay(id) != kCGNullDirectDisplay { return nil }
            return OnlineDisplay(id: id, name: names[id] ?? "", isBuiltIn: CGDisplayIsBuiltin(id) != 0,
                                 vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id),
                                 serial: CGDisplaySerialNumber(id), bounds: CGDisplayBounds(id))
        }
        return list.sorted { a, b in
            if a.isBuiltIn != b.isBuiltIn { return a.isBuiltIn }
            if a.bounds.minX != b.bounds.minX { return a.bounds.minX < b.bounds.minX }
            return a.bounds.minY < b.bounds.minY
        }
    }

    /// An external `DCPAVServiceProxy` with the attributes of the framebuffer it belongs to.
    struct AVServiceInfo: @unchecked Sendable {
        var service: CFTypeRef
        var edidUUID: String?
        var productName: String?
        var vendor: Int?, product: Int?, serial: Int?
        var transport: String?
    }

    /// Walks the IORegistry: each `AppleCLCD2`/`IOMobileFramebufferShim` is followed by the
    /// `DCPAVServiceProxy` of the same display (the layout MonitorControl and m1ddc rely on).
    static func externalAVServices() -> [AVServiceInfo] {
        guard let fns = IOAVService.functions else { return [] }
        var iterator = io_iterator_t()
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively),
                                            &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [AVServiceInfo] = []
        var framebuffer: [String: Any]?
        var name = [CChar](repeating: 0, count: 128)
        while true {
            let entry = IOIteratorNext(iterator)
            guard entry != 0 else { break }
            defer { IOObjectRelease(entry) }
            guard IORegistryEntryGetName(entry, &name) == KERN_SUCCESS else { continue }
            let entryName = String(cString: name)
            if entryName == "AppleCLCD2" || entryName == "IOMobileFramebufferShim" {
                framebuffer = properties(of: entry)
            } else if entryName == "DCPAVServiceProxy" || IOObjectConformsTo(entry, "DCPAVServiceProxy") != 0 {
                let location = property(entry, "Location") as? String
                guard location == "External", let unmanaged = fns.create(kCFAllocatorDefault, entry) else { continue }
                var info = AVServiceInfo(service: unmanaged.takeRetainedValue())
                if let fb = framebuffer {
                    info.edidUUID = fb["EDID UUID"] as? String
                    let attrs = (fb["DisplayAttributes"] as? [String: Any])?["ProductAttributes"] as? [String: Any]
                    info.productName = attrs?["ProductName"] as? String
                    info.vendor = attrs?["LegacyManufacturerID"] as? Int
                    info.product = attrs?["ProductID"] as? Int
                    info.serial = attrs?["SerialNumber"] as? Int
                    if let t = fb["Transport"] as? [String: Any] {
                        info.transport = (t["Downstream"] as? String) ?? (t["Upstream"] as? String)
                    }
                }
                result.append(info)
                framebuffer = nil
            }
        }
        return result
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func properties(of entry: io_registry_entry_t) -> [String: Any] {
        var out: [String: Any] = [:]
        for key in ["EDID UUID", "DisplayAttributes", "Transport"] {
            if let v = property(entry, key) { out[key] = v }
        }
        return out
    }

    /// Pairs displays with services by EDID vendor/product, serial and name; a lone pair matches regardless.
    static func match(displays: [OnlineDisplay], services: [AVServiceInfo]) -> [CGDirectDisplayID: AVServiceInfo] {
        var scored: [(Int, Int, Int)] = []   // score, display index, service index
        for (di, d) in displays.enumerated() {
            for (si, s) in services.enumerated() {
                scored.append((matchScore(d, s), di, si))
            }
        }
        scored.sort { $0.0 > $1.0 }
        var usedD = Set<Int>(), usedS = Set<Int>()
        var out: [CGDirectDisplayID: AVServiceInfo] = [:]
        for (score, di, si) in scored where score > 0 && !usedD.contains(di) && !usedS.contains(si) {
            out[displays[di].id] = services[si]
            usedD.insert(di)
            usedS.insert(si)
        }
        let leftD = displays.indices.filter { !usedD.contains($0) }
        let leftS = services.indices.filter { !usedS.contains($0) }
        if leftD.count == 1 && leftS.count == 1 { out[displays[leftD[0]].id] = services[leftS[0]] }
        return out
    }

    static func matchScore(_ d: OnlineDisplay, _ s: AVServiceInfo) -> Int {
        var score = 0
        if let uuid = s.edidUUID?.replacingOccurrences(of: "-", with: "").uppercased(), uuid.count >= 8 {
            let vendor = String(format: "%04X", d.vendor & 0xFFFF)
            let product = String(format: "%02X%02X", d.model & 0xFF, (d.model >> 8) & 0xFF)
            if vendor != "0000" && uuid.hasPrefix(vendor) { score += 1 }
            if product != "0000" && uuid.dropFirst(4).hasPrefix(product) { score += 1 }
        }
        if let v = s.vendor, v != 0, UInt32(truncatingIfNeeded: v) == d.vendor { score += 1 }
        if let p = s.product, p != 0, UInt32(truncatingIfNeeded: p) == d.model { score += 1 }
        if let serial = s.serial, serial != 0, UInt32(truncatingIfNeeded: serial) == d.serial { score += 2 }
        if let n = s.productName, !n.isEmpty, n == d.name { score += 1 }
        return score
    }
}
