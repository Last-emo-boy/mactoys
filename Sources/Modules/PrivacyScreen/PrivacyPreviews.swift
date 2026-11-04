import AppKit
import CoreImage
import MacToysCore
import SwiftUI

// Preview scenes are rendered offscreen, where the window server's behind-window blur doesn't
// exist. They draw a sample desktop, blur it with Core Image and composite it through the same
// regions the live overlays compute (`WindowScene.focusHoles`, `visibleRegions`, `MaskPaths`).

// MARK: - Sample desktop

/// Apps drawn on the sample desktop.
enum MockApp: Int32 {
    case safari = 101, messages, mail, slack, notes, music

    var name: String {
        switch self {
        case .safari: "Safari"
        case .messages: "Messages"
        case .mail: "Mail"
        case .slack: "Slack"
        case .notes: "Notes"
        case .music: "Music"
        }
    }

    var symbol: String {
        switch self {
        case .safari: "safari.fill"
        case .messages: "message.fill"
        case .mail: "envelope.fill"
        case .slack: "number"
        case .notes: "note.text"
        case .music: "music.note"
        }
    }

    var color: Color {
        switch self {
        case .safari: Color(red: 0.1, green: 0.5, blue: 1)
        case .messages: Color(red: 0.2, green: 0.8, blue: 0.35)
        case .mail: Color(red: 0.15, green: 0.55, blue: 1)
        case .slack: Color(red: 0.29, green: 0.1, blue: 0.3)
        case .notes: Color(red: 1, green: 0.8, blue: 0.1)
        case .music: Color(red: 1, green: 0.22, blue: 0.35)
        }
    }

    /// A flat app icon for badges and islands.
    @MainActor var icon: NSImage {
        let view = RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(LinearGradient(colors: [color.opacity(0.85), color], startPoint: .top, endPoint: .bottom))
            .overlay(Image(systemName: symbol).font(.system(size: 30, weight: .semibold)).foregroundStyle(.white))
            .frame(width: 64, height: 64)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return renderer.nsImage ?? NSImage()
    }
}

/// One window of the sample desktop, global top-left coordinates.
struct MockWindowSpec {
    let app: MockApp
    let frame: CGRect
}

/// A sample desktop: windows front to back.
struct MockDesktop {
    var size = CGSize(width: 1280, height: 800)
    var windows: [MockWindowSpec]
    var menuBar = true
    var notch = true
    /// The app named in the menu bar.
    var frontApp: MockApp = .safari

    static let menuBarHeight: CGFloat = 32
    static let notchSize = CGSize(width: 184, height: 32)

    /// The window-server view of this desktop, for the real geometry functions.
    var scene: WindowScene {
        var samples = windows.enumerated().map { i, w in
            WindowSample(id: CGWindowID(i + 1), pid: w.app.rawValue, layer: 0, frame: w.frame)
        }
        if menuBar {
            samples.insert(WindowSample(id: 900, pid: 1, layer: 24, frame: CGRect(x: 0, y: 0, width: size.width, height: Self.menuBarHeight)), at: 0)
        }
        return WindowScene(windows: samples, frontPID: frontApp.rawValue)
    }

    func frame(of app: MockApp) -> CGRect { windows.first { $0.app == app }?.frame ?? .zero }

    /// The everyday desktop used by most scenes.
    static let standard = MockDesktop(windows: [
        MockWindowSpec(app: .safari, frame: CGRect(x: 330, y: 92, width: 640, height: 470)),
        MockWindowSpec(app: .messages, frame: CGRect(x: 40, y: 150, width: 520, height: 380)),
        MockWindowSpec(app: .slack, frame: CGRect(x: 800, y: 300, width: 440, height: 380)),
        MockWindowSpec(app: .mail, frame: CGRect(x: 760, y: 60, width: 480, height: 300)),
        MockWindowSpec(app: .notes, frame: CGRect(x: 90, y: 520, width: 360, height: 230)),
    ])
}

