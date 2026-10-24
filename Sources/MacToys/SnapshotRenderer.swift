import AppKit
import MacToysCore
import SwiftUI

/// `MacToys --snapshot <dir> [--only <page>]` renders every Settings page offscreen to PNG.
/// Used to check layouts without Screen Recording permission.
@MainActor
enum SnapshotRenderer {
    static func renderAll(to dir: URL, only: String?) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var pages: [(String, SidebarItem)] = [("home", .home), ("general", .general)]
        pages += ModuleRegistry.shared.modules.map { ($0.info.id, .module($0.info.id)) }
        pages += [("welcome", .home), ("quickaccess", .home)]
        for (name, item) in pages where only == nil || only == name {
            let view: AnyView
            var size = CGSize(width: 1180, height: 780)
            switch name {
            case "welcome": view = AnyView(WelcomeView {}); size = CGSize(width: 860, height: 600)
            case "quickaccess": view = AnyView(QuickAccessView().background(.regularMaterial)); size = CGSize(width: 380, height: 560)
            default:
                SettingsNavigation.shared.selection = item
                view = AnyView(SettingsRootView())
            }
            render(view, size: size, to: dir.appendingPathComponent("\(name).png"))
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
