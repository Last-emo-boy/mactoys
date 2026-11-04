import AppKit
import MacToysCore
import SwiftUI

// Drawing helpers shared by the settings page (hero, layout pickers) and the preview scenes:
// layout diagrams, believable app windows and whole desktops laid out with the real geometry.

/// A small diagram of a layout, from the real geometry.
struct LayoutDiagram: View {
    let kind: TileLayoutKind
    var count = 4
    var shape: DisplayShape = .landscape
    var main: Double = 0.5
    var selected = false
    var gap: CGFloat = 3

    var body: some View {
        GeometryReader { geo in
            let area = CGRect(x: gap, y: gap, width: (geo.size.width - gap * 2).rounded(.down),
                              height: (geo.size.height - gap * 2).rounded(.down))
            let frames = TileTree.make(kind, count: count, shape: shape, main: main).map { TileGeometry.frames($0, in: area, gap: gap) } ?? []
            ZStack(alignment: .topLeading) {
                ForEach(Array(frames.enumerated()), id: \.offset) { i, f in
                    RoundedRectangle(cornerRadius: min(4, f.width / 5), style: .continuous)
                        .fill(fill(i))
                        .frame(width: f.width, height: f.height)
                        .offset(x: f.minX, y: f.minY)
                }
            }
        }
    }

    private func fill(_ i: Int) -> Color {
        let isMain = i == 0 && kind.hasMainWindow
        if selected { return Color.accentColor.opacity(isMain ? 0.95 : 0.55) }
        return Color.primary.opacity(isMain ? 0.32 : 0.17)
    }
}

/// Apps for sample windows (names and titles are sample data, not localized).
enum SampleApp: CaseIterable {
    case safari, xcode, terminal, notes, mail, music, messages, finder, calendar, photos

    var name: String {
        switch self {
        case .safari: "Safari"
        case .xcode: "Xcode"
        case .terminal: "Terminal"
        case .notes: "Notes"
        case .mail: "Mail"
        case .music: "Music"
        case .messages: "Messages"
        case .finder: "Finder"
        case .calendar: "Calendar"
        case .photos: "Photos"
        }
    }

    var bundleID: String {
        switch self {
        case .safari: "com.apple.Safari"
        case .xcode: "com.apple.dt.Xcode"
        case .terminal: "com.apple.Terminal"
        case .notes: "com.apple.Notes"
        case .mail: "com.apple.mail"
        case .music: "com.apple.Music"
        case .messages: "com.apple.MobileSMS"
        case .finder: "com.apple.finder"
        case .calendar: "com.apple.iCal"
        case .photos: "com.apple.Photos"
        }
    }

    var title: String {
        switch self {
        case .safari: "developer.apple.com"
        case .xcode: "TileGeometry.swift"
        case .terminal: "mactoys — zsh — 120×36"
        case .notes: "Kyoto, spring trip"
        case .mail: "Inbox — 14 messages"
        case .music: "Listen Now"
        case .messages: "Mika Tanaka"
        case .finder: "Downloads"
        case .calendar: "November 2026"
        case .photos: "Library"
        }
    }

    var hasToolbar: Bool { self != .terminal }
    var radius: CGFloat { WindowCorners.radius(hasToolbar: hasToolbar) }
    /// Dark content regardless of appearance (editors, terminals).
    var darkContent: Bool { self == .xcode || self == .terminal }

    var tint: Color {
        switch self {
        case .safari: Color(red: 0.12, green: 0.5, blue: 0.98)
        case .xcode: Color(red: 0.1, green: 0.55, blue: 0.95)
        case .terminal: Color(red: 0.2, green: 0.8, blue: 0.4)
        case .notes: Color(red: 0.98, green: 0.78, blue: 0.2)
        case .mail: Color(red: 0.2, green: 0.55, blue: 0.98)
        case .music: Color(red: 0.98, green: 0.24, blue: 0.36)
        case .messages: Color(red: 0.2, green: 0.78, blue: 0.35)
        case .finder: Color(red: 0.25, green: 0.6, blue: 0.98)
        case .calendar: Color(red: 0.98, green: 0.3, blue: 0.27)
        case .photos: Color(red: 0.96, green: 0.6, blue: 0.2)
        }
    }

