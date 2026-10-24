import AppKit
import Carbon.HIToolbox
import MacToysCore
import Observation

/// Display text for remaps.
@MainActor
enum RemapFormatting {
    private static var appNameCache: [String: String] = [:]

    /// "Xcode" for "com.apple.dt.Xcode"; the bundle id when the app isn't installed.
    static func appName(_ bundleID: String) -> String {
        if let cached = appNameCache[bundleID] { return cached }
        var name = bundleID
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            name = FileManager.default.displayName(atPath: url.path)
            if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        } else if let known = knownApps[bundleID] {
            name = known
        }
        appNameCache[bundleID] = name
        return name
    }

    /// Fallback names for sample data and apps that aren't installed.
    private static let knownApps = ["com.apple.dt.Xcode": "Xcode", "com.apple.Notes": "Notes",
                                    "com.apple.Safari": "Safari", "com.microsoft.VSCode": "VS Code"]

    static func scope(_ remap: Remap) -> String {
        if remap.apps.isEmpty { return "Global" }
        let names = remap.apps.map(appName)
        return names.count <= 2 ? names.joined(separator: ", ") : "\(names[0]) +\(names.count - 1)"
    }

    static func actionSummary(_ action: RemapAction) -> String {
        switch action.kind {
        case .send: action.combo?.description ?? "—"
        case .text: "“\(action.text ?? "")”"
        case .run: "Open " + programName(action.run?.path ?? "")
        case .openURL: "Open " + (action.url ?? "")
        case .disable: "Disabled"
        }
    }

    static func programName(_ path: String) -> String {
        let last = (path as NSString).lastPathComponent
        return last.hasSuffix(".app") ? String(last.dropLast(4)) : last
    }

    /// Secondary note after the target: "tap · ⌃ when held", "types text".
    static func annotation(_ remap: Remap) -> String? {
        var parts: [String] = []
        if remap.kind == .key && remap.tapAlone {
            parts.append("tap")
            if let hold = remap.holdKey { parts.append("\(hold.keycaps.last ?? hold.name) when held") }
            else if remap.trigger.key == .capsLock { parts.append("hold for Caps Lock") }
            else { parts.append("normal when held") }
            return parts.joined(separator: " · ")
        }
        switch remap.action.kind {
        case .text: return "types text"
        case .run:
            if let args = remap.action.run?.arguments, !args.isEmpty { return args }
            return nil
        case .openURL: return "opens URL"
        default: break
        }
        if remap.kind == .shortcut && remap.exactMatch { return "exact match" }
        return nil
    }
}

/// Remaps used by the editor preview (matches `design/exports/07-tool-windows.png`).
enum SampleRemaps {
    static let design: [Remap] = [
        Remap(kind: .key, trigger: KeyCombo([], .capsLock), action: .send(.escape), tapAlone: true,
              holdKey: .keyboard(kVK_Control)),
        .key(.keyboard(kVK_RightCommand), to: .send(.keyboard(kVK_F18))),
        .key(.keyboard(kVK_ISO_Section), to: .send(.keyboard(kVK_ANSI_Grave))),
        .shortcut(KeyCombo([.option, .shift], .keyboard(kVK_ANSI_K)),
                  to: .send(KeyCombo([.command, .shift], .keyboard(kVK_ANSI_K))), apps: ["com.apple.dt.Xcode"]),
        .shortcut(KeyCombo([.control, .option], .keyboard(kVK_ANSI_N)),
                  to: .launch(RunSpec(path: "/System/Applications/Notes.app"))),
        .shortcut(KeyCombo([.control, .option], .keyboard(kVK_ANSI_E)), to: .type("w33d@example.com")),
        .shortcut(KeyCombo([.control, .option, .shift], .keyboard(kVK_UpArrow)), to: .send(.media(0))),
    ]
}

/// State of the Keyboard Manager editor window.
@MainActor
@Observable
final class RemapEditorModel {
    enum Filter: Hashable {
        case all, keys, shortcuts, global
        case app(String)
    }

    /// A remap being added or edited in the sheet.
    struct Draft: Identifiable {
        var remap: Remap
        var isNew: Bool
        var id: UUID { remap.id }
    }

