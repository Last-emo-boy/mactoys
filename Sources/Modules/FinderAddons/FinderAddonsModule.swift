import MacToysCore
import PreviewKit
import SwiftUI

/// Finder Add-ons: settings and status for the Quick Look preview and thumbnail extensions.
///
/// The extensions run on their own (also while MacToys is quit) and read `finderaddons.json` and
/// the on/off state in `general.json`; this module edits those settings, shows whether macOS has
/// picked the extensions up, and resets the Quick Look cache after thumbnail changes.
@MainActor
public final class FinderAddonsModule: ToyModule {
    public let info = ModuleInfo(
        id: "finderaddons", name: "Finder Add-ons",
        summary: "Quick Look previews and thumbnails for Markdown, source code, SVG, G-code, STL, QOI and more.",
        symbol: "doc.viewfinder.fill", tint: .cyan, category: .fileManagement,
        permissions: [], enabledByDefault: true,
        keywords: ["quick look", "preview pane", "thumbnail", "markdown", "svg", "gcode", "stl", "qoi", "monaco", "source code"])

    let settings = Persisted("finderaddons", default: FinderAddonsSettings())
    let status = StatusModel()
    private var running = false
    private var cacheReset: Task<Void, Never>?
    private let log = Log.for("finderaddons")

    private var lastThumbnailInputs: ThumbnailInputs?
    /// Set when the user switched the module off, so switching it back on refreshes Finder's icons.
    private var switchedOff = false

    public init() {
        lastThumbnailInputs = ThumbnailInputs(settings.value)
        settings.onChange { [weak self] new in self?.settingsChanged(new) }
    }

    public func start() {
        guard !running else { return }
        running = true
        status.refresh()
        if switchedOff {
            switchedOff = false
            scheduleCacheReset()
        }
    }

    public func stop() {
        guard running else { return }
        running = false
        cacheReset?.cancel()
        cacheReset = nil
        // Switched off by the user (not app quit): thumbnails made by the add-ons would linger in Finder.
        if !ModuleRegistry.shared.isEnabled(info.id) {
            switchedOff = true
            Task.detached { await QuickLookControl.resetCache() }
        }
    }

    /// Thumbnail-affecting settings changed: Finder keeps old icons until the cache is reset.
    private func settingsChanged(_ new: FinderAddonsSettings) {
        let inputs = ThumbnailInputs(new)
        defer { lastThumbnailInputs = inputs }
        guard running, inputs != lastThumbnailInputs else { return }
        scheduleCacheReset()
    }

    private func scheduleCacheReset() {
        cacheReset?.cancel()
        cacheReset = Task { [log] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            log.info("Thumbnail settings changed; resetting the Quick Look cache")
            await QuickLookControl.resetCache()
        }
    }

    public var quickActions: [QuickAction] {
        [QuickAction(id: "finderaddons.resetcache", title: "Reset Quick Look Cache", symbol: "arrow.clockwise", tint: .cyan) {
            Task { await QuickLookControl.resetCache(); HUD.show("Quick Look cache reset", symbol: "doc.viewfinder") }
        }]
    }

    /// `mactoys://finderaddons/<action>`: `resetcache`, `register`, `extensions` (System Settings), `status`.
    public func handle(_ command: AppCommand) -> Bool {
        switch command.action {
        case "resetcache", "reset":
            Task { await QuickLookControl.resetCache(); HUD.show("Quick Look cache reset", symbol: "doc.viewfinder") }
        case "register":
            Task { [status] in await QuickLookControl.register(); status.refresh() }
        case "extensions":
            QuickLookControl.openExtensionSettings()
        case "status", "open", "settings":
            status.refresh()
            ModuleRegistry.shared.showSettings?(info.id)
        default:
            return false
        }
        return true
    }

    public func settingsView() -> AnyView {
        AnyView(FinderAddonsSettingsView(module: self))
    }

    public var previewScenes: [PreviewScene] { FinderAddonsScenes.all }
}

/// The settings that change what a thumbnail looks like.
private struct ThumbnailInputs: Equatable {
    var switches: [Bool]
    var gcode: String
    var stl: String

    init(_ s: FinderAddonsSettings) {
        switches = [s.thumbnailSVG, s.thumbnailGCode, s.thumbnailSTL, s.thumbnailQOI, s.thumbnailMarkdown, s.thumbnailPDF,
                    s.gcodeThumbnailUsesEmbedded, s.stlTransparentThumbnails]
        gcode = s.gcodeView.rawValue
        stl = s.stlColor + s.stlBackground
    }
}

/// Live extension status for the settings page.
@MainActor
@Observable
final class StatusModel {
    var preview = ExtensionStatus(identifier: QuickLookControl.previewID)
    var thumbnails = ExtensionStatus(identifier: QuickLookControl.thumbnailID)
    var busy = false

    func refresh() {
        Task {
            async let p = ExtensionStatus.query(QuickLookControl.previewID)
            async let t = ExtensionStatus.query(QuickLookControl.thumbnailID)
            let (pv, th) = await (p, t)
            preview = pv
            thumbnails = th
        }
    }

    func run(_ work: @escaping @Sendable () async -> Void) {
        busy = true
        Task {
            await work()
            busy = false
            refresh()
        }
    }
}
