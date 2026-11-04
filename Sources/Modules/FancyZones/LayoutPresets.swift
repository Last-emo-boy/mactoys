import CoreGraphics
import Foundation

/// Ready-made layouts for common kinds of work and for ultrawide displays. Picking one adds a
/// custom grid layout with its zones (editable like any other) and applies it to a display.
public enum LayoutPreset: String, CaseIterable, Identifiable, Sendable {
    // Workflows
    case vibecoding, writing, design, finance, marketing, meeting
    // Ultrawide displays
    case thirds, centerFocus, twoPlusCenter, fourColumns, fiveColumns

    public enum Group: Sendable { case workflow, ultrawide }

    public var id: String { rawValue }

    public var group: Group {
        switch self {
        case .vibecoding, .writing, .design, .finance, .marketing, .meeting: .workflow
        case .thirds, .centerFocus, .twoPlusCenter, .fourColumns, .fiveColumns: .ultrawide
        }
    }

    public static var workflows: [LayoutPreset] { allCases.filter { $0.group == .workflow } }
    public static var ultrawide: [LayoutPreset] { allCases.filter { $0.group == .ultrawide } }

    /// Localized name; also the name of the custom layout a preset creates.
    public var title: String {
        switch self {
        case .vibecoding: String(localized: "Vibecoding", comment: "FancyZones layout preset for coding with an AI assistant")
        case .writing: String(localized: "Writing", comment: "FancyZones layout preset name")
        case .design: String(localized: "Design", comment: "FancyZones layout preset name (graphic or UI design work)")
        case .finance: String(localized: "Spreadsheets", comment: "FancyZones layout preset name (spreadsheet and finance work)")
        case .marketing: String(localized: "Social media", comment: "FancyZones layout preset name (marketing and social media work)")
        case .meeting: String(localized: "Meeting", comment: "FancyZones layout preset name (a video call)")
        case .thirds: String(localized: "Thirds", comment: "FancyZones layout preset: three equal columns")
        case .centerFocus: String(localized: "Center focus", comment: "FancyZones layout preset: a wide center column with a narrow one on each side")
        case .twoPlusCenter: String(localized: "Center + stack", comment: "FancyZones layout preset: a wide center, one side column, two stacked windows on the other side")
        case .fourColumns: String(localized: "Four columns", comment: "FancyZones layout preset name")
        case .fiveColumns: String(localized: "Five columns", comment: "FancyZones layout preset name")
        }
    }

    /// A short line: what goes where.
    public var summary: String {
        switch self {
        case .vibecoding: String(localized: "Editor over terminal, live preview, AI chat.")
        case .writing: String(localized: "Outline, your draft, research over notes.")
        case .design: String(localized: "A big canvas beside references, assets and chat.")
        case .finance: String(localized: "A wide sheet, a dashboard over a calculator.")
        case .marketing: String(localized: "Two feeds, your calendar, analytics below it.")
        case .meeting: String(localized: "The call over its chat, notes beside it.")
        case .thirds: String(localized: "Chat, the main task and reference, side by side.")
        case .centerFocus: String(localized: "A wide center between narrow tool columns.")
        case .twoPlusCenter: String(localized: "A wide center, a side column, two stacked windows.")
        case .fourColumns: String(localized: "Four equal columns, each laptop-wide on 32:9.")
        case .fiveColumns: String(localized: "Five narrow columns for feeds and chats.")
        }
    }

    /// SF Symbols for what each zone holds (zone order), drawn in the gallery's diagrams.
    public var zoneSymbols: [String] {
        switch self {
        case .vibecoding: ["chevron.left.forwardslash.chevron.right", "terminal", "safari", "sparkles"]
        case .writing: ["list.bullet.indent", "doc.text", "safari", "note.text"]
        case .design: ["paintbrush.pointed", "photo.on.rectangle", "square.stack.3d.up", "bubble.left.and.bubble.right"]
        case .finance: ["tablecells", "chart.bar.xaxis", "plus.forwardslash.minus"]
        case .marketing: ["person.2", "number", "calendar", "chart.line.uptrend.xyaxis"]
        case .meeting: ["video", "bubble.left.and.bubble.right", "note.text"]
        case .thirds: ["bubble.left.and.bubble.right", "macwindow", "book"]
        case .centerFocus: ["slider.horizontal.3", "macwindow", "bubble.left.and.bubble.right"]
        case .twoPlusCenter: ["folder", "macwindow", "sparkles", "terminal"]
        case .fourColumns: ["envelope", "chevron.left.forwardslash.chevron.right", "safari", "bubble.left.and.bubble.right"]
        case .fiveColumns: ["number", "person.2", "macwindow", "chart.bar.xaxis", "bubble.left.and.bubble.right"]
        }
    }

