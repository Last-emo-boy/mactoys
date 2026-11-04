import MacToysCore
import SwiftUI

/// A mock window for preview scenes and the settings hero.
struct MockDimWindow: Identifiable {
    let id: CGWindowID
    let pid: pid_t
    /// Top-left coordinates in the scene.
    let frame: CGRect
    let content: AnyView
}

/// Stacks mock windows with the dimming overlay where `DimPlanner` puts it: the active window and
/// everything above it over the overlay, the rest under it, holes where windows stay bright.
struct DimmedStack: View {
    let size: CGSize
    /// Front to back.
    let windows: [MockDimWindow]
    let front: DimFrontApp
    let options: DimOptions
    let color: Color
    let alpha: Double
    /// Corner radius of the mock windows, for the holes.
    var windowRadius: CGFloat = 14

    var body: some View {
        let layout = Layout(size: size, windows: windows, front: front, options: options)
        ZStack(alignment: .topLeading) {
            ForEach(layout.below.reversed()) { place($0) }
            if let holes = layout.holes {
                HoleShape(holes: holes, radius: windowRadius)
                    .fill(color.opacity(alpha), style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)
            }
            ForEach(layout.above.reversed()) { place($0) }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private func place(_ w: MockDimWindow) -> some View {
        w.content
            .frame(width: w.frame.width, height: w.frame.height)
            .offset(x: w.frame.minX, y: w.frame.minY)
    }

    struct Layout {
        var below: [MockDimWindow] = []
        var above: [MockDimWindow] = []
        var holes: [DimHole]?

        init(size: CGSize, windows: [MockDimWindow], front: DimFrontApp, options: DimOptions) {
            let display = DimDisplay(id: 1, frame: CGRect(origin: .zero, size: size))
            let decision = DimPlanner.decide(windows: windows.map { DimWindow(id: $0.id, pid: $0.pid, frame: $0.frame) },
                                             front: front, displays: [display], options: options)
            guard case .dim(let plan) = decision else {
                below = windows
                return
            }
            holes = plan.holes[1] ?? []
            switch plan.placement {
            case .front:
                below = windows
            case .below(let id):
                let index = windows.firstIndex { $0.id == id } ?? -1
                above = Array(windows[...index])
                below = Array(windows[(index + 1)...])
            }
        }
    }
}

/// The scene rectangle with holes, as the overlay draws it; filled with the even-odd rule.
struct HoleShape: Shape {
    let holes: [DimHole]
    var radius = DimHole.windowRadius

    func path(in rect: CGRect) -> Path {
        Path(DimOverlayView.path(bounds: rect, holes: holes, cutOut: true, radius: radius))
    }
}

// MARK: - Desktop scene

/// Snapshot scene: a desktop with three windows dimmed around the one being edited, the menu bar
/// and Dock untouched above the dim.
struct DimDesktopPreview: View {
    let dark: Bool
    let intensity: Double
    var appMode = false

    var body: some View {
        let windows = [
            MockDimWindow(id: 3, pid: 30, frame: CGRect(x: 386, y: 150, width: 560, height: 470),
                          content: AnyView(NotesWindow(dark: dark))),
            MockDimWindow(id: 2, pid: appMode ? 30 : 20, frame: CGRect(x: 690, y: 92, width: 520, height: 430),
                          content: AnyView(appMode ? AnyView(NotesListWindow(dark: dark)) : AnyView(BrowserWindow(dark: dark)))),
            MockDimWindow(id: 1, pid: 10, frame: CGRect(x: 60, y: 76, width: 590, height: 420),
                          content: AnyView(MailWindow(dark: dark))),
            MockDimWindow(id: 4, pid: 40, frame: CGRect(x: 120, y: 470, width: 430, height: 250),
                          content: AnyView(MusicWindow(dark: dark))),
        ]
        // Full bleed: the menu bar sits at the very top and the dim covers the whole screen.
        GeometryReader { geo in
            ZStack(alignment: .top) {
                DesktopWallpaper(dark: dark)
                DimmedStack(size: geo.size, windows: windows,
                            front: DimFrontApp(pid: 30, focus: .window(3)),
                            options: DimOptions(highlight: appMode ? .frontApp : .frontWindow, onlyWithOtherWindows: true),
                            color: .black, alpha: DimIntensity.alpha(intensity / 100))
                MenuBarStrip(dark: dark, app: "Notes")
                VStack { Spacer(); DockStrip(dark: dark).padding(.bottom, 8) }
            }
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, dark ? .dark : .light)
    }
}

struct DesktopWallpaper: View {
    let dark: Bool

    var body: some View {
        if dark {
            LinearGradient(colors: [Color(red: 0.05, green: 0.08, blue: 0.22), Color(red: 0.16, green: 0.12, blue: 0.38),
                                    Color(red: 0.42, green: 0.18, blue: 0.42), Color(red: 0.62, green: 0.32, blue: 0.34)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        } else {
            LinearGradient(colors: [Color(red: 0.55, green: 0.74, blue: 0.95), Color(red: 0.62, green: 0.66, blue: 0.95),
                                    Color(red: 0.92, green: 0.68, blue: 0.82), Color(red: 0.99, green: 0.83, blue: 0.68)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

private struct MenuBarStrip: View {
    let dark: Bool
    let app: String

    var body: some View {
        HStack(spacing: 20) {
            Image(systemName: "applelogo").font(.system(size: 14, weight: .semibold))
            Text(verbatim: app).font(.system(size: 13, weight: .bold))
            ForEach(["File", "Edit", "Format", "View", "Window", "Help"], id: \.self) {
                Text(verbatim: $0).font(.system(size: 13))
            }
            Spacer()
            Image(systemName: "moon.haze.fill").font(.system(size: 13))
            Image(systemName: "wifi").font(.system(size: 13))
            Image(systemName: "battery.75percent").font(.system(size: 15))
            Text(verbatim: PreviewScene.menuBarClock(hour: 10, minute: 41)).font(.system(size: 13, weight: .medium)).monospacedDigit()
        }
        .foregroundStyle(dark ? Color.white : Color.black.opacity(0.85))
        .padding(.horizontal, 18)
        .frame(height: 30)
        .background(dark ? Color.black.opacity(0.18) : Color.white.opacity(0.28))
    }
}

private struct DockStrip: View {
    let dark: Bool

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Self.apps, id: \.0) { symbol, tint in
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(tint.gradient)
                    .frame(width: 50, height: 50)
                    .overlay(Image(systemName: symbol).font(.system(size: 22, weight: .semibold)).foregroundStyle(.white))
                    .shadow(color: .black.opacity(0.18), radius: 3, y: 2)
            }
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(dark ? Color.white.opacity(0.12) : Color.white.opacity(0.35)))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(dark ? 0.15 : 0.5)))
    }

    static let apps: [(String, Tint)] = [
        ("face.smiling", .blue), ("safari.fill", .cyan), ("envelope.fill", .blue), ("note.text", .yellow),
        ("music.note", .pink), ("calendar", .red), ("photo.fill", .orange), ("gearshape.fill", .graphite),
    ]
}

// MARK: - Mock app windows

/// Title bar and body of a mock window, in the light or dark appearance.
struct MockChrome<Content: View>: View {
    let dark: Bool
    let title: String
    var toolbarHeight: CGFloat = 46
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                HStack(spacing: 8) {
                    ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18),
                             Color(red: 0.16, green: 0.79, blue: 0.25)], id: \.self) { Circle().fill($0).frame(width: 12, height: 12) }
                    Spacer()
                }
                Text(verbatim: title).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MockPalette.primary(dark))
            }
            .padding(.horizontal, 16)
            .frame(height: toolbarHeight)
            .background(MockPalette.bar(dark))
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(MockPalette.body(dark))
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.black.opacity(dark ? 0.6 : 0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(dark ? 0.5 : 0.22), radius: 24, y: 12)
    }
}

