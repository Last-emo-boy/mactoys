import AppKit
import Carbon.HIToolbox
import MacToysCore
import PreviewKit
import Quartz
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// The Peek window: shows `PeekItems`, handles the keyboard, sizing, pinning and file actions.
@MainActor
final class PeekController: NSObject, NSWindowDelegate {
    let model = PeekModel()
    private let settings: Persisted<PeekSettings>
    private var window: NSWindow?
    private var keyMonitor: Any?
    private var loadTask: Task<Void, Never>?
    private var previousApp: NSRunningApplication?
    private var showingAlert = false
    private let log = Log.for("peek")

    init(settings: Persisted<PeekSettings>) {
        self.settings = settings
        super.init()
        model.onPrevious = { [weak self] in self?.step(-1) }
        model.onNext = { [weak self] in self?.step(1) }
        model.onOpen = { [weak self] in self?.openCurrent() }
        model.onTogglePin = { [weak self] in self?.togglePin() }
    }

    var isVisible: Bool { window?.isVisible == true }

    // MARK: Showing

    func show(_ items: PeekItems) {
        guard !items.isEmpty else { return }
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = front
        }
        model.items = items
        model.pinned = settings.value.pinned
        model.showDetails = settings.value.showDetails
        let w = window ?? makeWindow()
        window = w
        applySettings()
        let firstShow = !w.isVisible
        load(resizing: firstShow ? .center : .keepCenter)
        installKeyMonitor()
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
        // No control has focus at first, so Space/arrows act on Peek rather than a button.
        w.makeFirstResponder(nil)
    }

    /// Closes the window; `windowWillClose` tears everything down.
    func close() {
        window?.close()
    }

    private func teardown() {
        loadTask?.cancel()
        loadTask = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        model.content = .loading
        model.fields = []
        // Let the app we came from (usually Finder) have the keyboard back — unless the user already
        // switched elsewhere (focus loss) or another MacToys window is open.
        let others = NSApp.windows.contains { $0 !== window && $0.isVisible && $0.canBecomeMain }
        if NSApp.isActive, !others, let app = previousApp, !app.isTerminated { app.activate() }
        previousApp = nil
    }

    func applySettings() {
        guard let w = window else { return }
        w.level = settings.value.alwaysOnTop ? .floating : .normal
        model.showDetails = settings.value.showDetails
        model.pinned = settings.value.pinned
    }

    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 640),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.toolbarStyle = .unified
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        w.minSize = CGSize(width: 420, height: 300)
        w.tabbingMode = .disallowed
        w.delegate = self
        // SwiftUI's .toolbar and .navigationTitle become the window's own toolbar and title.
        let host = NSHostingController(rootView: PeekView(model: model))
        host.sizingOptions = []
        host.sceneBridgingOptions = [.toolbars, .title]
        w.contentViewController = host
        w.setContentSize(CGSize(width: 900, height: 640))
        return w
    }

    // MARK: Loading

    private enum Resize { case center, keepCenter, none }

    private func load(resizing: Resize) {
        loadTask?.cancel()
        guard let url = model.items.current else {
            model.content = .empty
            model.fields = []
            model.defaultApp = nil
            return
        }
        window?.title = model.items.title
        model.content = .loading
        model.defaultApp = Self.defaultAppName(for: url)
        let base = PeekMetadata.baseFields(url)
        model.fields = [base.size, base.modified, base.type].compactMap { $0 }
        if !settings.value.pinned, resizing != .none { fit(to: idealContentSize(url), center: resizing == .center) }
        else if resizing == .center, let frame = settings.value.pinnedFrame, NSScreen.screens.contains(where: { $0.frame.intersects(frame) }) {
            window?.setFrame(frame, display: true)
        } else if resizing == .center { window?.center() }

        let options = settings.value.previewOptions(base: FinderAddonsSettings.load())
        let imageSize = renderSize()
        loadTask = Task { [weak self] in
            let (content, extra) = await PeekLoader.load(url, options: options, imageSize: imageSize)
            guard !Task.isCancelled, let self, self.model.items.current == url else { return }
            self.model.content = content
            // Size, then the type-specific fields (dimensions, layers…), then modified and type.
            self.model.fields = [base.size].compactMap { $0 } + extra + [base.modified, base.type].compactMap { $0 }
        }
    }

    /// Bitmap size for PreviewKit renders: the screen at Retina scale, capped.
    private func renderSize() -> CGSize {
        let screen = window?.screen ?? NSScreen.underMouse ?? NSScreen.main
        let vf = screen?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let scale = screen?.backingScaleFactor ?? 2
        return CGSize(width: min(3200, vf.width * 0.85 * scale), height: min(2400, (vf.height * 0.85 - 90) * scale))
    }

    /// The content size a file would like (before chrome), from its kind and, for images, its pixels.
    private func idealContentSize(_ url: URL) -> CGSize {
        switch PreviewKind.of(url) {
        case .folder: return CGSize(width: 560, height: 380)
        case .markdown: return CGSize(width: 940, height: 760)
        case .sqlite, .delimited: return CGSize(width: 1080, height: 720)
        case .json, .xml, .code: return CGSize(width: 980, height: 720)
        case .pdf: return CGSize(width: 780, height: 940)
        case .svg, .qoi:
            if let s = ImageUtil.pixelSize(of: url) ?? (try? Data(contentsOf: url)).flatMap(SVGRenderer.intrinsicSize) {
                return CGSize(width: max(s.width + 48, 520), height: max(s.height + 48, 380))
            }
            return CGSize(width: 900, height: 680)
        case .gcode, .bgcode, .stl: return CGSize(width: 960, height: 720)
        case .other:
            let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            if let type, type.conforms(to: .image), let px = ImageUtil.pixelSize(of: url) {
                let scale = window?.screen?.backingScaleFactor ?? 2
                let points = px.width > 1200 || px.height > 900 ? CGSize(width: px.width / scale, height: px.height / scale) : px
                return CGSize(width: max(points.width, 420), height: max(points.height, 280))
            }
            if let type, type.conforms(to: .movie) { return CGSize(width: 960, height: 540) }
            if let type, type.conforms(to: .audio) { return CGSize(width: 560, height: 320) }
            return CGSize(width: 900, height: 680)
        }
    }

    /// Resizes the window so its content fits `content`, within 85 % of the screen.
    private func fit(to content: CGSize, center: Bool) {
        guard let w = window else { return }
        let screen = (center ? NSScreen.underMouse : w.screen) ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }
        // Title bar and toolbar come from frameRect(forContentRect:); the footer is part of the content.
        let footer = settings.value.showDetails ? PeekView.footerHeight + 1 : 0
        let chrome = w.frameRect(forContentRect: CGRect(x: 0, y: 0, width: 100, height: 100)).height - 100 + footer
        let maxW = vf.width * 0.85, maxH = vf.height * 0.85 - chrome
        let s = min(1, min(maxW / content.width, maxH / content.height))
        let size = CGSize(width: max(w.minSize.width, (content.width * s).rounded()),
                          height: max(w.minSize.height, (content.height * s).rounded() + chrome))
        let mid = center || !w.isVisible ? CGPoint(x: vf.midX, y: vf.midY) : CGPoint(x: w.frame.midX, y: w.frame.midY)
        var frame = CGRect(x: mid.x - size.width / 2, y: mid.y - size.height / 2, width: size.width, height: size.height)
        frame.origin.x = min(max(frame.minX, vf.minX), vf.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, vf.minY), vf.maxY - frame.height)
        w.setFrame(frame, display: true, animate: w.isVisible)
    }

    static func defaultAppName(for url: URL) -> String? {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return nil }
        let name = FileManager.default.displayName(atPath: app.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    // MARK: Actions

    func step(_ delta: Int) {
        guard model.items.count > 1 else { return }
        if delta > 0 { model.items.next() } else { model.items.previous() }
        load(resizing: .keepCenter)
        window?.makeFirstResponder(nil)
    }

    func openCurrent() {
        guard let url = model.items.current else { return }
        if !NSWorkspace.shared.open(url) { NSSound.beep() }
    }

    func copyCurrent() {
        guard let url = model.items.current else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([url as NSURL])
        HUD.show("Copied “\(url.lastPathComponent)”", symbol: "doc.on.doc")
    }

    func togglePin() {
        settings.value.pinned.toggle()
        model.pinned = settings.value.pinned
        if settings.value.pinned, let frame = window?.frame { settings.value.pinnedFrame = frame }
        else if let url = model.items.current { fit(to: idealContentSize(url), center: false) }
    }

    /// Moves the current file to the Trash (asking first unless turned off). Folders are never deleted.
    func deleteCurrent() {
        guard let url = model.items.current, let w = window else { return }
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            NSSound.beep()
            HUD.show("Peek doesn't delete folders", symbol: "folder")
            return
        }
        guard settings.value.confirmDelete else { trash(url); return }
        let alert = NSAlert()
        alert.messageText = "Move “\(url.lastPathComponent)” to the Trash?"
        alert.informativeText = "You can put it back from the Trash."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        showingAlert = true
        alert.beginSheetModal(for: w) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.showingAlert = false
                guard response == .alertFirstButtonReturn else { return }
                if alert.suppressionButton?.state == .on { self.settings.value.confirmDelete = false }
                self.trash(url)
            }
        }
    }

    private func trash(_ url: URL) {
        NSWorkspace.shared.recycle([url]) { [weak self] _, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let error {
                    self.log.error("Trash failed: \(error.localizedDescription, privacy: .public)")
                    HUD.show("Couldn't move to the Trash", symbol: "exclamationmark.triangle")
                    return
                }
                guard self.model.items.current == url else { return }
                self.model.items.removeCurrent()
                self.load(resizing: .keepCenter)
            }
        }
    }

    // MARK: Keyboard

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let w = self.window, event.window === w, w.attachedSheet == nil else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    /// Whether the user clicked into a preview that uses the keyboard itself (text, PDF, web page).
    private var contentHasFocus: Bool {
        var view = window?.firstResponder as? NSView
        while let v = view {
            if v is WKWebView || v is QLPreviewView { return true }
            view = v.superview
        }
        return false
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let interactive = contentHasFocus
        switch Int(event.keyCode) {
        case kVK_Escape:
            close(); return true
        case kVK_Space where mods.isEmpty:
            close(); return true
        case kVK_ANSI_W where mods == .command:
            close(); return true
        case kVK_LeftArrow, kVK_UpArrow:
            if mods == .option || (mods.isEmpty && !interactive) { step(-1); return true }
        case kVK_RightArrow, kVK_DownArrow:
            if mods == .option || (mods.isEmpty && !interactive) { step(1); return true }
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if mods == .command || (mods.isEmpty && !interactive) { openCurrent(); return true }
        case kVK_ANSI_O where mods == .command:
            openCurrent(); return true
        case kVK_ANSI_C where mods == .command && !interactive:
            copyCurrent(); return true
        case kVK_Delete, kVK_ForwardDelete:
            if mods == .command || (mods.isEmpty && !interactive) { deleteCurrent(); return true }
        default:
            break
        }
        return false
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        teardown()
    }

    func windowDidResignKey(_ notification: Notification) {
        guard settings.value.closeOnFocusLoss, !showingAlert, window?.attachedSheet == nil, window?.isVisible == true else { return }
        close()
    }

    func windowDidEndLiveResize(_ notification: Notification) { rememberPinnedFrame() }
    func windowDidMove(_ notification: Notification) { rememberPinnedFrame() }

    private func rememberPinnedFrame() {
        guard settings.value.pinned, let frame = window?.frame, window?.isVisible == true else { return }
        settings.value.pinnedFrame = frame
    }
}