    @MainActor var icon: NSImage? { AppIcons.icon(bundleID: bundleID) }
}

/// A believable app window drawn at its real size: macOS 26 chrome and placeholder content.
struct SampleWindow: View {
    let app: SampleApp
    var active = true
    var shadow = true
    @Environment(\.colorScheme) private var scheme

    /// Editors and terminals are dark in either appearance.
    private var dark: Bool { scheme == .dark || app.darkContent }
    private var surface: Color { dark ? Color(white: 0.16) : .white }
    private var chrome: Color { dark ? Color(white: 0.2) : Color(white: 0.965) }
    private var line: Color { dark ? .white.opacity(0.1) : .black.opacity(0.08) }
    private var ink: Color { dark ? .white.opacity(0.88) : .black.opacity(0.82) }
    private var soft: Color { dark ? .white.opacity(0.14) : .black.opacity(0.09) }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            VStack(spacing: 0) {
                titleBar(width: size.width)
                content(size: CGSize(width: size.width, height: max(0, size.height - barHeight)))
                    .frame(width: size.width, height: max(0, size.height - barHeight), alignment: .topLeading)
                    .clipped()
            }
            .background(app.darkContent ? Color(red: 0.11, green: 0.11, blue: 0.13) : surface)
            .clipShape(RoundedRectangle(cornerRadius: app.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: app.radius, style: .continuous)
                .strokeBorder(dark ? .white.opacity(0.14) : .black.opacity(0.14), lineWidth: 0.5))
            .shadow(color: .black.opacity(shadow ? (active ? 0.34 : 0.2) : 0), radius: active ? 26 : 14, y: active ? 12 : 6)
        }
    }

    private var barHeight: CGFloat { app.hasToolbar ? 52 : 28 }

    private func titleBar(width: CGFloat) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { i in
                    Circle().fill(active ? [Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18),
                                            Color(red: 0.16, green: 0.79, blue: 0.25)][i] : soft)
                        .frame(width: 12, height: 12)
                }
            }
            .padding(.leading, app.hasToolbar ? 18 : 10)
            if app.hasToolbar && width > 360 {
                HStack(spacing: 6) {
                    Image(systemName: "sidebar.left")
                    Image(systemName: "chevron.left")
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(ink.opacity(0.55))
                .padding(.horizontal, 12).frame(height: 30)
                .background(Capsule().fill(soft.opacity(0.7)))
                .padding(.leading, 10)
            }
            Spacer(minLength: 4)
            Text(verbatim: app == .safari && width > 520 ? "" : app.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ink.opacity(active ? 0.85 : 0.45))
                .lineLimit(1)
            if app == .safari && width > 520 {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill").font(.system(size: 10))
                    Text(verbatim: app.title).font(.system(size: 12.5))
                }
                .foregroundStyle(ink.opacity(0.7))
                .frame(width: min(320, width * 0.4), height: 30)
                .background(Capsule().fill(soft.opacity(0.7)))
            }
            Spacer(minLength: 4)
            if app.hasToolbar && width > 300 {
                HStack(spacing: 14) {
                    Image(systemName: app == .mail ? "square.and.pencil" : app == .finder ? "square.grid.2x2" : "square.and.arrow.up")
                    Image(systemName: "magnifyingglass")
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(ink.opacity(0.55))
                .padding(.horizontal, 14).frame(height: 30)
                .background(Capsule().fill(soft.opacity(0.7)))
                .padding(.trailing, 12)
            } else {
                Color.clear.frame(width: 50, height: 1)
            }
        }
        .frame(height: barHeight)
        .background(app.darkContent ? Color(red: 0.15, green: 0.15, blue: 0.17) : chrome)
        .overlay(alignment: .bottom) { Rectangle().fill(line).frame(height: 0.5) }
    }

    @ViewBuilder
    private func content(size: CGSize) -> some View {
        switch app {
        case .safari: webPage(size)
        case .xcode: code(size)
        case .terminal: terminal(size)
        case .notes, .mail, .messages: sidebarLayout(size)
        case .music, .photos: gallery(size)
        case .finder: finder(size)
        case .calendar: calendar(size)
        }
    }

    private func bar(_ w: CGFloat, _ color: Color, h: CGFloat = 8) -> some View {
        RoundedRectangle(cornerRadius: h / 2).fill(color).frame(width: max(w, 0), height: h)
    }

    private func webPage(_ size: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.36, green: 0.42, blue: 0.98), Color(red: 0.72, green: 0.38, blue: 0.9)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: "Liquid Glass").font(.system(size: min(30, size.width / 14), weight: .bold))
                        Text(verbatim: "Adopting the new design").font(.system(size: min(15, size.width / 26)))
                    }
                    .foregroundStyle(.white).padding(18)
                }
                .frame(height: min(size.height * 0.38, 260))
            ForEach(0..<8, id: \.self) { i in
                bar(size.width * [0.82, 0.9, 0.7, 0.86, 0.6, 0.88, 0.74, 0.5][i] - 48, soft)
            }
            let used = 48 + min(size.height * 0.38, 260) + 14 * 9 + 64
            let columns = size.width > 760 ? 3 : size.width > 420 ? 2 : 1
            ForEach(0..<max(0, Int((size.height - used) / 164)), id: \.self) { row in
                HStack(spacing: 14) {
                    ForEach(0..<columns, id: \.self) { c in card(index: row * columns + c) }
                }
                .frame(height: 150)
            }
        }
        .padding(24)
    }

    private func card(index i: Int) -> some View {
        let tints: [[Color]] = [
            [Color(red: 0.98, green: 0.55, blue: 0.4), Color(red: 0.98, green: 0.8, blue: 0.45)],
            [Color(red: 0.3, green: 0.6, blue: 0.95), Color(red: 0.5, green: 0.88, blue: 0.9)],
            [Color(red: 0.4, green: 0.78, blue: 0.5), Color(red: 0.8, green: 0.92, blue: 0.5)],
        ]
        return VStack(alignment: .leading, spacing: 10) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(colors: tints[i % tints.count], startPoint: .topLeading, endPoint: .bottomTrailing))
            bar(120, soft)
            bar(80, soft.opacity(0.7))
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(soft.opacity(0.35)))
    }

    private func code(_ size: CGSize) -> some View {
        let colors: [Color] = [Color(red: 0.98, green: 0.4, blue: 0.62), Color(red: 0.6, green: 0.78, blue: 1), .white.opacity(0.75),
                               Color(red: 0.98, green: 0.78, blue: 0.4), Color(red: 0.55, green: 0.86, blue: 0.6), .white.opacity(0.4)]
        let side = size.width > 520 ? min(220, size.width * 0.24) : 0
        return HStack(alignment: .top, spacing: 0) {
            if side > 0 {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(["AutoTiling", "TileLayout.swift", "TileGeometry.swift", "TileBoard.swift", "TilePlanner.swift",
                             "TilingEngine.swift", "Overlays.swift"], id: \.self) { f in
                        HStack(spacing: 6) {
                            Image(systemName: f.hasSuffix(".swift") ? "swift" : "folder.fill")
                                .foregroundStyle(f.hasSuffix(".swift") ? Color.orange : Color(red: 0.4, green: 0.7, blue: 1))
                            Text(verbatim: f).foregroundStyle(f == "TileGeometry.swift" ? .white : .white.opacity(0.65))
                        }
                        .font(.system(size: 12))
                        .padding(.leading, f.hasSuffix(".swift") ? 14 : 0)
                    }
                    Spacer()
                }
                .padding(14)
                .frame(width: side, alignment: .leading)
                .background(Color(red: 0.14, green: 0.14, blue: 0.16))
            }
            VStack(alignment: .leading, spacing: 7) {
                ForEach(0..<max(1, min(80, Int((size.height - 28) / 20))), id: \.self) { i in
                    HStack(spacing: 6) {
                        Text(verbatim: "\(i + 1)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.25))
                            .frame(width: 22, alignment: .trailing)
                        bar(CGFloat(30 + (i * 37) % 60), colors[i % colors.count], h: 7)
                            .padding(.leading, CGFloat((i % 4 == 0 ? 0 : (i % 3 + 1)) * 18))
                        bar(CGFloat(40 + (i * 53) % 140), colors[(i + 2) % colors.count], h: 7)
                        if i % 3 == 1 { bar(CGFloat(30 + (i * 29) % 80), colors[(i + 4) % colors.count], h: 7) }
                    }
                }
            }
            .padding(14)
            Spacer(minLength: 0)
        }
    }

    private func terminal(_ size: CGSize) -> some View {
        let lines: [(String, Color)] = [
            ("~/Playground/mactoys % swift test --filter AutoTiling", .white.opacity(0.9)),
            ("[1042/1044] Compiling AutoTiling TileGeometry.swift", .white.opacity(0.55)),
            ("◇ Test run started.", .white.opacity(0.55)),
            ("✔ Suite AutoTilingGeometryTests passed after 0.041 seconds.", Color(red: 0.4, green: 0.86, blue: 0.5)),
            ("✔ Suite AutoTilingBoardTests passed after 0.002 seconds.", Color(red: 0.4, green: 0.86, blue: 0.5)),
            ("✔ Test run with 51 tests in 7 suites passed.", Color(red: 0.4, green: 0.86, blue: 0.5)),
            ("~/Playground/mactoys % git log --oneline -3", .white.opacity(0.9)),
            ("cc6a480 Auto Tiling: layout geometry and planner", Color(red: 0.98, green: 0.78, blue: 0.4)),
            ("ed11edf Scaffold Auto Tiling and Privacy Screen", Color(red: 0.98, green: 0.78, blue: 0.4)),
            ("~/Playground/mactoys % ▍", .white.opacity(0.9)),
        ]
        return VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(lines.prefix(max(1, Int(size.height / 19))).enumerated()), id: \.offset) { _, l in
                Text(verbatim: l.0).foregroundStyle(l.1).lineLimit(1)
            }
        }
        .font(.system(size: 12.5, design: .monospaced))
        .padding(12)
    }

    private func sidebarLayout(_ size: CGSize) -> some View {
        let side = size.width > 460 ? min(250, size.width * 0.34) : 0
        let rows: [String] = switch app {
        case .mail: ["Apple Developer", "Mika Tanaka", "GitHub", "Kyoto Ryokan", "Design Weekly", "Hiroshi"]
        case .messages: ["Mika Tanaka", "Family", "Ryo", "Studio", "Alex"]
        default: ["Kyoto, spring trip", "Groceries", "Book list", "Meeting notes", "Ideas"]
        }
        let selectedInk: Color = app == .notes ? .black.opacity(0.8) : .white
        return HStack(alignment: .top, spacing: 0) {
            if side > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                        HStack(spacing: 10) {
                            if app != .notes {
                                Circle().fill(app.tint.opacity(0.3 + Double(i % 3) * 0.2)).frame(width: 30, height: 30)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: r).font(.system(size: 13, weight: .semibold)).foregroundStyle(i == 0 ? selectedInk : ink)
                                bar(side * 0.5, i == 0 ? selectedInk.opacity(0.35) : soft, h: 6)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(9)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(i == 0 ? app.tint : .clear))
                    }
                    Spacer()
                }
                .padding(10)
                .frame(width: side)
                .background(dark ? Color(white: 0.13) : Color(white: 0.95))
            }
            if app == .messages {
                VStack(spacing: 12) {
                    Spacer()
                    bubble(left: true, w: 0.55, size: size)
                    bubble(left: false, w: 0.42, size: size)
                    bubble(left: true, w: 0.36, size: size)
                    bubble(left: false, w: 0.6, size: size)
                }
                .padding(18)
                .frame(maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text(verbatim: app == .mail ? "Your build is ready" : "Kyoto, spring trip")
                        .font(.system(size: 22, weight: .bold)).foregroundStyle(ink).lineLimit(1)
                    ForEach(0..<9, id: \.self) { i in
                        bar((size.width - side) * [0.8, 0.86, 0.6, 0.78, 0.82, 0.5, 0.74, 0.66, 0.4][i] - 40, soft)
                    }
                }
                .padding(22)
            }
            Spacer(minLength: 0)
        }
    }

    private func bubble(left: Bool, w: CGFloat, size: CGSize) -> some View {
        HStack {
            if !left { Spacer() }
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(left ? soft : Color(red: 0.2, green: 0.55, blue: 1))
                .frame(width: size.width * w * 0.6, height: 34)
            if left { Spacer() }
        }
    }

    private func gallery(_ size: CGSize) -> some View {
        let columns = max(2, Int(size.width / 170))
        let tile = (size.width - 40 - CGFloat(columns - 1) * 14) / CGFloat(columns)
        let palettes: [[Color]] = [
            [Color(red: 0.98, green: 0.45, blue: 0.4), Color(red: 0.98, green: 0.75, blue: 0.4)],
            [Color(red: 0.3, green: 0.45, blue: 0.95), Color(red: 0.5, green: 0.85, blue: 0.95)],
            [Color(red: 0.55, green: 0.3, blue: 0.85), Color(red: 0.95, green: 0.45, blue: 0.7)],
            [Color(red: 0.2, green: 0.7, blue: 0.55), Color(red: 0.75, green: 0.9, blue: 0.5)],
            [Color(red: 0.15, green: 0.18, blue: 0.3), Color(red: 0.45, green: 0.5, blue: 0.7)],
        ]
        return VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: app.title).font(.system(size: 24, weight: .bold)).foregroundStyle(ink)
            ForEach(0..<max(1, Int((size.height - 70) / (tile + 30))), id: \.self) { row in
                HStack(spacing: 14) {
                    ForEach(0..<columns, id: \.self) { c in
                        VStack(alignment: .leading, spacing: 6) {
                            RoundedRectangle(cornerRadius: app == .photos ? 4 : 10, style: .continuous)
                                .fill(LinearGradient(colors: palettes[(row * columns + c) % palettes.count],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(width: tile, height: tile)
                            if app == .music { bar(tile * 0.7, soft, h: 6) }
                        }
                    }
                }
            }
        }
        .padding(20)
    }

    private func finder(_ size: CGSize) -> some View {
        let files = ["Quarterly.key", "IMG_4821.HEIC", "Invoice-2026-10.pdf", "mactoys.zip", "Brief.md", "Screenshot 2026-11-03.png",
                     "Kyoto.numbers", "Design v4.sketch"]
        let symbols = ["doc.richtext.fill", "photo.fill", "doc.fill", "doc.zipper", "doc.text.fill", "photo.fill", "tablecells.fill", "paintbrush.fill"]
        let side = size.width > 460 ? CGFloat(170) : 0
        let columns = max(2, Int((size.width - side - 30) / 110))
        return HStack(alignment: .top, spacing: 0) {
            if side > 0 {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(["Recents", "Applications", "Desktop", "Documents", "Downloads"], id: \.self) { s in
                        Label { Text(verbatim: s) } icon: { Image(systemName: "folder") }
                            .font(.system(size: 12.5)).foregroundStyle(s == "Downloads" ? Color.accentColor : ink.opacity(0.8))
                    }
                    Spacer()
                }
                .padding(16).frame(width: side, alignment: .leading)
                .background(dark ? Color(white: 0.13) : Color(white: 0.95))
            }
            VStack(alignment: .leading, spacing: 18) {
                ForEach(0..<max(1, (files.count + columns - 1) / columns), id: \.self) { row in
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(0..<columns, id: \.self) { c in
                            let i = row * columns + c
                            if i < files.count {
                                VStack(spacing: 6) {
                                    Image(systemName: symbols[i]).font(.system(size: 34)).foregroundStyle(app.tint.opacity(0.85))
                                        .frame(height: 44)
                                    Text(verbatim: files[i]).font(.system(size: 11)).foregroundStyle(ink).lineLimit(2)
                                        .multilineTextAlignment(.center)
                                }
                                .frame(width: 96)
                            }
                        }
                    }
                }
                Spacer()
            }
            .padding(18)
        }
    }

    private func calendar(_ size: CGSize) -> some View {
        let days = ["Mon 2", "Tue 3", "Wed 4", "Thu 5", "Fri 6"]
        let events: [(Int, CGFloat, CGFloat, Color, String)] = [
            (0, 0.1, 0.12, .blue, "Standup"), (1, 0.3, 0.2, .orange, "Design review"), (2, 0.15, 0.1, .green, "Lunch"),
            (2, 0.5, 0.18, .purple, "Release"), (3, 0.25, 0.25, .pink, "Workshop"), (4, 0.6, 0.15, .blue, "1:1"),
        ]
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(days, id: \.self) { d in
                    Text(verbatim: d).font(.system(size: 12, weight: .semibold)).foregroundStyle(ink.opacity(0.7))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 30)
            GeometryReader { geo in
                let colW = geo.size.width / CGFloat(days.count)
                ZStack(alignment: .topLeading) {
                    ForEach(0..<days.count, id: \.self) { i in
                        Rectangle().fill(line).frame(width: 0.5).offset(x: CGFloat(i) * colW)
                    }
                    ForEach(Array(events.enumerated()), id: \.offset) { _, e in
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(e.3.opacity(0.22))
                            .overlay(alignment: .topLeading) {
                                Text(verbatim: e.4).font(.system(size: 11, weight: .semibold)).foregroundStyle(e.3).padding(5)
                            }
                            .frame(width: colW - 8, height: geo.size.height * e.2)
                            .offset(x: CGFloat(e.0) * colW + 4, y: geo.size.height * e.1)
                    }
                }
            }
        }
        .padding(10)
    }
}

