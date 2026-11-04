import AppKit
import MacToysCore
import SwiftUI

/// Offscreen previews: desktops in every layout on 16:10, 32:9 and portrait displays, the
/// highlight styles, drag to swap, the quick-action pill, a stack, Tab View, Focus, No peek and
/// Clean Space — all laid out by the real geometry with sample windows.
@MainActor
enum AutoTilingPreviews {
    static let laptop = CGSize(width: 1440, height: 900)
    static let superWide = CGSize(width: 5120, height: 1440)
    static let portrait = CGSize(width: 1080, height: 1920)

    static func scenes(module: AutoTilingModule) -> [PreviewScene] {
        [
            PreviewScene("desktop", size: CGSize(width: 1440, height: 900), wallpaper: false) {
                AnyView(desktop(laptop, .side, [.xcode, .safari, .terminal], main: 0.6, style: .activeBorder))
            },
            PreviewScene("grid", size: CGSize(width: 1440, height: 900), wallpaper: false) {
                AnyView(desktop(laptop, .grid, [.safari, .notes, .mail, .music], style: .allBorders))
            },
            PreviewScene("ultrawide", size: CGSize(width: 1800, height: 506), wallpaper: false) {
                AnyView(Scaled(size: superWide, width: 1800) {
                    desktop(superWide, .side, [.xcode, .safari, .terminal, .messages, .notes], style: .glow)
                })
            },
            PreviewScene("portrait", size: CGSize(width: 563, height: 1000), wallpaper: false) {
                AnyView(Scaled(size: portrait, width: 563) {
                    desktop(portrait, .grid, [.safari, .notes, .terminal], main: 0.6, style: .activeBorder)
                })
            },
            PreviewScene("layouts-16x10", size: CGSize(width: 1440, height: 1000), wallpaper: false) {
                AnyView(LayoutGallery(display: laptop, counts: [1, 2, 3, 4], thumbWidth: 300))
            },
            PreviewScene("layouts-32x9", size: CGSize(width: 1760, height: 660), wallpaper: false) {
                AnyView(LayoutGallery(display: superWide, counts: [2, 3, 4, 5], thumbWidth: 380))
            },
            PreviewScene("layouts-portrait", size: CGSize(width: 760, height: 1160), wallpaper: false) {
                AnyView(LayoutGallery(display: portrait, counts: [1, 2, 3, 4], thumbWidth: 130))
            },
            PreviewScene("highlights", size: CGSize(width: 1180, height: 820), wallpaper: false) {
                AnyView(HighlightGallery())
            },
            PreviewScene("drag-swap", size: CGSize(width: 1440, height: 900), wallpaper: false) { AnyView(dragSwap) },
            PreviewScene("quick-actions", size: CGSize(width: 1440, height: 900), wallpaper: false) { AnyView(quickActions) },
            PreviewScene("stack", size: CGSize(width: 1440, height: 900), wallpaper: false) { AnyView(stack) },
            PreviewScene("tab-view", size: CGSize(width: 900, height: 480)) { AnyView(tabView) },
            PreviewScene("focus", size: CGSize(width: 1440, height: 900), wallpaper: false) { AnyView(focus) },
            PreviewScene("no-peek", size: CGSize(width: 1440, height: 900), wallpaper: false) { AnyView(noPeek) },
            PreviewScene("clean-space", size: CGSize(width: 1440, height: 900), wallpaper: false) { AnyView(cleanSpace) },
        ]
    }

    // MARK: Building blocks

    /// Tile frames for `count` windows on a sample desktop.
    static func frames(_ size: CGSize, _ kind: TileLayoutKind, count: Int, main: Double = 0.5, gap: CGFloat = 8) -> (frames: [CGRect], area: CGRect) {
        let area = TileGeometry.area(visibleFrame: SampleDesktop<EmptyView>.visibleFrame(size), reserve: nil, gap: gap)
        let tree = TileTree.make(kind, count: count, shape: DisplayShape(size: size), main: main)
        return (tree.map { TileGeometry.frames($0, in: area, gap: gap) } ?? [], area)
    }

    static func desktop(_ size: CGSize, _ kind: TileLayoutKind, _ apps: [SampleApp], main: Double = 0.5,
                        style: HighlightStyle, active: Int = 0) -> some View {
        let f = frames(size, kind, count: apps.count, main: main).frames
        return SampleDesktop(size: size, windows: Array(zip(apps, f)).map { ($0, $1) }, active: active) {
            ZStack(alignment: .topLeading) {
                ForEach(Array(f.enumerated()), id: \.offset) { i, frame in
                    HighlightShape(frame: frame, radius: apps[i].radius, style: style, active: i == active)
                }
            }
        }
    }

    private static var cursor: some View {
        ZStack {
            Image(systemName: "cursorarrow").font(.system(size: 30, weight: .regular)).foregroundStyle(.white)
                .offset(x: 1, y: 1)
            Image(systemName: "cursorarrow").font(.system(size: 28, weight: .regular)).foregroundStyle(.black)
        }
        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
    }

