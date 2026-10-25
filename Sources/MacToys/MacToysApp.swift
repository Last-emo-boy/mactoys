import AppKit
import MacToysCore
import MacToysModules
import SwiftUI

@main
struct MacToysApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var registry = ModuleRegistry.shared

    var body: some Scene {
        MenuBarExtra(isInserted: Binding(get: { registry.general.value.showMenuBarIcon },
                                         set: { registry.general.value.showMenuBarIcon = $0 })) {
            QuickAccessView()
        } label: {
            Image(systemName: "puzzlepiece.extension.fill")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let services = ServiceProvider()
    private var settingsObserver: NSObjectProtocol?

    func applicationWillFinishLaunching(_ notification: Notification) {
        installURLHandler()
    }

    /// SwiftUI's app lifecycle installs its own kAEGetURL handler during launch (it only routes
    /// to scenes, and MacToys has no window scene), so ours is installed before and after it.
    private func installURLHandler() {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            NSApp.setActivationPolicy(.accessory)
            ModuleRegistry.shared.register(AllModules.make())
            SnapshotRenderer.renderAll(to: URL(fileURLWithPath: args[i + 1]),
                                       only: args.firstIndex(of: "--only").map { args[$0 + 1] })
            exit(0)
        }

        if let i = args.firstIndex(of: "--export-assets"), i + 1 < args.count {
            NSApp.setActivationPolicy(.accessory)
            ModuleRegistry.shared.register(AllModules.make())
            let dir = URL(fileURLWithPath: args[i + 1])
            Task { @MainActor in
                await AssetExporter.run(to: dir)
                exit(0)
            }
            return
        }

        NSApp.setActivationPolicy(.accessory)
        installURLHandler()
        DispatchQueue.main.async { self.installURLHandler() }
        let registry = ModuleRegistry.shared
        registry.register(AllModules.make())
        registry.showSettings = { SettingsWindow.shared.show(page: $0) }
        AppearanceController.apply(registry.general.value.appearance)
        registry.general.onChange { AppearanceController.apply($0.appearance) }

        PermissionCenter.shared.startMonitoring()
        PermissionCenter.shared.onChange { granted in
            if granted.contains(.accessibility) { InputTap.shared.restart() }
        }
        registry.startEnabled()

        NSApp.servicesProvider = services
        NSUpdateDynamicServices()

        settingsObserver = DistributedNotificationCenter.default().addObserver(
            forName: SettingsStore.externalChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ModuleRegistry.shared.reloadFromDisk() }
        }

        if !registry.general.value.hasCompletedWelcome || args.contains("--welcome") {
            WelcomeWindow.shared.show()
        } else if args.contains("--settings") {
            SettingsWindow.shared.show(page: nil)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindow.shared.show(page: nil)
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        ModuleRegistry.shared.stopAll()
        ModuleRegistry.shared.general.flush()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { open(url) }
    }

    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: s) else { return }
        open(url)
    }

    private func open(_ url: URL) {
        Log.for("app").info("open \(url.absoluteString, privacy: .public)")
        if url.isFileURL {
            // Files opened with MacToys (e.g. .plist via Plist Preview).
            let cmd = AppCommand(module: url.pathExtension == "plist" ? "plistpreview" : "peek", action: "open", files: [url])
            ModuleRegistry.shared.dispatch(cmd)
            return
        }
        guard let cmd = AppCommand(url: url) else { return }
        if cmd.module == "app" {
            switch cmd.action {
            case "settings": SettingsWindow.shared.show(page: cmd.parameters["page"])
            case "welcome": WelcomeWindow.shared.show()
            case "reload": ModuleRegistry.shared.reloadFromDisk()
            case "debug-screenshot", "debug-state":
                // Only when launched with --debug: lets a developer see the screen and app state remotely.
                guard CommandLine.arguments.contains("--debug") else { return }
                Task { await DebugDump.run(screenshot: cmd.action == "debug-screenshot") }
            default: break
            }
            return
        }
        ModuleRegistry.shared.dispatch(cmd)
    }
}

/// Finder › Services entries declared in Info.plist (`NSUserData` = "module/action").
@MainActor
final class ServiceProvider: NSObject {
    @objc func runService(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = (pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let parts = (userData ?? "").split(separator: "/").map(String.init)
        guard parts.count == 2 else { return }
        ModuleRegistry.shared.dispatch(AppCommand(module: parts[0], action: parts[1], files: urls))
    }
}

enum AppearanceController {
    @MainActor static func apply(_ a: GeneralSettings.Appearance) {
        switch a {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