/// Colors of the sample windows in light or dark appearance.
struct MockPalette {
    let dark: Bool
    var window: Color { dark ? Color(white: 0.16) : .white }
    var chrome: Color { dark ? Color(white: 0.21) : Color(white: 0.955) }
    var sidebar: Color { dark ? Color(white: 0.19) : Color(white: 0.94) }
    var text: Color { dark ? .white.opacity(0.88) : .black.opacity(0.85) }
    var secondary: Color { dark ? .white.opacity(0.5) : .black.opacity(0.48) }
    var line: Color { dark ? .white.opacity(0.13) : .black.opacity(0.09) }
    var bubble: Color { dark ? Color(white: 0.27) : Color(white: 0.91) }
}

/// The design boards' wallpaper.
struct MockWallpaper: View {
    var body: some View {
        LinearGradient(colors: [Color(red: 0.09, green: 0.13, blue: 0.36), Color(red: 0.24, green: 0.17, blue: 0.56),
                                Color(red: 0.6, green: 0.25, blue: 0.53), Color(red: 0.88, green: 0.54, blue: 0.42)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// The sample desktop as a SwiftUI view (rendered once into an image).
struct MockDesktopView: View {
    let desktop: MockDesktop
    let dark: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            MockWallpaper()
            ForEach(Array(desktop.windows.enumerated().reversed()), id: \.offset) { _, w in
                MockAppWindow(app: w.app, palette: MockPalette(dark: dark))
                    .frame(width: w.frame.width, height: w.frame.height)
                    .offset(x: w.frame.minX, y: w.frame.minY)
            }
            if desktop.menuBar { MockMenuBar(app: desktop.frontApp, dark: dark, width: desktop.size.width) }
            if desktop.notch {
                UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12, style: .continuous)
                    .fill(.black)
                    .frame(width: MockDesktop.notchSize.width, height: MockDesktop.notchSize.height)
                    .offset(x: (desktop.size.width - MockDesktop.notchSize.width) / 2)
            }
        }
        .frame(width: desktop.size.width, height: desktop.size.height, alignment: .topLeading)
        .clipped()
    }
}

struct MockMenuBar: View {
    let app: MockApp
    let dark: Bool
    let width: CGFloat

