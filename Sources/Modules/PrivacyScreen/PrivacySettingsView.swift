import AppKit
import MacToysCore
import SwiftUI

struct PrivacyScreenSettingsView: View {
    let module: PrivacyScreenModule
    @Bindable var s: Persisted<PrivacyScreenSettings>
    let status: PrivacyStatus
    @State private var biometricsAvailable = BiometricPrompt.isAvailable

    init(module: PrivacyScreenModule) {
        self.module = module
        self.s = module.settings
        self.status = module.status
    }

    var body: some View {
        SettingsPage(module: module) {
            PrivacyHero(module: module, settings: s.value, status: status)
        } content: {
            lockSection
            blurSection
            privateAppsSection
            awaySection
            hotCornerSection
            shortcutsSection
        }
    }

    // MARK: Lock

    private var lockSection: some View {
        Section("Lock") {
            Picker(selection: $s.value.lockStyle) {
                ForEach(LockStyle.allCases) { Text(verbatim: $0.title).tag($0) }
            } label: {
                RowLabel(title: Text("Style"), subtitle: Text(verbatim: s.value.lockStyle.subtitle))
            }
            .pickerStyle(.segmented)
            .fixedSize(horizontal: false, vertical: true)
            Toggle(isOn: $s.value.showClock) {
                RowLabel("Show the clock", subtitle: "The time and date, large, over the lock screen.")
            }
            Toggle(isOn: $s.value.showAwayMessage) {
                RowLabel("Show an away message", subtitle: "A note for anyone passing by, such as when you'll be back.")
            }
            if s.value.showAwayMessage {
                LabeledContent {
                    TextField(text: $s.value.awayMessage, prompt: Text("Back at 3:30", comment: "Example away message (placeholder)")) {
                        Text("Away message")
                    }
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                } label: {
                    RowLabel("Message", subtitle: "Set it before you lock. A lock started from a link can bring its own message.")
                }
            }
            Picker(selection: $s.value.handOffMinutes) {
                ForEach(PrivacyScreenSettings.handOffChoices, id: \.self) { minutes in
                    Text(verbatim: PrivacyScreenSettings.minutesTitle(minutes, zero: String(localized: "Never", comment: "Hand-off delay: never lock macOS too")))
                        .tag(minutes)
                }
            } label: {
                RowLabel("Also lock macOS after",
                         subtitle: "After this long, the real macOS lock screen takes over too. Unlocking macOS also ends the Privacy Screen lock.")
            }
            Toggle(isOn: $s.value.allowTouchID) {
                RowLabel(title: Text("Unlock with Touch ID"),
                         subtitle: biometricsAvailable
                            ? Text("Or with an Apple Watch paired with this Mac.")
                            : Text("This Mac has no Touch ID or paired Apple Watch available right now; your password always works."))
            }
            .disabled(!biometricsAvailable)
            InfoBar(.info, title: Text("macOS checks your password"),
                    message: Text("Privacy Screen hands the password to macOS to verify and never stores, logs or sends it. Each wrong password makes the next try wait longer, and every failed attempt is listed after you unlock."))
            InfoBar(.success, title: Text("Protected even if MacToys quits"),
                    message: Text("While locked, a small guard process watches MacToys. If it is force quit or crashes, the guard locks your Mac with macOS before the desktop can show."))
        }
    }

    // MARK: Blur

    private var blurSection: some View {
        Section("Blur") {
            SliderRow("Blur Screen strength", subtitle: "Frosts every display. Esc, a click or the shortcut clears it.",
                      value: $s.value.screenBlurStrength, in: 0...1, format: Self.percent)
            SliderRow("Focus Blur strength", subtitle: "Everything but the front window. Private Apps uses it too.",
                      value: $s.value.focusBlurStrength, in: 0...1, format: Self.percent)
            BlurStrengthStrip(screen: s.value.screenBlurStrength, focus: s.value.focusBlurStrength)
        }
    }

