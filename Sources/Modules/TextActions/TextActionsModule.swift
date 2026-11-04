import AppKit
import Carbon.HIToolbox
import MacToysCore
import SwiftUI

/// Text Actions: select text in any app and a bar of actions appears next to it: copy, search,
/// look up, translate, open links, change case, count, calculate, format JSON and your own
/// URL, shell, AppleScript, Shortcut and key-press actions. ⌃⌥⇧A shows the bar for the current
/// selection and drives it with the keyboard.
///
/// URL actions: `show` (the bar for the current selection), `run?action=<id or name>` (runs an
/// action on the current selection, or on `text=` when given; results are copied), `toggle`
/// (automatic appearance on/off), `stop-speaking`, `settings` (or `open`).
@MainActor
public final class TextActionsModule: ToyModule {
    public let info = ModuleInfo(
        id: "textactions", name: "Text Actions",
        summary: "Select text in any app to get a bar of actions: copy, search, translate, transform and your own.",
        symbol: "text.cursor", tint: .orange, category: .systemTools,
        permissions: [.accessibility], enabledByDefault: false,
        keywords: ["selection", "popup", "bar", "search", "translate", "dictionary", "copy", "case", "count", "calculate",
                   "json", "markdown", "shell", "applescript", "shortcuts"])

    public let settings = Persisted("textactions", default: TextActionsSettings())
    let bar = BarController()
    private let monitor = SelectionMonitor()
    private let speaker = Speaker()
    private let log = Log.for("textactions")
    private var running = false
    private var observers: [NSObjectProtocol] = []
    /// Bumped by every new selection, so slow reads of an older one are dropped.
    private var generation = 0
    /// The selection the bar is showing.
    private var session: Session?
    private var runningTasks: [Task<Void, Never>] = []

    /// A selection and what was found out about it.
    struct Session {
        var snapshot: SelectionSnapshot
        var analysis: SelectionAnalysis
        var context: SelectionContext
        var suggestions: [String]
        var definition: String?
    }

    public init() {
        settings.onChange { [weak self] _ in
            guard let self, self.running else { return }
            self.apply()
        }
        bar.model.onActivate = { [weak self] item in
            // Keyboard activation arrives inside the event tap: act after it returns.
            DispatchQueue.main.async { self?.perform(item) }
        }
        bar.model.onCardAction = { [weak self] action in self?.cardAction(action) }
        bar.onStateChange = { [weak self] in self?.syncMonitor() }
        monitor.onSelection = { [weak self] kind, pointer, start in self?.present(kind, pointer: pointer, dragStart: start) }
        monitor.onDismiss = { [weak self] in self?.dismissBar() }
        monitor.onBarKey = { [weak self] code, shift in self?.bar.handleKey(code, shift: shift) ?? false }
    }

    // MARK: Lifecycle