    var body: some View {
        HStack(spacing: 20) {
            Image(systemName: "apple.logo").font(.system(size: 14, weight: .medium))
            Text(verbatim: app.name).font(.system(size: 13, weight: .bold))
            ForEach(["File", "Edit", "View", "History", "Window", "Help"], id: \.self) {
                Text(verbatim: $0).font(.system(size: 13))
            }
            Spacer()
            Image(systemName: "wifi").font(.system(size: 13, weight: .medium))
            Image(systemName: "battery.75percent").font(.system(size: 13))
            Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .medium))
            Text(PrivacyPreviews.sampleDate, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
                .font(.system(size: 13))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .frame(width: width, height: MockDesktop.menuBarHeight)
        .background(.black.opacity(0.18))
    }
}

/// A believable app window drawn in code.
struct MockAppWindow: View {
    let app: MockApp
    let palette: MockPalette

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                HStack(spacing: 7) {
                    ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18),
                             Color(red: 0.16, green: 0.79, blue: 0.25)], id: \.self) { Circle().fill($0).frame(width: 12, height: 12) }
                    Spacer()
                }
                Text(verbatim: title).font(.system(size: 13, weight: .semibold)).foregroundStyle(palette.text)
            }
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(palette.chrome)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(palette.window)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.3), radius: 22, y: 12)
    }

    private var title: String {
        switch app {
        case .safari: "Launch plan — Q4"
        case .messages: "Ava Chen"
        case .mail: "Inbox — 3 unread"
        case .slack: "#launch"
        case .notes: "Gift ideas"
        case .music: "Music"
        }
    }

    @ViewBuilder private var content: some View {
        switch app {
        case .safari: browser
        case .messages: messages
        case .mail: mail
        case .slack: chat
        case .notes: notes
        case .music: EmptyView()
        }
    }

    private func lines(_ widths: [CGFloat]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(widths.enumerated()), id: \.offset) { _, w in
                Capsule().fill(palette.line).frame(width: w, height: 7)
            }
        }
    }

    private var browser: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill").font(.system(size: 10))
                    Text(verbatim: "roadmap.northwind.app/q4")
                }
                .font(.system(size: 12))
                .foregroundStyle(palette.secondary)
                .padding(.horizontal, 14)
                .frame(height: 26)
                .background(Capsule().fill(palette.line))
                Spacer()
            }
            Text(verbatim: "Launch plan — Q4").font(.system(size: 26, weight: .bold)).foregroundStyle(palette.text)
            Text(verbatim: "Revenue target $4.2M · Ship date Dec 9 · Owner: Priya Raman")
                .font(.system(size: 13)).foregroundStyle(palette.secondary)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(["Pricing page goes live with annual plans", "Press embargo lifts at 9:00 PT",
                         "Support macros for the new billing flow", "Partner webinar with 1,200 sign-ups"], id: \.self) { item in
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(MockApp.safari.color)
                        Text(verbatim: item).font(.system(size: 13.5)).foregroundStyle(palette.text)
                    }
                }
            }
            lines([520, 470, 540, 300])
        }
        .padding(22)
    }

    private var messages: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach([("AC", "Ava Chen", "Booked the table for 7"), ("MR", "Mateo Ruiz", "Sent the contract"),
                         ("SK", "Sana Kapoor", "Call me when you can"), ("JL", "Jonas Lind", "😂 that slide")], id: \.0) { item in
                    HStack(spacing: 9) {
                        Circle().fill(LinearGradient(colors: [.gray.opacity(0.5), .gray], startPoint: .top, endPoint: .bottom))
                            .frame(width: 30, height: 30)
                            .overlay(Text(verbatim: item.0).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: item.1).font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.text)
                            Text(verbatim: item.2).font(.system(size: 11)).foregroundStyle(palette.secondary).lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                Spacer()
            }
            .frame(width: 190)
            .background(palette.sidebar)
            VStack(spacing: 10) {
                bubble("Are we still on for tonight?", mine: false)
                bubble("Yes! Booked the table for 7 at Nopa", mine: true)
                bubble("Perfect. I'll bring the gift 🎁", mine: false)
                bubble("Don't tell Sam 🤫", mine: true)
                Spacer()
            }
            .padding(14)
        }
    }

    private func bubble(_ text: String, mine: Bool) -> some View {
        HStack {
            if mine { Spacer(minLength: 30) }
            Text(verbatim: text)
                .font(.system(size: 12.5))
                .foregroundStyle(mine ? .white : palette.text)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(mine ? Color(red: 0.04, green: 0.52, blue: 1) : palette.bubble))
            if !mine { Spacer(minLength: 30) }
        }
    }

    private var mail: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach([("Northwind Bank", "Your statement is ready", "9:12 AM"),
                     ("Dr. Elena Ortiz", "Lab results — please review", "8:40 AM"),
                     ("Priya Raman", "Re: offer letter for Q4 hire", "Yesterday"),
                     ("Airline", "Boarding pass · SFO → JFK", "Yesterday")], id: \.0) { item in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(verbatim: item.0).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(palette.text)
                        Spacer()
                        Text(verbatim: item.2).font(.system(size: 11)).foregroundStyle(palette.secondary)
                    }
                    Text(verbatim: item.1).font(.system(size: 12)).foregroundStyle(palette.text.opacity(0.8))
                    Capsule().fill(palette.line).frame(width: 260, height: 6).padding(.top, 3)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                Divider().opacity(0.5)
            }
        }
    }

    private var chat: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(["general", "design", "launch", "random"], id: \.self) { ch in
                    Text(verbatim: "# \(ch)")
                        .font(.system(size: 12.5, weight: ch == "launch" ? .bold : .regular))
                        .foregroundStyle(.white.opacity(ch == "launch" ? 1 : 0.7))
                }
                Spacer()
            }
            .padding(14)
            .frame(width: 120)
            .frame(maxHeight: .infinity)
            .background(MockApp.slack.color)
            VStack(alignment: .leading, spacing: 14) {
                ForEach([("Priya", "Final pricing: $18/seat, annual -20%"), ("Mateo", "Legal approved the press release"),
                         ("Sana", "Stand-up moved to 10:30")], id: \.0) { item in
                    HStack(alignment: .top, spacing: 9) {
                        RoundedRectangle(cornerRadius: 6).fill(.orange.opacity(0.7)).frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: item.0).font(.system(size: 12, weight: .bold)).foregroundStyle(palette.text)
                            Text(verbatim: item.1).font(.system(size: 12)).foregroundStyle(palette.text.opacity(0.85))
                        }
                    }
                }
                Spacer()
            }
            .padding(14)
        }
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: "Gift ideas").font(.system(size: 17, weight: .bold)).foregroundStyle(palette.text)
            ForEach(["Mom — pottery class", "Sam — film camera", "Dad — record player"], id: \.self) {
                Text(verbatim: "• \($0)").font(.system(size: 12.5)).foregroundStyle(palette.text)
            }
            lines([220, 180])
        }
        .padding(16)
    }
}

