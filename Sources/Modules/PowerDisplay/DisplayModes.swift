import CoreGraphics
import Foundation

/// One display mode as plain data (a `CGDisplayMode` can't be stored or built in tests).
struct DisplayModeInfo: Equatable, Hashable, Sendable, Codable {
    /// Points: the size the desktop "looks like".
    var width: Int
    var height: Int
    /// Backing pixels.
    var pixelWidth: Int
    var pixelHeight: Int
    /// Hertz; 0 when the display doesn't report one.
    var refreshRate: Double
    var ioFlags: UInt32
    /// `CGDisplayModeGetIODisplayModeID`, unique per mode of one display.
    var modeID: Int32
    var isUsable = true

    /// IOKit `kDisplayModeNativeFlag`: the panel's own pixel grid.
    static let nativeFlag: UInt32 = 0x0200_0000
    /// IOKit `kDisplayModeDefaultFlag`: the mode macOS picks by default.
    static let defaultFlag: UInt32 = 0x0000_0004

    var isHiDPI: Bool { pixelWidth > width }
    var isNative: Bool { ioFlags & Self.nativeFlag != 0 }
    var isDefault: Bool { ioFlags & Self.defaultFlag != 0 }
    var resolution: ResolutionKey { ResolutionKey(width: width, height: height, pixelWidth: pixelWidth, pixelHeight: pixelHeight) }
}

/// A resolution independent of refresh rate, also the persisted favorite key: `1728x1117/3456x2234`.
struct ResolutionKey: Hashable, Sendable, Codable {
    var width: Int
    var height: Int
    var pixelWidth: Int
    var pixelHeight: Int

    var isHiDPI: Bool { pixelWidth > width }
    var string: String { "\(width)x\(height)/\(pixelWidth)x\(pixelHeight)" }
    /// `2560 × 1440` (digits only, no grouping).
    var title: String { "\(width) × \(height)" }

    init(width: Int, height: Int, pixelWidth: Int, pixelHeight: Int) {
        self.width = width
        self.height = height
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    init?(string: String) {
        let parts = string.split(separator: "/")
        guard parts.count == 2, let points = Self.size(parts[0]), let pixels = Self.size(parts[1]) else { return nil }
        self.init(width: points.0, height: points.1, pixelWidth: pixels.0, pixelHeight: pixels.1)
    }

    private static func size(_ s: Substring) -> (Int, Int)? {
        let wh = s.lowercased().split(separator: "x")
        guard wh.count == 2, let w = Int(wh[0]), let h = Int(wh[1]), w > 0, h > 0 else { return nil }
        return (w, h)
    }
}

/// An aspect ratio, snapped to the common names when close ("16:9", "21:9"), otherwise its value.
struct AspectRatio: Hashable, Sendable {
    /// "16:9", or nil for an unusual ratio.
    var name: String?
    /// Width ÷ height, rounded to two decimals for unusual ratios.
    var value: Double

    /// Common ratios. 21:9 is a marketing name for several ratios between 2.33 and 2.4.
    static let known: [(name: String, values: [Double])] = [
        ("16:9", [16.0 / 9]), ("16:10", [1.6]), ("21:9", [21.0 / 9, 64.0 / 27, 43.0 / 18, 2.4]),
        ("32:9", [32.0 / 9]), ("32:10", [3.2]), ("4:3", [4.0 / 3]), ("5:4", [1.25]), ("3:2", [1.5]),
        ("5:3", [5.0 / 3]), ("17:9", [17.0 / 9, 256.0 / 135]), ("1:1", [1]),
        ("9:16", [9.0 / 16]), ("10:16", [0.625]), ("3:4", [0.75]), ("2:3", [2.0 / 3]),
    ]

    /// Relative tolerance for snapping (1366 × 768 is 16:9, 1360 × 768 too).
    static let tolerance = 0.012

    static func of(width: Int, height: Int) -> AspectRatio {
        guard width > 0, height > 0 else { return AspectRatio(name: nil, value: 0) }
        let r = Double(width) / Double(height)
        for k in known {
            for v in k.values where abs(r - v) / v <= tolerance {
                return AspectRatio(name: k.name, value: k.values[0])
            }
        }
        return AspectRatio(name: nil, value: (r * 100).rounded() / 100)
    }

    /// "16:9", or "1.55:1" with the locale's decimal separator.
    func title(locale: Locale = .current) -> String {
        if let name { return name }
        return "\(value.formatted(.number.precision(.fractionLength(2)).locale(locale))):1"
    }
}

/// One resolution in a list, with the refresh rates it comes in.
struct ResolutionEntry: Identifiable, Equatable, Sendable {
    var key: ResolutionKey
    /// Fastest refresh first.
    var modes: [DisplayModeInfo]
    var isCurrent = false
    var isFavorite = false

