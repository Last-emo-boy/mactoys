import MacToysCore
import SwiftUI

struct ShelfSettingsView: View {
    let module: FileShelfModule
    @Bindable var s: Persisted<ShelfSettings>
    let manager: ShelfManager

    init(module: FileShelfModule) {
        self.module = module
        self.s = module.settings
        self.manager = module.manager
    }

    var body: some View {
        SettingsPage(module: module) {
            ShelfHero(settings: s.value, manager: manager)
        } content: {
            Section("Opening a shelf") {
                Toggle(isOn: $s.value.shakeToOpen) {
                    RowLabel("Shake to open a shelf",
                             subtitle: "While you drag files, text, images or links, shake the pointer quickly from side to side and a shelf opens under it.")
                }
                Group {
                    Picker(selection: $s.value.shakeSensitivity) {
                        ForEach(ShakeSensitivity.allCases, id: \.self) { Text($0.title).tag($0) }
                    } label: {
                        RowLabel("Shake sensitivity", subtitle: "Higher opens a shelf with a shorter, smaller shake.")
                    }
                    .pickerStyle(.segmented)
                    ExcludedAppsEditor("Apps where shaking does nothing", apps: $s.value.excludedApps)
                }
                .disabled(!s.value.shakeToOpen)
                ShortcutRow("New shelf", subtitle: "Opens an empty shelf, ready for drops or ⌘V.", shortcut: $s.value.newShelfShortcut)
                ShortcutRow("New shelf from the clipboard", shortcut: $s.value.clipboardShortcut)
                ShortcutRow("Reopen the last closed shelf", shortcut: $s.value.reopenShortcut)
            }

            Section("Shelves") {
                Picker(selection: $s.value.placement) {
                    ForEach(ShelfPlacement.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: {
                    RowLabel("New shelves appear", subtitle: "Shelves you drag elsewhere stay where you put them.")
                }
                Picker(selection: $s.value.layout) {
                    ForEach(ShelfLayout.allCases, id: \.self) { Label($0.title, systemImage: $0.symbol).tag($0) }
                } label: {
                    RowLabel("Show expanded shelves as", subtitle: "Click a pile to expand it. Also with the button at the top of a shelf.")
                }
                .pickerStyle(.segmented)
                Toggle(isOn: $s.value.showOnAllSpaces) {
                    RowLabel("Show shelves on every Space", subtitle: "Otherwise a shelf stays on the desktop where it opened.")
                }
            }

            Section("Closing shelves") {
                Toggle(isOn: $s.value.closeAfterDragOut) {
                    RowLabel("Close a shelf after dragging all of its items out",
                             subtitle: "Hold ⇧ while you drop, or pin the shelf, to keep it open. Closed shelves can be reopened from Recent Shelves.")
                }
                Toggle(isOn: $s.value.closeWhenEmptied) {
                    RowLabel("Close a shelf when its last item is removed", subtitle: "Pinned shelves stay open.")
                }
                Toggle(isOn: $s.value.alwaysCopyOnDragOut) {
                    RowLabel("Always copy files when dragging them out",
                             subtitle: "Otherwise dropping on a folder of the same disk moves the file, as in Finder. Shelves only point to your files; they never copy them.")
                }
            }

            Section("Restoring") {
                Toggle(isOn: $s.value.keepAcrossRestarts) {
                    RowLabel("Keep shelves when MacToys quits",
                             subtitle: "Open and recent shelves come back after a restart. Items whose files were deleted are left out. Pinned shelves are always kept.")
                }
            }

            Section {
                if manager.recent.isEmpty {
                    Text("Closed shelves appear here, so you can bring back what was on them.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(manager.recent) { shelf in
                        RecentShelfRow(shelf: shelf) { manager.reopen(shelf.id) }
                    }
                }
            } header: {
                HStack {
                    Text("Recent shelves")
                    Spacer()
                    if !manager.recent.isEmpty {
                        Button("Clear") { manager.clearRecent() }
                            .buttonStyle(.link)
                            .font(.system(size: 12))
                    }
                }
            }

            Section("In a shelf") {
                KeyRow("Quick Look the selected items", keys: ["Space"])
                KeyRow("Open the selected items", keys: ["⌘", "O"], alternative: ["↩"])
                KeyRow("Copy, or paste into the shelf", keys: ["⌘", "C"], alternative: ["⌘", "V"])
                KeyRow("Remove the selection from the shelf", keys: ["⌫"])
                KeyRow("Close the shelf", keys: ["⌘", "W"])
                KeyRow("Keep the shelf open when dragging everything out", keys: ["⇧"])
                Text("Right-click items for Open With, Share, Compress to ZIP, Move to Folder and more. In Finder, Services › Add to Shelf adds the selected files to the shelf you used last.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct RecentShelfRow: View {
    let shelf: Shelf
    let reopen: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if let item = shelf.items.last {
                ShelfItemThumb(item: item, thumbnail: ShelfThumbnailLoader.shared.immediate(for: item), side: 28)
                    .frame(width: 30, height: 30)
            }
            RowLabel(title: Text(verbatim: ShelfRecents.title(for: shelf)), subtitle: Text(verbatim: ShelfRecents.detail(for: shelf)))
            Spacer(minLength: 8)
            Button("Reopen", action: reopen)
        }
    }
}

private struct KeyRow: View {
    let title: LocalizedStringKey
    let keys: [String]
    let alternative: [String]?

    init(_ title: LocalizedStringKey, keys: [String], alternative: [String]? = nil) {
        self.title = title
        self.keys = keys
        self.alternative = alternative
    }

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                Keycaps(keys)
                if let alternative {
                    Text("or", comment: "Between two alternative keyboard shortcuts").foregroundStyle(.secondary).font(.system(size: 11.5))
                    Keycaps(alternative)
                }
            }
        } label: {
            RowLabel(title)
        }
    }
}

// MARK: - Hero

/// The page's hero: a miniature desktop showing how a shelf opens with the current settings,
/// what's open now, and buttons to open or bring back a shelf.
private struct ShelfHero: View {
    let settings: ShelfSettings
    let manager: ShelfManager

