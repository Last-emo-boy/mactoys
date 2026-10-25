import AppKit
import MacToysCore
import SwiftUI

/// First-run window: what MacToys is, which permissions matter, where to find things.
@MainActor
final class WelcomeWindow: NSObject, NSWindowDelegate {
    static let shared = WelcomeWindow()
    private var window: NSWindow?
    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: WelcomeView { [weak self] in self?.finish() }))
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    private func finish() {
        ModuleRegistry.shared.general.value.hasCompletedWelcome = true
        window?.close()
        SettingsWindow.shared.show(page: "home")
    }

    func windowWillClose(_ notification: Notification) {
        ModuleRegistry.shared.general.value.hasCompletedWelcome = true
    }
}

struct WelcomeView: View {
    let onDone: () -> Void

    private let highlights: [(String, Tint, String, String)] = [
        ("command", .blue, "Command Palette", "⌥ Space finds apps, files, windows and commands."),
        ("rectangle.3.group.fill", .blue, "FancyZones", "Hold ⇧ while dragging a window to snap it into zones."),
        ("eyedropper", .pink, "Color Picker", "⌃ ⌥ C picks any pixel on screen."),
        ("text.viewfinder", .mint, "Text Extractor", "⌃ ⌥ T copies text from anything with OCR."),
        ("list.bullet.rectangle.fill", .indigo, "Shortcut Guide", "Hold ⌘ to see the shortcuts of the frontmost app."),
    ]

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                AppMark(size: 64)
                Text("Welcome to MacToys").font(.system(size: 30, weight: .bold)).kerning(-0.6)
                Text("31 power-user utilities for macOS, modeled on Microsoft PowerToys. Everything runs from the menu bar; each utility can be switched on or off in Settings.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(highlights, id: \.2) { h in
                        HStack(spacing: 12) {
                            ModuleIcon(symbol: h.0, tint: h.1, size: 30)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(h.2).fontWeight(.semibold)
                                Text(h.3).font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Spacer()
            }
            .padding(36)
            .frame(width: 420)

            VStack(alignment: .leading, spacing: 14) {
                Text("Permissions").font(.system(size: 17, weight: .bold))
                Text("Grant what you need now or later from Settings › General. Each one is asked for once.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                VStack(spacing: 0) {
                    ForEach(Permission.allCases) { p in PermissionRow(permission: p) }
                }
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
                Spacer()
                HStack {
                    LanguagePicker { Relaunch.now() }.controlSize(.small)
                    Spacer()
                    Button("Get Started", action: onDone).buttonStyle(.borderedProminent).controlSize(.large)
                }
            }
            .padding(36)
            .frame(width: 440)
            .background(Color(nsColor: .underPageBackgroundColor).opacity(0.5))
        }
        .frame(height: 600)
    }
}