    /// A glass pill like the system HUD.
    private static func hud(_ text: Text, symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
            text.font(.system(size: 14, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        // Stands in for the glass, which offscreen renders leave out: visible over dark windows too.
        .background(Capsule().fill(Color(white: 0.24).opacity(0.92)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 0.5))
        .glassEffect(.regular, in: .capsule)
        .clipShape(.capsule)
        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
        .environment(\.colorScheme, .dark)
    }

    /// Offscreen renders draw no glass; this stands in for its blur of the title text underneath.
    private struct TitleBarBlur: View {
        @Environment(\.colorScheme) private var scheme

        var body: some View {
            Capsule().fill(scheme == .dark ? Color(white: 0.2) : Color(white: 0.965))
        }
    }

    // MARK: Scenes

    static var dragSwap: some View {
        let (f, _) = frames(laptop, .grid, count: 3)
        // Notes is being dragged from the top right over Safari, the main window.
        let dragged = f[1].offsetBy(dx: -560, dy: 120)
        let windows: [(app: SampleApp, frame: CGRect)] = [(.safari, f[0]), (.terminal, f[2]), (.notes, dragged)]
        return SampleDesktop(size: laptop, windows: windows, active: 2) {
            ZStack(alignment: .topLeading) {
                SwapTargetView(kind: .swap(app: "Safari"), radius: SampleApp.safari.radius,
                               cutout: dragged.offsetBy(dx: -f[0].minX, dy: -f[0].minY), cutoutRadius: SampleApp.notes.radius)
                    .frame(width: f[0].width, height: f[0].height)
                    .offset(x: f[0].minX, y: f[0].minY)
                cursor.offset(x: dragged.midX + 40, y: dragged.minY + 14)
            }
        }
    }

    static var quickActions: some View {
        let apps: [SampleApp] = [.mail, .safari, .notes]
        let (f, _) = frames(laptop, .side, count: 3, main: 0.6)
        let main = f[0]
        let pill = QuickActionPillView.size(buttons: 3)
        return SampleDesktop(size: laptop, windows: Array(zip(apps, f)).map { ($0, $1) }, active: 0) {
            ZStack(alignment: .topLeading) {
                HighlightShape(frame: main, radius: SampleApp.mail.radius, style: .activeBorder, active: true)
                TitleBarBlur()
                    .frame(width: pill.width, height: pill.height)
                    .offset(x: main.midX - pill.width / 2, y: main.minY + 6)
                QuickActionPillView(isMain: true, isFloating: false, canSendToDisplay: true)
                    .frame(width: pill.width, height: pill.height)
                    .offset(x: main.midX - pill.width / 2, y: main.minY + 6)
                cursor.offset(x: main.midX + 2, y: main.minY + 18)
            }
        }
    }

    static var stack: some View {
        let (f, _) = frames(laptop, .side, count: 2, main: 0.6)
        let windows: [(app: SampleApp, frame: CGRect)] = [(.mail, f[0]), (.messages, f[0]), (.safari, f[1]), (.notes, f[0])]
        return SampleDesktop(size: laptop, windows: windows, active: 3) {
            ZStack(alignment: .topLeading) {
                HighlightShape(frame: f[0], radius: SampleApp.notes.radius, style: .activeBorder, active: true)
                StackPips(frame: f[0], count: 3)
                hud(Text("\(SampleApp.notes.name) · \(1) of \(3)",
                         comment: "HUD when cycling a stack of windows: app name, position, number of windows"),
                    symbol: "square.stack.fill")
                    .frame(width: laptop.width).offset(y: laptop.height - 200)
            }
        }
    }

    static var focus: some View {
        let (f, area) = frames(laptop, .grid, count: 3)
        let windows: [(app: SampleApp, frame: CGRect)] = [(.safari, f[1]), (.terminal, f[2]), (.xcode, area)]
        return SampleDesktop(size: laptop, windows: windows, active: 2) {
            ZStack(alignment: .topLeading) {
                HighlightShape(frame: area, radius: SampleApp.xcode.radius, style: .activeBorder, active: true)
                hud(Text(AutoTilingModule.focusOn), symbol: "arrow.up.left.and.arrow.down.right")
                    .frame(width: laptop.width).offset(y: laptop.height - 200)
            }
        }
    }

    static var noPeek: some View {
        let apps: [SampleApp] = [.safari, .notes, .terminal]
        let (f, _) = frames(laptop, .grid, count: 3)
        return SampleDesktop(size: laptop, windows: Array(zip(apps, f)).map { ($0, $1) }, active: 1) {
            ZStack(alignment: .topLeading) {
                Veil(size: laptop, hole: f[1], radius: SampleApp.notes.radius, color: .black.opacity(0.62))
                HighlightShape(frame: f[1], radius: SampleApp.notes.radius, style: .activeBorder, active: true)
            }
        }
    }

    static var cleanSpace: some View {
        let (_, area) = frames(laptop, .grid, count: 3)
        let windows: [(app: SampleApp, frame: CGRect)] = [(.safari, area)]
        return SampleDesktop(size: laptop, windows: windows, active: 0) {
            Veil(size: laptop, hole: area, radius: SampleApp.safari.radius,
                 color: Color(red: 0.105, green: 0.11, blue: 0.125))
        }
    }

    static var tabView: some View {
        let model = TabSwitcherModel()
        func item(_ app: SampleApp, _ id: CGWindowID, _ frame: CGRect, title: String? = nil, count: Int = 1, index: Int = 0) -> TabSwitcherModel.Item {
            .init(id: id, app: app.name, title: title ?? app.title, icon: app.icon, frame: frame, isFloating: false,
                  stackCount: count, stackIndex: index)
        }
        func relative(_ size: CGSize, _ r: CGRect) -> CGRect {
            CGRect(x: r.minX / size.width, y: r.minY / size.height, width: r.width / size.width, height: r.height / size.height)
        }
        let built = CGSize(width: 1512, height: 982)
        let a = frames(built, .side, count: 3, main: 0.6).frames.map { relative(built, $0) }
        let studio = CGSize(width: 2560, height: 1440)
        let b = frames(studio, .grid, count: 4).frames.map { relative(studio, $0) }
        model.screens = [
            .init(id: "a", name: "Built-in Retina Display", aspect: built.width / built.height, kind: .side,
                  items: [item(.xcode, 1, a[0]), item(.safari, 2, a[1], title: "Liquid Glass — Apple Developer"), item(.terminal, 3, a[2])]),
            .init(id: "b", name: "Studio Display", aspect: studio.width / studio.height, kind: .grid,
                  items: [item(.mail, 4, b[0], count: 2), item(.messages, 5, b[0], count: 2, index: 1), item(.notes, 6, b[1]),
                          item(.music, 7, b[2]), item(.photos, 8, b[3])]),
        ]
        model.minimized = [item(.calendar, 9, .zero), item(.finder, 10, .zero)]
        model.order = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
        model.selection = 1
        model.holdKeys = ["⌃", "⌥"]
        return TabSwitcherView(model: model).fixedSize()
    }
}

/// A full-display cover with a rounded hole (No peek veil, Clean Space curtain).
struct Veil: View {
    let size: CGSize
    let hole: CGRect
    let radius: CGFloat
    let color: Color

    var body: some View {
        Path { p in
            p.addRect(CGRect(origin: .zero, size: size))
            p.addRoundedRect(in: hole, cornerSize: CGSize(width: radius, height: radius), style: .continuous)
        }
        .fill(color, style: FillStyle(eoFill: true))
        .frame(width: size.width, height: size.height)
    }
}

/// Every layout for several window counts on one kind of display.
private struct LayoutGallery: View {
    let display: CGSize
    let counts: [Int]
    let thumbWidth: CGFloat

    var body: some View {
        let shape = DisplayShape(size: display)
        let apps: [SampleApp] = [.safari, .notes, .terminal, .mail, .music]
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                Image(systemName: shape == .portrait ? "rectangle.portrait" : "display").foregroundStyle(Tint.indigo.color)
                Text("\(shape.title) · \(String(Int(display.width))) × \(String(Int(display.height)))",
                     comment: "Layout gallery heading: display shape, then its width and height in points")
            }
            .font(.system(size: 17, weight: .semibold))
            ForEach(TileLayoutKind.allCases) { kind in
                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 6) {
                        Image(systemName: kind.symbol).font(.system(size: 20, weight: .medium)).foregroundStyle(Tint.indigo.color)
                        Text(verbatim: kind.title).font(.system(size: 13, weight: .semibold))
                    }
                    .frame(width: 84)
                    .padding(.top, 8)
                    ForEach(counts, id: \.self) { n in
                        VStack(spacing: 6) {
                            Scaled(size: display, width: thumbWidth) {
                                AutoTilingPreviews.desktop(display, kind, Array(apps.prefix(n)), style: .activeBorder)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.black.opacity(0.12)))
                            .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
                            Text("\(n) windows", comment: "Caption under a layout preview").font(.system(size: 11.5)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The four highlight styles side by side.
private struct HighlightGallery: View {
    var body: some View {
        let size = AutoTilingPreviews.laptop
        Grid(horizontalSpacing: 28, verticalSpacing: 22) {
            ForEach([[HighlightStyle.none, .activeBorder], [.allBorders, .glow]], id: \.self) { row in
                GridRow {
                    ForEach(row) { style in
                        VStack(spacing: 8) {
                            Scaled(size: size, width: 540) {
                                AutoTilingPreviews.desktop(size, .grid, [.safari, .notes, .terminal], style: style)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .shadow(color: .black.opacity(0.14), radius: 8, y: 4)
                            Text(verbatim: style.title).font(.system(size: 13, weight: .semibold))
                        }
                    }
                }
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
