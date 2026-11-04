import AppKit
import MacToysCore
import SwiftUI
import UniformTypeIdentifiers

/// Screenshot: capture an area (⌃⌥A), a window or a screen; then copy, save, annotate, frame,
/// pin or drag it from the Quick Access card. Captures are kept in a browsable history.
///
/// URL actions: `area`, `window`, `screen` (`display=<n>`), `previous` (each takes `timer=<seconds>`),
/// `history`, `annotate` and `pin` (`file=<path>`, else the latest capture), `unlock-pins`,
/// `close-pins`, `settings`.
@MainActor
public final class ScreenshotModule: ToyModule {
    public let info = ModuleInfo(
        id: "screenshot", name: "Screenshot",
        summary: "Capture an area, window or screen, then annotate, frame, pin or share it.",
        symbol: "camera.viewfinder", tint: .pink, category: .systemTools,
        permissions: [.screenRecording], enabledByDefault: true,
        keywords: ["screenshot", "screen capture", "capture", "annotate", "markup", "arrow", "blur", "pixelate", "redact",
                   "pin", "float", "background", "mockup", "history", "OCR", "self-timer"])

    let settings = Persisted("screenshot", default: ScreenshotSettings())
    private let state = Persisted("screenshot-state", default: ScreenshotState())
    /// Opened on first use, so a disabled module never reads the history folder.
    private(set) lazy var history = CaptureHistory(directory: Paths.data(for: "screenshot").appendingPathComponent("History", isDirectory: true))

    private let quickAccess = QuickAccessController()
    private var session: CaptureSession?
    private var countdown: Countdown?
    private var busy = false
    private var pins: [PinWindow] = []
    private var editors: [AnnotateWindow] = []
    private var historyWindow: HostedToolWindow?
    /// The latest captures, newest first (others stay alive through their cards, pins and editors).
    private var recent: [CaptureItem] = []
    private var pendingHistoryWrites: [UUID: DispatchWorkItem] = [:]
    private var running = false
    private let log = Log.for("screenshot")

