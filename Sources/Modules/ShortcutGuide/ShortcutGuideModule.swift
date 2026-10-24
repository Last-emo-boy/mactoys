import AppKit
import Carbon.HIToolbox
import MacToysCore
import SwiftUI

public struct ShortcutGuideSettings: Codable, Equatable, Sendable {
    public enum Activation: String, Codable, CaseIterable, Sendable {
        case holdOrShortcut, hold, shortcut

        public var title: String {
            switch self {
            case .holdOrShortcut: "Hold ⌘ or press the shortcut"
            case .hold: "Hold ⌘"
            case .shortcut: "Shortcut only"
            }
        }

        var usesHold: Bool { self != .shortcut }
        var usesShortcut: Bool { self != .hold }
    }

    public enum Theme: String, Codable, CaseIterable, Sendable {
        case system, dark, light
        public var title: String {
            switch self {
            case .system: "System"
            case .dark: "Dark"
            case .light: "Light"
            }
        }
    }

    public var activation = Activation.holdOrShortcut
    public var shortcut: Shortcut? = Shortcut(kVK_ANSI_Slash, [.control, .option])
    /// Milliseconds ⌘ must be held alone.
    public var pressDuration: Double = 900
    public var closeOnRelease = true
    /// How dark the screen behind the guide gets.
    public var dimOpacity: Double = 0.5
    public var theme = Theme.system
    public var excludedApps: [String] = []
    /// Bundle id → pinned shortcut ids.
    public var pinned: [String: [String]] = [:]

    public init() {}
}

/// Shortcut Guide: hold ⌘ (or press ⌃⌥/) to see the frontmost app's shortcuts, read live from its
/// menu bar, plus macOS and MacToys shortcuts. Search, pin favorites, esc or a click outside closes.
///
/// URL actions: `open`/`show`, `toggle`, `close`.
@MainActor
public final class ShortcutGuideModule: ToyModule {
    public let info = ModuleInfo(
        id: "shortcutguide", name: "Shortcut Guide",
        summary: "Hold ⌘ to see every shortcut of the frontmost app, plus macOS and MacToys shortcuts.",
        symbol: "list.bullet.rectangle.fill", tint: .indigo, category: .systemTools,
        permissions: [.accessibility], enabledByDefault: true,
        keywords: ["keyboard", "shortcuts", "cheat sheet", "menu", "hotkeys", "command"])

    public let settings = Persisted("shortcutguide", default: ShortcutGuideSettings())
    lazy var controller = ShortcutGuideController(settings: settings)
    private var running = false
    private var holding = false
    private var timer: DispatchSourceTimer?

    public init() {
        settings.onChange { [weak self] _ in
            guard let self, self.running else { return }
            self.apply()
        }
    }

