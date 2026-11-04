import AppKit
import AVFoundation
import MacToysCore
import SwiftUI

/// Camera Mirror: check your camera from the menu bar before a call, in a small window you can keep on top.
@MainActor
public final class CameraMirrorModule: ToyModule {
    public let info = ModuleInfo(
        id: "mirror", name: "Camera Mirror",
        summary: "Check your camera from the menu bar before a call, in a small window you can keep on top.",
        symbol: "web.camera.fill", tint: .mint, category: .systemTools,
        permissions: [.camera], enabledByDefault: true,
        keywords: ["camera", "webcam", "mirror", "video call", "preview", "selfie", "photo", "facetime", "continuity camera"])

    let settings: Persisted<MirrorSettings>
    let camera = MirrorCamera()
    let ui = MirrorUIState()
    let log = Log.for("mirror")

    private var running = false
    private var statusItem: NSStatusItem?
    private var panel: MirrorDropPanel?
    private var floating: MirrorFloatingWindow?
    private var notchMonitor: Any?
    private var lastShortcut: Shortcut??
    private var savedChipWork: DispatchWorkItem?
    private var pendingPhoto = false

    private static let hotkeyID = "mirror.activate"

    public convenience init() {
        self.init(store: .shared)
    }

    /// `store` lets previews use throwaway settings.
    init(store: SettingsStore) {
        settings = Persisted("mirror", default: MirrorSettings(), store: store)
        settings.onChange { [weak self] new in self?.settingsChanged(new) }
    }

    // MARK: - Lifecycle

    public func start() {
        guard !running else { return }
        running = true
        registerHotkey()
        updateStatusItem()
        updateNotchMonitor()
    }

    public func stop() {
        guard running else { return }
        running = false
        HotkeyCenter.shared.unregister(Self.hotkeyID)
        lastShortcut = nil
        closeMirror()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
        if let notchMonitor { NSEvent.removeMonitor(notchMonitor) }
        notchMonitor = nil
        settings.flush()
    }

    private func settingsChanged(_ s: MirrorSettings) {
        guard running else { return }
        registerHotkey()
        updateStatusItem()
        updateNotchMonitor()
        floating?.apply(s)
        camera.setLightCheck(s.lightCheck)
    }

    private func registerHotkey() {
        let shortcut = settings.value.activation
        guard lastShortcut != .some(shortcut) else { return }
        lastShortcut = .some(shortcut)
        HotkeyCenter.shared.register(Self.hotkeyID, shortcut) { [weak self] in self?.toggle() }
    }

    // MARK: - Showing

    var isShowing: Bool { panel?.isVisible == true || floating?.isVisible == true }

    /// The menu bar icon, shortcut and quick action: opens the mirror, or closes whichever is open.
    func toggle() {
        if isShowing { closeMirror() } else { showPanel() }
    }

    /// Drops the mirror from the menu bar; `placement` overrides the setting (the notch click).
    func showPanel(placement: MirrorPlacement? = nil) {
        guard running else {
            HUD.show("Camera Mirror is turned off in MacToys settings", symbol: "web.camera")
            return
        }
        if let floating, floating.isVisible { closeFloating(stopCamera: false) }
        let p = panel ?? makePanel()
        panel = p
        ui.presented = false
        ui.pickerOpen = false
        let button = settings.value.showMenuBarIcon ? statusItem?.button : nil
        p.present(below: button, placement: placement ?? settings.value.placement)
        statusItem?.button?.highlight(true)
        startCamera()
    }

    private func makePanel() -> MirrorDropPanel {
        let p = MirrorDropPanel(module: self)
        p.onClose = { [weak self] in self?.panelClosed() }
        return p
    }

    private func panelClosed() {
        statusItem?.button?.highlight(false)
        ui.pickerOpen = false
        ui.presented = false
        // The camera stops the moment the mirror goes away, unless it moved to the floating window.
        if floating?.isVisible != true { camera.stop() }
    }

    /// Moves the mirror into its own floating window.
    func detach() {
        guard running else { return }
        let s = settings.value
        let screen = panel?.screen ?? MirrorDropPanel.cameraScreen
        let visible = screen.visibleFrame
        var frame = s.floatingFrame?.rect ?? FloatingGeometry.defaultFrame(in: visible, shape: s.shape, aspect: s.aspect)
        let onScreen = NSScreen.screens.first { $0.visibleFrame.intersects(frame) }?.visibleFrame ?? visible
        frame.size = FloatingGeometry.constrain(frame.size, shape: s.shape, aspect: s.aspect, visible: onScreen.size)
        frame = FloatingGeometry.fit(frame, in: onScreen)
        let w = floating ?? MirrorFloatingWindow(module: self, frame: frame)
        floating = w
        w.setFrame(frame, display: true)
        w.apply(s)
        ui.hovering = false
        w.orderFrontRegardless()
        if panel?.isVisible == true { panel?.dismiss() }
        startCamera()
    }

