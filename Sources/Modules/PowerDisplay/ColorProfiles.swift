import AppKit
import ColorSync
import CoreGraphics
import Foundation
import ObjectiveC

/// An installed RGB display profile.
struct ColorProfile: Identifiable, Hashable, Sendable {
    var url: URL
    /// The profile's description, localized by ColorSync.
    var name: String
    var id: String { url.path }
    /// Installed for one display (in `…/ColorSync/Profiles/Displays`), rather than a working space.
    var isDisplayProfile: Bool { url.deletingLastPathComponent().lastPathComponent == "Displays" }
}

/// Per-display ColorSync profiles: list, read, choose. Choices are stored by ColorSync itself
/// (System Settings › Displays › Color profile shows the same).
enum ColorProfiles {
    /// The display's own (factory) profile first, then other display profiles, then working spaces;
    /// alphabetical within each, duplicates by path dropped.
    static func ordered(_ profiles: [ColorProfile], factory: URL?) -> [ColorProfile] {
        var seen = Set<String>()
        let unique = profiles.filter { seen.insert($0.url.standardizedFileURL.path).inserted }
        func rank(_ p: ColorProfile) -> Int {
            if let factory, p.url.standardizedFileURL == factory.standardizedFileURL { return 0 }
            return p.isDisplayProfile ? 1 : 2
        }
        return unique.sorted { a, b in
            let ra = rank(a), rb = rank(b)
            if ra != rb { return ra < rb }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// Every installed RGB display-class profile. Can take a moment the first time: call off the main thread.
    static func installed() -> [ColorProfile] {
        final class Box { var items: [ColorProfile] = [] }
        let box = Box()
        let options = [kColorSyncWaitForCacheReply.takeUnretainedValue(): kCFBooleanTrue as Any] as CFDictionary
        ColorSyncIterateInstalledProfilesWithOptions({ info, context in
            guard let info, let context else { return true }
            let d = info as NSDictionary
            guard d[kColorSyncProfileClass.takeUnretainedValue()] as? String == "mntr",
                  d[kColorSyncProfileColorSpace.takeUnretainedValue()] as? String == "RGB ",
                  let url = d[kColorSyncProfileURL.takeUnretainedValue()] as? URL else { return true }
            let name = d[kColorSyncProfileDescription.takeUnretainedValue()] as? String ?? url.deletingPathExtension().lastPathComponent
            Unmanaged<Box>.fromOpaque(context).takeUnretainedValue().items.append(ColorProfile(url: url, name: name))
            return true
        }, nil, Unmanaged.passUnretained(box).toOpaque(), options, nil)
        return box.items
    }

    private static func deviceInfo(_ id: CGDirectDisplayID) -> NSDictionary? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return ColorSyncDeviceCopyDeviceInfo(kColorSyncDisplayDeviceClass.takeUnretainedValue(), uuid)?
            .takeRetainedValue() as NSDictionary?
    }

    /// The profile the display came with.
    static func factory(_ id: CGDirectDisplayID) -> URL? {
        guard let factory = deviceInfo(id)?[kColorSyncFactoryProfiles.takeUnretainedValue()] as? NSDictionary else { return nil }
        let key = factory[kColorSyncDeviceDefaultProfileID.takeUnretainedValue()] as? String ?? "1"
        return (factory[key] as? NSDictionary)?[kColorSyncDeviceProfileURL.takeUnretainedValue()] as? URL
    }

    /// The profile in use: a custom choice when there is one, else the factory profile.
    static func current(_ id: CGDirectDisplayID) -> URL? {
        guard let info = deviceInfo(id) else { return nil }
        if let custom = info[kColorSyncCustomProfiles.takeUnretainedValue()] as? NSDictionary {
            let factoryKey = (info[kColorSyncFactoryProfiles.takeUnretainedValue()] as? NSDictionary)?[
                kColorSyncDeviceDefaultProfileID.takeUnretainedValue()] as? String ?? "1"
            for key in [factoryKey, kColorSyncDeviceDefaultProfileID.takeUnretainedValue() as String] {
                if let url = custom[key] as? URL { return url }
            }
        }
        return factory(id)
    }

    /// Uses `url` for the display, or its factory profile when nil.
    @discardableResult
    static func set(_ url: URL?, for id: CGDirectDisplayID) -> Bool {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return false }
        let info: NSDictionary = [
            kColorSyncDeviceDefaultProfileID.takeUnretainedValue(): (url as Any?) ?? kCFNull as Any,
            kColorSyncProfileUserScope.takeUnretainedValue(): kCFPreferencesCurrentUser as Any,
        ]
        return ColorSyncDeviceSetCustomProfiles(kColorSyncDisplayDeviceClass.takeUnretainedValue(), uuid, info)
    }

    /// Posted (distributed) when a display's profile changes.
    static let changedNotification = Notification.Name(kColorSyncDisplayDeviceProfilesNotification.takeUnretainedValue() as String)
}

/// Night Shift on or off right now, through CoreBrightness' `CBBlueLightClient` (not public API:
/// looked up at run time, every selector checked; missing → unavailable).
@MainActor
enum NightShift {
    private static let client: NSObject? = {
        _ = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY)
        guard let cls = NSClassFromString("CBBlueLightClient") as? NSObject.Type else { return nil }
        let object = cls.init()
        guard object.responds(to: NSSelectorFromString("getBlueLightStatus:")),
              object.responds(to: NSSelectorFromString("setEnabled:")) else { return nil }
        return object
    }()

    static var isAvailable: Bool { client != nil }

    /// Whether Night Shift is tinting the screen now. Status layout:
    /// `{BOOL active, enabled, sunSchedulePermitted; int mode; {{int,int},{int,int}} schedule; uint64 flags; BOOL available}`.
    static var isOn: Bool? {
        guard let client else { return nil }
        let sel = NSSelectorFromString("getBlueLightStatus:")
        guard let method = class_getInstanceMethod(type(of: client), sel) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> Bool
        let getter = unsafeBitCast(method_getImplementation(method), to: Getter.self)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 128, alignment: 8)
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: 128)
        guard getter(client, sel, buffer) else { return nil }
        return buffer.load(fromByteOffset: 0, as: UInt8.self) != 0
    }

    /// Turns Night Shift on (until its schedule turns it off) or off.
    static func set(_ on: Bool) {
        guard let client else { return }
        let sel = NSSelectorFromString("setEnabled:")
        guard let method = class_getInstanceMethod(type(of: client), sel) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Bool
        _ = unsafeBitCast(method_getImplementation(method), to: Setter.self)(client, sel, on)
    }
}
