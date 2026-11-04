import AppKit
import MacToysCore
import Observation
import SwiftUI

/// Focus Dimmer: dims every window behind the one you're working in.
///
/// A normal-level overlay per display sits directly below the active window, so that window, its
/// sheets, menus, the Dock and all system UI stay above it and nothing needs Accessibility or
/// Screen Recording. See `DimPlanner` for the rules and `DimController` for the runtime.
///
/// URL actions: `toggle`, `on`, `off`, `intensity?value=0…100` (for the current appearance), `settings`.
@MainActor
public final class FocusDimmerModule: ToyModule {
    public let info = ModuleInfo(
        id: "focusdimmer", name: "Focus Dimmer",
        summary: "Dim every window behind the one you're working in.",
        symbol: "moon.haze.fill", tint: .indigo, category: .windowing,
        permissions: [], enabledByDefault: false,
        keywords: ["dim", "focus", "background", "distraction", "fade", "shade", "highlight", "window", "concentrate"])

    let settings = Persisted("focusdimmer", default: FocusDimmerSettings())
    /// Live state for the settings page.
    let status = DimStatus()
    private let controller = DimController()
    private var running = false
    private static let hotkeyID = "focusdimmer.toggle"

    public init() {
        settings.onChange { [weak self] _ in self?.settingsChanged() }
        controller.onShownChange = { [weak self] shown in self?.status.dimmingNow = shown }
    }

    // MARK: ToyModule

    public func start() {
        guard !running else { return }
        running = true
        registerHotkey()
        applyState()
    }

    public func stop() {
        guard running else { return }
        running = false
        HotkeyCenter.shared.unregister(Self.hotkeyID)
        controller.stop()
    }

    public func settingsView() -> AnyView { AnyView(FocusDimmerSettingsView(module: self)) }

    public var quickActions: [QuickAction] {
        [QuickAction(id: "focusdimmer.toggle", title: "Focus Dimmer", symbol: info.symbol, tint: info.tint,
                     shortcut: settings.value.toggle,
                     isOn: { [weak self] in self?.settings.value.dimming ?? false },
                     detail: { [weak self] in self?.detail ?? "" },
                     perform: { [weak self] in self?.toggle(feedback: false) })]
    }

    public var shortcutBindings: [ShortcutBinding] {
        [ShortcutBinding("Turn background dimming on or off", settings.value.toggle)]
    }

    public func handle(_ command: AppCommand) -> Bool {
        switch command.action {
        case "toggle": toggle(feedback: true)
        case "on": setDimming(true, feedback: true)
        case "off": setDimming(false, feedback: true)
        case "intensity":
            guard let raw = command.parameters["value"], let value = Double(raw) else { return false }
            let clamped = min(max(value, 0), 100)
            if SystemAppearance.isDark { settings.value.darkIntensity = clamped } else { settings.value.lightIntensity = clamped }
        case "open", "settings", "show": ModuleRegistry.shared.showSettings?(info.id)
        default: return false
        }
        return true
    }

    public var previewScenes: [PreviewScene] {
        [
            PreviewScene("desktop-light", size: CGSize(width: 1280, height: 800), wallpaper: false) {
                AnyView(DimDesktopPreview(dark: false, intensity: 40))
            },
            PreviewScene("desktop-dark", size: CGSize(width: 1280, height: 800), wallpaper: false) {
                AnyView(DimDesktopPreview(dark: true, intensity: 55))
            },
            PreviewScene("app-mode", size: CGSize(width: 1280, height: 800), wallpaper: false) {
                AnyView(DimDesktopPreview(dark: false, intensity: 45, appMode: true))
            },
            PreviewScene("hero", size: CGSize(width: 760, height: 180), wallpaper: false) { [settings] in
                // Shown as it looks while dimming around the active window.
                let status = DimStatus()
                status.dimmingNow = true
                return AnyView(FocusDimmerHero(settings: settings, status: status, toggle: {}).padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .windowBackgroundColor))
                    .ignoresSafeArea())
            },
        ]
    }

    // MARK: Actions

    func toggle(feedback: Bool) {
        setDimming(!settings.value.dimming, feedback: feedback)
    }

    private func setDimming(_ on: Bool, feedback: Bool) {
        settings.value.dimming = on
        guard feedback else { return }
        if !running {
            HUD.show("Focus Dimmer is off in MacToys Settings", symbol: "moon.haze")
        } else if on {
            HUD.show("Background dimming on", symbol: "moon.haze.fill")
        } else {
            HUD.show("Background dimming off", symbol: "moon.haze")
        }
    }

    private var detail: String {
        let s = settings.value
        guard s.dimming else {
            return String(localized: "Off", comment: "Focus Dimmer quick action: dimming is off")
        }
        let percent = (s.intensity(dark: SystemAppearance.isDark) / 100).formatted(.percent.precision(.fractionLength(0)))
        return String(localized: "Intensity \(percent)", comment: "Focus Dimmer quick action detail; %@ is a percentage")
    }

    private func settingsChanged() {
        guard running else { return }
        registerHotkey()
        applyState()
    }

    private func applyState() {
        let s = settings.value
        if s.dimming {
            if controller.isRunning { controller.update(s) } else { controller.start(s) }
        } else {
            controller.stop()
        }
    }

    private func registerHotkey() {
        HotkeyCenter.shared.register(Self.hotkeyID, settings.value.toggle) { [weak self] in self?.toggle(feedback: true) }
    }
}

/// Whether the overlays are showing right now, for the settings hero.
@MainActor
@Observable
final class DimStatus {
    var dimmingNow = false
}