    var body: some View {
        HeroCard(tint: .teal) {
            HStack(alignment: .center, spacing: 20) {
                ShelfHeroIllustration(placement: settings.placement, shake: settings.shakeToOpen,
                                      sensitivity: settings.shakeSensitivity, shortcut: settings.newShelfShortcut)
                    .frame(width: 236, height: 148)
                VStack(alignment: .leading, spacing: 6) {
                    Text(settings.shakeToOpen ? "Shake while dragging to open a shelf" : "Open a shelf with a shortcut")
                        .font(.system(size: 14, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Drop files, text, images or links on it, switch apps, then drag everything out at once.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    status
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                    HStack(spacing: 8) {
                        Button("New Shelf") { manager.newShelf() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!manager.isRunning)
                        if let shortcut = settings.newShelfShortcut { Keycaps(shortcut) }
                        if !manager.recent.isEmpty {
                            Button("Reopen Last Shelf") { manager.reopen() }
                                .disabled(!manager.isRunning)
                        }
                    }
                    .padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var status: Text {
        let open = manager.shelves.count
        if open == 0 { return Text("No shelves open") }
        return Text("\(open) shelves open · \(manager.itemCount) items", comment: "Hero status: number of open shelves, then the items on them")
    }
}

/// A tiny desktop: a Finder window, the pointer dragging files with a shake trail, and the shelf
/// that opens — at the pointer or at a screen edge, per the settings.
struct ShelfHeroIllustration: View {
    let placement: ShelfPlacement
    let shake: Bool
    let sensitivity: ShakeSensitivity
    let shortcut: Shortcut?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let shelfSize = CGSize(width: 52, height: 60)
            let windowOnRight = placement == .leftEdge
            let window = CGRect(x: windowOnRight ? w - 120 : 14, y: 22, width: 106, height: 84)
            let shelfCenter: CGPoint = switch placement {
            case .pointer: CGPoint(x: windowOnRight ? 64 : w - 66, y: h * 0.56)
            case .rightEdge: CGPoint(x: w - shelfSize.width / 2 - 8, y: 20 + shelfSize.height / 2 + 6)
            case .leftEdge: CGPoint(x: shelfSize.width / 2 + 8, y: 20 + shelfSize.height / 2 + 6)
            }
            let pointer: CGPoint = placement == .pointer
                ? CGPoint(x: shelfCenter.x + 6, y: shelfCenter.y + 2)
                : CGPoint(x: windowOnRight ? window.minX - 30 : window.maxX + 34, y: h * 0.66)

            ZStack(alignment: .topLeading) {
                MiniWallpaper()
                Rectangle().fill(.white.opacity(0.32)).frame(width: w, height: 9)
                MiniFinderWindow()
                    .frame(width: window.width, height: window.height)
                    .offset(x: window.minX, y: window.minY)
                if shake {
                    ShakeTrail(sensitivity: sensitivity, endingAt: pointer, leftward: windowOnRight)
                } else if let shortcut {
                    Keycaps(shortcut, dark: true)
                        .scaleEffect(0.8)
                        .offset(x: pointer.x - 30, y: pointer.y + 22)
                }
                MiniShelf()
                    .frame(width: shelfSize.width, height: shelfSize.height)
                    .offset(x: shelfCenter.x - shelfSize.width / 2, y: shelfCenter.y - shelfSize.height / 2)
                MiniDragCursor()
                    .offset(x: pointer.x - 4, y: pointer.y - 2)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.black.opacity(0.1)))
        .environment(\.colorScheme, .light)
        .accessibilityHidden(true)
    }
}

private struct MiniWallpaper: View {
    var body: some View {
        LinearGradient(colors: [Color(red: 0.09, green: 0.13, blue: 0.36), Color(red: 0.24, green: 0.17, blue: 0.56),
                                Color(red: 0.6, green: 0.25, blue: 0.53), Color(red: 0.88, green: 0.54, blue: 0.42)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

private struct MiniFinderWindow: View {
    private let fileColors: [Color] = [Tint.blue.color, Tint.orange.color, Tint.green.color, Tint.pink.color, Tint.indigo.color, Tint.yellow.color]

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 2.5) {
                    ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18),
                             Color(red: 0.16, green: 0.79, blue: 0.25)], id: \.self) { Circle().fill($0).frame(width: 4, height: 4) }
                }
                .padding(.bottom, 3)
                ForEach(0..<4, id: \.self) { i in
                    Capsule().fill(Color.black.opacity(i == 0 ? 0.25 : 0.12)).frame(width: i == 0 ? 18 : 14, height: 3)
                }
                Spacer()
            }
            .padding(6)
            .frame(width: 30)
            .frame(maxHeight: .infinity)
            .background(Color(white: 0.93))
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(16), spacing: 6), count: 3), spacing: 8) {
                ForEach(0..<6, id: \.self) { i in
                    VStack(spacing: 2) {
                        RoundedRectangle(cornerRadius: 2).fill(fileColors[i].gradient).frame(width: 13, height: 16)
                            .opacity(i < 2 ? 0.35 : 1)
                        Capsule().fill(Color.black.opacity(0.18)).frame(width: 14, height: 2)
                    }
                }
            }
            .padding(.top, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.white)
        }
        .clipShape(shape)
        .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
    }
}