enum MockPalette {
    static func primary(_ dark: Bool) -> Color { dark ? .white.opacity(0.92) : .black.opacity(0.85) }
    static func secondary(_ dark: Bool) -> Color { dark ? .white.opacity(0.55) : .black.opacity(0.5) }
    static func bar(_ dark: Bool) -> Color { dark ? Color(white: 0.2) : Color(white: 0.965) }
    static func body(_ dark: Bool) -> Color { dark ? Color(white: 0.13) : .white }
    static func sidebar(_ dark: Bool) -> Color { dark ? Color(white: 0.17) : Color(white: 0.94) }
    static func line(_ dark: Bool) -> Color { dark ? .white.opacity(0.08) : .black.opacity(0.07) }
}

private struct NotesWindow: View {
    let dark: Bool

    var body: some View {
        MockChrome(dark: dark, title: "Offsite plan — Lisbon") {
            VStack(alignment: .leading, spacing: 12) {
                Text(verbatim: "Offsite plan — Lisbon").font(.system(size: 24, weight: .bold))
                Text(verbatim: "Thursday 19 – Saturday 21 November").font(.system(size: 13, weight: .medium))
                    .foregroundStyle(MockPalette.secondary(dark))
                Text(verbatim: "Goals").font(.system(size: 15, weight: .semibold)).padding(.top, 4)
                VStack(alignment: .leading, spacing: 7) {
                    bullet("Agree on the Q1 roadmap and owners")
                    bullet("Two half-days of uninterrupted design work")
                    bullet("One evening off the clock — dinner in Alfama")
                }
                Text(verbatim: "Venue").font(.system(size: 15, weight: .semibold)).padding(.top, 4)
                Text(verbatim: "LX Factory has a 30-seat room with daylight and a terrace. Lena is holding it until Friday; we need a headcount by then.")
                    .font(.system(size: 13)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 0) {
                    Text(verbatim: "Budget: €14,200 for 24 people").font(.system(size: 13))
                    Rectangle().fill(Color.accentColor).frame(width: 2, height: 17).padding(.leading, 1)
                }
            }
            .foregroundStyle(MockPalette.primary(dark))
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(Color.yellow).frame(width: 6, height: 6).offset(y: -2)
            Text(verbatim: text).font(.system(size: 13))
        }
    }
}

