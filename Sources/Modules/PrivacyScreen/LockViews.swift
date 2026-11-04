import AppKit
import MacToysCore
import Observation
import QuartzCore
import SwiftUI

// MARK: - Models

/// What every display's shield shows.
@MainActor
@Observable
final class ShieldModel {
    var style: LockStyle = .frosted
    var showClock = true
    var awayMessage: String?
    /// Fixed time for previews; nil shows the live clock.
    var fixedDate: Date?
    /// Height kept free at the top for the unlock island.
    var islandClearance: CGFloat = 150
}

/// The unlock island's state (screen lock and App Lock).
@MainActor
@Observable
final class UnlockModel {
    enum Phase: Equatable {
        case ready
        case verifying
        /// Wrong passwords: the next one may be tried at this date.
        case waiting(until: Date)
    }

    enum Note: Equatable {
        case wrongPassword
        case touchIDFailed
        case touchIDLocked
    }

    /// The user's name, or "“Messages” is locked".
    var title = ""
    /// App Lock shows the app's icon instead of the lock glyph.
    var appIcon: NSImage?
    var password = ""
    var phase: Phase = .ready
    var note: Note?
    var offersBiometrics = false
    /// App Lock can be dismissed without unlocking.
    var canCancel = false
    /// Bumped on a wrong password (shake) and when the field should take focus again.
    var shakeCount = 0
    var focusCount = 0

    @ObservationIgnored var onSubmit: () -> Void = {}
    @ObservationIgnored var onCancel: () -> Void = {}
    @ObservationIgnored var onRetryBiometrics: () -> Void = {}

    var hint: String {
        switch (phase, note) {
        case (.verifying, _): String(localized: "Checking…", comment: "Unlock island: the password is being verified")
        case (.waiting, _): String(localized: "Too many wrong passwords", comment: "Unlock island: the user must wait before the next attempt")
        case (_, .wrongPassword?): String(localized: "Wrong password. Try again.", comment: "Unlock island")
        case (_, .touchIDFailed?): String(localized: "Not recognized. Try again or use your password.", comment: "Unlock island: Touch ID failed")
        case (_, .touchIDLocked?): String(localized: "Touch ID is locked. Use your password.", comment: "Unlock island")
        default:
            offersBiometrics
                ? String(localized: "Touch ID or enter your password", comment: "Unlock island hint")
                : String(localized: "Enter your password", comment: "Unlock island hint")
        }
    }

    var hintIsWarning: Bool {
        if case .waiting = phase { return true }
        return note != nil && phase != .verifying
    }
}

// MARK: - Shield

/// What lies over the frost on each display: style tint, clock and away message.
struct LockShieldView: View {
    let model: ShieldModel
    /// Draws the ambient glow in SwiftUI (previews); the live shield animates it in Core Animation.
    var drawsGlow = false

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        GeometryReader { geo in
            ZStack {
                backdrop
                VStack(spacing: 0) {
                    if model.showClock {
                        if let date = model.fixedDate {
                            LockClock(date: date)
                        } else {
                            TimelineView(.everyMinute) { ctx in LockClock(date: ctx.date) }
                        }
                    }
                    if let message = model.awayMessage, !message.isEmpty {
                        AwayMessageView(message: message, highContrast: contrast == .increased)
                            .padding(.top, model.showClock ? 28 : 0)
                    }
                }
                .padding(.top, max(model.islandClearance + 36, geo.size.height * 0.19))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var backdrop: some View {
        switch model.style {
        case .frosted:
            LinearGradient(colors: [.black.opacity(0.22), .black.opacity(0.04), .black.opacity(0.3)],
                           startPoint: .top, endPoint: .bottom)
        case .ambient:
            ZStack {
                if drawsGlow { AmbientGlowStatic() }
                LinearGradient(colors: [.black.opacity(0.18), .clear, .black.opacity(0.26)], startPoint: .top, endPoint: .bottom)
            }
        case .solid:
            ZStack {
                Color(red: 0.035, green: 0.035, blue: 0.05)
                RadialGradient(colors: [Color(red: 0.16, green: 0.16, blue: 0.24).opacity(0.55), .clear],
                               center: UnitPoint(x: 0.5, y: 0.3), startRadius: 0, endRadius: 900)
            }
        }
    }
}

/// The big lock screen clock: date line over the time.
struct LockClock: View {
    let date: Date

    var body: some View {
        VStack(spacing: 0) {
            Text(date, format: .dateTime.weekday(.wide).month(.wide).day())
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white.opacity(0.86))
            Text(date, format: .dateTime.hour(.defaultDigits(amPM: .omitted)).minute())
                .font(.system(size: 112, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.94))
                .shadow(color: .black.opacity(0.16), radius: 14, y: 4)
        }
        .accessibilityElement(children: .combine)
    }
}

/// "Back at 3:30", in a glass capsule.
struct AwayMessageView: View {
    let message: String
    var highContrast = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "person.crop.circle.badge.clock")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 17, weight: .medium))
            Text(verbatim: message)
                .font(.system(size: 15, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Capsule().fill(.white.opacity(highContrast ? 0.26 : 0.12)))
        .glassEffect(.regular, in: .capsule)
        .overlay(Capsule().strokeBorder(.white.opacity(highContrast ? 0.55 : 0.18), lineWidth: 1))
        .frame(maxWidth: 520)
        .accessibilityLabel(Text("Away message: \(message)", comment: "VoiceOver; the placeholder is the user's away note"))
    }
}

