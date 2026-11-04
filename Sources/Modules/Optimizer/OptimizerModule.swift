import AppKit
import MacToysCore
import SwiftUI
import UniformTypeIdentifiers

/// Optimizer: shrinks images, videos and PDFs as they are copied, dropped or saved, with Apple's
/// frameworks only.
///
/// - Clipboard: copied images are optimized automatically (off by default) or with ⌃⌥O.
/// - Drop zone: drag files toward the chosen screen corner and drop them on the zone (Optimize,
///   Downscale 50 %, Convert); ⌥ while dropping trades quality for size.
/// - Watch folders: new files in chosen folders are optimized as they appear.
/// - Result cards: one floating card per file (a batch card for four or more) with the saving and
///   Restore, Downscale More, Copy, Show in Finder, Open, Convert To, and for videos speed and audio.
///
/// URL actions (`mactoys://optimizer/<action>?file=…`, also used by Finder Services):
/// `optimize` (`aggressive=1`, `speed=2`, `audio=0`; the Finder selection when no files are given),
/// `downscale` (`factor=0.5`), `convert` (`to=jpeg|png|heic|avif|webp`), `convert-jpeg`, `convert-png`,
/// `convert-heic`, `convert-avif`, `convert-webp`, `clipboard`, `dropzone`, `choose`, `backups`,
/// `settings` (also `open`, `show`).
@MainActor
public final class OptimizerModule: ToyModule {
    public let info = ModuleInfo(
        id: "optimizer", name: "Optimizer",
        summary: "Shrink images, videos and PDFs as you copy, drop or save them.",
        symbol: "arrow.down.right.and.arrow.up.left", tint: .green, category: .fileManagement,
        permissions: [], enabledByDefault: true,
        keywords: ["compress", "optimize", "shrink", "smaller", "image", "png", "jpeg", "heic", "video", "hevc", "gif",
                   "pdf", "clipboard", "screenshot", "metadata", "downscale", "convert"])

    let settings = Persisted("optimizer", default: OptimizerSettings())
    let center = JobCenter()
    private lazy var results = ResultsPanelController(center: center)
    private let dropZone = DropZoneController()
    private let clipboard = ClipboardWatcher()
    private let drags = DragWatcher()
    private let folders = FolderWatcher()
    private var running = false
    private var pruneTimer: Timer?
    private let log = Log.for("optimizer")
    private static let clipboardHotkey = "optimizer.clipboard"