private struct NotesListWindow: View {
    let dark: Bool

    var body: some View {
        MockChrome(dark: dark, title: "Notes") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(Self.notes.enumerated()), id: \.offset) { i, note in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: note.0).font(.system(size: 13, weight: .semibold))
                        Text(verbatim: note.1).font(.system(size: 12)).foregroundStyle(MockPalette.secondary(dark)).lineLimit(1)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(i == 0 ? Color.yellow.opacity(dark ? 0.28 : 0.35) : .clear)
                    Rectangle().fill(MockPalette.line(dark)).frame(height: 1).padding(.leading, 18)
                }
            }
            .foregroundStyle(MockPalette.primary(dark))
        }
    }

    static let notes = [
        ("Offsite plan — Lisbon", "10:38  Thursday 19 – Saturday 21 November"),
        ("Reading list", "Yesterday  The Design of Everyday Things, ch. 4"),
        ("Grocery run", "Monday  Oat milk, lemons, basil, sourdough"),
        ("Interview questions", "Monday  Tell me about a time you changed your mind"),
        ("Bike service", "2 Nov  Rear brake pads, chain wear 0.5"),
        ("Gift ideas", "28 Oct  Film camera for Ana, ceramic course"),
    ]
}

private struct MailWindow: View {
    let dark: Bool

