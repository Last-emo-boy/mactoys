import Foundation
import MacToysCore
import Observation

/// What the activation shortcut does.
public enum ColorPickerActivation: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Opens the editor (history, shades, formats).
    case openEditor
    /// Opens the picker; a click picks, copies and opens the editor.
    case pickThenEditor
    /// Opens the picker; a click picks, copies and closes.
    case pickOnly

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .openEditor: String(localized: "Open editor", comment: "Color Picker activation behavior")
        case .pickThenEditor: String(localized: "Pick a color, then open editor")
        case .pickOnly: String(localized: "Only pick a color")
        }
    }
}

/// What a mouse button does while the picker is up.
public enum ColorPickerClick: String, Codable, CaseIterable, Sendable, Identifiable {
    case pickThenEditor, pickAndClose, close
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .pickThenEditor: String(localized: "Pick a color and open editor")
        case .pickAndClose: String(localized: "Pick a color and close")
        case .close: String(localized: "Close", comment: "Color Picker mouse action: close the picker without picking")
        }
    }
}

public struct ColorPickerSettings: Codable, Equatable, Sendable {
    public var activationShortcut: Shortcut? = Shortcut(8, [.control, .option])   // ⌃⌥C
    public var activation: ColorPickerActivation = .pickThenEditor
    public var leftClick: ColorPickerClick = .pickThenEditor
    public var middleClick: ColorPickerClick = .pickAndClose
    public var rightClick: ColorPickerClick = .close
    /// Name of the format used when copying (one of `formats`).
    public var defaultFormat = "HEX"
    public var showColorName = false
    public var historyLimit = 20
    /// Magnifier cells across the loupe (odd, 7…41).
    public var magnifierCells = 13
    public var formats: [ColorFormat] = ColorFormat.builtIns

    public init() {}

    /// The format used for copying, falling back to HEX when the chosen one was deleted.
    public var copyFormat: ColorFormat {
        formats.first { $0.name == defaultFormat } ?? ColorFormat.builtIns[0]
    }

    public func action(forButton button: Int) -> ColorPickerClick {
        switch button {
        case 0: leftClick
        case 2: middleClick
        default: rightClick
        }
    }
}

/// Picked colors, newest first, persisted as JSON next to the module's data.
@MainActor
@Observable
public final class ColorHistory {
    public private(set) var colors: [ColorValue] = []
    public var limit: Int {
        didSet { trim(); save() }
    }

    @ObservationIgnored private let file: URL?
    @ObservationIgnored private let log = Log.for("colorpicker")

    /// - Parameter file: where to persist; `nil` keeps the history in memory (previews, tests).
    public init(file: URL?, limit: Int = 20) {
        self.file = file
        self.limit = limit
        guard let file, FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            colors = try JSONDecoder().decode([ColorValue].self, from: Data(contentsOf: file))
            trim()
        } catch {
            log.error("Could not read color history: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Moves `color` to the front (adding it when new).
    public func add(_ color: ColorValue) {
        colors.removeAll { $0 == color }
        colors.insert(color, at: 0)
        trim()
        save()
    }

    public func remove(_ color: ColorValue) {
        colors.removeAll { $0 == color }
        save()
    }

    public func clear() {
        colors.removeAll()
        save()
    }

    /// Replaces the list (preview data).
    public func replace(with list: [ColorValue]) {
        colors = list
        trim()
        save()
    }

    private func trim() {
        let cap = max(1, limit)
        if colors.count > cap { colors.removeLast(colors.count - cap) }
    }

    private func save() {
        guard let file else { return }
        do {
            try JSONEncoder().encode(colors).write(to: file, options: .atomic)
        } catch {
            log.error("Could not save color history: \(error.localizedDescription, privacy: .public)")
        }
    }
}
