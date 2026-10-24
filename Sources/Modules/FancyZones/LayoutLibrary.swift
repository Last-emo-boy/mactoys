import CoreGraphics
import Foundation

/// Every layout the user has (templates with their parameters, custom layouts) and which one
/// each display uses. Persisted as `fancyzones.layouts.json` in the settings folder.
public struct LayoutLibrary: Codable, Equatable, Sendable {
    /// Settings id of the library: `SettingsStore.shared.load(LayoutLibrary.storageID, default: LayoutLibrary())`.
    public static let storageID = "fancyzones.layouts"

    /// The built-in templates, one per template kind, with their editable parameters.
    public var templates: [ZoneLayout]
    /// Custom grid and canvas layouts, in editor order.
    public var custom: [ZoneLayout]
    /// Display key (`NSScreen.stableID`, or `ZoneDisplay.allDisplaysKey`) → layout id.
    public var assignments: [String: String]

    public init(templates: [ZoneLayout] = ZoneLayout.defaultTemplates, custom: [ZoneLayout] = [],
                assignments: [String: String] = [:]) {
        self.templates = templates
        self.custom = custom
        self.assignments = assignments
    }

    public var all: [ZoneLayout] { templates + custom }

    public func layout(id: String) -> ZoneLayout? {
        templates.first { $0.id == id } ?? custom.first { $0.id == id }
    }

    public func layout(quickKey: Int) -> ZoneLayout? {
        all.first { $0.quickKey == quickKey }
    }

    /// Looks a layout up by id, quick key number, or name (case-insensitive) — for URLs and the CLI.
    public func resolve(_ query: String) -> ZoneLayout? {
        let q = query.trimmingCharacters(in: .whitespaces)
        if let n = Int(q), let l = layout(quickKey: n) { return l }
        if let l = layout(id: q) { return l }
        let lower = q.lowercased()
        return all.first { $0.name.lowercased() == lower }
            ?? templates.first { $0.kind.rawValue.lowercased() == lower.replacingOccurrences(of: " ", with: "") }
    }

    /// The layout a display uses: its assignment, or the default for its orientation.
    public func layout(forDisplay key: String, vertical: Bool, defaultHorizontal: String,
                       defaultVertical: String) -> ZoneLayout {
        if let id = assignments[key], let l = layout(id: id) { return l }
        let fallback = vertical ? defaultVertical : defaultHorizontal
        return layout(id: fallback) ?? templates.first { $0.kind == .priorityGrid } ?? .template(.priorityGrid)
    }

    /// Replaces the layout with the same id.
    public mutating func update(_ layout: ZoneLayout) {
        if let i = templates.firstIndex(where: { $0.id == layout.id }) { templates[i] = layout }
        else if let i = custom.firstIndex(where: { $0.id == layout.id }) { custom[i] = layout }
    }

    public mutating func add(_ layout: ZoneLayout) {
        custom.append(layout)
        if let key = layout.quickKey { setQuickKey(key, for: layout.id) }
    }

    /// Deletes a custom layout; displays that used it fall back to their default.
    public mutating func delete(id: String) {
        custom.removeAll { $0.id == id }
        assignments = assignments.filter { $0.value != id }
    }

    /// Gives `id` the quick key (1…9), taking it away from any other layout; nil clears it.
    public mutating func setQuickKey(_ key: Int?, for id: String) {
        for i in templates.indices {
            if templates[i].id == id { templates[i].quickKey = key }
            else if key != nil && templates[i].quickKey == key { templates[i].quickKey = nil }
        }
        for i in custom.indices {
            if custom[i].id == id { custom[i].quickKey = key }
            else if key != nil && custom[i].quickKey == key { custom[i].quickKey = nil }
        }
    }

    /// Layouts the mouse wheel cycles through while dragging: those with quick keys (in key
    /// order) when at least two have one, else the custom layouts when there are two or more,
    /// else every layout except "No layout".
    public var wheelCycle: [ZoneLayout] {
        let keyed = all.filter { $0.quickKey != nil }.sorted { ($0.quickKey ?? 0) < ($1.quickKey ?? 0) }
        if keyed.count >= 2 { return keyed }
        if custom.count >= 2 { return custom }
        return all.filter { $0.kind != .blank }
    }

    /// The layout `steps` away from `current` in `wheelCycle`, wrapping around.
    public func cycled(from current: String, steps: Int) -> ZoneLayout? {
        let list = wheelCycle
        guard list.count >= 2 else { return nil }
        let i = list.firstIndex { $0.id == current } ?? (steps > 0 ? -1 : 0)
        let n = list.count
        return list[((i + steps) % n + n) % n]
    }

    /// "Custom layout", "Custom layout 2", … — the first name not taken.
    public func uniqueName(_ base: String) -> String {
        let names = Set(all.map(\.name))
        if !names.contains(base) { return base }
        var n = 2
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    /// Repairs a library read from disk: exactly one template per kind, in canonical order,
    /// custom layouts with the right payload, and unique quick keys.
    public func normalized() -> LayoutLibrary {
        var lib = self
        lib.templates = ZoneLayout.Kind.templates.map { kind in
            var t = templates.first { $0.kind == kind } ?? .template(kind)
            t.id = kind.rawValue
            t.zoneCount = max(kind == .blank ? 0 : 1, min(t.zoneCount, 40))
            return t
        }
        lib.custom = custom.compactMap { l -> ZoneLayout? in
            var l = l
            switch l.kind {
            case .customGrid:
                guard let g = l.grid, g.isWellFormed else { return nil }
                l.grid = g.normalized()
                guard l.grid?.isValid == true else { return nil }
            case .canvas:
                guard l.canvas?.isValid == true else { return nil }
            default:
                return nil
            }
            l.zoneCount = l.count
            return l
        }
        var seen = Set<Int>()
        for i in lib.templates.indices {
            if let k = lib.templates[i].quickKey, !(1...9).contains(k) || !seen.insert(k).inserted {
                lib.templates[i].quickKey = nil
            }
        }
        for i in lib.custom.indices {
            if let k = lib.custom[i].quickKey, !(1...9).contains(k) || !seen.insert(k).inserted {
                lib.custom[i].quickKey = nil
            }
        }
        return lib
    }
}
