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

    /// `transparent` keeps the background clear (icons); `scale` overrides the backing scale.
    static func render(_ view: AnyView, size: CGSize, to url: URL, transparent: Bool = false, scale renderScale: CGFloat? = nil,
                       toolbar: Bool = true) {
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -20000, y: -20000), size: size),
                              styleMask: toolbar ? [.titled, .fullSizeContentView] : [.borderless],
                              backing: .buffered, defer: false)
        if toolbar {
            window.toolbar = NSToolbar(identifier: "snap")
            window.toolbarStyle = .unified
        }
        // cacheDisplay draws grouped-Form backgrounds in the light style even in Dark Mode,
        // so render everything light for legible snapshots (`--dark` overrides for overlays).
        let dark = CommandLine.arguments.contains("--dark")
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .toggleStyle(.adaptiveSwitch)
            .environment(\.drawsControlsForSnapshot, true))
        window.contentView = host
        window.orderFrontRegardless()
        for _ in 0..<6 { RunLoop.main.run(until: Date().addingTimeInterval(0.15)) }
        host.layoutSubtreeIfNeeded()
        // Render the layer tree: grouped Forms draw their rows into layers, which
        // cacheDisplay (a drawRect pass) skips.
        let scale = renderScale ?? window.backingScaleFactor
        let bounds = host.bounds
        if let layer = host.layer,
           let ctx = CGContext(data: nil, width: Int(bounds.width * scale), height: Int(bounds.height * scale),
                               bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            ctx.scaleBy(x: scale, y: scale)
            if layer.isGeometryFlipped {
                ctx.translateBy(x: 0, y: bounds.height)
                ctx.scaleBy(x: 1, y: -1)
            }
            if !transparent {
                ctx.setFillColor((window.appearance ?? NSAppearance.currentDrawing()).bestMatch(from: [.darkAqua]) != nil
                                 ? CGColor(gray: 0.12, alpha: 1) : CGColor(gray: 0.96, alpha: 1))
                ctx.fill(CGRect(origin: .zero, size: bounds.size))
            }
            layer.render(in: ctx)
            if let image = ctx.makeImage() {
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
            }
        }
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

/// `CGWindowListCreateImage` is unavailable to Swift on macOS 15+, but still exported.
enum WindowImage {
    private typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    private static let fn: Fn? = {
        guard let h = dlopen(nil, RTLD_NOW), let sym = dlsym(h, "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(sym, to: Fn.self)
    }()

    static func capture(_ id: CGWindowID) -> CGImage? {
        // optionIncludingWindow = 1 << 3; boundsIgnoreFraming = 1 << 0, bestResolution = 1 << 3
        fn?(.null, 1 << 3, id, (1 << 0) | (1 << 3))?.takeRetainedValue()
    }
}

