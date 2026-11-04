import MacToysCore
import SwiftUI

struct KeystrokeSettingsView: View {
    let module: KeystrokeOverlayModule

    var body: some View {
        @Bindable var s = module.settings
        SettingsPage(module: module) {
            HeroCard(tint: .yellow) {
                KeystrokeHero(settings: module.settings.value) { module.toggle(feedback: false) }
            }
        } content: {
            Section("Activation") {
                ShortcutRow("Show or hide keystrokes", subtitle: "Also in the menu bar flyout", shortcut: $s.value.toggle)
            }
            Section("What to show") {
                Picker(selection: $s.value.mode) {
                    ForEach(KeystrokeSettings.Mode.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
                } label: {
                    RowLabel(title: Text("Show"), subtitle: Text(verbatim: s.value.mode.summary))
                }
                Toggle(isOn: $s.value.showNames) {
                    RowLabel("Name shortcuts after the app's menu items",
                             subtitle: "⌘S shows as “⌘S Save”, read from the menus of the app you're in.")
                }
                if s.value.mode == .shortcuts {
                    Toggle(isOn: $s.value.specialKeys) {
                        RowLabel("Include esc, return, tab, delete, arrows and function keys")
                    }
                }
                Toggle(isOn: $s.value.modifierOnly) {
                    RowLabel("Modifier keys pressed on their own", subtitle: "⌘, ⌥, ⌃ or ⇧ tapped without another key")
                }
                Toggle(isOn: $s.value.mouseClicks) {
                    RowLabel("Mouse clicks", subtitle: "Clicks, double clicks and right clicks, with the modifier keys held")
                }
            }
            Section("Overlay") {
                Picker(selection: $s.value.position) {
                    ForEach(KeystrokeSettings.Position.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
                } label: {
                    RowLabel("Position")
                }
                LabeledContent {
                    Button("Drag to Position…") { module.editPosition() }
                } label: {
                    RowLabel("Place it anywhere", subtitle: "Drag a sample of the overlay to the spot you want.")
                }
                Picker(selection: $s.value.screen) {
                    ForEach(KeystrokeSettings.Screen.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
                } label: {
                    RowLabel("Show on")
                }
                Picker(selection: $s.value.size) {
                    ForEach(KeystrokeSettings.Size.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
                } label: {
                    RowLabel("Size")
                }
                Picker(selection: $s.value.theme) {
                    ForEach(KeystrokeSettings.Theme.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
                } label: {
                    RowLabel("Theme")
                }
                .pickerStyle(.segmented)
                SliderRow("Stays on screen for", subtitle: "After the last key, before it fades away",
                          value: $s.value.duration, in: 0.5...6, step: 0.5) {
                    Measurement(value: $0, unit: UnitDuration.seconds)
                        .formatted(.measurement(width: .abbreviated, numberFormatStyle: .number.precision(.fractionLength(1))))
                }
            }
            Section("Privacy") {
                Toggle(isOn: $s.value.maskText) {
                    RowLabel("Mask letters and numbers", subtitle: "Typed text and keys show as dots; shortcuts still show in full.")
                }
                ExcludedAppsEditor("Never show keystrokes while these apps are active", apps: $s.value.excludedApps)
                Label {
                    Text("Keystrokes are only drawn on screen: nothing is recorded, saved or sent. Nothing shows while you type in a password field or while secure keyboard entry is on.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "lock.shield.fill").foregroundStyle(.green)
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            }
        }
    }
}

/// Settings hero: where the overlay appears, a live sample in the chosen theme, size and mode,
/// and the on/off state with its shortcut.
struct KeystrokeHero: View {
    let settings: KeystrokeSettings
    let toggle: () -> Void
    /// The settings page disables its hero while the module is off.
    @Environment(\.isEnabled) private var moduleOn

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 22) {
                MiniScreen(settings: settings)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your keys on screen, as you press them").font(.system(size: 14, weight: .semibold))
                    Text("For screen recordings, demos and teaching. Shortcuts carry the name of the menu item they trigger.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Circle().fill(moduleOn && settings.showing ? Color.green : Color.secondary.opacity(0.6)).frame(width: 7, height: 7)
                        if !moduleOn {
                            Text("Off", comment: "Keystroke Overlay state: the module is turned off")
                        } else if settings.showing {
                            Text("On · \(settings.mode.title)", comment: "Keystroke Overlay state; %@ is the mode, e.g. Shortcuts only")
                        } else {
                            Text("Hidden", comment: "Keystroke Overlay state: not showing keys")
                        }
                    }
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Button(moduleOn && settings.showing ? "Hide Keystrokes" : "Show Keystrokes", action: toggle)
                            .buttonStyle(.borderedProminent)
                        Keycaps(settings.toggle)
                    }
                    .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            SampleStrip(settings: settings)
        }
    }
}

/// The overlay in the current theme, size and mode on a wallpaper strip, scaled down to fit.
struct SampleStrip: View {
    let settings: KeystrokeSettings
    @State private var natural: CGSize = .zero
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let style = PillStyle(theme: settings.theme, size: settings.size, reduceTransparency: reduceTransparency)
        GeometryReader { geo in
            let scale = natural.width > 0
                ? min(1, (geo.size.width - 40) / natural.width, (geo.size.height - 28) / natural.height) : 1
            KeystrokePill(items: KeystrokeSamples.feed(settings.mode, size: settings.size).items, style: style)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { natural = $0 }
                .scaleEffect(scale)
                .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(height: 104)
        .background(KeystrokeWallpaper())
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.primary.opacity(0.1)))
        .animation(.smooth(duration: 0.25), value: settings)
    }
}

/// A 16:10 screen with a tiny pill at the chosen position.
private struct MiniScreen: View {
    let settings: KeystrokeSettings
    private let size = CGSize(width: 176, height: 110)

    var body: some View {
        let pill = CGSize(width: 54, height: 13)
        let center = Self.center(settings, screen: size, pill: pill)
        ZStack(alignment: .topLeading) {
            KeystrokeWallpaper()
            Rectangle().fill(.white.opacity(0.22)).frame(height: 6)
            MiniEditor().frame(width: 112, height: 66).offset(x: 32, y: 15)
            Capsule().fill(.white.opacity(0.28)).frame(width: 64, height: 7).offset(x: (size.width - 64) / 2, y: size.height - 11)
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(settings.theme == .light ? Color.white : Color(white: 0.12).opacity(0.85))
                .overlay {
                    HStack(spacing: 2) {
                        ForEach(0..<3, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(settings.theme == .light ? Color.black.opacity(0.18) : Color.white.opacity(0.55))
                                .frame(width: i == 2 ? 16 : 8, height: 7)
                        }
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.white.opacity(0.35), lineWidth: 0.5))
                .frame(width: pill.width, height: pill.height)
                .position(center)
                .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.primary.opacity(0.15)))
        .animation(.smooth(duration: 0.3), value: center)
    }

    static func center(_ s: KeystrokeSettings, screen: CGSize, pill: CGSize) -> CGPoint {
        let mx: CGFloat = 8 + pill.width / 2, top: CGFloat = 10 + pill.height / 2, bottom: CGFloat = 16 + pill.height / 2
        switch s.position {
        case .bottomCenter: return CGPoint(x: screen.width / 2, y: screen.height - bottom)
        case .topCenter: return CGPoint(x: screen.width / 2, y: top)
        case .bottomLeading: return CGPoint(x: mx, y: screen.height - bottom)
        case .bottomTrailing: return CGPoint(x: screen.width - mx, y: screen.height - bottom)
        case .topLeading: return CGPoint(x: mx, y: top)
        case .topTrailing: return CGPoint(x: screen.width - mx, y: top)
        case .custom:
            return CGPoint(x: min(max(screen.width * s.customX, mx), screen.width - mx),
                           y: min(max(screen.height * s.customY, top), screen.height - bottom))
        }
    }
}

/// A tiny code editor window on the mini screen.
private struct MiniEditor: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 2.5) {
                ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0.opacity(0.85)).frame(width: 4, height: 4) }
            }
            .padding(.bottom, 2)
            ForEach(Array([(0, 46.0, Color.pink), (0, 70, .white), (8, 54, .cyan), (8, 38, .cyan), (16, 60, .white)].enumerated()),
                    id: \.offset) { _, line in
                Capsule().fill(line.2.opacity(0.55)).frame(width: line.1, height: 2.5).padding(.leading, CGFloat(line.0))
            }
        }
        .padding(7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
    }
}

/// The design boards' wallpaper, for glass to sit on.
struct KeystrokeWallpaper: View {
    var body: some View {
        LinearGradient(colors: [Color(red: 0.09, green: 0.13, blue: 0.36), Color(red: 0.24, green: 0.17, blue: 0.56),
                                Color(red: 0.6, green: 0.25, blue: 0.53), Color(red: 0.88, green: 0.54, blue: 0.42)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