    // MARK: Private Apps

    private var privateAppsSection: some View {
        Section("Private Apps") {
            Toggle(isOn: Binding(get: { s.value.privateAppsOn }, set: { module.request(.setPrivateApps($0)) })) {
                RowLabel("Blur private apps", subtitle: "These apps stay blurred wherever they show, unless they're in front.")
            }
            ExcludedAppsEditor("Private apps", apps: $s.value.privateApps)
            Toggle(isOn: $s.value.peekWithOption) {
                RowLabel("Peek with ⌥", subtitle: "Hold Option with the pointer over a blurred app to see it without switching to it.")
            }
        }
    }

    // MARK: Away

    private var awaySection: some View {
        Section("Away") {
            idlePicker(Text("Blur after"), subtitle: Text("Blur Screen starts when the Mac has had no input for this long."),
                       selection: $s.value.blurAfterIdleMinutes)
            idlePicker(Text("Lock after"), subtitle: Text("Lock starts when the Mac has had no input for this long."),
                       selection: $s.value.lockAfterIdleMinutes)
            Toggle(isOn: $s.value.pauseWhileDisplayKeptAwake) {
                RowLabel("Wait during video and calls",
                         subtitle: "The timers pause while another app keeps the display on, such as a video player or a video call.")
            }
            .disabled(s.value.blurAfterIdleMinutes == 0 && s.value.lockAfterIdleMinutes == 0)
        }
    }

    private func idlePicker(_ title: Text, subtitle: Text, selection: Binding<Int>) -> some View {
        Picker(selection: selection) {
            ForEach(PrivacyScreenSettings.idleChoices, id: \.self) { minutes in
                Text(verbatim: PrivacyScreenSettings.minutesTitle(minutes, zero: String(localized: "Never", comment: "Idle timer: off")))
                    .tag(minutes)
            }
        } label: {
            RowLabel(title: title, subtitle: subtitle)
        }
    }

    // MARK: Hot corner

    private var hotCornerSection: some View {
        Section("Hot corner") {
            LabeledContent {
                HotCornerPicker(corner: $s.value.hotCorner)
            } label: {
                RowLabel("Corner", subtitle: "Move the pointer into this corner of any display and rest it there.")
            }
            Picker(selection: $s.value.hotCornerAction) {
                ForEach(HotCornerAction.allCases) { Text(verbatim: $0.title).tag($0) }
            } label: {
                RowLabel("Action")
            }
            .disabled(s.value.hotCorner == .none)
            SliderRow("Rest for", subtitle: "How long the pointer stays in the corner before it triggers.",
                      value: $s.value.hotCornerDelay, in: 0.2...2, step: 0.1,
                      format: { Measurement(value: $0, unit: UnitDuration.seconds)
                          .formatted(.measurement(width: .abbreviated, numberFormatStyle: .number.precision(.fractionLength(1)))) })
                .disabled(s.value.hotCorner == .none)
        }
    }

    // MARK: Shortcuts

    private var shortcutsSection: some View {
        Section("Shortcuts") {
            ShortcutRow("Lock Screen", subtitle: "Touch ID or your password unlocks.", shortcut: $s.value.lockShortcut)
            ShortcutRow("Blur Screen", subtitle: "Press it again, Esc or click to clear.", shortcut: $s.value.blurShortcut)
            ShortcutRow("Focus Blur", subtitle: "Turns Focus Blur on or off.", shortcut: $s.value.focusShortcut)
            ShortcutRow("Private Apps", subtitle: "Turns Private Apps on or off.", shortcut: $s.value.privateAppsShortcut)
            ShortcutRow("Lock App", subtitle: "Locks the app in front until Touch ID or your password unlock it.",
                        shortcut: $s.value.appLockShortcut)
        }
    }

    static func percent(_ v: Double) -> String { v.formatted(.percent.precision(.fractionLength(0))) }
}