    /// The zone that holds the main work (drawn emphasized).
    public var primaryZone: Int {
        switch self {
        case .vibecoding: 0
        case .writing, .thirds, .centerFocus, .twoPlusCenter: 1
        case .design, .finance, .meeting: 0
        case .marketing: 2
        case .fourColumns: 1
        case .fiveColumns: 2
        }
    }

    /// The display shapes an ultrawide preset suits (not localized); nil for workflows.
    public var aspectLabel: String? {
        switch self {
        case .thirds, .centerFocus, .twoPlusCenter: "21:9 · 32:9"
        case .fourColumns, .fiveColumns: "32:9"
        default: nil
        }
    }

    /// The display size the gallery draws an ultrawide preset on, so it looks the part.
    public var referenceSize: CGSize? {
        switch self {
        case .thirds, .centerFocus, .twoPlusCenter: CGSize(width: 3440, height: 1440)
        case .fourColumns, .fiveColumns: CGSize(width: 5120, height: 1440)
        default: nil
        }
    }

    /// The preset's zones (normalized: numbered column by column, top to bottom).
    public var grid: GridLayout {
        let g: GridLayout
        switch self {
        case .vibecoding:
            // Editor over terminal | preview | chat
            g = GridLayout(rows: [0.64, 0.36], columns: [0.38, 0.37, 0.25], cells: [[0, 2, 3], [1, 2, 3]])
        case .writing:
            // Outline | draft | research over notes
            g = GridLayout(rows: [0.55, 0.45], columns: [0.2, 0.5, 0.3], cells: [[0, 1, 2], [0, 1, 3]])
        case .design:
            // Canvas | references, assets, chat
            g = GridLayout(rows: [0.34, 0.33, 0.33], columns: [0.75, 0.25], cells: [[0, 1], [0, 2], [0, 3]])
        case .finance:
            // Sheet | dashboard over calculator
            g = GridLayout(rows: [0.58, 0.42], columns: [0.64, 0.36], cells: [[0, 1], [0, 2]])
        case .marketing:
            // Feed | feed | calendar over analytics
            g = GridLayout(rows: [0.6, 0.4], columns: [0.2, 0.2, 0.6], cells: [[0, 1, 2], [0, 1, 3]])
        case .meeting:
            // Call over chat | notes
            g = GridLayout(rows: [0.68, 0.32], columns: [0.62, 0.38], cells: [[0, 2], [1, 2]])
        case .thirds:
            g = .columns(3)
        case .centerFocus:
            g = GridLayout(rows: [1], columns: [0.25, 0.5, 0.25], cells: [[0, 1, 2]])
        case .twoPlusCenter:
            g = GridLayout(rows: [0.5, 0.5], columns: [0.25, 0.5, 0.25], cells: [[0, 1, 2], [0, 1, 3]])
        case .fourColumns:
            g = .columns(4)
        case .fiveColumns:
            g = .columns(5)
        }
        return g.normalized()
    }

    /// A new custom grid layout with the preset's zones.
    public func makeLayout(name: String? = nil) -> ZoneLayout {
        var l = ZoneLayout.newGrid(name: name ?? title)
        l.grid = grid
        l.zoneCount = l.count
        return l
    }

    /// Looks a preset up by id or (case-insensitive) title, for URLs.
    public static func resolve(_ query: String) -> LayoutPreset? {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return allCases.first { $0.rawValue.lowercased() == q || $0.title.lowercased() == q }
    }
}

extension LayoutLibrary {
    /// The custom layout for `preset`: one made from it earlier and still untouched (same name and
    /// zones) is reused, so picking a preset twice doesn't pile up copies; otherwise a new one.
    public mutating func adopt(_ preset: LayoutPreset) -> ZoneLayout {
        let grid = preset.grid
        if let existing = custom.first(where: { $0.kind == .customGrid && $0.grid == grid && $0.name == preset.title }) {
            return existing
        }
        let layout = preset.makeLayout(name: uniqueName(preset.title))
        add(layout)
        return layout
    }
}