    public func start() {
        guard !running else { return }
        running = true
        apply()
        monitor.start()
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updateFrontmost(app)
                if app?.processIdentifier != ProcessInfo.processInfo.processIdentifier { self.dismissBar() }
            }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissBar() }
        })
    }

    public func stop() {
        guard running else { return }
        running = false
        HotkeyCenter.shared.unregister("textactions.show")
        monitor.stop()
        for token in observers { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        observers.removeAll()
        for task in runningTasks { task.cancel() }
        runningTasks.removeAll()
        generation &+= 1
        session = nil
        bar.dispose()
        speaker.stop()
    }

    private func apply() {
        let s = settings.value
        HotkeyCenter.shared.register("textactions.show", s.showShortcut) { [weak self] in self?.shortcutPressed() }
        monitor.config = SelectionMonitor.Config(autoShow: s.autoShow, triggers: s.triggers, required: s.requiredModifier,
                                                 delay: max(0, min(2000, s.delay)) / 1000, showShortcut: s.showShortcut)
        updateFrontmost(NSWorkspace.shared.frontmostApplication)
    }

    private func updateFrontmost(_ app: NSRunningApplication?) {
        let own = app?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        monitor.frontmostExcluded = own || settings.value.excludedApps.matches(app: app)
    }

    private func syncMonitor() {
        monitor.barVisible = bar.isVisible
        monitor.barKeyboard = bar.model.keyboardMode
        monitor.barFrame = bar.frameAX
    }

    private func dismissBar() {
        guard bar.isVisible else { return }
        bar.hide()
        session = nil
    }

    // MARK: Reading the selection

    private func shortcutPressed() {
        guard running else { return }
        if bar.isVisible {
            if bar.model.keyboardMode { dismissBar() } else { bar.enterKeyboardMode() }
            return
        }
        present(.shortcut, pointer: nil, dragStart: nil)
    }

    /// Reads the selection of the frontmost app and shows the bar for it.
    func present(_ kind: SelectionGesture.Kind, pointer: CGPoint?, dragStart: CGPoint?) {
        guard running else { return }
        generation &+= 1
        let gen = generation
        if kind.isAutomatic && !settings.value.autoShow { return }
        guard !IsSecureEventInputEnabled() else { return }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        let s = settings.value
        if kind.isAutomatic && s.excludedApps.matches(app: app) { return }
        guard AXIsProcessTrusted() else {
            if !kind.isAutomatic {
                HUD.show("Accessibility permission needed", symbol: "exclamationmark.shield")
                PermissionCenter.shared.request(.accessibility)
            }
            return
        }
        let pid = app.processIdentifier, name = app.localizedName, bundleID = app.bundleIdentifier, bundleURL = app.bundleURL
        track(Task { [weak self] in
            let read = await Task.detached {
                SelectionReader.read(pid: pid, appName: name, bundleID: bundleID, bundleURL: bundleURL)
            }.value
            guard let self, gen == self.generation else { return }
            var snapshot = read ?? SelectionSnapshot.empty(pid: pid, appName: name, bundleID: bundleID)
            if snapshot.isSecure { return }
            if snapshot.text.isEmpty, kind != .longPress, s.copyFallback || kind == .shortcut {
                await Self.waitForModifierRelease()
                guard gen == self.generation, !IsSecureEventInputEnabled() else { return }
                if let copied = await SelectionReader.copySelection(), !copied.isEmpty {
                    snapshot.text = copied
                    snapshot.viaClipboard = true
                }
                guard gen == self.generation else { return }
            }
            if snapshot.text.isEmpty && kind != .longPress && kind != .shortcut { return }
            let session = await self.prepare(snapshot, settings: s)
            guard gen == self.generation, self.running else { return }
            let items = BarItems.actions(settings: s, analysis: session.analysis, context: session.context)
            guard !items.isEmpty else {
                if kind == .shortcut { HUD.show("Select some text first", symbol: "text.cursor") }
                return
            }
            let bounds = SelectionReader.plausible(snapshot.bounds)
            let usesPointer = kind != .keyboard && kind != .shortcut
            let anchor = BarPlacement.anchor(selection: bounds, pointer: usesPointer || bounds == nil ? (pointer ?? MouseSynth.location) : nil,
                                             dragStart: dragStart, preferred: s.placement)
            self.session = session
            self.bar.present(items: items, anchor: anchor.rect, side: anchor.side, settings: s, keyboard: kind == .shortcut)
        })
    }

    /// Detection, file checks, dictionary and language lookups off the main thread; the
    /// clipboard and spell checker on it.
    private func prepare(_ snapshot: SelectionSnapshot, settings s: TextActionsSettings) async -> Session {
        let text = snapshot.text
        let target = LanguageGuess.target(setting: s.translateTarget)
        let enabled = Set(s.slots.filter(\.enabled).map(\.id))
        let wantsDefinition = enabled.contains(BuiltInAction.lookUp.slotID)
        let wantsLanguage = enabled.contains(BuiltInAction.translate.slotID)
        let (analysis, pathExists, definition, inTarget) = await Task.detached {
            let a = SelectionAnalysis(text)
            let exists = a.pathCandidate.map { FileManager.default.fileExists(atPath: $0) } ?? false
            let definition = wantsDefinition && a.isShortPhrase ? DictionaryLookup.definition(of: a.trimmed) : nil
            let language = wantsLanguage && a.hasLetters ? LanguageGuess.confident(a.trimmed) : nil
            return (a, exists, definition, language.map { LanguageGuess.sameLanguage($0, target) } ?? false)
        }.value
        let pb = NSPasteboard.general
        let clipboardText = pb.availableType(from: [.string]) != nil
        let suggestions = analysis.isSingleWord && enabled.contains(BuiltInAction.spelling.slotID)
            ? SpellCheck.suggestions(for: analysis.trimmed) : nil
        let context = SelectionContext(isEditable: snapshot.isEditable, clipboardHasText: clipboardText,
                                       clipboardURL: enabled.contains(BuiltInAction.markdownLink.slotID) ? Self.clipboardURL(pb) : nil,
                                       pathExists: pathExists, hasDefinition: definition != nil,
                                       isMisspelled: suggestions != nil, isInTargetLanguage: inTarget)
        return Session(snapshot: snapshot, analysis: analysis, context: context, suggestions: suggestions ?? [], definition: definition)
    }

    /// A single web link on the clipboard.
    private static func clipboardURL(_ pb: NSPasteboard) -> URL? {
        guard let s = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), s.count <= 2048,
              !s.contains(where: \.isWhitespace), let url = URL(string: s),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil else { return nil }
        return url
    }

    /// Lets the user let go of the shortcut's modifiers before ⌘C is pressed for them.
    private static func waitForModifierRelease() async {
        for _ in 0..<25 {
            let flags = CGEventSource.flagsState(.combinedSessionState)
            if flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift]).isEmpty { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func track(_ task: Task<Void, Never>) {
        runningTasks.removeAll { $0.isCancelled }
        if runningTasks.count > 8 { runningTasks.removeFirst(runningTasks.count - 8) }
        runningTasks.append(task)
    }

    // MARK: Actions

    func perform(_ item: BarItem) {
        guard bar.isVisible, let session else { return }
        switch item.kind {
        case .more: bar.setPage(.overflow)
        case .back: bar.setPage(.main)
        case .caseOption(let transform): deliver(transform.apply(session.snapshot.text), item: item, session: session)
        case .suggestion(let word): deliver(word, item: item, session: session)
        case .builtIn(let action): perform(action, item: item, session: session)
        case .custom(let id):
            guard let custom = settings.value.customActions.first(where: { $0.id == id }) else { return }
            runCustom(custom, item: item, session: session)
        }
    }

    private func perform(_ action: BuiltInAction, item: BarItem, session: Session) {
        let a = session.analysis
        let text = session.snapshot.text
        switch action {
        case .copy: copy(item: item, session: session)
        case .cut:
            bar.hide()
            KeySynth.tap(kVK_ANSI_X, flags: .maskCommand)
        case .paste:
            bar.hide()
            KeySynth.paste()
        case .search:
            bar.hide()
            if let url = URLTemplate.expand(settings.value.searchTemplate, text: a.trimmed) { NSWorkspace.shared.open(url) }
        case .openLink:
            bar.hide()
            for url in a.links.prefix(10) { NSWorkspace.shared.open(url) }
        case .email:
            bar.hide()
            let to = a.emails.prefix(10).map(URLTemplate.encode).joined(separator: ",")
            if let url = URL(string: "mailto:" + to) { NSWorkspace.shared.open(url) }
        case .map:
            bar.hide()
            if let address = a.addresses.first, let url = URL(string: "maps://?q=" + URLTemplate.encode(address)) {
                NSWorkspace.shared.open(url)
            }
        case .call:
            bar.hide()
            let digits = (a.phoneNumbers.first ?? "").filter { $0.isNumber || $0 == "+" }
            if let url = URL(string: "tel:" + digits) { NSWorkspace.shared.open(url) }
        case .revealPath:
            bar.hide()
            guard let path = a.pathCandidate else { return }
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        case .spelling: bar.setPage(.spelling(session.suggestions))
        case .changeCase: bar.setPage(.cases)
        case .lookUp:
            if let definition = session.definition {
                bar.showCard(ResultCard(title: action.title, symbol: action.symbol, tint: .indigo,
                                        content: .definition(word: a.trimmed, text: definition), canReplace: false))
            } else {
                bar.hide()
                DictionaryLookup.open(a.trimmed)
            }
        case .translate: translate(a.trimmed, session: session)
        case .calculate:
            guard let value = a.calculation else { return }
            bar.showCard(ResultCard(title: action.title, symbol: action.symbol, tint: .orange,
                                    content: .calculation(expression: a.trimmed, value: value), canReplace: session.context.isEditable))
        case .formatJSON: if let json = a.prettyJSON { deliver(json, item: item, session: session) }
        case .minifyJSON: if let json = a.minifiedJSON { deliver(json, item: item, session: session) }
        case .markdownLink:
            let clip = a.wholeLink == nil ? session.context.clipboardURL : nil
            if let link = MarkdownLink.make(selection: a.trimmed, wholeLink: a.wholeLink, clipboardURL: clip) {
                deliver(link, item: item, session: session)
            }
        case .count:
            bar.showCard(ResultCard(title: action.title, symbol: action.symbol, tint: .orange, content: .stats(TextStats(text)),
                                    canReplace: false))
        case .speak:
            bar.hide()
            if speaker.isSpeaking { speaker.stop() } else { speaker.speak(text) }
        }
    }

    /// ⌘C keeps the app's formatting; plain text is written when the app ignores it.
    private func copy(item: BarItem, session: Session) {
        if session.snapshot.viaClipboard {
            TextReplacer.copy(session.snapshot.text)
            bar.confirm(item.id, caption: String(localized: "Copied", comment: "Confirmation after copying"))
            return
        }
        let pb = NSPasteboard.general
        let before = pb.changeCount
        KeySynth.copy()
        let text = session.snapshot.text
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if pb.changeCount == before { TextReplacer.copy(text) }
        }
        bar.confirm(item.id, caption: String(localized: "Copied", comment: "Confirmation after copying"))
    }

    /// Replaces the selection with a result where it's editable; copies it otherwise.
    private func deliver(_ result: String, item: BarItem, session: Session) {
        if session.context.isEditable {
            bar.hide()
            let preferPaste = settings.value.pasteToReplace
            track(Task { await TextReplacer.replace(session.snapshot, with: result, preferPaste: preferPaste) })
        } else {
            TextReplacer.copy(result)
            bar.confirm(item.id, caption: String(localized: "Copied", comment: "Confirmation after copying"))
        }
    }

    private func translate(_ text: String, session: Session) {
        let target = LanguageGuess.target(setting: settings.value.translateTarget)
        let title = BuiltInAction.translate.title
        let symbol = BuiltInAction.translate.symbol
        let editable = session.context.isEditable
        bar.showCard(ResultCard(title: title, symbol: symbol, tint: .indigo,
                                content: .translation(.working(target: LanguageGuess.name(target))), canReplace: false))
        let token = bar.token
        track(Task { [weak self] in
            let state: ResultCard.Translation
            do {
                state = .done(try await OnDeviceTranslator.translate(text, to: target))
            } catch let failure as OnDeviceTranslator.Failure {
                state = Self.describe(failure)
            } catch {
                state = .failed(error.localizedDescription, offerSettings: false)
            }
            guard let self else { return }
            let isError: Bool = if case .failed = state { true } else { false }
            self.bar.updateCard(ResultCard(title: title, symbol: symbol, tint: .indigo, content: .translation(state),
                                           canReplace: editable, isError: isError), token: token)
        })
    }

    private static func describe(_ failure: OnDeviceTranslator.Failure) -> ResultCard.Translation {
        switch failure {
        case .unknownLanguage:
            .failed(String(localized: "The language of this text couldn’t be recognized."), offerSettings: false)
        case .sameLanguage(let language):
            .failed(String(localized: "This text is already in \(language). Choose another language for Translate in Text Actions settings.",
                           comment: "%@ is a language name"), offerSettings: false)
        case .notInstalled(let source, let target):
            .failed(String(localized: "Download \(source) and \(target) in Language & Region › Translation Languages to translate on this Mac.",
                           comment: "Both %@ are language names"), offerSettings: true)
        case .unsupported(let source, let target):
            .failed(String(localized: "Translating from \(source) to \(target) isn’t available on this Mac.",
                           comment: "Both %@ are language names"), offerSettings: false)
        case .failed(let message):
            .failed(message, offerSettings: false)
        }
    }

    // MARK: Custom actions

    private func runCustom(_ action: CustomAction, item: BarItem, session: Session) {
        let text = session.snapshot.text
        switch action.kind {
        case .url:
            bar.hide()
            if let url = URLTemplate.expand(action.template, text: text) { NSWorkspace.shared.open(url) }
        case .keyPress:
            bar.hide()
            guard let keys = action.keys else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { KeySynth.tap(keys) }
        case .shell, .appleScript, .shortcut:
            bar.model.busyID = item.id
            let token = bar.token
            let editable = session.context.isEditable
            let preferPaste = settings.value.pasteToReplace
            track(Task { [weak self] in
                let result = await CustomActionRunner.run(action, text: text, appName: session.snapshot.appName,
                                                          bundleID: session.snapshot.bundleID)
                guard let self, token == self.bar.token, self.bar.isVisible else { return }
                self.bar.model.busyID = nil
                switch result {
                case .failure(let message):
                    self.bar.showCard(ResultCard(title: action.name, symbol: action.symbol, tint: .purple,
                                                 content: .message(message), canReplace: false, isError: true))
                case .success(let output):
                    switch ScriptIO.effect(of: output, mode: action.output, editable: editable) {
                    case .replace(let value):
                        self.bar.hide()
                        await TextReplacer.replace(session.snapshot, with: value, preferPaste: preferPaste)
                    case .copy(let value):
                        TextReplacer.copy(value)
                        self.bar.confirm(item.id, caption: String(localized: "Copied", comment: "Confirmation after copying"))
                    case .show(let value):
                        self.bar.showCard(ResultCard(title: action.name, symbol: action.symbol, tint: .purple,
                                                     content: .output(value), canReplace: editable && !value.isEmpty))
                    case .nothing:
                        self.bar.confirm(item.id, caption: String(localized: "Done", comment: "Confirmation after a custom action ran"))
                    }
                }
            })
        }
    }

    private func cardAction(_ action: CardAction) {
        guard let session else { bar.hide(); return }
        switch action {
        case .copy(let text):
            TextReplacer.copy(text)
            bar.confirmCardCopy()
        case .replace(let text):
            bar.hide()
            let preferPaste = settings.value.pasteToReplace
            track(Task { await TextReplacer.replace(session.snapshot, with: text, preferPaste: preferPaste) })
        case .openDictionary(let word):
            bar.hide()
            DictionaryLookup.open(word)
        case .openLanguageSettings:
            bar.hide()
            OnDeviceTranslator.openLanguageSettings()
        case .close:
            bar.hide()
        }
    }

    /// Runs an action by id or name on `text` without the bar (URL `run` action). Text results
    /// are copied; links open.
    private func runHeadless(_ ref: String, text: String) -> Bool {
        let a = SelectionAnalysis(text)
        if let builtIn = BuiltInAction(rawValue: ref) {
            var result: String?
            switch builtIn {
            case .search: if let url = URLTemplate.expand(settings.value.searchTemplate, text: a.trimmed) { NSWorkspace.shared.open(url) }
            case .openLink: a.links.prefix(10).forEach { NSWorkspace.shared.open($0) }
            case .lookUp: DictionaryLookup.open(a.trimmed)
            case .speak: speaker.speak(text)
            case .formatJSON: result = a.prettyJSON
            case .minifyJSON: result = a.minifiedJSON
            case .calculate: result = a.calculation.map(ArithmeticEvaluator.canonical)
            case .copy: result = text
            case .count:
                let stats = TextStats(text)
                HUD.show(String(localized: "\(stats.characters) characters · \(stats.words) words · \(stats.lines) lines",
                                comment: "HUD: counts of the given text"), symbol: "number")
            default: return false
            }
            if let result {
                TextReplacer.copy(result)
                HUD.show("Copied", symbol: "doc.on.doc")
            }
            return true
        }
        if let transform = CaseTransform(rawValue: ref) {
            TextReplacer.copy(transform.apply(text))
            HUD.show("Copied", symbol: "doc.on.doc")
            return true
        }
        guard let custom = settings.value.customActions.first(where: { $0.name.lowercased() == ref.lowercased() || $0.id.uuidString == ref })
        else { return false }
        switch custom.kind {
        case .url:
            if let url = URLTemplate.expand(custom.template, text: text) { NSWorkspace.shared.open(url) }
        case .keyPress:
            if let keys = custom.keys { KeySynth.tap(keys) }
        case .shell, .appleScript, .shortcut:
            track(Task {
                switch await CustomActionRunner.run(custom, text: text, appName: nil, bundleID: nil) {
                case .success(let output):
                    if custom.output != .ignore, !output.isEmpty {
                        TextReplacer.copy(output)
                        HUD.show("Copied", symbol: "doc.on.doc")
                    }
                case .failure(let message):
                    HUD.show(message, symbol: "exclamationmark.triangle", duration: 3)
                }
            })
        }
        return true
    }

    // MARK: ToyModule

    public func settingsView() -> AnyView {
        AnyView(TextActionsSettingsView(module: self, settings: settings))
    }

    public var quickActions: [QuickAction] {
        [QuickAction(id: "textactions.auto", title: "Text Actions", symbol: info.symbol, tint: info.tint,
                     shortcut: settings.value.showShortcut,
                     isOn: { [weak self] in
                         ModuleRegistry.shared.isEnabled("textactions") && (self?.settings.value.autoShow ?? false)
                     },
                     detail: { [weak self] in
                         guard let self, ModuleRegistry.shared.isEnabled("textactions") else { return String(localized: "Off", comment: "Quick action detail: Text Actions is turned off") }
                         return self.settings.value.autoShow
                             ? String(localized: "Appears when you select text", comment: "Quick action detail")
                             : String(localized: "Only with the shortcut", comment: "Quick action detail: the bar appears only when the shortcut is pressed")
                     },
                     perform: { [weak self] in
                         guard let self else { return }
                         if !ModuleRegistry.shared.isEnabled("textactions") {
                             self.settings.value.autoShow = true
                             ModuleRegistry.shared.setEnabled("textactions", true)
                         } else {
                             self.settings.value.autoShow.toggle()
                         }
                     })]
    }

    public var shortcutBindings: [ShortcutBinding] {
        [ShortcutBinding("Show text actions for the selection", settings.value.showShortcut)]
    }

    public func handle(_ command: AppCommand) -> Bool {
        switch command.action {
        case "show":
            guard isEnabled else { return false }
            // Let the caller (Terminal, a launcher) give focus back before reading the selection.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.present(.shortcut, pointer: nil, dragStart: nil)
            }
            return true
        case "run":
            guard isEnabled, let ref = command.parameters["action"] else { return false }
            if let text = command.parameters["text"] { return runHeadless(ref, text: text) }
            track(Task { [weak self] in
                guard let self, let app = NSWorkspace.shared.frontmostApplication, AXIsProcessTrusted() else { return }
                let pid = app.processIdentifier, name = app.localizedName, bid = app.bundleIdentifier, url = app.bundleURL
                let read = await Task.detached { SelectionReader.read(pid: pid, appName: name, bundleID: bid, bundleURL: url) }.value
                var text = read?.text ?? ""
                if text.isEmpty, read?.isSecure != true { text = await SelectionReader.copySelection() ?? "" }
                if text.isEmpty {
                    HUD.show("Select some text first", symbol: "text.cursor")
                } else if !self.runHeadless(ref, text: text) {
                    self.log.error("Unknown text action \(ref, privacy: .public)")
                }
            })
            return true
        case "toggle":
            settings.value.autoShow.toggle()
            HUD.show(settings.value.autoShow ? String(localized: "Text Actions · appear when you select text")
                                             : String(localized: "Text Actions · only with the shortcut"),
                     symbol: info.symbol)
            return true
        case "stop-speaking":
            speaker.stop()
            return true
        case "open", "settings":
            ModuleRegistry.shared.showSettings?(info.id)
            return true
        default:
            return false
        }
    }

    public var previewScenes: [PreviewScene] { TextActionsPreviews.scenes(settings: settings.value) }
}