// MARK: - Ambient glow

enum AmbientPalette {
    /// (color, center x, center y, radius as a fraction of the width)
    static let blobs: [(NSColor, CGFloat, CGFloat, CGFloat)] = [
        (NSColor(srgbRed: 0.37, green: 0.36, blue: 0.95, alpha: 1), 0.22, 0.30, 0.55),
        (NSColor(srgbRed: 0.95, green: 0.30, blue: 0.55, alpha: 1), 0.78, 0.38, 0.5),
        (NSColor(srgbRed: 0.20, green: 0.72, blue: 0.90, alpha: 1), 0.55, 0.85, 0.5),
    ]
}

/// The ambient glow, drawn once in SwiftUI (previews, the settings illustration).
struct AmbientGlowStatic: View {
    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(Array(AmbientPalette.blobs.enumerated()), id: \.offset) { _, blob in
                    RadialGradient(colors: [Color(nsColor: blob.0).opacity(0.5), Color(nsColor: blob.0).opacity(0)],
                                   center: UnitPoint(x: blob.1, y: blob.2), startRadius: 0,
                                   endRadius: geo.size.width * blob.3)
                }
            }
        }
    }
}

/// The live ambient glow: radial gradients drifting slowly, animated by Core Animation (the app
/// does no per-frame work). Still under Reduce Motion.
final class AmbientGlowView: NSView {
    private var blobs: [CAGradientLayer] = []
    var animated: Bool { didSet { if animated != oldValue { restartAnimations() } } }

    init(frame: CGRect, animated: Bool) {
        self.animated = animated
        super.init(frame: frame)
        wantsLayer = true
        for blob in AmbientPalette.blobs {
            let g = CAGradientLayer()
            g.type = .radial
            g.colors = [blob.0.withAlphaComponent(0.5).cgColor, blob.0.withAlphaComponent(0).cgColor]
            g.startPoint = CGPoint(x: 0.5, y: 0.5)
            g.endPoint = CGPoint(x: 1, y: 1)
            layer?.addSublayer(g)
            blobs.append(g)
        }
        layoutBlobs()
        restartAnimations()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        layoutBlobs()
        restartAnimations()
    }

    private func layoutBlobs() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (g, blob) in zip(blobs, AmbientPalette.blobs) {
            let d = bounds.width * blob.3 * 2
            g.bounds = CGRect(x: 0, y: 0, width: d, height: d)
            // SwiftUI's y grows downward; layers here grow upward.
            g.position = CGPoint(x: bounds.width * blob.1, y: bounds.height * (1 - blob.2))
        }
        CATransaction.commit()
    }

    private func restartAnimations() {
        for (i, g) in blobs.enumerated() {
            g.removeAllAnimations()
            guard animated else { continue }
            let drift = CABasicAnimation(keyPath: "position")
            let dx = bounds.width * (i == 1 ? -0.16 : 0.14)
            let dy = bounds.height * (i == 2 ? 0.18 : -0.12)
            drift.fromValue = NSValue(point: g.position)
            drift.toValue = NSValue(point: CGPoint(x: g.position.x + dx, y: g.position.y + dy))
            drift.duration = 26 + Double(i) * 7
            drift.autoreverses = true
            drift.repeatCount = .infinity
            drift.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            g.add(drift, forKey: "drift")
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0.65
            pulse.toValue = 1
            pulse.duration = 11 + Double(i) * 3
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            g.add(pulse, forKey: "pulse")
        }
    }
}

