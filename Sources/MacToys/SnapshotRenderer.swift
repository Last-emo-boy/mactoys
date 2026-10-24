import AppKit
import MacToysCore
import MacToysModules
import SwiftUI

/// `MacToys --snapshot <dir> [--only <page>]` renders Settings pages — and each module's
/// `previewScenes` as `<module>.<scene>.png` — offscreen to PNG. Used to check layouts
/// without Screen Recording permission.
@MainActor
enum SnapshotRenderer {
    static func renderAll(to dir: URL, only: String?) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var pages: [(String, SidebarItem)] = [("home", .home), ("general", .general)]
        pages += ModuleRegistry.shared.modules.map { ($0.info.id, .module($0.info.id)) }
        for (name, item) in pages where only == nil || only == name {
            SettingsNavigation.shared.selection = item
            render(AnyView(SettingsRootView()), size: CGSize(width: 1180, height: 780),
                   to: dir.appendingPathComponent("\(name).png"))
        }
        if only == nil || only == "welcome" {
            render(AnyView(WelcomeView {}), size: CGSize(width: 860, height: 600), to: dir.appendingPathComponent("welcome.png"))
        }
        if only == nil || only == "quickaccess" {
            render(AnyView(QuickAccessView().background(.regularMaterial)), size: CGSize(width: 380, height: 560),
                   to: dir.appendingPathComponent("quickaccess.png"))
        }
        for m in ModuleRegistry.shared.modules where only == nil || only == m.info.id {
            for scene in m.previewScenes {
                let content = scene.view()
                let view = scene.wallpaper ? AnyView(ZStack { Wallpaper(); content }) : content
                render(view, size: scene.size, to: dir.appendingPathComponent("\(m.info.id).\(scene.name).png"))
            }
        }
    }

    static func render(_ view: AnyView, size: CGSize, to url: URL) {
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -20000, y: -20000), size: size),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.toolbar = NSToolbar(identifier: "snap")
        window.toolbarStyle = .unified
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        window.contentView = host
        window.orderFrontRegardless()
        for _ in 0..<6 { RunLoop.main.run(until: Date().addingTimeInterval(0.15)) }
        host.layoutSubtreeIfNeeded()
        let bounds = host.bounds
        guard let rep = host.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        host.cacheDisplay(in: bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
        print("wrote \(url.path)")
    }
}

/// The design boards' wallpaper, behind glass overlays in snapshots.
struct Wallpaper: View {
    var body: some View {
        LinearGradient(colors: [Color(red: 0.09, green: 0.13, blue: 0.36), Color(red: 0.24, green: 0.17, blue: 0.56),
                                Color(red: 0.6, green: 0.25, blue: 0.53), Color(red: 0.88, green: 0.54, blue: 0.42)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