/// Four corners of a little display; click one (again to turn it off).
private struct HotCornerPicker: View {
    @Binding var corner: ScreenCorner

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.24, green: 0.17, blue: 0.56), Color(red: 0.88, green: 0.54, blue: 0.42)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.black.opacity(0.15)))
                ForEach([ScreenCorner.topLeft, .topRight, .bottomLeft, .bottomRight]) { c in
                    Button {
                        corner = corner == c ? .none : c
                    } label: {
                        Circle()
                            .fill(corner == c ? Color.accentColor : Color.white.opacity(0.55))
                            .overlay(Circle().strokeBorder(.white, lineWidth: corner == c ? 2 : 0))
                            .frame(width: 14, height: 14)
                            .padding(5)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment(c))
                    .accessibilityLabel(Text(verbatim: c.title))
                    .accessibilityAddTraits(corner == c ? .isSelected : [])
                }
            }
            .frame(width: 84, height: 54)
            Text(verbatim: corner.title)
                .foregroundStyle(.secondary)
                .frame(minWidth: 80, alignment: .leading)
        }
    }

    private func alignment(_ c: ScreenCorner) -> Alignment {
        switch c {
        case .topLeft: .topLeading
        case .topRight: .topTrailing
        case .bottomLeft: .bottomLeading
        case .bottomRight, .none: .bottomTrailing
        }
    }
}

/// The two strengths side by side on a scrap of sample text.
private struct BlurStrengthStrip: View {
    let screen: Double
    let focus: Double

    var body: some View {
        HStack(spacing: 12) {
            sample(Text("Blur Screen"), strength: screen)
            sample(Text("Focus Blur"), strength: focus)
        }
        .padding(.vertical, 2)
        .accessibilityHidden(true)
    }

    private func sample(_ title: Text, strength: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .textBackgroundColor))
                BlurredSample(radius: 1 + 6 * strength)
                    .opacity(1 - 0.35 * strength)
            }
            .frame(height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.quaternary))
            title.font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// The sample text blurred with CoreImage. An offscreen render (snapshots, the product film) skips
/// SwiftUI's `.blur`, so this way the app and its pictures show the same thing.
private struct BlurredSample: View {
    let radius: Double
    @Environment(\.colorScheme) private var scheme
    private static var plain: [Bool: CGImage] = [:]

    var body: some View {
        let dark = scheme == .dark
        // Half-point steps keep the cache small while the slider moves.
        if let base = Self.base(dark: dark),
           let image = PreviewImages.blurred(base, radius: (radius * 2).rounded() / 2, wash: 0, dark: dark, key: "strength-strip") {
            Image(decorative: image, scale: PreviewImages.scale)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static func base(dark: Bool) -> CGImage? {
        if let hit = plain[dark] { return hit }
        let lines = VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: "Booked the table for 7 at Nopa").font(.system(size: 12, weight: .semibold))
            Text(verbatim: "Lab results — please review").font(.system(size: 11))
            Text(verbatim: "Revenue target $4.2M").font(.system(size: 11))
        }
        .foregroundStyle(dark ? Color.white : Color.black)
        .padding(10)
        let renderer = ImageRenderer(content: lines)
        renderer.scale = PreviewImages.scale
        plain[dark] = renderer.cgImage
        return plain[dark]
    }
}

// MARK: - Hero

/// A live miniature of the lock screen built from the current settings, plus the five modes.
private struct PrivacyHero: View {
    let module: PrivacyScreenModule
    let settings: PrivacyScreenSettings
    let status: PrivacyStatus