// MARK: - Unlock island

/// The island's outline: hanging from the top edge with soft shoulders (notched displays), or a
/// floating rounded slab.
struct IslandShape: Shape {
    var hanging: Bool
    var radius: CGFloat = 28
    var shoulder: CGFloat = IslandMetrics.shoulder

    func path(in r: CGRect) -> Path {
        guard hanging else { return Path(roundedRect: r, cornerRadius: radius, style: .continuous) }
        let s = shoulder
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - s, y: r.minY + s), control: CGPoint(x: r.maxX - s, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - s, y: r.maxY - radius))
        p.addCurve(to: CGPoint(x: r.maxX - s - radius, y: r.maxY),
                   control1: CGPoint(x: r.maxX - s, y: r.maxY - radius * 0.35),
                   control2: CGPoint(x: r.maxX - s - radius * 0.35, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + s + radius, y: r.maxY))
        p.addCurve(to: CGPoint(x: r.minX + s, y: r.maxY - radius),
                   control1: CGPoint(x: r.minX + s + radius * 0.35, y: r.maxY),
                   control2: CGPoint(x: r.minX + s, y: r.maxY - radius * 0.35))
        p.addLine(to: CGPoint(x: r.minX + s, y: r.minY + s))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.minY), control: CGPoint(x: r.minX + s, y: r.minY))
        p.closeSubpath()
        return p
    }
}

enum IslandMetrics {
    static let shoulder: CGFloat = 12
    /// Content area (below the notch), shoulders included.
    static let content = CGSize(width: 404, height: 116)
}

/// Hosts the live Touch ID view (`LAAuthenticationView`).
struct BiometricSlotView: NSViewRepresentable {
    let slot: NSView
    func makeNSView(context: Context) -> NSView { slot }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// The compact black island that asks for Touch ID or the password.
struct UnlockIslandView: View {
    @Bindable var model: UnlockModel
    /// Height of the notch part at the top (0 when the island floats).
    let notch: CGFloat
    /// The live Touch ID view; nil draws the glyph (previews).
    var biometricSlot: NSView?
    /// False draws a still picture of the field (previews, the settings illustration).
    var interactive = true

