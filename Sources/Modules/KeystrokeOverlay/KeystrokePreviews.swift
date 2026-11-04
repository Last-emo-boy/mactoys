import MacToysCore
import SwiftUI

/// Snapshot scenes: the pill over an app window in each mode, the theme and size variants, clicks and
/// the privacy notice, the drag-to-place editor, and the settings hero. Sample data stays verbatim.
@MainActor
enum KeystrokePreviews {
    static func scenes(settings: Persisted<KeystrokeSettings>) -> [PreviewScene] {
        [
            PreviewScene("shortcuts", size: CGSize(width: 1280, height: 720), wallpaper: false) {
                var feed = KeystrokeFeed(maxItems: 4)
                feed.add(keys: ["⌘", "T"], name: "New Tab")
                feed.add(keys: ["⌘", "L"], name: "Open Location…")
                for _ in 0..<3 { feed.add(keys: ["⇧", "⌘", "]"], name: "Show Next Tab") }
                return AnyView(OverlayScene(feed: feed, theme: .glass, size: .medium))
            },
            PreviewScene("typed", size: CGSize(width: 1280, height: 720), wallpaper: false) {
                var feed = KeystrokeFeed(maxItems: 4, maxText: 40)
                feed.add(keys: ["⌘", "N"], name: "New Message")
                feed.type("Dinner on Friday? I booked us a table")
                feed.add(keys: ["⇧", "⌘", "D"], name: "Send")
                return AnyView(OverlayScene(feed: feed, theme: .glass, size: .medium))
            },
            PreviewScene("variants", size: CGSize(width: 1280, height: 720), wallpaper: false) { AnyView(VariantsScene()) },
            PreviewScene("clicks", size: CGSize(width: 1280, height: 720), wallpaper: false) {
                var feed = KeystrokeFeed(maxItems: 4)
                feed.click(.init(.left, modifiers: ["⌘"]))
                feed.click(.init(.left))
                feed.click(.init(.left, count: 2))
                feed.add(keys: ["⌥", "⌘", "I"], name: "Show Inspector")
                feed.hidden()
                return AnyView(OverlayScene(feed: feed, theme: .dark, size: .medium))
            },
            PreviewScene("position", size: CGSize(width: 1280, height: 720), wallpaper: false) { [settings] in
                var s = settings.value
                s.theme = .glass
                s.size = .large
                return AnyView(ZStack {
                    KeystrokeWallpaper()
                    BackdropWindow().frame(width: 760, height: 470).offset(y: -10)
                    PositionEditorView(settings: s, start: CGPoint(x: 0.7, y: 0.74), onDone: { _ in }, onCancel: {})
                }
                .ignoresSafeArea())
            },
            PreviewScene("hero", size: CGSize(width: 760, height: 270), wallpaper: false) { [settings] in
                AnyView(KeystrokeHero(settings: settings.value, toggle: {}).padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .ignoresSafeArea())
            },
        ]
    }
}

/// A window behind the pill, so glass has something to show through.
private struct OverlayScene: View {
    let feed: KeystrokeFeed
    let theme: KeystrokeSettings.Theme
    let size: KeystrokeSettings.Size

    var body: some View {
        ZStack {
            KeystrokeWallpaper()
            BackdropWindow().frame(width: 900, height: 540).offset(y: -40)
            KeystrokePill(items: feed.items, style: PillStyle(theme: theme, size: size))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 56)
        }
        .ignoresSafeArea()
    }
}

/// Each theme in a different size, captioned, on the wallpaper.
private struct VariantsScene: View {
    var body: some View {
        ZStack {
            KeystrokeWallpaper()
            VStack(spacing: 34) {
                pill(.glass, .extraLarge) { $0.add(keys: ["⌘", "Z"], name: "Undo") }
                pill(.dark, .large) {
                    $0.add(keys: ["⌥", "⌘", "←"], name: "Previous Tab")
                    $0.add(keys: ["esc"])
                }
                pill(.light, .medium) {
                    $0.add(keys: ["⌃", "⌘", "F"], name: "Enter Full Screen")
                    $0.add(keys: ["F5"])
                    $0.add(keys: ["⌘", "+"], name: "Zoom In")
                }
                pill(.glass, .small) {
                    $0.add(keys: ["⇧", "⌘", "4"])
                    $0.add(keys: ["Space"])
                    $0.add(keys: ["⌘", "Q"], name: "Quit Preview")
                    $0.add(keys: ["⌥"])
                }
            }
        }
        .ignoresSafeArea()
    }

    private func pill(_ theme: KeystrokeSettings.Theme, _ size: KeystrokeSettings.Size,
                      _ fill: (inout KeystrokeFeed) -> Void) -> some View {
        var feed = KeystrokeFeed(maxItems: 5)
        fill(&feed)
        return VStack(spacing: 10) {
            Text(verbatim: "\(theme.title) · \(size.title)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
            KeystrokePill(items: feed.items, style: PillStyle(theme: theme, size: size))
        }
    }
}

/// A code editor window, dark.
private struct BackdropWindow: View {
    private static let code: [(String, Color)] = [
        ("import SwiftUI", .pink), ("", .clear), ("struct TripPlanner: View {", .white),
        ("    @State private var stops: [Stop] = Stop.lisbon", .cyan), ("    @State private var day = 1", .cyan), ("", .clear),
        ("    var body: some View {", .white), ("        NavigationStack {", .white),
        ("            List(stops.filter { $0.day == day }) { stop in", .white),
        ("                StopRow(stop: stop)", .mint), ("            }", .white),
        ("            .navigationTitle(\"Day \\(day)\")", .orange), ("        }", .white), ("    }", .white), ("}", .white),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18),
                         Color(red: 0.16, green: 0.79, blue: 0.25)], id: \.self) { Circle().fill($0).frame(width: 12, height: 12) }
                Spacer()
                Text(verbatim: "TripPlanner.swift").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
                Spacer()
                Color.clear.frame(width: 52)
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background(Color(white: 0.17))
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .trailing, spacing: 6) {
                    ForEach(1...Self.code.count, id: \.self) { Text(verbatim: "\($0)").foregroundStyle(.white.opacity(0.3)) }
                }
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(Self.code.enumerated()), id: \.offset) { _, line in
                        Text(verbatim: line.0.isEmpty ? " " : line.0).foregroundStyle(line.1.opacity(0.85))
                    }
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 14, design: .monospaced))
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(white: 0.11))
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.1)))
        .shadow(color: .black.opacity(0.45), radius: 30, y: 14)
    }
}
