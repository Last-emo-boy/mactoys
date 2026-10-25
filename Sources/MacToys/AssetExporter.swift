import AppKit
import MacToysCore
import MacToysModules
import ScreenCaptureKit
import SwiftUI

/// `MacToys --export-assets <dir> [-AppleLanguages "(xx)"]` writes the app's own UI as images for
/// the product film (`broll/`), in the language the process runs in:
///
///     <dir>/<lang>/icons/<module>.png      module icon tiles, 512 px
///     <dir>/<lang>/icons/app.png           the app mark
///     <dir>/<lang>/pages/<page>.png        Settings pages (home, general, every module)
///     <dir>/<lang>/scenes/<module>.<scene>.png   every module's preview scene, 2x
///     <dir>/<lang>/ui/{welcome,quickaccess}.png
///     <dir>/<lang>/manifest.json           localized module names, summaries, categories, sizes
///
/// Settings pages are captured from a real on-screen window through ScreenCaptureKit when
/// MacToys has Screen Recording permission (the translucent sidebar only renders that way);
/// otherwise they fall back to the offscreen layer render.
@MainActor
enum AssetExporter {
    static func run(to root: URL) async {
        let lang = AppLanguage.current
        let dir = root.appendingPathComponent(lang, isDirectory: true)
        for sub in ["icons", "pages", "scenes", "ui"] {
            try? FileManager.default.createDirectory(at: dir.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        let registry = ModuleRegistry.shared
        var modules: [[String: Any]] = []

        for m in registry.modules {
            let info = m.info
            SnapshotRenderer.render(AnyView(ModuleIcon(info, size: 512).padding(0)), size: CGSize(width: 512, height: 512),
                                    to: dir.appendingPathComponent("icons/\(info.id).png"), transparent: true, scale: 1)
            modules.append([
                "id": info.id, "name": info.name, "summary": info.summary, "symbol": info.symbol,
                "tint": info.tint.rawValue, "category": info.category.rawValue, "categoryTitle": info.category.title,
                "scenes": m.previewScenes.map { ["name": $0.name, "width": $0.size.width, "height": $0.size.height] },
                "shortcuts": m.shortcutBindings.map { ["title": $0.title, "keys": $0.keys] },
            ])
            for scene in m.previewScenes {
                let content = scene.view()
                let view = scene.wallpaper ? AnyView(ZStack { Wallpaper(); content }) : content
                SnapshotRenderer.render(view, size: scene.size,
                                        to: dir.appendingPathComponent("scenes/\(info.id).\(scene.name).png"))
            }
        }
        SnapshotRenderer.render(AnyView(AppMark(size: 512)), size: CGSize(width: 512, height: 512),
                                to: dir.appendingPathComponent("icons/app.png"), transparent: true, scale: 1)
        SnapshotRenderer.render(AnyView(WelcomeView {}), size: CGSize(width: 860, height: 600),
                                to: dir.appendingPathComponent("ui/welcome.png"))
        SnapshotRenderer.render(AnyView(QuickAccessView().background(.regularMaterial)), size: CGSize(width: 380, height: 560),
                                to: dir.appendingPathComponent("ui/quickaccess.png"))

        let pages = ["home", "general"] + registry.modules.map(\.info.id)
        var captured = 0
        for page in pages {
            let url = dir.appendingPathComponent("pages/\(page).png")
            if await captureLiveWindow(page: page, to: url) {
                captured += 1
            } else {
                SettingsNavigation.shared.selection = SidebarItem(page: page)
                SnapshotRenderer.render(AnyView(SettingsRootView()), size: CGSize(width: 1180, height: 780), to: url)
            }
        }

        let manifest: [String: Any] = [
            "language": lang,
            "languageName": AppLanguage.displayName(lang),
            "languages": AppLanguage.available.filter { $0 != "eo" },
            "pagesCapturedLive": captured,
            "categories": ModuleCategory.allCases.map { ["id": $0.rawValue, "title": $0.title] },
            "modules": modules,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: dir.appendingPathComponent("manifest.json"))
        }
        print("exported \(lang): \(modules.count) modules, \(pages.count) pages (\(captured) live)")
    }

    /// Shows the Settings window on screen at a fixed size and captures just that window.
    private static func captureLiveWindow(page: String, to url: URL) async -> Bool {
        guard CGPreflightScreenCaptureAccess() else { return false }
        SettingsWindow.shared.show(page: page)
        guard let window = NSApp.windows.first(where: { $0.title == "MacToys" && $0.isVisible }) else { return false }
        window.setContentSize(NSSize(width: 1180, height: 780))
        window.center()
        try? await Task.sleep(for: .milliseconds(900))
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let scWindow = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { return false }
            let config = SCStreamConfiguration()
            let scale = window.backingScaleFactor
            config.width = Int(scWindow.frame.width * scale)
            config.height = Int(scWindow.frame.height * scale)
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: scWindow),
                                                                   configuration: config)
            try image.pngData?.write(to: url)
            return true
        } catch {
            Log.for("export").error("live capture \(page, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