    @ObservationIgnored weak var module: KeyboardManagerModule?
    private var previewRemaps: [Remap]?
    var filter: Filter = .all
    var search = ""
    var selection: Set<UUID> = []
    var draft: Draft?
    /// Anchor for ⇧-click range selection.
    @ObservationIgnored var selectionAnchor: UUID?

    init(module: KeyboardManagerModule, preview: [Remap]? = nil) {
        self.module = module
        self.previewRemaps = preview
    }

    var remaps: [Remap] {
        get { previewRemaps ?? module?.settings.value.remaps ?? [] }
        set {
            if previewRemaps != nil { previewRemaps = newValue } else { module?.settings.value.remaps = newValue }
        }
    }

    var profileName: String { previewRemaps != nil ? "Default" : (module?.activeProfileName ?? "Default") }

    /// Bundle ids that appear in any remap, sorted by app name.
    var apps: [String] {
        Array(Set(remaps.flatMap(\.apps))).sorted { RemapFormatting.appName($0) < RemapFormatting.appName($1) }
    }

    func count(_ f: Filter) -> Int { remaps.filter { matches($0, f) }.count }

    func matches(_ r: Remap, _ f: Filter) -> Bool {
        switch f {
        case .all: true
        case .keys: r.kind == .key
        case .shortcuts: r.kind == .shortcut
        case .global: r.isGlobal
        case .app(let id): r.apps.contains(id)
        }
    }

    var visible: [Remap] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return remaps.filter { r in
            guard matches(r, filter) else { return false }
            guard !q.isEmpty else { return true }
            let hay = (r.triggerKeycaps + [RemapFormatting.actionSummary(r.action), RemapFormatting.scope(r),
                                           RemapFormatting.annotation(r) ?? ""] + r.apps)
                .joined(separator: " ").lowercased()
            return hay.contains(q)
        }
    }

    var orphans: [Key] { OrphanCheck.orphans(in: remaps) }

    // MARK: - Editing

    func addKey() {
        draft = Draft(remap: Remap(kind: .key, trigger: KeyCombo([], .keyboard(kVK_ANSI_A)),
                                   action: .send(.keyboard(kVK_ANSI_B))), isNew: true)
    }

    func addShortcut() {
        draft = Draft(remap: Remap(kind: .shortcut, trigger: KeyCombo([.control, .option], .keyboard(kVK_ANSI_K)),
                                   action: .send(KeyCombo([.command], .keyboard(kVK_ANSI_K)))), isNew: true)
    }

    func edit(_ id: UUID) {
        guard let r = remaps.first(where: { $0.id == id }) else { return }
        draft = Draft(remap: r, isNew: false)
    }

    func save(_ remap: Remap) {
        var list = remaps
        if let i = list.firstIndex(where: { $0.id == remap.id }) { list[i] = remap } else { list.append(remap) }
        remaps = list
        selection = [remap.id]
        draft = nil
    }

    func duplicate(_ id: UUID) {
        guard let i = remaps.firstIndex(where: { $0.id == id }) else { return }
        var copy = remaps[i]
        copy.id = UUID()
        copy.isEnabled = false
        var list = remaps
        list.insert(copy, at: i + 1)
        remaps = list
        selection = [copy.id]
    }

    func delete(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        remaps = remaps.filter { !ids.contains($0.id) }
        selection.subtract(ids)
    }

    func setEnabled(_ ids: Set<UUID>, _ on: Bool) {
        remaps = remaps.map { r in
            var r = r
            if ids.contains(r.id) { r.isEnabled = on }
            return r
        }
    }

    /// Click selection: plain click selects one, ⌘ toggles, ⇧ extends the range.
    func click(_ id: UUID, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            selectionAnchor = id
        } else if modifiers.contains(.shift), let anchor = selectionAnchor {
            let ids = visible.map(\.id)
            if let a = ids.firstIndex(of: anchor), let b = ids.firstIndex(of: id) {
                selection = Set(ids[min(a, b)...max(a, b)])
            }
        } else {
            selection = [id]
            selectionAnchor = id
        }
    }

    func selectAll() { selection = Set(visible.map(\.id)) }

    // MARK: - Recording

    func recorderFocusChanged(_ focused: Bool) {
        guard previewRemaps == nil else { return }
        module?.recorderFocusChanged(focused)
    }
}
