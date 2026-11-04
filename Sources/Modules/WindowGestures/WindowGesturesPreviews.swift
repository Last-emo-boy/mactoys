import MacToysCore
import SwiftUI

/// Offscreen previews: a swipe to the left half with its live preview, the thirds and quarters
/// grids, the pinch-to-close confirmation, a Dock swipe, a move Auto Tiling declined, the
/// cheat sheet, and the settings hero on its own.
@MainActor
enum WindowGesturesPreviews {
    static let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    /// Below the menu bar, above the Dock.
    static let work = CGRect(x: 0, y: 25, width: 1440, height: 800)

    static func scenes(_ settings: WindowGesturesSettings) -> [PreviewScene] {
        [
            PreviewScene("swipe-half", size: screen.size) { AnyView(swipeHalf) },
            PreviewScene("thirds", size: screen.size) { AnyView(thirds) },
            PreviewScene("quarters", size: screen.size) { AnyView(quarters) },
            PreviewScene("pinch-close", size: screen.size) { AnyView(pinchClose) },
            PreviewScene("dock", size: screen.size) { AnyView(dock) },
            PreviewScene("auto-tiling", size: CGSize(width: 1440, height: 900)) { AnyView(autoTiling) },
            PreviewScene("cheat-sheet", size: CGSize(width: 1100, height: 720)) {
                AnyView(CheatSheetView(entries: GestureCatalog.entries(WindowGesturesSettings()), onSettings: {})
                    .frame(width: 860).fixedSize(horizontal: false, vertical: true))
            },
            PreviewScene("hero", size: CGSize(width: 860, height: 240), wallpaper: false) {
                AnyView(GestureHero(settings: settings).padding(24))
            },
        ]
    }

    // MARK: Scenes

    /// Swiping left on a Safari title bar: the left half lights up before the fingers lift.
    static var swipeHalf: some View {
        let window = CGRect(x: 380, y: 150, width: 820, height: 560)
        let tile = Tile.half(.left)
        return Desktop {
            SampleWindow(kind: .notes).frame(width: 560, height: 420).offset(x: 820, y: 330)
            SampleWindow(kind: .browser).frame(width: window.width, height: window.height).offset(x: window.minX, y: window.minY)
            TargetPreviewView(target: tile.frame(in: work), title: tile.title, tile: tile, symbol: nil,
                              cells: tile.cells(in: work))
            Pointer().offset(x: window.midX + 40, y: window.minY + 22)
        }
    }

    /// A window in the left third, swiped right: it slides to the center third.
    static var thirds: some View {
        let left = Tile(columns: 3, column: 0), center = Tile(columns: 3, column: 1)
        let from = left.frame(in: work)
        return Desktop {
            SampleWindow(kind: .notes).frame(width: 470, height: 800).offset(x: 970, y: 25)
            SampleWindow(kind: .browser).frame(width: from.width, height: from.height).offset(x: from.minX, y: from.minY)
            TargetPreviewView(target: center.frame(in: work), title: center.title, tile: center, symbol: nil,
                              cells: center.cells(in: work))
            Pointer().offset(x: from.midX + 60, y: from.minY + 22)
        }
    }

    /// A swipe right, then up: the top right quarter, with the 2 × 2 grid behind it.
    static var quarters: some View {
        let window = CGRect(x: 520, y: 260, width: 700, height: 480)
        let tile = Tile.quarter(.right, top: true)
        return Desktop(app: .notes) {
            SampleWindow(kind: .browser).frame(width: 720, height: 800).offset(x: 0, y: 25)
            SampleWindow(kind: .notes).frame(width: window.width, height: window.height).offset(x: window.minX, y: window.minY)
            TargetPreviewView(target: tile.frame(in: work), title: tile.title, tile: tile, symbol: nil,
                              cells: tile.cells(in: work))
            Pointer().offset(x: window.midX - 30, y: window.minY + 20)
        }
    }

    /// Pinching in on a title bar: the ring fills while the pinch is held.
    static var pinchClose: some View {
        let window = CGRect(x: 300, y: 130, width: 840, height: 600)
        return Desktop(app: .notes) {
            SampleWindow(kind: .notes, title: "Project Brief").frame(width: window.width, height: window.height)
                .offset(x: window.minX, y: window.minY)
            OverlayModelPreview(content: .confirm(center: window.center, armed: false, quitting: false, name: "Project Brief"),
                                progress: 0.72)
            Pointer().offset(x: window.midX + 80, y: window.minY + 20)
        }
    }