    public func start() {
        guard !running else { return }
        running = true
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.holdElapsed() } }
        timer.schedule(deadline: .distantFuture)
        timer.resume()
        self.timer = timer
        apply()
    }

    public func stop() {
        guard running else { return }
        running = false
        HotkeyCenter.shared.unregister("shortcutguide.open")
        InputTap.shared.remove(info.id)
        timer?.cancel()
        timer = nil
        holding = false
        controller.close()
    }

    private func apply() {
        let s = settings.value
        HotkeyCenter.shared.register("shortcutguide.open", s.activation.usesShortcut ? s.shortcut : nil) { [weak self] in
            self?.controller.toggle()
        }
        if s.activation.usesHold {
            InputTap.shared.add(info.id, priority: 10, events: [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown,
                                                                .otherMouseDown, .scrollWheel]) { [weak self] type, event in
                self?.handle(type, event)
                return .pass
            }
        } else {
            InputTap.shared.remove(info.id)
            cancelHold()
        }
    }

    // MARK: Hold ⌘ (hot path: O(1), never blocks)

    private static let modifierMask: CGEventFlags = [.maskCommand, .maskShift, .maskControl, .maskAlternate, .maskSecondaryFn]

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .flagsChanged:
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            let mods = event.flags.intersection(Self.modifierMask)
            if mods == .maskCommand, code == kVK_Command || code == kVK_RightCommand, !controller.isOpen {
                holding = true
                let duration = min(5000, max(100, settings.value.pressDuration)) / 1000
                timer?.schedule(deadline: .now() + duration)
            } else {
                cancelHold()
                if controller.closesOnRelease, !event.flags.contains(.maskCommand) {
                    DispatchQueue.main.async { [weak self] in self?.controller.close() }
                }
            }
        case .keyDown:
            cancelHold()
            // Opened by holding ⌘ and not focused: any key (⌘Tab, ⌘W, esc) means the user moved on.
            if controller.closesOnRelease, !controller.isKey {
                DispatchQueue.main.async { [weak self] in self?.controller.close() }
            }
        default:
            cancelHold()
        }
    }

    private func cancelHold() {
        guard holding else { return }
        holding = false
        timer?.schedule(deadline: .distantFuture)
    }

    private func holdElapsed() {
        guard holding else { return }
        holding = false
        guard CGEventSource.flagsState(.combinedSessionState).intersection(Self.modifierMask) == .maskCommand else { return }
        controller.open(byHold: true)
    }

    // MARK: ToyModule

    public func settingsView() -> AnyView {
        AnyView(ShortcutGuideSettingsView(module: self, settings: settings))
    }

    public var quickActions: [QuickAction] {
        [QuickAction(id: "shortcutguide.open", title: "Shortcut Guide", symbol: info.symbol, tint: info.tint,
                     shortcut: settings.value.shortcut) { [weak self] in self?.controller.open(byHold: false) }]
    }

    public var shortcutBindings: [ShortcutBinding] {
        let s = settings.value
        var list: [ShortcutBinding] = []
        if s.activation.usesHold { list.append(ShortcutBinding("Show Shortcut Guide (hold)", keys: ["Hold", "⌘"])) }
        if s.activation.usesShortcut, s.shortcut != nil { list.append(ShortcutBinding("Show Shortcut Guide", s.shortcut)) }
        return list
    }

    public func handle(_ command: AppCommand) -> Bool {
        switch command.action {
        case "open", "show":
            guard isEnabled else { return false }
            controller.open(byHold: false)
            return true
        case "toggle":
            guard isEnabled else { return false }
            controller.toggle()
            return true
        case "close":
            controller.close()
            return true
        default:
            return false
        }
    }

    public var previewScenes: [PreviewScene] {
        func scene(_ name: String, _ scheme: ColorScheme, tab: GuideModel.Tab) -> PreviewScene {
            PreviewScene(name, size: CGSize(width: 1600, height: 1000)) {
                let model = GuideModel(appName: "Safari", appIcon: nil, bundleID: "com.apple.Safari",
                                       systemGroups: SystemShortcuts.groups, macToysGroups: [], openedByHold: true,
                                       pinned: ["Reload Page\u{1F}⌘ R"])
                model.loading = false
                model.appGroups = Self.sampleSafari
                model.tab = tab
                return AnyView(ShortcutGuideView(model: model, dimOpacity: 0.35, scheme: scheme))
            }
        }
        return [scene("safari", .dark, tab: .app), scene("macos-light", .light, tab: .macOS)]
    }

    static let sampleSafari: [ShortcutGroup] = [
        ShortcutGroup("File", [
            ShortcutItem("New Window", ["⌘", "N"]), ShortcutItem("New Private Window", ["⇧", "⌘", "N"]),
            ShortcutItem("New Tab", ["⌘", "T"]), ShortcutItem("Open Location…", ["⌘", "L"]),
            ShortcutItem("Close Tab", ["⌘", "W"]), ShortcutItem("Save As…", ["⌘", "S"]), ShortcutItem("Print…", ["⌘", "P"]),
        ]),
        ShortcutGroup("Edit", [
            ShortcutItem("Undo", ["⌘", "Z"]), ShortcutItem("Find…", ["⌘", "F"]), ShortcutItem("Find Next", ["⌘", "G"]),
            ShortcutItem("Paste and Match Style", ["⌥", "⇧", "⌘", "V"]),
        ]),
        ShortcutGroup("View", [
            ShortcutItem("Show Tab Overview", ["⇧", "⌘", "\\"]), ShortcutItem("Show Sidebar", ["⇧", "⌘", "L"]),
            ShortcutItem("Reload Page", ["⌘", "R"]), ShortcutItem("Actual Size", ["⌘", "0"]),
            ShortcutItem("Zoom In", ["⌘", "+"]), ShortcutItem("Zoom Out", ["⌘", "-"]),
            ShortcutItem("Enter Full Screen", ["fn", "F"]),
        ]),
        ShortcutGroup("History", [
            ShortcutItem("Show All History", ["⌘", "Y"]), ShortcutItem("Back", ["⌘", "["]),
            ShortcutItem("Forward", ["⌘", "]"]), ShortcutItem("Reopen Last Closed Tab", ["⇧", "⌘", "T"]),
        ]),
        ShortcutGroup("Bookmarks", [
            ShortcutItem("Add Bookmark…", ["⌘", "D"]), ShortcutItem("Show Bookmarks", ["⌥", "⌘", "B"]),
            ShortcutItem("Edit Bookmarks", ["⌥", "⌘", "B"], enabled: false),
        ]),
        ShortcutGroup("Window", [
            ShortcutItem("Minimize", ["⌘", "M"]), ShortcutItem("Show Previous Tab", ["⇧", "⌘", "["]),
            ShortcutItem("Show Next Tab", ["⇧", "⌘", "]"]),
            ShortcutItem("Move Tab to New Window", ["⌥", "⌘", "N"], enabled: false),
        ]),
        ShortcutGroup("Develop", [
            ShortcutItem("Show Web Inspector", ["⌥", "⌘", "I"]), ShortcutItem("Show JavaScript Console", ["⌥", "⌘", "C"]),
        ]),
    ]
}