    var body: some View {
        MockChrome(dark: dark, title: "Inbox — 3 unread") {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(["tray.fill|Inbox", "star|VIP", "paperplane|Sent", "doc|Drafts", "archivebox|Archive"], id: \.self) { item in
                        let parts = item.split(separator: "|").map(String.init)
                        HStack(spacing: 8) {
                            Image(systemName: parts[0]).font(.system(size: 12)).foregroundStyle(Color.accentColor).frame(width: 16)
                            Text(verbatim: parts[1]).font(.system(size: 12.5))
                        }
                    }
                    Spacer()
                }
                .padding(14)
                .frame(width: 140)
                .frame(maxHeight: .infinity)
                .background(MockPalette.sidebar(dark))
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(Self.messages.enumerated()), id: \.offset) { i, m in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(verbatim: m.0).font(.system(size: 13, weight: .semibold))
                                Spacer()
                                Text(verbatim: m.3).font(.system(size: 11)).foregroundStyle(MockPalette.secondary(dark))
                            }
                            Text(verbatim: m.1).font(.system(size: 12.5))
                            Text(verbatim: m.2).font(.system(size: 12)).foregroundStyle(MockPalette.secondary(dark)).lineLimit(1)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(i == 0 ? Color.accentColor.opacity(0.14) : .clear)
                        Rectangle().fill(MockPalette.line(dark)).frame(height: 1)
                    }
                    Spacer(minLength: 0)
                }
            }
            .foregroundStyle(MockPalette.primary(dark))
        }
    }

    static let messages = [
        ("Lena Fischer", "Venue options for the offsite", "I've shortlisted three places near the river…", "10:12"),
        ("Ana Souza", "Revised budget (Q4)", "Attached the updated sheet with travel included.", "09:47"),
        ("Build Bot", "Nightly build passed", "All 653 tests green on main in 6 min 12 s.", "07:03"),
        ("Kenji Watanabe", "Re: Tokyo trip photos", "Uploaded the full set to the shared album.", "Yesterday"),
        ("Marta Rossi", "Coffee next week?", "Tuesday or Thursday afternoon works for me.", "Yesterday"),
    ]
}

private struct BrowserWindow: View {
    let dark: Bool

    var body: some View {
        MockChrome(dark: dark, title: "") {
            VStack(alignment: .leading, spacing: 12) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.2, green: 0.55, blue: 0.75), Color(red: 0.95, green: 0.7, blue: 0.45)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(height: 150)
                    .overlay(alignment: .bottomLeading) {
                        Text(verbatim: "A weekend in Lisbon").font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
                            .padding(14)
                    }
                Text(verbatim: "Trams, tiles and the best pastel de nata").font(.system(size: 15, weight: .semibold))
                Text(verbatim: "Start early in Alfama before the crowds, take tram 28 up to Graça for the view, and leave the afternoon for Belém.")
                    .font(.system(size: 12.5)).foregroundStyle(MockPalette.secondary(dark)).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(MockPalette.primary(dark))
            .padding(18)
        }
        .overlay(alignment: .top) {
            HStack(spacing: 6) {
                Image(systemName: "lock.fill").font(.system(size: 10))
                Text(verbatim: "travelnotes.example/lisbon").font(.system(size: 12))
            }
            .foregroundStyle(MockPalette.secondary(dark))
            .padding(.horizontal, 14)
            .frame(height: 26)
            .background(Capsule().fill(dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05)))
            .padding(.top, 10)
        }
    }
}

private struct MusicWindow: View {
    let dark: Bool

    var body: some View {
        MockChrome(dark: dark, title: "Music", toolbarHeight: 38) {
            HStack(spacing: 16) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.98, green: 0.36, blue: 0.45), Color(red: 0.55, green: 0.2, blue: 0.85)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 120, height: 120)
                    .overlay(Image(systemName: "music.note").font(.system(size: 40, weight: .semibold)).foregroundStyle(.white))
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: "Maré Alta").font(.system(size: 15, weight: .semibold))
                    Text(verbatim: "Lua Nova · Lisbon Sessions").font(.system(size: 12.5)).foregroundStyle(MockPalette.secondary(dark))
                    HStack(spacing: 22) {
                        Image(systemName: "backward.fill")
                        Image(systemName: "pause.fill").font(.system(size: 22))
                        Image(systemName: "forward.fill")
                    }
                    .padding(.top, 8)
                    Capsule().fill(MockPalette.line(dark)).frame(height: 4)
                        .overlay(alignment: .leading) { Capsule().fill(MockPalette.secondary(dark)).frame(width: 90, height: 4) }
                        .padding(.top, 6)
                }
            }
            .foregroundStyle(MockPalette.primary(dark))
            .padding(20)
        }
    }
}