/// A desktop of a given point size: wallpaper, menu bar, Dock and windows at their frames
/// (top-left coordinates within the desktop). Drawn at full size; scale it to fit.
struct SampleDesktop<Overlay: View>: View {
    let size: CGSize
    let windows: [(app: SampleApp, frame: CGRect)]
    var active: Int? = 0
    var dock = true
    @ViewBuilder var overlay: () -> Overlay

    static var menuBarHeight: CGFloat { 33 }
    static var dockHeight: CGFloat { 78 }

    /// The visible frame (no menu bar, no Dock) of a desktop of this size.
    static func visibleFrame(_ size: CGSize, dock: Bool = true) -> CGRect {
        CGRect(x: 0, y: menuBarHeight, width: size.width, height: size.height - menuBarHeight - (dock ? dockHeight : 0))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            DesktopWallpaper()
            ForEach(Array(windows.enumerated()), id: \.offset) { i, w in
                SampleWindow(app: w.app, active: i == active)
                    .frame(width: w.frame.width, height: w.frame.height)
                    .offset(x: w.frame.minX, y: w.frame.minY)
                    .zIndex(i == active ? 1 : 0)
            }
            overlay().zIndex(2)
            menuBar.zIndex(3)
            if dock {
                dockView.frame(width: size.width).offset(y: size.height - Self.dockHeight + 8).zIndex(3)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
    }

    private var menuBar: some View {
        HStack(spacing: 20) {
            Image(systemName: "apple.logo").font(.system(size: 15, weight: .semibold))
            Text(verbatim: windows.indices.contains(active ?? -1) ? windows[active ?? 0].app.name : "Finder")
                .font(.system(size: 13.5, weight: .bold))
            ForEach(["File", "Edit", "View", "Window", "Help"], id: \.self) { Text(verbatim: $0).font(.system(size: 13.5)) }
            Spacer()
            Image(systemName: "rectangle.split.2x2.fill").font(.system(size: 13))
            Image(systemName: "wifi").font(.system(size: 13))
            Image(systemName: "battery.75percent").font(.system(size: 14))
            Text(verbatim: PreviewScene.menuBarClock(hour: 9, minute: 41)).font(.system(size: 13.5, weight: .medium))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .frame(width: size.width, height: Self.menuBarHeight)
    }

    private var dockView: some View {
        HStack(spacing: 10) {
            ForEach([SampleApp.finder, .safari, .mail, .messages, .music, .photos, .calendar, .notes, .xcode, .terminal], id: \.self) { app in
                Group {
                    if let icon = app.icon { Image(nsImage: icon).resizable() } else { RoundedRectangle(cornerRadius: 12).fill(app.tint) }
                }
                .frame(width: 52, height: 52)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
        .frame(height: Self.dockHeight - 8)
    }
}

extension SampleDesktop where Overlay == EmptyView {
    init(size: CGSize, windows: [(app: SampleApp, frame: CGRect)], active: Int? = 0, dock: Bool = true) {
        self.init(size: size, windows: windows, active: active, dock: dock, overlay: { EmptyView() })
    }
}

/// The wallpaper behind sample desktops.
struct DesktopWallpaper: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.07, green: 0.12, blue: 0.33), Color(red: 0.22, green: 0.16, blue: 0.52),
                                    Color(red: 0.58, green: 0.25, blue: 0.52), Color(red: 0.9, green: 0.55, blue: 0.42)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [.white.opacity(0.18), .clear], center: UnitPoint(x: 0.75, y: 0.2), startRadius: 0, endRadius: 600)
        }
    }
}