    var id: String { key.string }
    var isHiDPI: Bool { key.isHiDPI }
    var isNative: Bool { modes.contains(where: \.isNative) }
    var isDefault: Bool { modes.contains(where: \.isDefault) }
    var refreshRates: [Double] { modes.map(\.refreshRate) }
}

/// Resolutions that share an aspect ratio.
struct AspectGroup: Identifiable, Equatable, Sendable {
    var aspect: AspectRatio
    /// Largest first.
    var entries: [ResolutionEntry]

    var id: String { aspect.name ?? String(aspect.value) }
    /// The panel's native resolution is in this group.
    var isNative: Bool { entries.contains(where: \.isNative) }
}

/// A display's modes, organized for the flyout and the command line: one entry per resolution
/// (refresh rates folded in), grouped by aspect ratio, with HiDPI, native, current and favorites.
struct ModeCatalog: Equatable, Sendable {
    var groups: [AspectGroup]
    var current: DisplayModeInfo?
    /// In the order the user starred them; favorites that no longer exist are skipped.
    var favorites: [ResolutionEntry]

    /// - Parameters:
    ///   - favorites: `ResolutionKey.string`s.
    ///   - hideLowResolutionDuplicates: drop 1× modes whose size also exists as HiDPI.
    init(modes: [DisplayModeInfo], current: DisplayModeInfo?, favorites: [String] = [],
         hideLowResolutionDuplicates: Bool = false) {
        self.current = current
        let usable = modes.filter { $0.isUsable && $0.width > 0 && $0.height > 0 }
        let byKey = Dictionary(grouping: usable, by: \.resolution)
        let hiDPISizes = Set(byKey.keys.filter(\.isHiDPI).map { "\($0.width)x\($0.height)" })
        let favoriteSet = Set(favorites)
        let currentKey = current?.resolution
        var entries: [ResolutionEntry] = []
        for (key, list) in byKey {
            if hideLowResolutionDuplicates && !key.isHiDPI && hiDPISizes.contains("\(key.width)x\(key.height)")
                && key != currentKey { continue }
            var sorted = list.sorted { a, b in
                let ra = RefreshFormat.rounded(a.refreshRate), rb = RefreshFormat.rounded(b.refreshRate)
                return ra != rb ? ra > rb : a.modeID < b.modeID
            }
            // The same rate can appear twice (different timings); keep the first.
            var seen = Set<Int>()
            sorted = sorted.filter { seen.insert(Int(($0.refreshRate * 100).rounded())).inserted }
            entries.append(ResolutionEntry(key: key, modes: sorted, isCurrent: key == currentKey,
                                           isFavorite: favoriteSet.contains(key.string)))
        }
        let grouped = Dictionary(grouping: entries) { AspectRatio.of(width: $0.key.width, height: $0.key.height) }
        groups = grouped.map { AspectGroup(aspect: $0.key, entries: $0.value.sorted(by: Self.larger)) }
            .sorted { a, b in
                if a.isNative != b.isNative { return a.isNative }
                if a.entries.count != b.entries.count { return a.entries.count > b.entries.count }
                return a.aspect.value > b.aspect.value
            }
        let all = Dictionary(entries.map { ($0.key.string, $0) }, uniquingKeysWith: { a, _ in a })
        var seenFavorites = Set<String>()
        self.favorites = favorites.compactMap { seenFavorites.insert($0).inserted ? all[$0] : nil }
    }

    /// Bigger desktop first; for the same size, HiDPI first.
    static func larger(_ a: ResolutionEntry, _ b: ResolutionEntry) -> Bool {
        if a.key.width != b.key.width { return a.key.width > b.key.width }
        if a.key.height != b.key.height { return a.key.height > b.key.height }
        return a.key.isHiDPI && !b.key.isHiDPI
    }

    var entries: [ResolutionEntry] { groups.flatMap(\.entries) }
    var currentEntry: ResolutionEntry? { entries.first(where: \.isCurrent) }
    var isEmpty: Bool { groups.isEmpty }

    /// The refresh rates of the current resolution, fastest first.
    var refreshRates: [Double] { currentEntry?.refreshRates ?? [] }

    func entry(_ key: ResolutionKey) -> ResolutionEntry? { entries.first { $0.key == key } }

    /// The mode to switch to for a resolution: the requested refresh rate (or the current one)
    /// when it exists, else the closest one, else the fastest.
    func mode(for key: ResolutionKey, refresh: Double? = nil) -> DisplayModeInfo? {
        guard let entry = entry(key) else { return nil }
        guard let wanted = refresh ?? current?.refreshRate, wanted > 0 else { return entry.modes.first }
        return entry.modes.min { abs($0.refreshRate - wanted) < abs($1.refreshRate - wanted) }
    }

    /// The current resolution at another refresh rate.
    func mode(refresh: Double) -> DisplayModeInfo? {
        guard let key = current?.resolution else { return nil }
        return mode(for: key, refresh: refresh)
    }