    public init() {
        settings.onChange { [weak self] new in
            guard let self, self.running else { return }
            self.registerHotkeys()
            if new.keepHistory { self.history.prune(limitMB: new.historyLimitMB, maxAgeDays: new.historyMaxAgeDays) }
        }
        quickAccess.settings = { [weak self] in self?.settings.value ?? ScreenshotSettings() }
        quickAccess.actions = QuickAccessActions(
            copy: { [weak self] in self?.copy($0) },
            save: { [weak self] item in
                guard let self else { return }
                if let url = item.savedURL, FileManager.default.fileExists(atPath: url.path) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } else if self.save(item) != nil {
                    HUD.show("Screenshot saved", symbol: "checkmark.circle")
                }
            },
            annotate: { [weak self] in self?.annotate($0) },
            pin: { [weak self] in self?.pin($0) },
            copyText: { [weak self] in self?.copyText(in: $0) },
            dragFile: { [weak self] in self?.dragFile($0) })
    }

    // MARK: ToyModule

    public func start() {
        guard !running else { return }
        running = true
        registerHotkeys()
    }

    public func stop() {
        guard running else { return }
        running = false
        HotkeyCenter.shared.unregister(prefix: "screenshot.")
        session?.cancel()
        session = nil
        countdown?.end(false)
        countdown = nil
        quickAccess.closeAll()
        for pin in pins { pin.close() }
        pins.removeAll()
        for editor in editors { editor.close() }
        editors.removeAll()
        historyWindow?.close()
        historyWindow = nil
        for work in pendingHistoryWrites.values { work.perform() }
        pendingHistoryWrites.removeAll()
        recent.removeAll()
    }

    public func settingsView() -> AnyView { AnyView(ScreenshotSettingsView(module: self, settings: settings)) }

    private func registerHotkeys() {
        let s = settings.value
        let bindings: [(String, Shortcut?, () -> Void)] = [
            ("area", s.areaShortcut, { [weak self] in self?.captureArea() }),
            ("window", s.windowShortcut, { [weak self] in self?.captureWindow() }),
            ("screen", s.screenShortcut, { [weak self] in self?.captureScreen() }),
            ("previous", s.previousAreaShortcut, { [weak self] in self?.capturePreviousArea() }),
            ("history", s.historyShortcut, { [weak self] in self?.showHistory() }),
        ]
        for (name, shortcut, action) in bindings {
            HotkeyCenter.shared.register("screenshot.\(name)", shortcut, onPress: action)
        }
    }

    public var shortcutBindings: [ShortcutBinding] {
        let s = settings.value
        return [
            ShortcutBinding("Capture area", s.areaShortcut),
            ShortcutBinding("Capture window", s.windowShortcut),
            ShortcutBinding("Capture screen", s.screenShortcut),
            ShortcutBinding("Capture the previous area", s.previousAreaShortcut),
            ShortcutBinding("Capture history", s.historyShortcut),
            ShortcutBinding("Area selection: square, from center, move", keys: ["⇧", "⌥", KeyCodes.name(for: 49)]),
            ShortcutBinding("Annotate: tools", keys: MarkupTool.allCases.map { String($0.key).uppercased() }),
            ShortcutBinding("Annotate: undo, copy, save", keys: ["⌘Z", "⌘C", "⌘S"]),
        ]
    }

    public var quickActions: [QuickAction] {
        let s = settings.value
        let tint = info.tint
        var actions = [
            QuickAction(id: "screenshot.area", title: "Capture Area", symbol: "rectangle.dashed", tint: tint,
                        shortcut: s.areaShortcut) { [weak self] in self?.captureArea() },
            QuickAction(id: "screenshot.window", title: "Capture Window", symbol: "macwindow", tint: tint,
                        shortcut: s.windowShortcut) { [weak self] in self?.captureWindow() },
            QuickAction(id: "screenshot.screen", title: "Capture Screen", symbol: "display", tint: tint,
                        shortcut: s.screenShortcut) { [weak self] in self?.captureScreen() },
            QuickAction(id: "screenshot.history", title: "Capture History", symbol: "clock.arrow.circlepath", tint: tint,
                        shortcut: s.historyShortcut) { [weak self] in self?.showHistory() },
        ]
        if pins.contains(where: \.model.locked) {
            actions.append(QuickAction(id: "screenshot.unlock-pins", title: "Unlock Pinned Screenshots", symbol: "lock.open",
                                       tint: tint) { [weak self] in self?.unlockPins() })
        }
        return actions
    }

    public func handle(_ command: AppCommand) -> Bool {
        let timer = command.parameters["timer"].flatMap(Int.init)
        switch command.action {
        case "area": captureArea(timer: timer)
        case "window": captureWindow(timer: timer)
        case "screen":
            if let n = command.parameters["display"].flatMap(Int.init), n >= 1, n <= NSScreen.screens.count {
                capture(.display(NSScreen.screens[n - 1]), timer: timer ?? settings.value.selfTimer, afterOverlay: false)
            } else {
                captureScreen(timer: timer)
            }
        case "previous": capturePreviousArea(timer: timer)
        case "history": showHistory()
        case "annotate":
            if let url = command.files.first { openFile(url, pin: false) } else if let item = latest { annotate(item) }
        case "pin":
            if let url = command.files.first { openFile(url, pin: true) } else if let item = latest { pin(item) }
        case "unlock-pins": unlockPins()
        case "close-pins": closePins()
        case "open", "settings": ModuleRegistry.shared.showSettings?(info.id)
        default: return false
        }
        return true
    }

    // MARK: Capture

    func captureArea(timer: Int? = nil) { begin(.area, timer: timer) }
    func captureWindow(timer: Int? = nil) { begin(.window, timer: timer) }

    func captureScreen(timer: Int? = nil) {
        if settings.value.screenTarget == .choose, NSScreen.screens.count > 1 {
            begin(.display, timer: timer)
        } else if let screen = NSScreen.underMouse ?? NSScreen.main {
            guard canCapture() else { return }
            capture(.display(screen), timer: timer ?? settings.value.selfTimer, afterOverlay: false)
        }
    }

    /// Captures the last selected area again, without a selection overlay.
    func capturePreviousArea(timer: Int? = nil) {
        guard let last = state.value.lastArea else {
            HUD.show("No previous area yet — capture an area first", symbol: "rectangle.dashed")
            return
        }
        let screen = NSScreen.screens.first { $0.stableID == last.display } ?? NSScreen.main
        guard let screen, let rect = AreaGeometry.restored(last.rect, in: CGRect(origin: .zero, size: screen.frame.size)),
              canCapture() else { return }
        capture(.area(screen, rect, frozen: nil), timer: timer ?? settings.value.selfTimer, afterOverlay: false)
    }

    /// Whether a capture may start now (running, nothing else in progress, permission granted).
    private func canCapture() -> Bool {
        guard running else {
            HUD.show("Screenshot is off", symbol: "camera.viewfinder")
            return false
        }
        guard session == nil, countdown == nil, !busy else { return false }
        guard CGPreflightScreenCaptureAccess() else {
            HUD.show("Screen Recording permission needed", symbol: "exclamationmark.shield")
            PermissionCenter.shared.request(.screenRecording)
            return false
        }
        return true
    }

    private func begin(_ mode: SelectionModel.Mode, timer: Int?) {
        guard canCapture() else { return }
        let s = settings.value
        busy = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let options = Capturer.Options(hideDesktopIcons: s.hideDesktopIcons, includePointer: false)
            // Stills are needed to freeze the screen and for the loupe.
            let wantsStills = s.freezeScreen || (mode == .area && s.showMagnifier)
            var displays: [SelectionModel.Display] = []
            for screen in NSScreen.screens {
                var still: CGImage?
                var scale = screen.backingScaleFactor
                if wantsStills {
                    do {
                        (still, scale) = try await Capturer.display(screen, options: options)
                    } catch {
                        self.log.error("Snapshot failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
                displays.append(SelectionModel.Display(screen: screen, axFrame: screen.axFrame, scale: scale, snapshot: still,
                                                       name: screen.localizedName))
            }
            self.busy = false
            guard self.running else { return }
            let model = SelectionModel(mode: mode, displays: displays, frozen: s.freezeScreen && mode != .display,
                                       showMagnifier: s.showMagnifier, showCrosshair: s.showCrosshair,
                                       canSwitchMode: mode != .display)
            var initial: (Int, CGRect)?
            if mode == .area, s.rememberLastArea, let last = self.state.value.lastArea,
               let i = displays.firstIndex(where: { $0.screen?.stableID == last.display }),
               let rect = AreaGeometry.restored(last.rect, in: displays[i].bounds) {
                initial = (i, rect)
            }
            let session = CaptureSession(model: model, initial: initial)
            session.onFinish = { [weak self] target in
                guard let self else { return }
                self.session = nil
                guard let target, self.running else { return }
                self.capture(target, timer: timer ?? s.selfTimer, afterOverlay: true)
            }
            self.session = session
            session.begin()
        }
    }

    /// Captures what was picked, after the self-timer when one is set.
    private func capture(_ target: CaptureTarget, timer: Int, afterOverlay: Bool) {
        if case .area(let screen, let rect, _) = target {
            state.value.lastArea = ScreenshotState.Area(display: screen.stableID, rect: rect)
        }
        guard timer > 0 else {
            perform(target, live: false, afterOverlay: afterOverlay)
            return
        }
        let center: CGPoint = switch target {
        case .area(let screen, let rect, _):
            CGPoint(x: screen.frame.minX + rect.midX, y: screen.frame.maxY - rect.midY)
        case .window(let w, _): ScreenGeometry.toCocoa(w.frame.center)
        case .display(let screen): CGPoint(x: screen.frame.midX, y: screen.frame.midY)
        }
        let c = Countdown(seconds: min(timer, 60), center: center) { [weak self] fire in
            guard let self else { return }
            self.countdown = nil
            if fire, self.running { self.perform(target, live: true, afterOverlay: false) }
        }
        countdown = c
        c.start()
    }

    private func perform(_ target: CaptureTarget, live: Bool, afterOverlay: Bool) {
        let s = settings.value
        let options = Capturer.Options(hideDesktopIcons: s.hideDesktopIcons, includePointer: s.includePointer)
        busy = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.busy = false }
            do {
                if afterOverlay {
                    // The app that was in front comes back once the overlay closes; let it redraw.
                    try await Task.sleep(for: .milliseconds(180))
                }
                switch target {
                case .area(let screen, let rect, let frozen):
                    if !live, let (still, scale) = frozen, let cropped = still.cropping(to: AreaGeometry.pixelRect(rect, scale: scale)) {
                        self.finish(cropped, scale: scale, kind: .area, screen: screen)
                    } else {
                        var areaOptions = options
                        areaOptions.includePointer = false
                        let (image, scale) = try await Capturer.display(screen, rect: rect, options: areaOptions)
                        self.finish(image, scale: scale, kind: .area, screen: screen)
                    }
                case .window(let window, let screen):
                    let (image, scale) = try await Capturer.window(window.id, options: options)
                    let framed = s.autoBeautify.applies(to: .window)
                    let composed = WindowFramer.compose(image, scale: scale, shadow: s.windowShadow && !framed,
                                                        padding: framed ? 0 : CGFloat(s.windowPadding)) ?? image
                    self.finish(composed, scale: scale, kind: .window, screen: screen)
                case .display(let screen):
                    let (image, scale) = try await Capturer.display(screen, options: options)
                    self.finish(image, scale: scale, kind: .screen, screen: screen)
                }
            } catch is CancellationError {
                return
            } catch {
                self.log.error("Capture failed: \(error.localizedDescription, privacy: .public)")
                HUD.show("Couldn’t capture the screen", symbol: "exclamationmark.triangle")
            }
        }
    }

    /// Everything that happens after a capture: sound, save, copy, history, card, editor, pin.
    private func finish(_ image: CGImage, scale: CGFloat, kind: CaptureKind, screen: NSScreen?) {
        guard running else { return }
        let s = settings.value
        if s.playSound { CaptureTransfer.playShutter() }
        let item = CaptureItem(image: image, scale: scale, kind: kind)
        if s.autoBeautify.applies(to: kind) { item.document.beautify = s.beautify }
        remember(item)
        var saved = false
        if s.saveToFile { saved = save(item) != nil }
        if s.copyToClipboard { copy(item) }
        if s.keepHistory {
            history.add(id: item.id, image: image, rendered: item.rendered, document: item.document, kind: kind, date: item.date,
                        savedURL: item.savedURL, limitMB: s.historyLimitMB, maxAgeDays: s.historyMaxAgeDays)
        }
        if s.showQuickAccess { quickAccess.show(item, on: screen) }
        if s.openAnnotate { annotate(item) }
        if s.pinToScreen { pin(item) }
        if !s.showQuickAccess && !s.openAnnotate && !s.pinToScreen {
            if saved {
                HUD.show("Screenshot saved", symbol: "checkmark.circle")
            } else if s.copyToClipboard {
                HUD.show("Screenshot copied", symbol: "doc.on.doc")
            }
        }
    }

    private func remember(_ item: CaptureItem) {
        recent.removeAll { $0 === item }
        recent.insert(item, at: 0)
        if recent.count > 3 { recent.removeLast(recent.count - 3) }
    }

    /// The latest capture of this session, or the newest one in the history.
    private var latest: CaptureItem? {
        if let item = recent.first { return item }
        return history.entries.first.flatMap { item(for: $0.id) }
    }

    // MARK: Output

    @discardableResult
    func save(_ item: CaptureItem) -> URL? {
        let s = settings.value
        let image = item.output(retina: s.retina)
        let scale = item.outputScale(retina: s.retina)
        do {
            let url: URL
            if let existing = item.savedURL, existing.pathExtension.lowercased() == s.format.fileExtension,
               FileManager.default.fileExists(atPath: existing.path) {
                // Saving again after annotating replaces the earlier file.
                try ImageEncoder.data(image, format: s.format, quality: s.jpegQuality, scale: scale).write(to: existing, options: .atomic)
                url = existing
            } else {
                url = try ImageEncoder.save(image, to: s.saveFolderURL, settings: s, scale: scale, date: item.date)
            }
            item.savedURL = url
            if s.keepHistory { history.setSaved(item.id, url: url) }
            return url
        } catch {
            log.error("Saving failed: \(error.localizedDescription, privacy: .public)")
            HUD.show("Couldn’t save the screenshot", symbol: "exclamationmark.triangle")
            return nil
        }
    }

    func saveAs(_ item: CaptureItem) {
        let s = settings.value
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic]
        panel.nameFieldStringValue = FileNamer.name(template: s.fileNameTemplate, date: item.date, format: s.format)
        panel.directoryURL = s.saveFolderURL
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        NSApp.activate()
        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, response == .OK, let url = panel.url else { return }
                let format = ImageFormat.allCases.first { $0.fileExtension == url.pathExtension.lowercased() }
                    ?? (url.pathExtension.lowercased() == "jpeg" ? .jpeg : .png)
                do {
                    try ImageEncoder.data(item.output(retina: s.retina), format: format, quality: s.jpegQuality,
                                          scale: item.outputScale(retina: s.retina)).write(to: url, options: .atomic)
                    item.savedURL = url
                    if s.keepHistory { self.history.setSaved(item.id, url: url) }
                } catch {
                    self.log.error("Save As failed: \(error.localizedDescription, privacy: .public)")
                    HUD.show("Couldn’t save the screenshot", symbol: "exclamationmark.triangle")
                }
            }
        }
    }

    func copy(_ item: CaptureItem) {
        let s = settings.value
        CaptureTransfer.copy(item.output(retina: s.retina), scale: item.outputScale(retina: s.retina))
    }

    func copyText(in item: CaptureItem) {
        let image = item.rendered
        Task { @MainActor [weak self] in
            do {
                let text = try await TextReader.text(in: image)
                if text.isEmpty {
                    HUD.show("No text found", symbol: "text.viewfinder")
                } else {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    HUD.show("Text copied", symbol: "text.viewfinder")
                }
            } catch {
                self?.log.error("Text recognition failed: \(error.localizedDescription, privacy: .public)")
                HUD.show("Couldn’t read the text", symbol: "exclamationmark.triangle")
            }
        }
    }

    private func dragFile(_ item: CaptureItem) -> URL? {
        let s = settings.value
        do {
            return try CaptureTransfer.temporaryFile(item.output(retina: s.retina), settings: s,
                                                     scale: item.outputScale(retina: s.retina), date: item.date)
        } catch {
            log.error("Drag file failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func share(_ item: CaptureItem, from view: NSView?) {
        guard let url = dragFile(item), let view else { return }
        let picker = NSSharingServicePicker(items: [url])
        let anchor = CGRect(x: view.bounds.maxX - 150, y: view.isFlipped ? 0 : view.bounds.maxY - 44, width: 44, height: 44)
        picker.show(relativeTo: anchor, of: view, preferredEdge: .minY)
    }

    // MARK: Annotate

    func annotate(_ item: CaptureItem) {
        if let open = editors.first(where: { $0.model.item === item }) {
            open.show()
            return
        }
        let model = AnnotateModel(item: item, settings: settings.value)
        model.actions = AnnotateActions(
            copy: { [weak self] m in
                self?.copy(m.item)
                m.showToast(String(localized: "Copied", comment: "Annotate toast: the image was copied"))
            },
            save: { [weak self] m in
                if self?.save(m.item) != nil { m.showToast(String(localized: "Saved", comment: "Annotate toast: the image was saved")) }
            },
            saveAs: { [weak self] m in self?.saveAs(m.item) },
            share: { [weak self] m, view in self?.share(m.item, from: view) },
            pin: { [weak self] m in self?.pin(m.item) },
            copyText: { [weak self] m in self?.copyText(in: m.item) },
            dragFile: { [weak self] m in self?.dragFile(m.item) },
            makeDefaultBackground: { [weak self] style in self?.settings.value.beautify = style })
        model.onChange = { [weak self, weak item] in
            guard let self, let item else { return }
            self.edited(item)
        }
        let window = AnnotateWindow(model: model)
        window.onClose = { [weak self, weak window] in
            guard let self, let window else { return }
            self.editors.removeAll { $0 === window }
            self.flushHistory(window.model.item)
        }
        editors.append(window)
        window.show()
    }

    /// Keeps cards, pins and the history in step with an edit (history writes are coalesced).
    private func edited(_ item: CaptureItem) {
        quickAccess.refresh(item)
        for pin in pins where pin.item === item { pin.refresh() }
        guard settings.value.keepHistory else { return }
        pendingHistoryWrites[item.id]?.cancel()
        let work = DispatchWorkItem { [weak self, weak item] in
            guard let self, let item else { return }
            self.pendingHistoryWrites[item.id] = nil
            self.history.update(item.id, document: item.document, rendered: item.rendered)
        }
        pendingHistoryWrites[item.id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func flushHistory(_ item: CaptureItem) {
        pendingHistoryWrites.removeValue(forKey: item.id)?.perform()
    }

    // MARK: Pin

    func pin(_ item: CaptureItem) {
        let screen = NSScreen.underMouse ?? NSScreen.main
        var window: PinWindow?
        let actions = PinActions(
            copy: { [weak self] in self?.copy(item); HUD.show("Copied", symbol: "doc.on.doc") },
            save: { [weak self] in self?.saveAs(item) },
            annotate: { [weak self] in self?.annotate(item) },
            copyText: { [weak self] in self?.copyText(in: item) },
            setOpacity: { value in window?.setOpacity(value) },
            lock: {
                window?.setLocked(true)
                HUD.show("Pinned screenshot locked · unlock it from the MacToys menu", symbol: "lock", duration: 2.4)
            },
            close: { window?.close() },
            closeAll: { [weak self] in self?.closePins() })
        let pin = PinWindow(item: item, actions: actions, near: screen)
        window = pin
        pin.onClose = { [weak self] closed in self?.pins.removeAll { $0 === closed } }
        pins.append(pin)
        pin.show()
    }

    func unlockPins() {
        for pin in pins where pin.model.locked { pin.setLocked(false) }
    }

    func closePins() {
        for pin in pins { pin.close() }
        pins.removeAll()
    }

    // MARK: Files and history

    private func openFile(_ url: URL, pin: Bool) {
        guard running else {
            HUD.show("Screenshot is off", symbol: "camera.viewfinder")
            return
        }
        guard let (image, scale) = CaptureTransfer.load(url) else {
            HUD.show("That file isn’t an image MacToys can open", symbol: "exclamationmark.triangle")
            return
        }
        let item = CaptureItem(image: image, scale: scale, kind: .file)
        remember(item)
        if pin { self.pin(item) } else { annotate(item) }
    }

    /// A capture from this session, or rebuilt from the history.
    private func item(for id: UUID) -> CaptureItem? {
        if let open = recent.first(where: { $0.id == id }) { return open }
        if let editor = editors.first(where: { $0.model.item.id == id }) { return editor.model.item }
        if let pin = pins.first(where: { $0.item.id == id }) { return pin.item }
        guard let entry = history.entries.first(where: { $0.id == id }), let (image, scale) = history.image(for: id) else {
            HUD.show("That capture is no longer in the history", symbol: "exclamationmark.triangle")
            return nil
        }
        let saved = entry.savedPath.map { URL(fileURLWithPath: $0) }
        return CaptureItem(id: id, image: image, scale: scale, kind: entry.kind, date: entry.date,
                           document: history.document(for: id), savedURL: saved)
    }

    func showHistory() {
        guard running else {
            HUD.show("Screenshot is off", symbol: "camera.viewfinder")
            return
        }
        if let historyWindow {
            historyWindow.show()
            return
        }
        let actions = HistoryActions(
            open: { [weak self] id in if let item = self?.item(for: id) { self?.annotate(item) } },
            copy: { [weak self] id in
                if let item = self?.item(for: id) { self?.copy(item); HUD.show("Copied", symbol: "doc.on.doc") }
            },
            pin: { [weak self] id in if let item = self?.item(for: id) { self?.pin(item) } },
            reveal: { [weak self] id in
                guard let path = self?.history.entries.first(where: { $0.id == id })?.savedPath else { return }
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            },
            delete: { [weak self] id in self?.history.delete(id) },
            clear: { [weak self] in self?.history.clear() },
            capture: { [weak self] in self?.captureArea() })
        let view = HistoryView(history: history, actions: actions, areaShortcut: settings.value.areaShortcut)
        let window = HostedToolWindow(title: String(localized: "Capture History", comment: "Window title"),
                                      size: CGSize(width: 940, height: 640), minSize: CGSize(width: 620, height: 420),
                                      autosaveName: "MacToys.ScreenshotHistory", content: view)
        window.onClose = { [weak self] in self?.historyWindow = nil }
        historyWindow = window
        window.show()
    }

    /// Bytes and count of the history, for the settings page.
    var historySummary: (count: Int, bytes: Int64) { (history.entries.count, history.totalBytes) }

    // MARK: Previews

    public var previewScenes: [PreviewScene] { ScreenshotPreviews.scenes(module: self) }
}
