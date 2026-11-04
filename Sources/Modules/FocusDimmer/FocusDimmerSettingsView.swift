import AppKit
import MacToysCore
import SwiftUI

struct FocusDimmerSettingsView: View {
    let module: FocusDimmerModule
    @State private var permissions = PermissionCenter.shared

    var body: some View {
        @Bindable var s = module.settings
        SettingsPage(module: module) {
            HeroCard(tint: .indigo) {
                FocusDimmerHero(settings: module.settings, status: module.status) { module.toggle(feedback: false) }
            }
        } content: {
            Section("Activation") {
                ShortcutRow("Turn dimming on or off", subtitle: "Also in the menu bar flyout, with the intensity in use",
                            shortcut: $s.value.toggle)
            }
            Section("Dimming") {
                SliderRow("Intensity in light appearance", value: $s.value.lightIntensity, in: 0...100, step: 1,
                          format: Self.percent)
                SliderRow("Intensity in dark appearance", value: $s.value.darkIntensity, in: 0...100, step: 1,
                          format: Self.percent)
                ColorRow("Tint", subtitle: "Black dims; a color tints the background as it dims.", color: $s.value.color,
                         supportsOpacity: false)
                Toggle(isOn: $s.value.animate) {
                    RowLabel("Fade when you switch windows", subtitle: "The window you leave darkens gradually instead of at once.")
                }
                SliderRow("Fade duration", value: $s.value.fadeDuration, in: 0.1...1, step: 0.05) {
                    Duration.milliseconds(Int(($0 * 1000).rounded())).formatted(.units(allowed: [.milliseconds], width: .abbreviated))
                }
                .disabled(!s.value.animate)
            }
            Section("What stays bright") {
                Picker(selection: $s.value.highlight) {
                    ForEach(FocusDimmerSettings.Highlight.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
                } label: {
                    RowLabel("Keep bright")
                }
                Picker(selection: $s.value.otherDisplays) {
                    ForEach(FocusDimmerSettings.OtherDisplays.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
                } label: {
                    RowLabel("Other displays", subtitle: "Displays that don't show the window you're working in")
                }
                Toggle(isOn: $s.value.onlyWithOtherWindows) {
                    RowLabel("Only when other windows are visible",
                             subtitle: "Leaves the desktop alone while the active window is the only one on screen.")
                }
                if !permissions.isGranted(.accessibility) {
                    InfoBar(.info, title: Text("Optional: sharper focus tracking"),
                            message: Text("With Accessibility access, Focus Dimmer reads the focused window directly, so sheets and dialogs stay bright and switching windows inside an app takes effect at once."),
                            actionTitle: Text("Grant Access")) { permissions.request(.accessibility) }
                }
            }
            Section("Excluded apps") {
                ExcludedAppsEditor("Never dim while these apps are active", apps: $s.value.excludedApps)
                Text("Useful for apps you compare side by side or present from. Partial names match too: “Note” covers Notes and Notefile.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    static func percent(_ value: Double) -> String {
        (value / 100).formatted(.percent.precision(.fractionLength(0)))
    }
}

/// Settings hero: two miniature desktops (light and dark appearance) dimmed live with the current
/// settings, the state, and the shortcut.
struct FocusDimmerHero: View {
    let settings: Persisted<FocusDimmerSettings>
    let status: DimStatus
    let toggle: () -> Void
    /// The settings page disables its hero while the module is off.
    @Environment(\.isEnabled) private var moduleOn

    var body: some View {
        let s = settings.value
        let dark = SystemAppearance.isDark
        HStack(alignment: .center, spacing: 22) {
            HStack(spacing: 14) {
                MiniDesktop(dark: false, settings: s, current: !dark)
                MiniDesktop(dark: true, settings: s, current: dark)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Everything but your window steps back").font(.system(size: 14, weight: .semibold))
                Text("Windows behind the one you're using fade under a tint. Menus, the Dock and notifications stay bright, and clicks go through as usual.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                StateBadge(on: s.dimming, active: status.dimmingNow)
                HStack(spacing: 10) {
                    Button(moduleOn && s.dimming ? "Pause Dimming" : "Resume Dimming", action: toggle)
                        .buttonStyle(.borderedProminent)
                    Keycaps(s.toggle)
                }
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .animation(.smooth(duration: 0.25), value: s)
    }
}

private struct StateBadge: View {
    let on: Bool
    let active: Bool
    /// The settings page disables its hero while the module is off.
    @Environment(\.isEnabled) private var moduleOn

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(moduleOn && on ? (active ? Color.green : Color.orange) : Color.secondary.opacity(0.6))
                .frame(width: 7, height: 7)
            Group {
                if !moduleOn {
                    Text("Off", comment: "Focus Dimmer state: the module is turned off")
                } else if !on {
                    Text("Paused")
                } else if active {
                    Text("Dimming around the active window")
                } else {
                    Text("On · nothing to dim right now", comment: "Focus Dimmer state: on, but the active window is alone or the app is excluded")
                }
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.secondary)
        }
    }
}

/// A 16:10 desktop with three windows, dimmed like the real thing for one appearance.
struct MiniDesktop: View {
    let dark: Bool
    let settings: FocusDimmerSettings
    let current: Bool

    private static let size = CGSize(width: 168, height: 105)

    var body: some View {
        let intensity = settings.intensity(dark: dark)
        let appMode = settings.highlight == .frontApp
        let windows = [
            MockDimWindow(id: 3, pid: 30, frame: CGRect(x: 52, y: 30, width: 74, height: 56),
                          content: AnyView(MiniWindow(dark: dark, accent: .yellow, lines: 4))),
            MockDimWindow(id: 2, pid: appMode ? 30 : 20, frame: CGRect(x: 96, y: 14, width: 62, height: 50),
                          content: AnyView(MiniWindow(dark: dark, accent: appMode ? .yellow : .cyan, lines: 3))),
            MockDimWindow(id: 1, pid: 10, frame: CGRect(x: 10, y: 12, width: 70, height: 58),
                          content: AnyView(MiniWindow(dark: dark, accent: .blue, lines: 5))),
        ]
        VStack(spacing: 7) {
            ZStack(alignment: .topLeading) {
                DesktopWallpaper(dark: dark)
                DimmedStack(size: Self.size, windows: windows, front: DimFrontApp(pid: 30, focus: .window(3)),
                            options: DimOptions(highlight: settings.highlight, onlyWithOtherWindows: false),
                            color: settings.dimming ? settings.color.color : .clear,
                            alpha: DimIntensity.alpha(intensity / 100), windowRadius: 5)
                Rectangle().fill(.white.opacity(dark ? 0.12 : 0.35)).frame(height: 5)
            }
            .frame(width: Self.size.width, height: Self.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.primary.opacity(0.12)))
            .padding(3)
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 2).opacity(current ? 1 : 0))
            HStack(spacing: 5) {
                Image(systemName: dark ? "moon.fill" : "sun.max.fill").font(.system(size: 10))
                if dark {
                    Text("Dark", comment: "Focus Dimmer hero: the dark appearance preview")
                } else {
                    Text("Light", comment: "Focus Dimmer hero: the light appearance preview")
                }
                Text(verbatim: FocusDimmerSettingsView.percent(intensity)).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.system(size: 11.5, weight: current ? .semibold : .regular))
        }
    }
}

/// A window in miniature: title bar dots and a few text lines.
private struct MiniWindow: View {
    let dark: Bool
    let accent: Color
    let lines: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 2.5) {
                ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0.opacity(0.85)).frame(width: 4, height: 4) }
            }
            .padding(.bottom, 1)
            Capsule().fill(accent.opacity(0.85)).frame(width: 26, height: 3.5)
            ForEach(0..<lines, id: \.self) { i in
                Capsule().fill(MockPalette.secondary(dark).opacity(0.5)).frame(width: CGFloat(22 + (i * 17) % 30), height: 3)
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(MockPalette.body(dark))
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.black.opacity(dark ? 0.5 : 0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 3, y: 1.5)
    }
}
