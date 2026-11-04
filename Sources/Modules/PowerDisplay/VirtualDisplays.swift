import AppKit
import CoreGraphics
import Foundation
import MacToysCore
import ObjectiveC

/// A virtual display MacToys keeps while it runs: for HiDPI on monitors that lack it (mirror the
/// monitor onto a HiDPI virtual display), or a screen to stream or record that isn't on a panel.
struct VirtualDisplayConfig: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    /// Pixels.
    var width: Int
    var height: Int
    /// Offer HiDPI modes (each pixel size also as a sharp half-size "looks like" desktop).
    var hiDPI = true
    var refreshRate: Double = 60
    /// Created at launch; off keeps the settings without the display.
    var enabled = true
    /// Stable serial number so macOS remembers this display's arrangement.
    var serial: UInt32 = UInt32.random(in: 0x1000...0xFFFF_FFF0)
    /// A physical monitor (monitor id) that mirrors this display: shows its HiDPI picture.
    var mirroredBy: String?

    var aspect: AspectRatio { AspectRatio.of(width: width, height: height) }
    /// The HiDPI desktop size at the largest mode.
    var looksLike: (Int, Int) { hiDPI ? (width / 2, height / 2) : (width, height) }
}

extension VirtualDisplayConfig {
    /// Missing keys take their defaults (entries live in an array the default merge doesn't reach).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        width = try c.decodeIfPresent(Int.self, forKey: .width) ?? 1920
        height = try c.decodeIfPresent(Int.self, forKey: .height) ?? 1080
        hiDPI = try c.decodeIfPresent(Bool.self, forKey: .hiDPI) ?? true
        refreshRate = try c.decodeIfPresent(Double.self, forKey: .refreshRate) ?? 60
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        serial = try c.decodeIfPresent(UInt32.self, forKey: .serial) ?? UInt32.random(in: 0x1000...0xFFFF_FFF0)
        mirroredBy = try c.decodeIfPresent(String.self, forKey: .mirroredBy)
    }
}

struct VirtualDisplayPreset: Identifiable, Hashable, Sendable {
    var width: Int
    var height: Int
    var id: String { "\(width)x\(height)" }
    var aspect: AspectRatio { AspectRatio.of(width: width, height: height) }

    /// Common sizes; with HiDPI each looks like half its size.
    static let all: [VirtualDisplayPreset] = [
        .init(width: 1920, height: 1080), .init(width: 2560, height: 1440), .init(width: 3840, height: 2160),
        .init(width: 5120, height: 2880), .init(width: 6016, height: 3384),
        .init(width: 2560, height: 1600), .init(width: 3456, height: 2234), .init(width: 3840, height: 2400),
        .init(width: 3440, height: 1440), .init(width: 5120, height: 2160),
        .init(width: 2732, height: 2048), .init(width: 2160, height: 3840),
    ]
}

/// Mode sizes offered for a virtual display: its full size and smaller sizes of the same shape,
/// so System Settings and the flyout have something to scale between.
enum VirtualDisplayModes {
    static let scales: [Double] = [1, 0.875, 0.75, 0.625, 0.5, 0.375]

    static func sizes(width: Int, height: Int) -> [(Int, Int)] {
        guard width > 0, height > 0 else { return [] }
        var seen = Set<String>()
        var out: [(Int, Int)] = []
        for s in scales {
            // Even sizes keep HiDPI halves whole.
            let w = Int((Double(width) * s / 2).rounded()) * 2
            let h = Int((Double(height) * s / 2).rounded()) * 2
            guard min(w, h) >= 480, seen.insert("\(w)x\(h)").inserted else { continue }
            out.append((w, h))
        }
        return out
    }

    /// Physical size reported to macOS: about 109 ppi, 218 for HiDPI (like Apple's 27" panels).
    static func millimeters(width: Int, height: Int, hiDPI: Bool) -> CGSize {
        let ppi = hiDPI ? 218.0 : 109.0
        return CGSize(width: Double(width) / ppi * 25.4, height: Double(height) / ppi * 25.4)
    }

    /// Keeps sizes within what CoreGraphics accepts.
    static func clamp(_ v: Int) -> Int { max(640, min(8192, v)) }
}

/// A running virtual display. Releasing it removes the display.
@MainActor
final class VirtualDisplayHandle {
    let configID: UUID
    let displayID: CGDirectDisplayID
    /// The `CGVirtualDisplay`; the display exists for as long as this is retained.
    private var object: NSObject?

    init(configID: UUID, displayID: CGDirectDisplayID, object: NSObject) {
        self.configID = configID
        self.displayID = displayID
        self.object = object
    }

    func remove() { object = nil }
}

/// CoreGraphics' virtual display classes, found at run time. They aren't public API: every class and
/// selector is checked before use, and when anything is missing the feature reports unavailable
/// instead of calling into it.
@MainActor
enum VirtualDisplayAPI {
    /// Vendor id written into virtual displays, to recognize them during discovery.
    nonisolated static let vendorID: UInt32 = 0x4D54
    nonisolated static let productID: UInt32 = 0x5644

    private struct Classes {
        let descriptor: NSObject.Type
        let display: AnyClass
        let settings: NSObject.Type
        let mode: AnyClass
    }

    private static let descriptorKeys = ["name", "maxPixelsWide", "maxPixelsHigh", "sizeInMillimeters",
                                         "vendorID", "productID", "serialNum", "queue"]