    /// Back from the floating window to the menu bar.
    func attach() {
        closeFloating(stopCamera: false)
        showPanel()
    }

    /// Closes the panel and the floating window; the camera stops.
    func closeMirror() {
        closeFloating(stopCamera: false)
        if panel?.isVisible == true { panel?.dismiss() }
        camera.stop()
        pendingPhoto = false
    }

    private func closeFloating(stopCamera: Bool) {
        guard let floating, floating.isVisible else { return }
        settings.value.floatingFrame = StoredFrame(floating.frame)
        floating.orderOut(nil)
        ui.hovering = false
        if stopCamera { camera.stop() }
    }

    // MARK: - Camera

    private func startCamera() {
        camera.start(preferring: settings.value.cameraID, lightCheck: settings.value.lightCheck)
        if case .needsPermission = camera.status { PermissionCenter.shared.refresh() }
    }

    func restartCamera() {
        camera.stop()
        startCamera()
    }

    func requestAccess() {
        camera.requestAccess { [weak self] in
            guard let self, self.isShowing else { return }
            self.startCamera()
        }
    }

    func selectCamera(_ id: String) {
        settings.value.cameraID = id
        withAnimation(.snappy(duration: 0.2)) { ui.pickerOpen = false }
        startCamera()
    }

    func zoom(by factor: CGFloat) {
        let view = ui.videoSize
        settings.value.setFraming(settings.value.framing.zoomed(by: factor, source: camera.sourceSize, view: view))
    }

    /// 1× → 1.5× → 2× → 1×.
    func cycleZoom() {
        let z = settings.value.zoom
        let next: Double = z < 1.4 ? 1.5 : z < 1.9 ? 2 : 1
        settings.update { $0.zoom = next }
        if next == 1 { resetFraming() }
    }

    func resetFraming() {
        settings.update { $0.setFraming(MirrorFraming(zoom: 1, center: CGPoint(x: 0.5, y: 0.45))) }
    }

    // MARK: - Photos

    /// Takes a photo of what the mirror shows and saves it to the chosen folder.
    func takePhoto() {
        guard running else { return }
        if !isShowing {
            pendingPhoto = true
            showPanel()
            waitForCameraThenShoot(attempts: 20)
            return
        }
        guard camera.status == .running else {
            if case .needsPermission = camera.status {
                HUD.show("Camera permission needed", symbol: "exclamationmark.shield")
                PermissionCenter.shared.request(.camera)
            }
            return
        }
        let s = settings.value
        let viewSize = ui.videoSize
        if s.shutterSound { MirrorPhoto.playShutter() }
        withAnimation(.easeOut(duration: 0.05)) { ui.flash = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            withAnimation(.easeIn(duration: 0.35)) { self?.ui.flash = false }
        }
        camera.capturePhoto { [weak self] image in
            guard let self else { return }
            guard let image else {
                HUD.show("Couldn’t take the photo", symbol: "exclamationmark.triangle")
                return
            }
            let folder = s.photoFolder.url
            Task.detached(priority: .userInitiated) {
                let url = MirrorPhoto.fileURL(in: folder, date: Date())
                do {
                    guard let rendered = MirrorPhoto.render(image, framing: s.framing, viewSize: viewSize, mirrored: s.photoMirrored) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    try MirrorPhoto.write(rendered, to: url)
                    await MainActor.run { self.photoSaved(url) }
                } catch {
                    await MainActor.run {
                        self.log.error("Saving photo failed: \(error.localizedDescription, privacy: .public)")
                        HUD.show("Couldn’t save the photo: \(error.localizedDescription)", symbol: "exclamationmark.triangle")
                    }
                }
            }
        }
    }

    private func waitForCameraThenShoot(attempts: Int) {
        guard pendingPhoto else { return }
        if camera.status == .running {
            pendingPhoto = false
            // Give auto-exposure a moment after the camera starts.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.takePhoto() }
            return
        }
        guard attempts > 0, camera.status == .starting || camera.status == .idle else {
            pendingPhoto = false
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.waitForCameraThenShoot(attempts: attempts - 1)
        }
    }

    private func photoSaved(_ url: URL) {
        withAnimation(.snappy(duration: 0.25)) { ui.savedPhoto = url }
        if floating?.isVisible == true && panel?.isVisible != true {
            HUD.show("Photo saved to \(url.deletingLastPathComponent().lastPathComponent)", symbol: "camera.fill")
        }
        savedChipWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            withAnimation(.smooth(duration: 0.3)) { self?.ui.savedPhoto = nil }
        }
        savedChipWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    // MARK: - Menu bar and notch