// MARK: - Images

/// Renders, blurs and composites the sample desktop.
@MainActor
enum PreviewImages {
    static let scale: CGFloat = 2
    private static var cache: [String: CGImage] = [:]
    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func desktop(_ desktop: MockDesktop, dark: Bool, key: String) -> CGImage? {
        let id = "desk-\(key)-\(dark)"
        if let hit = cache[id] { return hit }
        let renderer = ImageRenderer(content: MockDesktopView(desktop: desktop, dark: dark))
        renderer.scale = scale
        let image = renderer.cgImage
        cache[id] = image
        return image
    }

    /// Gaussian blur (radius in points) with a wash, like the frost the window server draws.
    static func blurred(_ image: CGImage, radius: CGFloat, wash: Double, dark: Bool, key: String) -> CGImage? {
        let id = "blur-\(key)-\(radius)-\(wash)-\(dark)"
        if let hit = cache[id] { return hit }
        let input = CIImage(cgImage: image)
        let blurred = input.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius * scale])
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.35])
            .cropped(to: input.extent)
        let washColor = dark ? CIColor(red: 0, green: 0, blue: 0, alpha: wash) : CIColor(red: 1, green: 1, blue: 1, alpha: wash * 0.75)
        let tinted = CIImage(color: washColor).cropped(to: input.extent).composited(over: blurred)
        let out = context.createCGImage(tinted, from: input.extent)
        cache[id] = out
        return out
    }

    /// `base` with `overlay` drawn inside `region` (top-left points).
    static func composite(base: CGImage, overlay: CGImage, region: CGPath) -> CGImage? {
        let w = base.width, h = base.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let full = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.draw(base, in: full)
        var t = CGAffineTransform(a: scale, b: 0, c: 0, d: -scale, tx: 0, ty: CGFloat(h))
        guard let path = region.copy(using: &t) else { return base }
        ctx.addPath(path)
        ctx.clip()
        ctx.draw(overlay, in: full)
        return ctx.makeImage()
    }

    /// Blur radius (points) that stands in for a strength's stacked layers.
    static func radius(for strength: Double) -> CGFloat {
        let recipe = BlurRecipe.make(strength: strength)
        return CGFloat(14 + recipe.layers * 12) + CGFloat(strength) * 8
    }
}

