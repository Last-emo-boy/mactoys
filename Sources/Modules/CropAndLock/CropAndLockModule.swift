import AppKit
import MacToysCore
import Observation
import SwiftUI

/// Crop And Lock: select part of a window and keep it as a small floating window — a live
/// thumbnail, an interactive live crop, or a frozen screenshot.
@MainActor
public final class CropAndLockModule: ToyModule {
    public let info = ModuleInfo(
        id: "cropandlock", name: "Crop And Lock",
        summary: "Crop part of a window into a live thumbnail that stays on top.",
        symbol: "crop", tint: .teal, category: .windowing,
        permissions: [.accessibility, .screenRecording], enabledByDefault: true,
        keywords: ["crop", "thumbnail", "reparent", "picture in picture", "pip", "screenshot", "mirror"])

    let settings = Persisted("cropandlock", default: CropAndLockSettings())
    /// Open crop windows, for the settings page.
    let openCrops = CropCounter()

    private var live: [LiveCropWindow] = []
    private var shots: [ScreenshotCropWindow] = []
    private var selection: CropSelection?
    private var running = false
    private var activationObserver: NSObjectProtocol?
    private var lastExternalPID: pid_t?
    private let log = Log.for("cropandlock")

    public init() {
        settings.onChange { [weak self] _ in
            guard let self, self.running else { return }
            self.registerHotkeys()
        }
    }

    // MARK: ToyModule

