import AppKit
import SwiftUI

/// A regular titled window that hosts a SwiftUI tool (PowerRename, Image Resizer, File Locksmith, …).
/// The SwiftUI view's `.toolbar` items appear in the window's unified toolbar next to the title,
/// as in `design/exports/07-tool-windows.png`.
@MainActor
public final class HostedToolWindow: NSObject, NSWindowDelegate {
    public let window: NSWindow
    /// Called once when the window closes.
    public var onClose: (() -> Void)?

    public init<Content: View>(title: String, size: CGSize, minSize: CGSize? = nil, resizable: Bool = true,
                               autosaveName: String? = nil, content: Content) {
        let controller = NSHostingController(rootView: content)
        controller.sceneBridgingOptions = [.toolbars]
        let w = NSWindow(contentViewController: controller)
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        if resizable { style.insert(.resizable) }
        w.styleMask = style
        w.title = title
        w.toolbarStyle = .unified
        w.isReleasedWhenClosed = false
        w.setContentSize(size)
        if let minSize { w.contentMinSize = minSize }
        window = w
        super.init()
        w.delegate = self
        if let autosaveName, w.setFrameUsingName(autosaveName) {
            w.setFrameAutosaveName(autosaveName)
        } else {
            w.center()
            if let autosaveName { w.setFrameAutosaveName(autosaveName) }
        }
    }

    public var title: String {
        get { window.title }
        set { window.title = newValue }
    }

    /// Brings MacToys forward and shows the window.
    public func show() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    public func close() { window.close() }

    public func windowWillClose(_ notification: Notification) {
        let callback = onClose
        onClose = nil
        callback?()
    }
}

/// Draws a title bar (traffic lights, icon, title, toolbar buttons) around a tool view, for
/// `previewScenes`: offscreen snapshots only capture content, not the real window toolbar.
public struct HostedToolWindowChrome<Content: View, Actions: View>: View {
    let title: String
    let symbol: String
    let tint: Tint
    let actions: Actions
    let content: Content

    public init(title: String, symbol: String, tint: Tint, @ViewBuilder actions: () -> Actions,
                @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.actions = actions()
        self.content = content()
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18),
                             Color(red: 0.16, green: 0.79, blue: 0.25)], id: \.self) { c in
                        Circle().fill(c).frame(width: 12, height: 12)
                    }
                }
                .padding(.trailing, 10)
                ModuleIcon(symbol: symbol, tint: tint, size: 20)
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 12)
                actions
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            content
        }
    }
}