struct ShortcutGuideSettingsView: View {
    let module: ShortcutGuideModule
    @Bindable var settings: Persisted<ShortcutGuideSettings>

    var body: some View {
        SettingsPage(module: module) {
            HeroCard(tint: .indigo) {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Every shortcut of the app you're in").font(.system(size: 14, weight: .semibold))
                        Text("Read live from the app's menu bar, with macOS and MacToys shortcuts in their own tabs. Type to filter, ⌘F to search, ⌘1–3 to switch tabs.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Show") { module.controller.open(byHold: false) }.buttonStyle(.borderedProminent)
                }
            }
        } content: {
            Section("Activation") {
                Picker(selection: $settings.value.activation) {
                    ForEach(ShortcutGuideSettings.Activation.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: { RowLabel("Activation method") }
                if settings.value.activation.usesShortcut {
                    ShortcutRow("Activation shortcut", subtitle: "Press again or esc to close.", shortcut: $settings.value.shortcut)
                }
                if settings.value.activation.usesHold {
                    SliderRow("Press duration", subtitle: "How long ⌘ must be held alone. Any other key or a click cancels.",
                              value: $settings.value.pressDuration, in: 100...5000, step: 50) { "\(Int($0)) ms" }
                    Toggle(isOn: $settings.value.closeOnRelease) {
                        RowLabel("Close when ⌘ is released", subtitle: "Off: the guide stays open until esc or a click outside it.")
                    }
                }
            }
            Section("Appearance") {
                SliderRow("Background dimming", value: $settings.value.dimOpacity, in: 0...0.9, step: 0.05) { "\(Int(($0 * 100).rounded())) %" }
                Picker(selection: $settings.value.theme) {
                    ForEach(ShortcutGuideSettings.Theme.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: { RowLabel("Theme") }
            }
            Section("Pinned shortcuts") {
                let count = settings.value.pinned.values.reduce(0) { $0 + $1.count }
                LabeledContent {
                    Button("Unpin all") { settings.value.pinned = [:] }.disabled(count == 0)
                } label: {
                    RowLabel("\(count) pinned in \(settings.value.pinned.count) app\(settings.value.pinned.count == 1 ? "" : "s")",
                             subtitle: "Hover a shortcut in the guide and click the pin to keep it at the top for that app.")
                }
            }
            Section("Excluded apps") {
                ExcludedAppsEditor("Don't open the guide in these apps", apps: $settings.value.excludedApps)
            }
        }
    }
}