/// A finished preview image.
struct PreviewImage: View {
    let image: CGImage?
    let size: CGSize

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: PreviewImages.scale).resizable()
            } else {
                MockWallpaper()
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

// MARK: - Lock screen composite

/// A whole lock screen: frosted (or solid) desktop, shield content and the island — used by the
/// preview scenes and, scaled down, by the settings illustration.
struct LockScreenComposite: View {
    let style: LockStyle
    var showClock = true
    var awayMessage: String?
    var unlock: UnlockModel
    var notch = true
    var date: Date = PrivacyPreviews.sampleDate
    var desktop = MockDesktop.standard

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let size = desktop.size
        var lockDesktop = desktop
        lockDesktop.menuBar = false
        lockDesktop.notch = notch
        let base = PreviewImages.desktop(lockDesktop, dark: colorScheme == .dark, key: "lock-\(notch)")
        let frosted = base.flatMap { PreviewImages.blurred($0, radius: 44, wash: 0.3, dark: true, key: "lock-\(notch)") }
        let shield = ShieldModel()
        shield.style = style
        shield.showClock = showClock
        shield.awayMessage = awayMessage
        shield.fixedDate = date
        let placed = IslandLayout.frame(content: IslandMetrics.content, screen: CGRect(origin: .zero, size: size),
                                        notchHeight: notch ? MockDesktop.notchSize.height : 0,
                                        leftOfNotch: notch ? CGRect(x: 0, y: size.height - 32, width: (size.width - MockDesktop.notchSize.width) / 2, height: 32) : nil,
                                        rightOfNotch: notch ? CGRect(x: (size.width + MockDesktop.notchSize.width) / 2, y: size.height - 32,
                                                                     width: (size.width - MockDesktop.notchSize.width) / 2, height: 32) : nil,
                                        topMargin: 14)
        shield.islandClearance = placed.frame.height
        return ZStack(alignment: .topLeading) {
            if style != .solid { PreviewImage(image: frosted, size: size) }
            LockShieldView(model: shield, drawsGlow: true)
                .frame(width: size.width, height: size.height)
            UnlockIslandView(model: unlock, notch: placed.notch, interactive: false)
                .frame(width: placed.frame.width, height: placed.frame.height)
                .offset(x: placed.frame.minX, y: size.height - placed.frame.maxY)
            if notch {
                // The notch itself, drawn over the island's top.
                UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12, style: .continuous)
                    .fill(.black)
                    .frame(width: MockDesktop.notchSize.width, height: MockDesktop.notchSize.height)
                    .offset(x: (size.width - MockDesktop.notchSize.width) / 2)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background(Color.black)
        .clipped()
    }
}

// MARK: - Scenes

@MainActor
enum PrivacyPreviews {
    static var sampleDate: Date {
        var c = DateComponents()
        c.year = 2026
        c.month = 11
        c.day = 4
        c.hour = 15
        c.minute = 41
        return Calendar.current.date(from: c) ?? Date()
    }

    static func unlockModel(_ configure: (UnlockModel) -> Void = { _ in }) -> UnlockModel {
        let m = UnlockModel()
        m.title = "Jordan Lee"
        m.offersBiometrics = true
        configure(m)
        return m
    }

    nonisolated static let size = CGSize(width: 1280, height: 800)

    static var scenes: [PreviewScene] {
        [
            scene("lock-frosted") {
                LockScreenComposite(style: .frosted, awayMessage: "Back at 3:30 — grabbing coffee", unlock: unlockModel())
            },
            scene("lock-ambient") {
                LockScreenComposite(style: .ambient, unlock: unlockModel())
            },
            scene("lock-solid") {
                LockScreenComposite(style: .solid, awayMessage: "In a meeting until 4", unlock: unlockModel { $0.offersBiometrics = false },
                                    notch: false)
            },
            scene("lock-wrong-password") {
                LockScreenComposite(style: .frosted, unlock: unlockModel {
                    $0.note = .wrongPassword
                    $0.phase = .waiting(until: Date().addingTimeInterval(8))
                })
            },
            scene("island", size: CGSize(width: 720, height: 220)) {
                LockScreenComposite(style: .frosted, unlock: unlockModel { $0.password = "hunter22" })
                    .offset(x: -280)
                    .frame(width: 720, height: 220, alignment: .topLeading)
                    .clipped()
            },
            scene("unlocked-attempts") { AttemptsScene() },
            scene("blur-screen") { BlurScreenScene() },
            scene("focus-blur") { FocusBlurScene() },
            scene("private-apps") { PrivateAppsScene() },
            scene("app-lock") { AppLockScene() },
        ]
    }

    /// A full-bleed scene: the scene draws its own desktop, so no wallpaper behind it.
    private static func scene<V: View>(_ name: String, size: CGSize = size, _ view: @escaping @MainActor () -> V) -> PreviewScene {
        PreviewScene(name, size: size, wallpaper: false) {
            AnyView(view().frame(width: size.width, height: size.height, alignment: .topLeading))
        }
    }

    static func attempts() -> [FailedAttempt] {
        let base = sampleDate
        return [FailedAttempt(date: base.addingTimeInterval(-38 * 60 + 7), method: .password),
                FailedAttempt(date: base.addingTimeInterval(-38 * 60 + 19), method: .password),
                FailedAttempt(date: base.addingTimeInterval(-37 * 60 + 2), method: .touchID),
                FailedAttempt(date: base.addingTimeInterval(-12 * 60 + 44), method: .password)]
    }
}

private struct AttemptsScene: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let desktop = MockDesktop.standard
        ZStack(alignment: .top) {
            PreviewImage(image: PreviewImages.desktop(desktop, dark: colorScheme == .dark, key: "std"), size: desktop.size)
            FailedAttemptsView(attempts: PrivacyPreviews.attempts())
                .padding(.top, MockDesktop.menuBarHeight + 14)
        }
        .frame(width: desktop.size.width, height: desktop.size.height)
    }
}