/// Scales full-size content (a desktop) down to a given width, keeping its proportions.
struct Scaled<Content: View>: View {
    let size: CGSize
    let width: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        let s = width / max(size.width, 1)
        content()
            .frame(width: size.width, height: size.height)
            .scaleEffect(s, anchor: .topLeading)
            .frame(width: size.width * s, height: size.height * s, alignment: .topLeading)
    }
}

/// SwiftUI drawing of the highlight overlay, for the hero and preview scenes (the live
/// overlay draws the same shapes with Core Animation).
struct HighlightShape: View {
    let frame: CGRect
    let radius: CGFloat
    let style: HighlightStyle
    let active: Bool
    var color: Color = .accentColor
    var gap: CGFloat = 8

    var body: some View {
        let width = min(max(gap * 0.35, 2), 4)
        switch style {
        case .none:
            EmptyView()
        case .activeBorder, .allBorders:
            if active || style == .allBorders {
                let w = active ? width : max(1.5, width - 1)
                let outset = w / 2 + 1
                RoundedRectangle(cornerRadius: radius + outset, style: .continuous)
                    .stroke(color.opacity(active ? 1 : 0.45), lineWidth: w)
                    .frame(width: frame.width + outset * 2, height: frame.height + outset * 2)
                    .offset(x: frame.minX - outset, y: frame.minY - outset)
            }
        case .glow:
            if active {
                // Spills outward only, never over the window, like the live overlay.
                let spill: CGFloat = 48
                RoundedRectangle(cornerRadius: radius + 1.5, style: .continuous)
                    .stroke(color, lineWidth: 3)
                    .frame(width: frame.width + 3, height: frame.height + 3)
                    .shadow(color: color, radius: 6)
                    .shadow(color: color.opacity(0.9), radius: 16)
                    .shadow(color: color.opacity(0.5), radius: 30)
                    .frame(width: frame.width + spill * 2, height: frame.height + spill * 2)
                    .mask(OutsideMask(radius: radius, inset: spill).fill(style: FillStyle(eoFill: true)))
                    .offset(x: frame.minX - spill, y: frame.minY - spill)
            }
        }
    }
}

