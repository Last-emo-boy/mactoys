import CoreGraphics
import Foundation
import MacToysCore

/// A display as it was when a layout was saved (global top-left coordinates).
public struct LayoutDisplay: Codable, Hashable, Sendable {
    /// Stable across reconnects (vendor-model-serial).
    public var key: String
    public var name: String
    public var frame: CGRect
    public var visible: CGRect
    public var isMain: Bool

    public init(key: String, name: String, frame: CGRect, visible: CGRect, isMain: Bool) {
        self.key = key
        self.name = name
        self.frame = frame
        self.visible = visible
        self.isMain = isMain
    }
}

/// One window of a saved layout.
public struct SavedWindow: Codable, Hashable, Sendable {
    public var bundleID: String
    public var appName: String
    /// Position among its app's windows, front to back, when the layout was saved.
    public var index: Int
    /// Empty when the title couldn't be read.
    public var title: String
    public var frame: CGRect
    /// `LayoutDisplay.key` of the display that showed it.
    public var displayKey: String

    public init(bundleID: String, appName: String, index: Int, title: String, frame: CGRect, displayKey: String) {
        self.bundleID = bundleID
        self.appName = appName
        self.index = index
        self.title = title
        self.frame = frame
        self.displayKey = displayKey
    }
}

/// The frames of the windows that were open, for one display arrangement.
public struct SavedLayout: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var displays: [LayoutDisplay]
    public var windows: [SavedWindow]
    public var created: Date
    /// Restore it on its own when its display arrangement appears again.
    public var autoRestore: Bool
    /// Saved on its own when its display arrangement went away.
    public var isAutomatic: Bool

    public init(id: UUID = UUID(), name: String, displays: [LayoutDisplay], windows: [SavedWindow], created: Date = Date(),
                autoRestore: Bool = false, isAutomatic: Bool = false) {
        self.id = id
        self.name = name
        self.displays = displays
        self.windows = windows
        self.created = created
        self.autoRestore = autoRestore
        self.isAutomatic = isAutomatic
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        displays = try c.decodeIfPresent([LayoutDisplay].self, forKey: .displays) ?? []
        windows = try c.decodeIfPresent([SavedWindow].self, forKey: .windows) ?? []
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
        autoRestore = try c.decodeIfPresent(Bool.self, forKey: .autoRestore) ?? false
        isAutomatic = try c.decodeIfPresent(Bool.self, forKey: .isAutomatic) ?? false
    }

    public var arrangementKey: String { DisplayArrangement.key(displays) }
    public var appCount: Int { Set(windows.map(\.bundleID)).count }

    /// A window found on screen, front to back, before it becomes part of a layout.
    struct Found: Equatable {
        var bundleID: String
        var appName: String
        var title: String
        var frame: CGRect
    }

    /// A layout of `windows` (front to back): numbers each app's windows in that order and records
    /// the display each one is on.
    static func assemble(name: String, windows: [Found], displays: [LayoutDisplay], date: Date = Date()) -> SavedLayout {
        var counts: [String: Int] = [:]
        let saved = windows.map { w -> SavedWindow in
            let index = counts[w.bundleID, default: 0]
            counts[w.bundleID] = index + 1
            let display = DisplayArrangement.display(showing: w.frame, among: displays)
            return SavedWindow(bundleID: w.bundleID, appName: w.appName, index: index, title: w.title, frame: w.frame,
                               displayKey: display?.key ?? "")
        }
        return SavedLayout(name: name, displays: displays, windows: saved, created: date)
    }
}

/// Display arrangements: which displays are connected, at which resolutions and positions.
enum DisplayArrangement {
    /// Identifies a set of displays with their sizes and positions, whatever order they're listed in.
    static func key(_ displays: [LayoutDisplay]) -> String {
        displays.map { d in
            let f = d.frame
            return "\(d.key)@\(Int(f.minX.rounded())),\(Int(f.minY.rounded())),\(Int(f.width.rounded()))x\(Int(f.height.rounded()))"
        }
        .sorted()
        .joined(separator: "|")
    }