    public func start() {
        guard !running else { return }
        running = true
        registerHotkeys()
        let own = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication?.processIdentifier, front != own { lastExternalPID = front }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                if let pid = app?.processIdentifier, pid != own { self?.lastExternalPID = pid }
            }
        }
    }

    public func stop() {
        guard running else { return }
        running = false
        HotkeyCenter.shared.unregister(prefix: "cropandlock.")
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        selection?.cancel()
        selection = nil
        closeAll()
    }

    public func settingsView() -> AnyView { AnyView(CropAndLockSettingsView(module: self)) }

    public var quickActions: [QuickAction] {
        let s = settings.value
        var actions = [
            QuickAction(id: "cropandlock.thumbnail", title: "Crop Thumbnail", symbol: "pip", tint: info.tint,
                        shortcut: s.thumbnail) { [weak self] in self?.begin(.thumbnail) },
            QuickAction(id: "cropandlock.interactive", title: "Interactive Crop", symbol: "cursorarrow.rays", tint: info.tint,
                        shortcut: s.interactive) { [weak self] in self?.begin(.interactive) },
            QuickAction(id: "cropandlock.screenshot", title: "Crop Screenshot", symbol: "camera.viewfinder", tint: info.tint,
                        shortcut: s.screenshot) { [weak self] in self?.begin(.screenshot) },
        ]
        if openCrops.count > 0 {
            actions.append(QuickAction(id: "cropandlock.closeall", title: "Close Crops", symbol: "xmark.square", tint: info.tint) {
                [weak self] in self?.closeAll()
            })
        }
        return actions
    }

    public var shortcutBindings: [ShortcutBinding] {
        let s = settings.value
        return [ShortcutBinding("Crop to a live thumbnail", s.thumbnail),
                ShortcutBinding("Crop to an interactive window", s.interactive),
                ShortcutBinding("Crop to a screenshot", s.screenshot)]
    }

    /// `mactoys://cropandlock/<action>`: `thumbnail`, `interactive` (alias `reparent`), `screenshot`,
    /// `closeall`, `settings`.
    public func handle(_ command: AppCommand) -> Bool {
        switch command.action {
        case "thumbnail": begin(.thumbnail)
        case "interactive", "reparent": begin(.interactive)
        case "screenshot": begin(.screenshot)
        case "closeall": closeAll()
        case "open", "settings": ModuleRegistry.shared.showSettings?(info.id)
        default: return false
        }
        return true
    }

    public var previewScenes: [PreviewScene] {
        [PreviewScene("selection", size: CGSize(width: 900, height: 580)) { AnyView(CropSelectionPreview()) },
         PreviewScene("thumbnail", size: CGSize(width: 900, height: 580)) { AnyView(CropWindowPreview()) },
         PreviewScene("screenshot", size: CGSize(width: 560, height: 360)) { AnyView(ScreenshotCropPreview()) }]
    }

    // MARK: Cropping

    func begin(_ mode: CropMode) {
        guard running else {
            HUD.show("Crop And Lock is off", symbol: "crop")
            return
        }
        guard AXIsProcessTrusted() else {
            HUD.show("Accessibility permission needed", symbol: "exclamationmark.shield")
            PermissionCenter.shared.request(.accessibility)
            return
        }
        guard CGPreflightScreenCaptureAccess() else {
            HUD.show("Screen Recording permission needed", symbol: "exclamationmark.shield")
            PermissionCenter.shared.request(.screenRecording)
            return
        }
        guard let window = targetWindow(), let id = window.windowID, let frame = window.frame,
              frame.width >= CropGeometry.minimumSide, frame.height >= CropGeometry.minimumSide else {
            HUD.show("No window to crop", symbol: "crop")
            return
        }
        if window.isFullScreen {
            HUD.show("Leave full screen to crop this window", symbol: "crop")
            return
        }
        selection?.cancel()
        let sel = CropSelection(windowFrame: frame, mode: mode) { [weak self] rect in
            guard let self else { return }
            self.selection = nil
            guard let rect else { return }
            self.create(mode, window: window, id: id, frame: frame, crop: rect)
        }
        selection = sel
        sel.present()
    }

    private func create(_ mode: CropMode, window: WindowRef, id: CGWindowID, frame: CGRect, crop: CGRect) {
        let s = settings.value
        switch mode {
        case .thumbnail, .interactive:
            let options = LiveCropWindow.Options(forwardClicks: s.forwardClicks, restorePosition: s.restorePosition,
                                                 allSpaces: s.showOnAllSpaces, frameRate: s.frameRate)
            let w = LiveCropWindow(mode: mode, source: window, sourceID: id, sourceFrame: frame, crop: crop, options: options)
            w.onClosed = { [weak self] closed in
                self?.live.removeAll { $0 === closed }
                self?.syncCount()
            }
            live.append(w)
            syncCount()
            w.start()
        case .screenshot:
            let scale = ScreenGeometry.screen(forAX: frame)?.backingScaleFactor ?? 2
            let name = window.title.flatMap { $0.isEmpty ? nil : $0 } ?? window.appName
            Task { [weak self] in
                do {
                    let full = try await ScreenCapture.image(windowID: id, scale: scale)
                    let px = CropGeometry.pixelRect(crop: crop, windowSize: frame.size,
                                                    imageSize: CGSize(width: full.width, height: full.height))
                    guard !px.isNull, let cropped = full.cropping(to: px) else { throw CaptureError.notFound }
                    self?.showScreenshot(cropped, size: crop.size,
                                         at: CropGeometry.globalRect(crop: crop, windowFrame: frame), name: name)
                } catch {
                    self?.log.error("Screenshot crop failed: \(error.localizedDescription, privacy: .public)")
                    HUD.show("Couldn't capture the window", symbol: "exclamationmark.triangle")
                }
            }
        }
    }

    private func showScreenshot(_ image: CGImage, size: CGSize, at rect: CGRect, name: String) {
        guard running else { return }
        let w = ScreenshotCropWindow(image: image, pointSize: size, at: rect, sourceName: name,
                                     allSpaces: settings.value.showOnAllSpaces)
        w.onClosed = { [weak self] closed in
            self?.shots.removeAll { $0 === closed }
            self?.syncCount()
        }
        shots.append(w)
        syncCount()
        w.show()
    }

    func closeAll() {
        for w in live { w.close() }
        for w in shots { w.close() }
        live.removeAll()
        shots.removeAll()
        syncCount()
    }

    private func syncCount() { openCrops.count = live.count + shots.count }

    /// The focused window of the frontmost app, or of the last other app when MacToys is in front.
    private func targetWindow() -> WindowRef? {
        let own = ProcessInfo.processInfo.processIdentifier
        var pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if pid == nil || pid == own { pid = lastExternalPID }
        guard let pid, pid != own else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        if let element: AXUIElement = app.ax(kAXFocusedWindowAttribute) { return WindowRef(element: element, pid: pid) }
        return WindowRef.windows(of: pid).first { $0.isStandard && !$0.isMinimized }
    }

    private func registerHotkeys() {
        let s = settings.value
        HotkeyCenter.shared.register("cropandlock.thumbnail", s.thumbnail) { [weak self] in self?.begin(.thumbnail) }
        HotkeyCenter.shared.register("cropandlock.interactive", s.interactive) { [weak self] in self?.begin(.interactive) }
        HotkeyCenter.shared.register("cropandlock.screenshot", s.screenshot) { [weak self] in self?.begin(.screenshot) }
    }
}

/// Number of open crop windows, observed by the settings page.
@MainActor
@Observable
final class CropCounter {
    var count = 0
}