private struct BlurScreenScene: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let desktop = MockDesktop.standard
        let dark = colorScheme == .dark
        let strength = PrivacyScreenSettings().screenBlurStrength
        let base = PreviewImages.desktop(desktop, dark: dark, key: "std")
        let blurred = base.flatMap {
            PreviewImages.blurred($0, radius: PreviewImages.radius(for: strength), wash: BlurRecipe.make(strength: strength).wash,
                                  dark: dark, key: "screen")
        }
        return ZStack {
            PreviewImage(image: blurred, size: desktop.size)
            BlurHint(fades: false)
        }
        .frame(width: desktop.size.width, height: desktop.size.height)
    }
}

private struct FocusBlurScene: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let desktop = MockDesktop.standard
        let dark = colorScheme == .dark
        let strength = PrivacyScreenSettings().focusBlurStrength
        let base = PreviewImages.desktop(desktop, dark: dark, key: "std")
        let blurred = base.flatMap {
            PreviewImages.blurred($0, radius: PreviewImages.radius(for: strength), wash: BlurRecipe.make(strength: strength).wash,
                                  dark: dark, key: "focus")
        }
        // The same hole the live overlay cuts; the menu bar sits above the overlay.
        let holes = desktop.scene.focusHoles(overlayLevel: BlurLevels.window.rawValue)
        let below = CGRect(x: 0, y: MockDesktop.menuBarHeight, width: desktop.size.width,
                           height: desktop.size.height - MockDesktop.menuBarHeight)
        let region = MaskPaths.excluding(holes, from: below)
        let image = base.flatMap { b in blurred.flatMap { PreviewImages.composite(base: b, overlay: $0, region: region) } }
        return PreviewImage(image: image, size: desktop.size)
    }
}