    private func updateStatusItem() {
        if settings.value.showMenuBarIcon {
            guard statusItem == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.autosaveName = "com.w33d.mactoys.mirror"
            let image = NSImage(systemSymbolName: "web.camera", accessibilityDescription: String(localized: "Camera Mirror"))
            image?.isTemplate = true
            item.button?.image = image
            item.button?.toolTip = String(localized: "Camera Mirror")
            item.button?.target = MirrorStatusTarget.shared
            item.button?.action = #selector(MirrorStatusTarget.clicked(_:))
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            MirrorStatusTarget.shared.module = self
            statusItem = item
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    /// The small menu on right-click.
    func showStatusMenu(_ button: NSStatusBarButton) {
        let menu = NSMenu()
        let open = NSMenuItem(title: String(localized: "Show Mirror"), action: #selector(MirrorStatusTarget.showMirror), keyEquivalent: "")
        let float = NSMenuItem(title: String(localized: "Float in a Window"), action: #selector(MirrorStatusTarget.float), keyEquivalent: "")
        let photo = NSMenuItem(title: String(localized: "Take a Photo"), action: #selector(MirrorStatusTarget.photo), keyEquivalent: "")
        let prefs = NSMenuItem(title: String(localized: "Camera Mirror Settings…"), action: #selector(MirrorStatusTarget.settings), keyEquivalent: ",")
        for item in [open, float, photo, prefs] { item.target = MirrorStatusTarget.shared }
        menu.items = [open, float, photo, .separator(), prefs]
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    /// Clicking the notch opens the mirror right under the camera. A global monitor only sees
    /// clicks that go to other apps, which is what the empty notch area is.
    private func updateNotchMonitor() {
        let want = settings.value.openFromNotch && NSScreen.screens.contains { $0.safeAreaInsets.top > 0 }
        if want, notchMonitor == nil {
            notchMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                let p = NSEvent.mouseLocation
                MainActor.assumeIsolated {
                    guard let self, NotchArea.contains(p) else { return }
                    if self.isShowing { self.closeMirror() } else { self.showPanel(placement: .underCamera) }
                }
            }
        } else if !want, let monitor = notchMonitor {
            NSEvent.removeMonitor(monitor)
            notchMonitor = nil
        }
    }

    // MARK: - ToyModule

    public func settingsView() -> AnyView {
        AnyView(MirrorSettingsView(module: self))
    }

    public var quickActions: [QuickAction] {
        [QuickAction(id: "mirror.show", title: "Camera Mirror", symbol: "web.camera.fill", tint: .mint,
                     shortcut: settings.value.activation, perform: { [weak self] in self?.toggle() })]
    }

    public var shortcutBindings: [ShortcutBinding] {
        [ShortcutBinding("Show or hide the camera mirror", settings.value.activation),
         ShortcutBinding("Take a photo in the mirror", keys: [String(localized: "Space", comment: "Key name: space bar")]),
         ShortcutBinding("Mirror the picture", keys: ["M"]),
         ShortcutBinding("Float the mirror in a window", keys: ["D"])]
    }

    /// `mactoys://mirror/<action>`: `open`/`show`/`toggle` (the menu bar mirror), `float` (floating window),
    /// `close`, `photo` (opens the mirror if needed and saves a photo), `settings`.
    public func handle(_ command: AppCommand) -> Bool {
        switch command.action {
        case "settings":
            ModuleRegistry.shared.showSettings?(info.id)
        case "open", "show":
            guard running else { ModuleRegistry.shared.showSettings?(info.id); return true }
            if !isShowing { showPanel() }
        case "toggle":
            guard running else { ModuleRegistry.shared.showSettings?(info.id); return true }
            toggle()
        case "float", "detach":
            guard running else { ModuleRegistry.shared.showSettings?(info.id); return true }
            detach()
        case "close", "hide":
            closeMirror()
        case "photo", "snap":
            guard running else { return false }
            takePhoto()
        default:
            return false
        }
        return true
    }

    public var previewScenes: [PreviewScene] { MirrorScenes.all }
}

/// The empty strip of menu bar in front of the camera on Macs with a notch.
enum NotchArea {
    @MainActor
    static func contains(_ p: CGPoint) -> Bool {
        for screen in NSScreen.screens where screen.safeAreaInsets.top > 0 {
            guard let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { continue }
            let rect = CGRect(x: left.maxX, y: screen.frame.maxY - screen.safeAreaInsets.top,
                              width: right.minX - left.maxX, height: screen.safeAreaInsets.top)
            if rect.contains(p) { return true }
        }
        return false
    }
}

/// Target for the menu bar button and its menu (Objective-C selectors).
@MainActor
final class MirrorStatusTarget: NSObject {
    static let shared = MirrorStatusTarget()
    weak var module: CameraMirrorModule?

    @objc func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            module?.showStatusMenu(sender)
        } else {
            module?.toggle()
        }
    }

    @objc func showMirror() { module?.showPanel() }
    @objc func float() { module?.detach() }
    @objc func photo() { module?.takePhoto() }
    @objc func settings() { ModuleRegistry.shared.showSettings?(module?.info.id) }
}