    @FocusState private var fieldFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    private var highContrast: Bool { contrast == .increased }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: notch)
            content
                .padding(.horizontal, IslandMetrics.shoulder + 18)
                .padding(.top, notch > 0 ? 8 : 16)
                .padding(.bottom, 16)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .background(IslandShape(hanging: notch > 0).fill(Color.black))
        .overlay {
            if notch == 0 || highContrast {
                IslandShape(hanging: notch > 0)
                    .stroke(Color.white.opacity(highContrast ? 0.6 : 0.12), lineWidth: 1)
            }
        }
        .environment(\.colorScheme, .dark)
        .onAppear { if interactive { fieldFocused = true } }
        .onChange(of: model.focusCount) { if interactive { fieldFocused = true } }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                badge
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: model.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(verbatim: model.hint)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(model.hintIsWarning ? Color(red: 1, green: 0.55, blue: 0.5)
                                                             : .white.opacity(highContrast ? 0.85 : 0.6))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 6)
                if model.offersBiometrics { biometric }
            }
            passwordRow
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: model.hint)
    }

    @ViewBuilder private var badge: some View {
        if let icon = model.appIcon {
            Image(nsImage: icon).resizable().interpolation(.high).frame(width: 34, height: 34)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "lock.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Circle().fill(.white.opacity(0.14)))
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder private var biometric: some View {
        Group {
            if let slot = biometricSlot {
                BiometricSlotView(slot: slot)
            } else {
                Image(systemName: "touchid")
                    .font(.system(size: 25, weight: .regular))
                    .foregroundStyle(Color(red: 1, green: 0.33, blue: 0.42))
            }
        }
        .frame(width: 34, height: 34)
        .contentShape(Rectangle())
        .onTapGesture { model.onRetryBiometrics() }
        .accessibilityElement()
        .accessibilityLabel(Text("Touch ID", comment: "VoiceOver label of the fingerprint button on the unlock island"))
        .accessibilityHint(Text("Touch the sensor to unlock.", comment: "VoiceOver hint on the unlock island"))
        .accessibilityAddTraits(.isButton)
    }

    private var passwordRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                if case .waiting(let until) = model.phase {
                    Image(systemName: "hourglass")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        let left = max(0, Int(until.timeIntervalSince(ctx.date).rounded(.up)))
                        Text("Try again in \(Duration.seconds(left).formatted(.time(pattern: .minuteSecond)))",
                             comment: "Unlock island countdown, e.g. 'Try again in 0:08'")
                            .font(.system(size: 13, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    Spacer(minLength: 0)
                } else if !interactive {
                    Group {
                        if model.password.isEmpty {
                            Text("Password", comment: "Placeholder of the password field on the unlock island")
                                .foregroundStyle(.white.opacity(0.42))
                        } else {
                            Text(verbatim: String(repeating: "•", count: model.password.count))
                                .foregroundStyle(.white)
                                .kerning(1.5)
                        }
                    }
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    submitButton
                } else {
                    SecureField(text: $model.password, prompt: Text("Password", comment: "Placeholder of the password field on the unlock island")
                        .foregroundStyle(.white.opacity(0.42))) {
                        Text("Password", comment: "Accessibility label of the password field on the unlock island")
                    }
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .focused($fieldFocused)
                    .onSubmit { model.onSubmit() }
                    .disabled(model.phase == .verifying)
                    submitButton
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 4)
            .frame(height: 34)
            .background(Capsule().fill(.white.opacity(highContrast ? 0.2 : 0.12)))
            .overlay(Capsule().strokeBorder(.white.opacity(highContrast ? 0.6 : 0.08), lineWidth: 1))
            .modifier(Shake(travel: reduceMotion ? 0 : 7, shakes: CGFloat(model.shakeCount)))
            .animation(reduceMotion ? nil : .linear(duration: 0.42), value: model.shakeCount)
            if model.canCancel {
                Button {
                    model.onCancel()
                } label: {
                    Text("Cancel", comment: "Unlock island button: close the island without unlocking the app")
                        .font(.system(size: 12.5, weight: .medium))
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                        .background(Capsule().fill(.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
            }
        }
    }

    private var submitButton: some View {
        Button {
            model.onSubmit()
        } label: {
            Group {
                if model.phase == .verifying {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 24, weight: .regular))
                        .symbolRenderingMode(.hierarchical)
                }
            }
            .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(model.password.isEmpty ? 0.35 : 0.95))
        .disabled(model.password.isEmpty || model.phase == .verifying)
        .accessibilityLabel(Text("Unlock", comment: "VoiceOver label of the submit button on the unlock island"))
    }
}

/// Side-to-side shake for a wrong password.
struct Shake: GeometryEffect {
    var travel: CGFloat
    var shakes: CGFloat
    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: travel * sin(shakes * .pi * 4), y: 0))
    }
}

// MARK: - Failed attempts

/// Shown once after unlocking when someone tried and failed while the screen was locked.
struct FailedAttemptsView: View {
    let attempts: [FailedAttempt]
    var onDone: () -> Void = {}

    private static let shown = 6

    var body: some View {
        GlassPanel(cornerRadius: 22) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.lock.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.orange)
                        .frame(width: 30)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(attempts.count) failed attempts while locked",
                             comment: "Title after unlocking; the number counts wrong passwords and unrecognized fingerprints")
                            .font(.system(size: 14, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Someone tried to unlock this Mac while you were away.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                VStack(spacing: 0) {
                    ForEach(Array(attempts.suffix(Self.shown).enumerated()), id: \.offset) { i, attempt in
                        if i > 0 { Divider().opacity(0.5) }
                        HStack(spacing: 10) {
                            Image(systemName: attempt.method == .password ? "key.fill" : "touchid")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 18)
                            (attempt.method == .password
                                 ? Text("Wrong password", comment: "Failed unlock attempt kind")
                                 : Text("Touch ID not recognized", comment: "Failed unlock attempt kind"))
                                .font(.system(size: 12.5))
                            Spacer(minLength: 8)
                            Text(attempt.date, format: .dateTime.hour().minute().second())
                                .font(.system(size: 12.5))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 7)
                    }
                }
                .padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.06)))
                if attempts.count > Self.shown {
                    Text("Earlier attempts: \(attempts.count - Self.shown)", comment: "Failed attempts list footer")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button {
                        onDone()
                    } label: {
                        Text("OK", comment: "Button: dismiss the failed attempts list").frame(minWidth: 52)
                    }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                }
            }
            .padding(18)
        }
        .frame(width: 380)
    }
}