    /// Swiping up on a Dock icon brings the app's windows forward.
    static var dock: some View {
        Desktop(app: .notes, dockHighlight: 2) {
            SampleWindow(kind: .notes).frame(width: 700, height: 480).offset(x: 160, y: 120)
            OverlayModelPreview(content: .badge(center: CGPoint(x: SampleDock.iconCenter(2).x, y: SampleDock.top - 34),
                                                title: GestureTitles.dock(.show, app: "Safari", settings: WindowGesturesSettings()),
                                                symbol: "macwindow.on.rectangle"), progress: 0)
            Pointer().offset(x: SampleDock.iconCenter(2).x - 4, y: SampleDock.iconCenter(2).y - 6)
        }
    }

    /// On a display Auto Tiling arranges, a move becomes a note instead.
    static var autoTiling: some View {
        let left = Tile.half(.left).frame(in: work, gap: 8), right = Tile.half(.right).frame(in: work, gap: 8)
        return Desktop(app: .notes) {
            SampleWindow(kind: .browser).frame(width: left.width, height: left.height).offset(x: left.minX, y: left.minY)
            SampleWindow(kind: .notes).frame(width: right.width, height: right.height).offset(x: right.minX, y: right.minY)
            OverlayModelPreview(content: .badge(center: right.center, title: String(localized: "Auto Tiling arranges this display"),
                                                symbol: "rectangle.split.2x2"), progress: 0)
            Pointer().offset(x: right.midX + 30, y: right.minY + 22)
        }
    }
}

/// Renders overlay content through the real overlay view.
private struct OverlayModelPreview: View {
    @State private var model: OverlayModel

    init(content: OverlayContent, progress: Double) {
        let m = OverlayModel()
        m.content = content
        m.progress = progress
        _model = State(initialValue: m)
    }

    var body: some View { OverlayContentView(model: model) }
}

/// A 1440 × 900 desktop: wallpaper (drawn by the snapshot renderer), the menu bar of the front
/// app and the Dock. The content (windows, then the overlay and the pointer) is drawn last: the
/// sample windows stay clear of the menu bar and Dock, and the overlay and pointer sit above both.
private struct Desktop<Content: View>: View {
    var app = SampleWindow.Kind.browser
    var dockHighlight: Int?
    @ViewBuilder let content: Content

    var body: some View {
        ZStack(alignment: .topLeading) {
            MenuBarStrip(app: app)
            SampleDock(highlight: dockHighlight)
            content
        }
        .frame(width: 1440, height: 900, alignment: .topLeading)
    }
}

private struct MenuBarStrip: View {
    let app: SampleWindow.Kind

    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: "apple.logo").font(.system(size: 13))
            Text(verbatim: app == .browser ? "Safari" : "Notes").font(.system(size: 13, weight: .bold))
            ForEach(app == .browser ? ["File", "Edit", "View", "History", "Bookmarks", "Window", "Help"]
                        : ["File", "Edit", "Format", "View", "Window", "Help"], id: \.self) {
                Text(verbatim: $0).font(.system(size: 13))
            }
            Spacer()
            Image(systemName: "wifi").font(.system(size: 12, weight: .medium))
            Image(systemName: "battery.75percent").font(.system(size: 13))
            Text(verbatim: PreviewScene.menuBarClock(hour: 9, minute: 41)).font(.system(size: 13, weight: .medium))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .frame(width: 1440, height: 25)
        .background(.black.opacity(0.08))
    }
}

/// A Dock with plain app tiles (no real app icons).
private struct SampleDock: View {
    let highlight: Int?
    static let apps: [(String, Tint)] = [("face.smiling", .blue), ("envelope.fill", .blue), ("safari.fill", .cyan),
                                         ("message.fill", .green), ("calendar", .red), ("note.text", .yellow),
                                         ("music.note", .pink), ("photo.on.rectangle", .orange), ("gearshape.fill", .graphite)]
    static let icon: CGFloat = 52, spacing: CGFloat = 10, padding: CGFloat = 8
    static var width: CGFloat { CGFloat(apps.count) * icon + CGFloat(apps.count - 1) * spacing + 2 * padding }
    static let top: CGFloat = 900 - 6 - icon - 2 * padding