/// Runs the script kinds of custom actions.
enum CustomActionRunner {
    static let timeout: TimeInterval = 30

    static func run(_ action: CustomAction, text: String, appName: String?, bundleID: String?) async -> ScriptIO.Result {
        let env = ScriptIO.environment(text: text, appName: appName, bundleID: bundleID)
        switch action.kind {
        case .shell:
            return ScriptIO.interpret(await ScriptRunner.run("/bin/zsh", ScriptIO.shellArguments(action.script), input: text,
                                                             environment: env, timeout: timeout))
        case .appleScript:
            let source = ScriptIO.appleScriptSource(action.script, text: text)
            return ScriptIO.interpret(await ScriptRunner.run("/usr/bin/osascript", ["-"], input: source, environment: env,
                                                             timeout: timeout))
        case .shortcut:
            return await runShortcut(action.shortcutName, text: text, environment: env)
        case .url, .keyPress:
            return .success("")
        }
    }

    private static func runShortcut(_ name: String, text: String, environment: [String: String]) async -> ScriptIO.Result {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mactoys-textactions-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("selection.txt"), output = dir.appendingPathComponent("result.txt")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: input)
        } catch {
            return .failure(error.localizedDescription)
        }
        let outcome = await ScriptRunner.run("/usr/bin/shortcuts", ScriptIO.shortcutArguments(name: name, input: input, output: output),
                                             input: nil, environment: environment, timeout: timeout * 2)
        switch ScriptIO.interpret(outcome) {
        case .failure(let message): return .failure(message)
        case .success(let stdout):
            if let data = try? Data(contentsOf: output) {
                return .success(ScriptIO.trimmingOneNewline(String(decoding: data, as: UTF8.self)))
            }
            return .success(stdout)
        }
    }
}