    /// Finds the mode a command-line request names; nil when no resolution matches.
    func match(_ request: ModeRequest) -> DisplayModeInfo? {
        if let id = request.modeID {
            return entries.lazy.flatMap(\.modes).first { $0.modeID == id }
        }
        let candidates = entries.filter { e in
            e.key.width == request.width && e.key.height == request.height
                && (request.hiDPI == nil || e.key.isHiDPI == request.hiDPI)
        }
        // Without --hidpi/--no-hidpi, prefer the current kind, then HiDPI.
        let preferHiDPI = current?.isHiDPI ?? true
        guard let pick = candidates.sorted(by: { a, b in
            if a.key.isHiDPI != b.key.isHiDPI { return a.key.isHiDPI == preferHiDPI }
            return a.key.pixelWidth > b.key.pixelWidth
        }).first else { return nil }
        return mode(for: pick.key, refresh: request.refresh)
    }
}

/// `2560x1440`, `2560x1440@60`, `1920x1080@59.94` — what `set-mode` and `mactoys://…/set-mode` accept.
struct ModeRequest: Equatable, Sendable {
    var width = 0
    var height = 0
    var refresh: Double?
    /// nil: either.
    var hiDPI: Bool?
    var modeID: Int32?

    static func parse(_ text: String) -> ModeRequest? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        let parts = t.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return nil }
        let size = parts[0].replacingOccurrences(of: "×", with: "x").split(separator: "x")
        guard size.count == 2, let w = Int(size[0]), let h = Int(size[1]), w > 0, h > 0 else { return nil }
        var r = ModeRequest(width: w, height: h)
        if parts.count == 2 {
            let hz = parts[1].replacingOccurrences(of: "hz", with: "")
            guard let rate = Double(hz), rate > 0 else { return nil }
            r.refresh = rate
        }
        return r
    }
}

/// How refresh rates read: "120 Hz", "59.94 Hz", "ProMotion".
enum RefreshFormat {
    /// Rates are rounded to hundredths (displays report 59.93998718…).
    static func rounded(_ rate: Double) -> Double { (rate * 100).rounded() / 100 }

    /// The built-in panel's fastest rate on a ProMotion Mac is its adaptive mode.
    static func isProMotion(_ rate: Double, builtIn: Bool, rates: [Double]) -> Bool {
        builtIn && rate >= 100 && rate == rates.max() && rates.count > 1
    }

    static func title(_ rate: Double, proMotion: Bool = false, locale: Locale = .current) -> String {
        if proMotion { return "ProMotion" }
        guard rate > 0 else { return String(localized: "Default", comment: "Refresh rate the display doesn't report") }
        return Measurement(value: rounded(rate), unit: UnitFrequency.hertz)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided,
                                    numberFormatStyle: .number.precision(.fractionLength(0...2))).locale(locale))
    }
}

/// Reads and switches modes through CoreGraphics. Main thread or any single thread.
enum DisplayModeReader {
    /// Every mode, including HiDPI "looks like" modes and their low-resolution duplicates.
    static func modes(_ id: CGDirectDisplayID) -> [DisplayModeInfo] {
        cgModes(id).map(info)
    }

    static func current(_ id: CGDirectDisplayID) -> DisplayModeInfo? {
        CGDisplayCopyDisplayMode(id).map(info)
    }

    static func catalog(_ id: CGDirectDisplayID, favorites: [String], hideLowResolutionDuplicates: Bool) -> ModeCatalog {
        ModeCatalog(modes: modes(id), current: current(id), favorites: favorites,
                    hideLowResolutionDuplicates: hideLowResolutionDuplicates)
    }

    private static func cgModes(_ id: CGDirectDisplayID) -> [CGDisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        return (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode]) ?? []
    }

    static func info(_ m: CGDisplayMode) -> DisplayModeInfo {
        DisplayModeInfo(width: m.width, height: m.height, pixelWidth: m.pixelWidth, pixelHeight: m.pixelHeight,
                        refreshRate: m.refreshRate, ioFlags: m.ioFlags, modeID: m.ioDisplayModeID,
                        isUsable: m.isUsableForDesktopGUI())
    }

    /// Switches a display to a mode, permanently (as System Settings does).
    @discardableResult
    static func apply(_ mode: DisplayModeInfo, to id: CGDirectDisplayID) -> Bool {
        guard let cg = cgModes(id).first(where: { info($0) == mode })
                ?? cgModes(id).first(where: { $0.ioDisplayModeID == mode.modeID }) else { return false }
        return DisplayConfiguration.run { config in CGConfigureDisplayWithDisplayMode(config, id, cg, nil) }
    }
}

/// One `CGBeginDisplayConfiguration` … `CGCompleteDisplayConfiguration` transaction.
enum DisplayConfiguration {
    /// Runs `body` in a configuration transaction; cancels it when any step fails.
    @discardableResult
    static func run(_ option: CGConfigureOption = .permanently, _ body: (CGDisplayConfigRef) -> CGError) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        guard body(config) == .success else {
            CGCancelDisplayConfiguration(config)
            return false
        }
        return CGCompleteDisplayConfiguration(config, option) == .success
    }
}