/// Everything but a rounded rectangle inset by `inset` from the edges.
private struct OutsideMask: Shape {
    let radius: CGFloat
    let inset: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path(rect)
        p.addRoundedRect(in: rect.insetBy(dx: inset, dy: inset), cornerSize: CGSize(width: radius, height: radius), style: .continuous)
        return p
    }
}

/// Stack pips above a tile, as the live overlay draws them.
struct StackPips: View {
    let frame: CGRect
    let count: Int
    var front = 0
    var gap: CGFloat = 8
    var color: Color = .white
    /// Enlarges the pips for miniatures.
    var scale: CGFloat = 1
    /// Where the pips' center line goes; by default in the gap above the tile.
    var centerY: CGFloat?

    var body: some View {
        let pips = StackPipMetrics.frames(centerX: frame.midX, centerY: centerY ?? frame.minY - StackPipMetrics.offset(gap: gap),
                                          count: count, front: front, gap: gap, scale: scale)
        ZStack(alignment: .topLeading) {
            ForEach(Array(pips.enumerated()), id: \.offset) { i, p in
                Capsule().fill(color.opacity(i == front ? 1 : 0.6))
                    .shadow(color: .black.opacity(0.4), radius: 1.5)
                    .frame(width: p.width, height: p.height)
                    .offset(x: p.minX, y: p.minY)
            }
        }
    }
}