    /// Per-display keys from stable ids; identical monitors that report no serial number get their
    /// display id appended so they stay apart.
    static func keys(stableIDs: [String], displayIDs: [UInt32]) -> [String] {
        stableIDs.enumerated().map { i, id in
            stableIDs.filter { $0 == id }.count > 1 && displayIDs.indices.contains(i) ? "\(id)-\(displayIDs[i])" : id
        }
    }

    /// The saved display showing most of a frame.
    static func display(showing frame: CGRect, among displays: [LayoutDisplay]) -> LayoutDisplay? {
        let c = CGPoint(x: frame.midX, y: frame.midY)
        if let d = displays.first(where: { $0.frame.contains(c) }) { return d }
        return displays.max { $0.frame.intersection(frame).area < $1.frame.intersection(frame).area }
    }

    /// The arrangement's display names, main display first: "Built-in Display and LG UltraFine".
    static func name(of displays: [LayoutDisplay]) -> String {
        let ordered = displays.sorted { ($0.isMain ? 0 : 1, $0.frame.minX) < ($1.isMain ? 0 : 1, $1.frame.minX) }
        return ordered.map(\.name).formatted(.list(type: .and))
    }
}

/// A window that is open now, as layout matching sees it.
struct LiveWindow: Equatable {
    var bundleID: String
    /// Position among its app's windows, front to back.
    var index: Int
    var title: String
}

/// Pairs saved windows with open ones.
enum LayoutMatcher {
    /// For each saved window, the index in `live` of the window that takes its place, or nil when its
    /// app or window isn't open. Within an app: the same title first, then the same position among
    /// the app's windows, then the windows left over, in order. Each open window is used once.
    static func match(saved: [SavedWindow], live: [LiveWindow]) -> [Int?] {
        var result = [Int?](repeating: nil, count: saved.count)
        var used = Set<Int>()
        var bundles: [String] = []
        for w in saved where !bundles.contains(w.bundleID) { bundles.append(w.bundleID) }
        for bundle in bundles {
            let s = saved.indices.filter { saved[$0].bundleID == bundle }.sorted { saved[$0].index < saved[$1].index }
            let l = live.indices.filter { live[$0].bundleID == bundle }.sorted { live[$0].index < live[$1].index }
            func pass(_ fits: (SavedWindow, LiveWindow) -> Bool) {
                for i in s where result[i] == nil {
                    if let j = l.first(where: { !used.contains($0) && fits(saved[i], live[$0]) }) {
                        result[i] = j
                        used.insert(j)
                    }
                }
            }
            pass { !$0.title.isEmpty && $0.title == $1.title }
            pass { $0.index == $1.index }
            pass { _, _ in true }
        }
        return result
    }
}

/// Where saved windows go on the displays connected now.
enum LayoutPlanner {
    /// The frame for a saved window: exactly where it was when its display is connected as it was;
    /// moved along when the display was rearranged; scaled when its size changed; on the main
    /// display when its display is gone. Moved or scaled frames stay inside the visible area.
    static func target(for window: SavedWindow, in layout: SavedLayout, displays: [DisplayBox]) -> CGRect? {
        guard !displays.isEmpty else { return nil }
        let saved = layout.displays.first { $0.key == window.displayKey }
        let target = displays.first { $0.key == window.displayKey } ?? displays.first { $0.isMain } ?? displays[0]
        let tv = target.visible
        guard let saved, saved.visible.width > 0, saved.visible.height > 0 else {
            return Placement.clamp(window.frame, into: tv)
        }
        let sv = saved.visible
        if saved.key == target.key && saved.frame == target.frame && sv == tv { return window.frame }
        if abs(sv.width - tv.width) < 1 && abs(sv.height - tv.height) < 1 {
            return Placement.clamp(window.frame.offsetBy(dx: tv.minX - sv.minX, dy: tv.minY - sv.minY), into: tv)
        }
        let sx = tv.width / sv.width, sy = tv.height / sv.height
        let f = window.frame
        return Placement.clamp(CGRect(x: tv.minX + (f.minX - sv.minX) * sx, y: tv.minY + (f.minY - sv.minY) * sy,
                                      width: f.width * sx, height: f.height * sy), into: tv)
    }
}