    public init() {
        center.settings = { [weak self] in self?.settings.value ?? OptimizerSettings() }
        center.writeClipboard = { [weak self] data, type in self?.clipboard.write(data, type: type) }
        center.onFinish = { [weak self] job in self?.announce(job) }
        clipboard.onImage = { [weak self] data, type in self?.center.submitClipboard(data, type: type) }
        dropZone.onDrop = { [weak self] urls, target, aggressive in self?.dropped(urls, on: target, aggressive: aggressive) }
        drags.onCorner = { [weak self] inside, screen in
            guard let self else { return }
            if inside {
                self.dropZone.model.convertFormat = self.settings.value.dropZoneConvertFormat
                self.dropZone.show(on: screen, corner: self.settings.value.dropZoneCorner, pinned: false)
            } else {
                self.dropZone.dragLeftCorner()
            }
        }
        drags.onDragEnd = { [weak self] in
            guard let self, !self.dropZone.model.pinned else { return }
            // The drop (if any) is delivered right after the mouse goes up; hide just after it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, !self.dropZone.model.pinned else { return }
                self.dropZone.hide()
            }
        }
        folders.onNewFile = { [weak self] url, folder in self?.watched(url, in: folder) }
        settings.onChange { [weak self] _ in self?.apply() }
    }

    public func start() {
        guard !running else { return }
        running = true
        results.start()
        apply()
        pruneBackups()
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            MainActor.assumeIsolated { [weak self] in self?.pruneBackups() }
        }
    }

    public func stop() {
        guard running else { return }
        running = false
        HotkeyCenter.shared.unregister(Self.clipboardHotkey)
        clipboard.stop()
        drags.stop()
        folders.stop()
        dropZone.hide()
        center.stop()
        results.stop()
        pruneTimer?.invalidate()
        pruneTimer = nil
    }

    /// Brings the running services in line with the settings.
    private func apply() {
        guard running else { return }
        let s = settings.value
        HotkeyCenter.shared.register(Self.clipboardHotkey, s.clipboardShortcut) { [weak self] in self?.optimizeClipboard() }
        if s.optimizeClipboard { clipboard.start() } else { clipboard.stop() }
        drags.corner = s.dropZoneCorner
        drags.acceptedKinds = { url in MediaKind.of(url, gifAsVideo: s.video.convertGIFs) != nil }
        if s.dropZoneEnabled { drags.start() } else {
            drags.stop()
            if !dropZone.model.pinned { dropZone.hide() }
        }
        dropZone.model.convertFormat = s.dropZoneConvertFormat
        folders.update(s.watchFolders)
        results.corner = s.resultsCorner
        results.enabled = s.showResults
    }

    private func pruneBackups() {
        guard let interval = settings.value.backupRetention.interval else { return }
        let store = center.backups
        let cutoff = Date().addingTimeInterval(-interval)
        Task.detached(priority: .utility) { store.prune(before: cutoff) }
    }

    // MARK: Entry points

    /// Optimizes the clipboard: a copied image, or files copied in Finder.
    func optimizeClipboard() {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            if center.submit(urls) == 0 { HUD.show("Nothing to optimize in the copied files", symbol: "doc.badge.ellipsis") }
            return
        }
        guard let (data, type) = ClipboardWatcher.image(on: pb) else {
            HUD.show("Copy an image or files first", symbol: "doc.on.clipboard")
            return
        }
        center.submitClipboard(data, type: type)
    }

    /// Lets the user pick files to optimize.
    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .movie, .pdf]
        panel.prompt = String(localized: "Optimize", comment: "Optimizer: open panel button")
        panel.message = String(localized: "Choose images, videos or PDFs to make smaller.", comment: "Optimizer: open panel message")
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        submit(panel.urls)
    }

    func revealBackups() {
        let root = center.backups.root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([root])
    }

    func showDropZone() {
        guard let screen = NSScreen.underMouse ?? NSScreen.main else { return }
        dropZone.model.convertFormat = settings.value.dropZoneConvertFormat
        dropZone.show(on: screen, corner: settings.value.dropZoneCorner, pinned: true)
    }

    private func submit(_ urls: [URL], operation: JobOperation = .optimize, options: JobOptions = JobOptions()) {
        guard !urls.isEmpty else { return }
        if center.submit(urls, operation: operation, options: options) == 0 {
            HUD.show("No images, videos or PDFs to optimize", symbol: "doc.badge.ellipsis")
        }
    }

    private func dropped(_ urls: [URL], on target: DropTarget, aggressive: Bool) {
        let options = JobOptions(aggressive: aggressive)
        switch target {
        case .optimize: submit(urls, options: options)
        case .downscale: submit(urls, operation: .downscale(0.5), options: options)
        case .convert: submit(urls, operation: .convert(settings.value.dropZoneConvertFormat), options: options)
        }
    }

    private func watched(_ url: URL, in folder: WatchFolder) {
        let s = settings.value
        guard let kind = MediaKind.of(url, gifAsVideo: s.video.convertGIFs), folder.kinds.contains(kind) else { return }
        switch folder.action {
        case .optimize: center.submit([url])
        case .downscale: center.submit([url], operation: .downscale(0.5))
        case .convert(let format): center.submit([url], operation: kind == .image ? .convert(format) : .optimize)
        }
    }

    /// With result cards off, a short HUD reports each finished file.
    private func announce(_ job: OptimizationJob) {
        guard !settings.value.showResults else { return }
        switch job.state {
        case .done:
            if let saving = job.saving, let size = job.resultSize {
                HUD.show(String(localized: "\(job.name): \(FileSize.format(size)), \(SavingBadge.text(saving))",
                                comment: "Optimizer HUD: file name, new size, saving such as −74 %"),
                         symbol: "arrow.down.right.and.arrow.up.left", duration: 2)
            }
        case .unchanged:
            HUD.show(String(localized: "\(job.name) is already optimized", comment: "Optimizer HUD"), symbol: "checkmark.seal")
        case .failed(let message):
            HUD.show(String(localized: "\(job.name): \(message)", comment: "Optimizer HUD: file name, then the error"),
                     symbol: "exclamationmark.triangle", duration: 3)
        default:
            break
        }
    }

    // MARK: ToyModule

    public var quickActions: [QuickAction] {
        [
            QuickAction(id: "optimizer.clipboard", title: "Optimize Clipboard", symbol: "doc.on.clipboard", tint: info.tint,
                        shortcut: settings.value.clipboardShortcut) { [weak self] in self?.optimizeClipboard() },
            QuickAction(id: "optimizer.choose", title: "Optimize Files…", symbol: info.symbol, tint: info.tint) { [weak self] in
                self?.chooseFiles()
            },
            QuickAction(id: "optimizer.dropzone", title: "Show Drop Zone", symbol: "square.and.arrow.down", tint: info.tint) { [weak self] in
                self?.showDropZone()
            },
            QuickAction(id: "optimizer.auto", title: "Optimize Copied Images", symbol: "photo.on.rectangle", tint: info.tint,
                        isOn: { [weak self] in self?.settings.value.optimizeClipboard ?? false },
                        detail: { [weak self] in
                            (self?.settings.value.optimizeClipboard ?? false)
                                ? String(localized: "On · originals can be restored", comment: "Optimizer quick switch detail")
                                : String(localized: "Off", comment: "Optimizer quick switch detail: not optimizing copied images")
                        }) { [weak self] in
                self?.settings.value.optimizeClipboard.toggle()
            },
        ]
    }

    public var shortcutBindings: [ShortcutBinding] {
        settings.value.clipboardShortcut.map { [ShortcutBinding("Optimize the clipboard", $0)] } ?? []
    }

    public func handle(_ command: AppCommand) -> Bool {
        let action = command.action
        if ["settings", "open", "show"].contains(action) {
            ModuleRegistry.shared.showSettings?(info.id)
            return true
        }
        guard isEnabled else {
            ModuleRegistry.shared.showSettings?(info.id)
            return true
        }
        let p = command.parameters
        var options = JobOptions()
        options.aggressive = ["1", "true", "yes"].contains(p["aggressive"]?.lowercased() ?? "")
        options.speed = p["speed"].flatMap(Double.init)
        if let audio = p["audio"]?.lowercased() { options.removeAudio = ["0", "false", "no", "off"].contains(audio) }
        let files = command.files

        switch action {
        case "optimize":
            if files.isEmpty {
                guard let selection = FinderSelection.selectionRequestingPermission() else { return true }
                submit(selection, options: options)
            } else {
                submit(files, options: options)
            }
        case "downscale":
            let factor = p["factor"].flatMap(Double.init).map { min(0.95, max(0.05, $0)) } ?? 0.5
            submit(files, operation: .downscale(factor), options: options)
        case "convert":
            guard let format = p["to"].flatMap(Self.format(named:)) else {
                HUD.show("Choose a format: jpeg, png, heic, avif or webp", symbol: "exclamationmark.triangle")
                return true
            }
            convert(files, to: format)
        case let a where a.hasPrefix("convert-"):
            guard let format = Self.format(named: String(a.dropFirst("convert-".count))) else { return false }
            convert(files, to: format)
        case "clipboard":
            optimizeClipboard()
        case "dropzone":
            showDropZone()
        case "choose":
            chooseFiles()
        case "backups":
            revealBackups()
        default:
            return false
        }
        return true
    }

    private func convert(_ files: [URL], to format: ImageFormat) {
        guard format.isWritable else {
            HUD.show(String(localized: "This Mac can’t write \(format.title) images", comment: "Optimizer error; the value is an image format such as WebP"),
                     symbol: "exclamationmark.triangle")
            return
        }
        let images = files.filter { MediaKind.of($0, gifAsVideo: false) == .image }
        guard !images.isEmpty else {
            HUD.show("Only images can be converted", symbol: "photo.badge.exclamationmark")
            return
        }
        submit(images, operation: .convert(format))
    }

    static func format(named name: String) -> ImageFormat? {
        switch name.lowercased() {
        case "jpeg", "jpg": .jpeg
        case "png": .png
        case "heic", "heif": .heic
        case "avif": .avif
        case "webp": .webp
        default: nil
        }
    }

    public func settingsView() -> AnyView {
        AnyView(OptimizerSettingsView(module: self))
    }

    public var previewScenes: [PreviewScene] { OptimizerScenes.all }
}
