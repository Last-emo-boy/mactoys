import MacToysCore
import SwiftUI

/// Advanced Paste: ⌃⌥V opens a window near the caret with the clipboard preview, paste formats
/// (plain text, Markdown, JSON, files, OCR, transcoding), AI actions and clipboard history.
/// Each action can also have its own direct shortcut (⌃⌥⇧V pastes as plain text).
///
/// URL actions: `open`, `paste?as=<action>` or `paste?custom=<name>`, `transform?as=<action>`
/// (converts the clipboard in place), `clear-history`, `settings`.
@MainActor
public final class AdvancedPasteModule: ToyModule {
    public let info = ModuleInfo(
        id: "advancedpaste", name: "Advanced Paste",
        summary: "Paste clipboard content as plain text, Markdown, JSON, files or through your own AI actions.",
        symbol: "doc.on.clipboard.fill", tint: .purple, category: .systemTools,
        permissions: [.accessibility], enabledByDefault: true,
        keywords: ["clipboard", "markdown", "json", "ocr", "ai", "history", "plain text", "transcode"])

    public let settings = Persisted("advancedpaste", default: AdvancedPasteSettings())
    lazy var controller = AdvancedPasteController(settings: settings)
    private var running = false
    private var retainsHistory = false

    public init() {
        settings.onChange { [weak self] _ in
            guard let self, self.running else { return }
            self.apply()
        }
    }

    public func start() {
        guard !running else { return }
        running = true
        controller.start()
        apply()
        Task.detached(priority: .background) { AdvancedPasteTransforms.removeOldFiles() }
    }

    public func stop() {
        guard running else { return }
        running = false
        HotkeyCenter.shared.unregister(prefix: "advancedpaste.")
        controller.stop()
        setHistory(false)
    }

    private func apply() {
        let s = settings.value
        HotkeyCenter.shared.unregister(prefix: "advancedpaste.")
        HotkeyCenter.shared.register("advancedpaste.open", s.openShortcut) { [weak self] in self?.controller.toggleWindow() }
        for action in AdvancedPasteTransforms.Action.builtIns {
            let prefs = s.prefs(action)
            guard prefs.enabled, let shortcut = prefs.shortcut else { continue }
            HotkeyCenter.shared.register("advancedpaste.action.\(action.name)", shortcut) { [weak self] in
                self?.controller.runDirect(action, title: action.title)
            }
        }
        if s.aiEnabled {
            for custom in s.customActions {
                guard let shortcut = custom.shortcut, !custom.prompt.isEmpty else { continue }
                HotkeyCenter.shared.register("advancedpaste.custom.\(custom.id.uuidString)", shortcut) { [weak self] in
                    guard let self else { return }
                    self.controller.runDirect(.ai(prompt: custom.prompt, provider: self.settings.value.provider), title: custom.name)
                }
            }
        }
        setHistory(s.historyEnabled)
    }

    private func setHistory(_ on: Bool) {
        guard on != retainsHistory else { return }
        retainsHistory = on
        if on { ClipboardHistory.shared.retain(info.id) } else { ClipboardHistory.shared.release(info.id) }
    }

    public func settingsView() -> AnyView {
        AnyView(AdvancedPasteSettingsView(module: self, settings: settings))
    }

    public var quickActions: [QuickAction] {
        [QuickAction(id: "advancedpaste.open", title: "Advanced Paste", symbol: info.symbol, tint: info.tint,
                     shortcut: settings.value.openShortcut) { [weak self] in self?.controller.showWindow() }]
    }

    public var shortcutBindings: [ShortcutBinding] {
        let s = settings.value
        var list = [ShortcutBinding("Open Advanced Paste", s.openShortcut)]
        for action in AdvancedPasteTransforms.Action.builtIns {
            let prefs = s.prefs(action)
            if prefs.enabled, let shortcut = prefs.shortcut {
                let title = action == .plainText
                    ? String(localized: "Paste as plain text")
                    : String(localized: "Paste as \(action.title)", comment: "Shortcut list: %@ is a paste format, e.g. Markdown")
                list.append(ShortcutBinding(title, shortcut))
            }
        }
        if s.aiEnabled {
            for custom in s.customActions where custom.shortcut != nil {
                list.append(ShortcutBinding(String(localized: "AI · \(custom.name)",
                                                   comment: "Shortcut list: %@ is the name of a custom AI action"),
                                            custom.shortcut))
            }
        }
        return list
    }

    public func handle(_ command: AppCommand) -> Bool {
        switch command.action {
        case "open", "show":
            guard isEnabled else { return false }
            controller.showWindow()
            return true
        case "paste", "transform":
            guard isEnabled else { return false }
            let paste = command.action == "paste"
            if let name = command.parameters["custom"] {
                guard settings.value.aiEnabled,
                      let custom = settings.value.customActions.first(where: { $0.name.lowercased() == name.lowercased() || $0.id.uuidString == name })
                else { return false }
                controller.runDirect(.ai(prompt: custom.prompt, provider: settings.value.provider), title: custom.name, paste: paste)
                return true
            }
            if let prompt = command.parameters["prompt"], settings.value.aiEnabled {
                controller.runDirect(.ai(prompt: prompt, provider: settings.value.provider), title: String(localized: "Paste with AI"),
                                     paste: paste)
                return true
            }
            guard let action = AdvancedPasteTransforms.Action(name: command.parameters["as"] ?? "plain-text") else { return false }
            controller.runDirect(action, title: action.title, paste: paste)
            return true
        case "clear-history":
            ClipboardHistory.shared.clear()
            return true
        case "settings":
            ModuleRegistry.shared.showSettings?(info.id)
            return true
        default:
            return false
        }
    }

    public var previewScenes: [PreviewScene] {
        let csv = "name,role,city\nAda,Engineer,London\nLinus,Maintainer,Portland\nGrace,Admiral,Arlington"
        var s = AdvancedPasteSettings()
        s.aiEnabled = true
        s.customActions = [CustomAction(name: "Fix grammar", prompt: "Fix grammar."),
                           CustomAction(name: "Summarize in 3 bullets", prompt: "Summarize in three bullets.")]
        let history = [
            ClipItem(kind: .text, text: "https://github.com/mactoys/mactoys/pull/128"),
            ClipItem(kind: .text, text: "Screenshot 2026-10-24 at 22.31.png"),
            ClipItem(kind: .text, text: "let total = items.reduce(0) { $0 + $1.price }"),
        ]
        let settingsCopy = s
        return [
            PreviewScene("window", size: CGSize(width: 520, height: 640)) {
                let session = PasteSession(input: .init(text: csv), settings: settingsCopy, history: history)
                session.selection = 2
                return AnyView(AdvancedPasteView(session: session))
            },
            PreviewScene("result", size: CGSize(width: 520, height: 640)) {
                let session = PasteSession(input: .init(text: "their going too the libary tomorow"), settings: settingsCopy, history: [])
                session.state = .preview(title: "Fix grammar", output: .text("They're going to the library tomorrow."))
                return AnyView(AdvancedPasteView(session: session))
            },
            PreviewScene("transcoding", size: CGSize(width: 520, height: 640)) {
                let session = PasteSession(input: .init(files: [URL(fileURLWithPath: "/tmp/Keynote rehearsal.mov")]),
                                           settings: settingsCopy, history: [])
                session.state = .running(title: AdvancedPasteTransforms.Action.transcodeMP4.title, progress: 0.42)
                return AnyView(AdvancedPasteView(session: session))
            },
        ]
    }
}