    private static let classes: Classes? = {
        guard let descriptor = NSClassFromString("CGVirtualDisplayDescriptor") as? NSObject.Type,
              let display = NSClassFromString("CGVirtualDisplay"),
              let settings = NSClassFromString("CGVirtualDisplaySettings") as? NSObject.Type,
              let mode = NSClassFromString("CGVirtualDisplayMode"),
              class_getInstanceMethod(display, NSSelectorFromString("initWithDescriptor:")) != nil,
              class_getInstanceMethod(display, NSSelectorFromString("applySettings:")) != nil,
              class_getInstanceMethod(display, NSSelectorFromString("displayID")) != nil,
              class_getInstanceMethod(mode, NSSelectorFromString("initWithWidth:height:refreshRate:")) != nil,
              descriptorKeys.allSatisfy({ descriptor.instancesRespond(to: setter($0)) }),
              settings.instancesRespond(to: setter("hiDPI")), settings.instancesRespond(to: setter("modes"))
        else { return nil }
        return Classes(descriptor: descriptor, display: display, settings: settings, mode: mode)
    }()

    static var isAvailable: Bool { classes != nil }

    private static func setter(_ key: String) -> Selector {
        NSSelectorFromString("set\(key.prefix(1).uppercased())\(key.dropFirst()):")
    }

    /// KVC only after checking the setter exists (an unknown key would raise).
    @discardableResult
    private static func set(_ object: NSObject, _ key: String, _ value: Any) -> Bool {
        guard object.responds(to: setter(key)) else { return false }
        object.setValue(value, forKey: key)
        return true
    }

    /// The descriptor for a configuration (also used by tests to check the bridge without creating
    /// a display).
    static func descriptor(for config: VirtualDisplayConfig) -> NSObject? {
        guard let c = classes else { return nil }
        let d = c.descriptor.init()
        let w = VirtualDisplayModes.clamp(config.width), h = VirtualDisplayModes.clamp(config.height)
        set(d, "name", config.name as NSString)
        set(d, "maxPixelsWide", NSNumber(value: UInt32(w)))
        set(d, "maxPixelsHigh", NSNumber(value: UInt32(h)))
        set(d, "sizeInMillimeters", NSValue(size: VirtualDisplayModes.millimeters(width: w, height: h, hiDPI: config.hiDPI)))
        set(d, "vendorID", NSNumber(value: vendorID))
        set(d, "productID", NSNumber(value: productID))
        set(d, "serialNum", NSNumber(value: config.serial))
        set(d, "queue", DispatchQueue.main)
        return d
    }

    /// The settings object (HiDPI flag and modes) for a configuration.
    static func settings(for config: VirtualDisplayConfig) -> NSObject? {
        guard let c = classes else { return nil }
        let s = c.settings.init()
        let modes = VirtualDisplayModes.sizes(width: VirtualDisplayModes.clamp(config.width),
                                              height: VirtualDisplayModes.clamp(config.height))
            .compactMap { makeMode(c.mode, width: $0.0, height: $0.1, refresh: config.refreshRate) }
        guard !modes.isEmpty else { return nil }
        set(s, "hiDPI", NSNumber(value: UInt32(config.hiDPI ? 1 : 0)))
        set(s, "modes", modes as NSArray)
        return s
    }

    private static func makeMode(_ cls: AnyClass, width: Int, height: Int, refresh: Double) -> NSObject? {
        let sel = NSSelectorFromString("initWithWidth:height:refreshRate:")
        guard let raw = alloc(cls) else { return nil }
        typealias Init = @convention(c) (Unmanaged<AnyObject>, Selector, UInt32, UInt32, Double) -> Unmanaged<AnyObject>?
        let imp = class_getMethodImplementation(cls, sel)
        let f = unsafeBitCast(imp, to: Init.self)
        return f(raw, sel, UInt32(width), UInt32(height), max(1, refresh))?.takeRetainedValue() as? NSObject
    }

    /// `+alloc`; the result is consumed by the `init…` call.
    private static func alloc(_ cls: AnyClass) -> Unmanaged<AnyObject>? {
        let sel = NSSelectorFromString("alloc")
        guard let method = class_getClassMethod(cls, sel) else { return nil }
        typealias Alloc = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>?
        return unsafeBitCast(method_getImplementation(method), to: Alloc.self)(cls, sel)
    }

    /// Creates the display. Returns nil (and logs) when macOS refuses.
    static func create(_ config: VirtualDisplayConfig) -> VirtualDisplayHandle? {
        let log = Log.for("powerdisplay")
        guard let c = classes, let descriptor = descriptor(for: config), let settings = settings(for: config) else { return nil }
        let initSel = NSSelectorFromString("initWithDescriptor:")
        guard let raw = alloc(c.display) else { return nil }
        typealias Init = @convention(c) (Unmanaged<AnyObject>, Selector, AnyObject) -> Unmanaged<AnyObject>?
        let initF = unsafeBitCast(class_getMethodImplementation(c.display, initSel), to: Init.self)
        guard let display = initF(raw, initSel, descriptor)?.takeRetainedValue() as? NSObject else {
            log.error("virtual display: init failed")
            return nil
        }
        let applySel = NSSelectorFromString("applySettings:")
        typealias Apply = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        let apply = unsafeBitCast(class_getMethodImplementation(c.display, applySel), to: Apply.self)
        guard apply(display, applySel, settings) else {
            log.error("virtual display: settings rejected")
            return nil
        }
        let id = (display.value(forKey: "displayID") as? NSNumber)?.uint32Value ?? 0
        guard id != 0 else {
            log.error("virtual display: no display id")
            return nil
        }
        log.info("virtual display \(config.width)x\(config.height) created as \(id)")
        return VirtualDisplayHandle(configID: config.id, displayID: id, object: display)
    }

    /// Whether a display is one of ours (discovery runs in the app and the CLI).
    nonisolated static func isVirtual(vendor: UInt32, model: UInt32) -> Bool {
        vendor == vendorID && model == productID
    }
}