private struct PrivateAppsScene: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let desktop = MockDesktop.standard
        let dark = colorScheme == .dark
        let strength = PrivacyScreenSettings().focusBlurStrength
        let base = PreviewImages.desktop(desktop, dark: dark, key: "std")
        let blurred = base.flatMap {
            PreviewImages.blurred($0, radius: PreviewImages.radius(for: strength), wash: BlurRecipe.make(strength: strength).wash,
                                  dark: dark, key: "private")
        }
        let privateApps: Set<Int32> = [MockApp.messages.rawValue, MockApp.mail.rawValue, MockApp.slack.rawValue]
        let regions = desktop.scene.visibleRegions(overlayLevel: BlurLevels.window.rawValue) { privateApps.contains($0) }
        // Slack is being peeked at with ⌥.
        let peeked = MockApp.slack.rawValue
        let path = CGMutablePath()
        for r in regions where r.window.pid != peeked { path.addPath(MaskPaths.visible(parts: r.parts, of: r.window.frame)) }
        let image = base.flatMap { b in blurred.flatMap { PreviewImages.composite(base: b, overlay: $0, region: path) } }
        let slack = desktop.frame(of: .slack)
        let pointer = CGPoint(x: slack.minX + 300, y: slack.minY + 250)
        return ZStack(alignment: .topLeading) {
            PreviewImage(image: image, size: desktop.size)
            PeekPointer()
                .offset(x: pointer.x, y: pointer.y)
        }
        .frame(width: desktop.size.width, height: desktop.size.height, alignment: .topLeading)
    }
}

/// The pointer with ⌥ held, peeking at a private app.
private struct PeekPointer: View {
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "cursorarrow")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(.black)
                .shadow(color: .white, radius: 0.5)
                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            Keycaps(["⌥"], dark: true)
                .padding(4)
                .background(Capsule().fill(.black.opacity(0.65)))
                .offset(y: 18)
        }
    }
}

private struct AppLockScene: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        var desktop = MockDesktop.standard
        desktop.frontApp = .messages
        if let i = desktop.windows.firstIndex(where: { $0.app == .messages }) {
            desktop.windows.insert(desktop.windows.remove(at: i), at: 0)
        }
        let dark = colorScheme == .dark
        let base = PreviewImages.desktop(desktop, dark: dark, key: "applock")
        let blurred = base.flatMap { PreviewImages.blurred($0, radius: 46, wash: 0.62, dark: true, key: "applock") }
        let regions = desktop.scene.visibleRegions(overlayLevel: BlurLevels.window.rawValue, skipFrontmost: false) {
            $0 == MockApp.messages.rawValue
        }
        let path = CGMutablePath()
        var badgeRect = CGRect.zero
        for r in regions {
            path.addPath(MaskPaths.visible(parts: r.parts, of: r.window.frame))
            if let largest = r.parts.max(by: { $0.width * $0.height < $1.width * $1.height }) { badgeRect = largest }
        }
        let image = base.flatMap { b in blurred.flatMap { PreviewImages.composite(base: b, overlay: $0, region: path) } }
        let unlock = PrivacyPreviews.unlockModel {
            $0.title = String(localized: "“\(MockApp.messages.name)” is locked", comment: "App Lock cover and unlock island title; the placeholder is the app's name")
            $0.appIcon = MockApp.messages.icon
            $0.canCancel = true
        }
        let size = desktop.size
        let placed = IslandLayout.frame(content: IslandMetrics.content, screen: CGRect(origin: .zero, size: size),
                                        notchHeight: MockDesktop.notchSize.height,
                                        leftOfNotch: CGRect(x: 0, y: size.height - 32, width: (size.width - MockDesktop.notchSize.width) / 2, height: 32),
                                        rightOfNotch: CGRect(x: (size.width + MockDesktop.notchSize.width) / 2, y: size.height - 32,
                                                             width: (size.width - MockDesktop.notchSize.width) / 2, height: 32))
        return ZStack(alignment: .topLeading) {
            PreviewImage(image: image, size: size)
            AppLockBadge(name: MockApp.messages.name, icon: MockApp.messages.icon)
                .frame(width: badgeRect.width, height: badgeRect.height)
                .offset(x: badgeRect.minX, y: badgeRect.minY)
            UnlockIslandView(model: unlock, notch: placed.notch, interactive: false)
                .frame(width: placed.frame.width, height: placed.frame.height)
                .offset(x: placed.frame.minX)
            UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12, style: .continuous)
                .fill(.black)
                .frame(width: MockDesktop.notchSize.width, height: MockDesktop.notchSize.height)
                .offset(x: (size.width - MockDesktop.notchSize.width) / 2)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}