    var body: some View {
        HeroCard(tint: .purple) {
            HStack(alignment: .center, spacing: 22) {
                MiniLockScreen(settings: settings)
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Lock, blur or hide — right where you are")
                            .font(.system(size: 15, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Apps keep running behind it and windows never move. No permissions needed.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                        GridRow {
                            ModeChip(title: Text("Lock Screen"), symbol: "lock.fill", shortcut: settings.lockShortcut) {
                                module.request(.lock)
                            }
                            ModeChip(title: Text("Blur Screen"), symbol: "eye.slash.fill", shortcut: settings.blurShortcut) {
                                module.request(.blur)
                            }
                        }
                        GridRow {
                            ModeChip(title: Text("Focus Blur"), symbol: "scope", shortcut: settings.focusShortcut,
                                     isOn: status.modes.focusBlur) { module.request(.toggleFocus) }
                            ModeChip(title: Text("Private Apps"), symbol: "hand.raised.fill", shortcut: settings.privateAppsShortcut,
                                     isOn: status.modes.privateApps) { module.request(.togglePrivateApps) }
                        }
                        GridRow {
                            ModeChip(title: Text("Lock App"), symbol: "lock.app.dashed", shortcut: settings.appLockShortcut,
                                     detail: status.lockedApps.isEmpty ? nil
                                        : Text("Locked: \(status.lockedApps.formatted(.list(type: .and, width: .narrow)))",
                                               comment: "Hero chip detail; the placeholder lists app names")) {
                                module.lockFrontmostApp()
                            }
                            .help(Text("Locks the app you used last before MacToys."))
                            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        }
                    }
                }
            }
        }
    }
}

/// One mode: icon, name and shortcut; on/off modes light up.
private struct ModeChip: View {
    let title: Text
    let symbol: String
    let shortcut: Shortcut?
    var isOn: Bool?
    var detail: Text?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(isOn == true ? .white : Tint.purple.color)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isOn == true ? Tint.purple.color : Tint.purple.color.opacity(0.13)))
                VStack(alignment: .leading, spacing: 1) {
                    title
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    secondLine
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if isOn == true {
                    Circle().fill(Tint.purple.color).frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor).opacity(0.85)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isOn == true ? Tint.purple.color.opacity(0.55) : Color.primary.opacity(0.08)))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn == true ? .isSelected : [])
    }

    /// The shortcut, then the state or detail.
    private var secondLine: Text {
        let keys = shortcut.map { Text(verbatim: $0.description).monospacedDigit() }
        let state: Text? = detail ?? isOn.map { $0 ? Text("On", comment: "Mode state") : Text("Off", comment: "Mode state") }
        switch (keys, state) {
        case let (k?, s?): return Text("\(k) · \(s)", comment: "Mode chip: a keyboard shortcut, then the mode's state")
        case let (k?, nil): return k
        case let (nil, s?): return s
        default: return Text(verbatim: " ")
        }
    }
}

/// The lock screen of the current settings on a little laptop display.
private struct MiniLockScreen: View {
    let settings: PrivacyScreenSettings
    private static let scale: CGFloat = 0.21

    var body: some View {
        let unlock = PrivacyPreviews.unlockModel { $0.offersBiometrics = settings.allowTouchID }
        let message = settings.showAwayMessage
            ? (settings.awayMessage.isEmpty ? String(localized: "Back at 3:30", comment: "Example away message (placeholder)") : settings.awayMessage)
            : nil
        let size = PrivacyPreviews.size
        VStack(spacing: 0) {
            LockScreenComposite(style: settings.lockStyle, showClock: settings.showClock, awayMessage: message,
                                unlock: unlock, date: .now)
                .scaleEffect(Self.scale, anchor: .topLeading)
                .frame(width: size.width * Self.scale, height: size.height * Self.scale, alignment: .topLeading)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .padding(5)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(white: 0.08)))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color(white: 0.35), lineWidth: 1))
            UnevenRoundedRectangle(bottomLeadingRadius: 6, bottomTrailingRadius: 6, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.78), Color(white: 0.62)], startPoint: .top, endPoint: .bottom))
                .frame(width: size.width * Self.scale + 34, height: 7)
        }
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel(Text("Lock screen preview: \(settings.lockStyle.title)", comment: "VoiceOver; the placeholder is the lock style name"))
    }
}