    static func iconCenter(_ i: Int) -> CGPoint {
        let x0 = (1440 - width) / 2 + padding
        return CGPoint(x: x0 + CGFloat(i) * (icon + spacing) + icon / 2, y: top + padding + icon / 2)
    }

    var body: some View {
        HStack(spacing: Self.spacing) {
            ForEach(Array(Self.apps.enumerated()), id: \.offset) { i, app in
                ModuleIcon(symbol: app.0, tint: app.1, size: Self.icon)
                    .overlay(alignment: .bottom) {
                        if [0, 1, 2, 3].contains(i) {
                            Circle().fill(.white.opacity(0.8)).frame(width: 4, height: 4).offset(y: 7)
                        }
                    }
                    .scaleEffect(i == highlight ? 1.08 : 1, anchor: .bottom)
            }
        }
        .padding(Self.padding)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.white.opacity(0.12)))
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.2)))
        .offset(x: (1440 - Self.width) / 2, y: Self.top)
    }
}

/// A believable app window: unified toolbar, sidebar or tab bar, text.
private struct SampleWindow: View {
    enum Kind { case browser, notes }
    let kind: Kind
    var title: String?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.32), radius: 28, y: 14)
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0.opacity(0.9)).frame(width: 12, height: 12) }
            }
            switch kind {
            case .browser:
                Image(systemName: "sidebar.left").foregroundStyle(.secondary)
                Image(systemName: "chevron.left").foregroundStyle(.secondary)
                Spacer(minLength: 20)
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill").font(.system(size: 10))
                    Text(verbatim: "developer.apple.com").font(.system(size: 13))
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: 360)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
                Spacer(minLength: 20)
                Image(systemName: "square.and.arrow.up").foregroundStyle(.secondary)
                Image(systemName: "plus").foregroundStyle(.secondary)
            case .notes:
                Text(verbatim: title ?? "Trip to Kyoto").font(.system(size: 13, weight: .semibold))
                Spacer()
                Image(systemName: "square.and.pencil").foregroundStyle(.secondary)
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 14))
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder private var content: some View {
        switch kind {
        case .browser:
            VStack(alignment: .leading, spacing: 16) {
                Text(verbatim: "Designing with Glass").font(.system(size: 30, weight: .bold))
                Text(verbatim: "How light, depth and motion help a window feel at home on the desktop.")
                    .font(.system(size: 15)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: [Tint.cyan.color.opacity(0.5), Tint.indigo.color.opacity(0.45)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(height: 180)
                ForEach(0..<5, id: \.self) { i in
                    Capsule().fill(Color.primary.opacity(0.08)).frame(height: 9).frame(maxWidth: i == 4 ? 220 : .infinity)
                }
            }
            .padding(28)
        case .notes:
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(["Trip to Kyoto", "Project Brief", "Groceries", "Reading list", "Ideas"], id: \.self) { note in
                        let selected = note == (title ?? "Trip to Kyoto")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: note).font(.system(size: 13, weight: .semibold))
                            Text(verbatim: "Yesterday").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(selected ? Color.yellow.opacity(0.28) : .clear))
                    }
                    Spacer()
                }
                .padding(10)
                .frame(width: 200)
                .background(Color.primary.opacity(0.03))
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text(verbatim: title ?? "Trip to Kyoto").font(.system(size: 22, weight: .bold))
                    ForEach(title == "Project Brief"
                                ? ["Outline the three launch milestones", "Collect screenshots for the review",
                                   "Share the draft with design", "Final read-through on Friday"]
                                : ["Fushimi Inari at sunrise, before the crowds", "Lunch at Nishiki Market",
                                   "Philosopher's Path → Ginkaku-ji", "Book the ryokan in Arashiyama"], id: \.self) { item in
                        Label { Text(verbatim: item) } icon: { Image(systemName: "circle") }
                            .font(.system(size: 14))
                    }
                    Spacer()
                }
                .padding(24)
            }
        }
    }
}

/// The system pointer: a black arrow with a white rim.
private struct Pointer: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<4, id: \.self) { i in
                Image(systemName: "cursorarrow").foregroundStyle(.white)
                    .offset(x: [-1.5, 1.5, 0, 0][i], y: [0, 0, -1.5, 1.5][i])
            }
            Image(systemName: "cursorarrow").foregroundStyle(.black)
        }
        .font(.system(size: 22))
        .fixedSize()
        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
    }
}
