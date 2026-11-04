import AppKit
import MacToysCore

/// A target for one layout: a screen, or every screen combined when zones span displays.
struct ZoneDisplay: Identifiable, Equatable {
    /// Key of the combined display used when "Allow zones to span across displays" is on.
    static let allDisplaysKey = "all-displays"

    /// The display's UUID (stable across reconnects, see `keys(for:)`), or `allDisplaysKey`.
    let key: String
    let name: String
    /// 1-based, left to right.
    let number: Int
    /// Full frame in top-left coordinates.
    let frame: CGRect
    /// Visible frame (menu bar and Dock excluded) in top-left coordinates: where zones go.
    let workArea: CGRect
    let isBuiltIn: Bool
    /// The key earlier versions stored this display's layout under (vendor/model/serial), read as
    /// a fallback and kept in step; nil when it is the same as `key`.
    var legacyKey: String? = nil

    /// Whether `key` names this display, under its current or its legacy key.
    func matches(_ key: String) -> Bool { key == self.key || key == legacyKey }

    var id: String { key }
    var isVertical: Bool { workArea.height > workArea.width }

    /// Current displays, left to right. With `spanning`, one display covering every screen.
    @MainActor
    static func current(spanning: Bool) -> [ZoneDisplay] {
        let screens = sortedScreens
        guard !screens.isEmpty else { return [] }
        if spanning && screens.count > 1 {
            let frame = screens.map(\.axFrame).reduce(CGRect.null) { $0.union($1) }
            let work = screens.map(\.axVisibleFrame).reduce(CGRect.null) { $0.union($1) }
            let name = String(localized: "All displays", comment: "FancyZones: every display combined into one canvas")
            return [ZoneDisplay(key: allDisplaysKey, name: name, number: 1, frame: frame, workArea: work, isBuiltIn: false)]
        }
        let keys = keys(for: screens.map(DisplayIdentity.init))
        return screens.enumerated().map { i, s in
            ZoneDisplay(key: keys[i].key, name: s.localizedName, number: i + 1, frame: s.axFrame,
                        workArea: s.axVisibleFrame, isBuiltIn: s.isBuiltIn, legacyKey: keys[i].legacy)
        }
    }

    @MainActor
    static var sortedScreens: [NSScreen] {
        NSScreen.screens.sorted { a, b in
            a.axFrame.minX != b.axFrame.minX ? a.axFrame.minX < b.axFrame.minX : a.axFrame.minY < b.axFrame.minY
        }
    }

    /// Storage keys for screens, in order. The key is the display's UUID, which macOS derives from
    /// the monitor itself and keeps across reconnects, sleep and reboots, even when the
    /// `CGDirectDisplayID` changes and for identical monitors without serial numbers. (Should two
    /// screens ever report the same UUID, the second gets `#2`, by position.) Without a UUID the
    /// vendor/model/serial key stands in.
    ///
    /// `legacy` is the key earlier versions used: vendor/model/serial, with the display id appended
    /// for identical monitors. Layouts saved under it are still found.
    static func keys(for screens: [DisplayIdentity]) -> [(key: String, legacy: String?)] {
        let hardware = screens.map(\.hardwareID)
        let legacy = screens.enumerated().map { i, s in
            hardware.filter { $0 == hardware[i] }.count > 1 ? "\(hardware[i])-\(s.displayID)" : hardware[i]
        }
        var seen: [String: Int] = [:]
        return screens.enumerated().map { i, s in
            guard let uuid = s.uuid, !uuid.isEmpty else { return (legacy[i], nil) }
            let n = (seen[uuid] ?? 0) + 1
            seen[uuid] = n
            return (n == 1 ? uuid : "\(uuid)#\(n)", legacy[i])
        }
    }

    /// Display containing a top-left point (nearest when outside all of them).
    static func containing(_ p: CGPoint, in displays: [ZoneDisplay]) -> ZoneDisplay? {
        displays.first { $0.frame.containsInclusive(p) }
            ?? displays.min { $0.frame.distance(to: p) < $1.frame.distance(to: p) }
    }

    /// Display showing most of a window frame.
    static func showing(_ rect: CGRect, in displays: [ZoneDisplay]) -> ZoneDisplay? {
        if let d = containing(rect.center, in: displays), d.frame.contains(rect.center) { return d }
        return displays.max { $0.frame.intersection(rect).area < $1.frame.intersection(rect).area }
    }
}

/// What identifies a screen: its UUID, its vendor/model/serial and its current display id.
struct DisplayIdentity: Equatable, Sendable {
    /// Changes when the display is reconnected or the Mac restarts.
    var displayID: CGDirectDisplayID
    /// `CGDisplayCreateUUIDFromDisplayID`: stable for the same monitor.
    var uuid: String?
    /// `NSScreen.stableID`: vendor-model-serial (the serial is 0 on many monitors).
    var hardwareID: String

    init(displayID: CGDirectDisplayID, uuid: String?, hardwareID: String) {
        self.displayID = displayID
        self.uuid = uuid
        self.hardwareID = hardwareID
    }

    @MainActor
    init(_ screen: NSScreen) {
        let id = screen.displayID
        let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue()
        self.init(displayID: id, uuid: uuid.flatMap { CFUUIDCreateString(nil, $0) as String? },
                  hardwareID: screen.stableID)
    }
}