/// The zigzag the pointer just drew: wider and longer for low sensitivity.
private struct ShakeTrail: View {
    let sensitivity: ShakeSensitivity
    let endingAt: CGPoint
    let leftward: Bool

    var body: some View {
        let (amplitude, sweeps): (CGFloat, Int) = switch sensitivity {
        case .low: (17, 5)
        case .medium: (12, 4)
        case .high: (8, 3)
        }
        Path { p in
            var point = CGPoint(x: endingAt.x + (leftward ? 1 : -1) * CGFloat(sweeps) * 7, y: endingAt.y + 16)
            p.move(to: point)
            for i in 0..<sweeps {
                point = CGPoint(x: point.x + (leftward ? -7 : 7), y: point.y - 16 / CGFloat(sweeps))
                p.addLine(to: CGPoint(x: point.x + (i.isMultiple(of: 2) ? amplitude : -amplitude), y: point.y))
            }
            p.addLine(to: endingAt)
        }
        .stroke(LinearGradient(colors: [.white.opacity(0.1), .white.opacity(0.95)], startPoint: .bottom, endPoint: .top),
                style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
    }
}

private struct MiniShelf: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        ZStack {
            shape.fill(.white.opacity(0.72))
            shape.strokeBorder(.white.opacity(0.9), lineWidth: 0.75)
            ZStack {
                card(Tint.indigo.color, angle: -9, x: -5)
                card(Tint.orange.color, angle: 7, x: 5)
                card(Tint.teal.color, angle: 0, x: 0)
            }
            .offset(y: -5)
            Capsule().fill(Color.black.opacity(0.22)).frame(width: 26, height: 3).offset(y: 21)
            Text(verbatim: "3")
                .font(.system(size: 7.5, weight: .bold))
                .foregroundStyle(.white)
                .frame(minWidth: 11, minHeight: 11)
                .background(Circle().fill(Tint.teal.color))
                .overlay(Circle().strokeBorder(.white, lineWidth: 1))
                .offset(x: 13, y: -17)
        }
        .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
    }

    private func card(_ color: Color, angle: Double, x: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
            .fill(LinearGradient(colors: [color.opacity(0.65), color], startPoint: .top, endPoint: .bottom))
            .frame(width: 20, height: 24)
            .padding(1.5)
            .background(RoundedRectangle(cornerRadius: 3.5, style: .continuous).fill(.white))
            .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
            .rotationEffect(.degrees(angle))
            .offset(x: x)
    }
}

/// The arrow pointer carrying two files.
private struct MiniDragCursor: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: -6) {
                RoundedRectangle(cornerRadius: 2).fill(Tint.orange.color.gradient).frame(width: 12, height: 15).rotationEffect(.degrees(-8))
                RoundedRectangle(cornerRadius: 2).fill(Tint.green.color.gradient).frame(width: 12, height: 15).rotationEffect(.degrees(6))
            }
            .opacity(0.9)
            .offset(x: 8, y: 12)
            Image(systemName: "cursorarrow")
                .font(.system(size: 15))
                .foregroundStyle(.black)
                .background(Image(systemName: "cursorarrow").font(.system(size: 17, weight: .black)).foregroundStyle(.white))
        }
    }
}
