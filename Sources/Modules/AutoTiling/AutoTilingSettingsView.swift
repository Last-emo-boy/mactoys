import AppKit
import MacToysCore
import SwiftUI

/// The Auto Tiling settings page.
struct AutoTilingSettingsView: View {
    let module: AutoTilingModule

    var body: some View {
        @Bindable var s = module.settings
        let v = s.value
        let status = module.engine.status
        SettingsPage(module: module) {
            AutoTilingHero(module: module)
        } content: {
            Section("Tiling") {
                if status.stageManager {
                    InfoBar(.info, title: "Paused while Stage Manager is on",
                            message: "Windows are tiled again as soon as you turn Stage Manager off.")
                } else if v.paused {
                    InfoBar(.info, title: Text("Tiling is paused"), message: Text("Windows stay where they are."),
                            actionTitle: Text("Resume")) { module.setPaused(false) }
                }
                Toggle(isOn: $s.value.paused) {
                    RowLabel("Pause tiling", subtitle: "Windows stay where they are until you resume")
                }
                Picker(selection: $s.value.maxWindows) {
                    ForEach(1...4, id: \.self) { n in Text(verbatim: n.formatted()).tag(n) }
                } label: {
                    RowLabel("Windows per display", subtitle: "Ultrawide displays take a fifth window when this is 4")
                }
                .pickerStyle(.segmented)
                Toggle(isOn: $s.value.stackWhenFull) {
                    RowLabel(title: Text("Stack when the screen is full"),
                             subtitle: v.stackWhenFull
                                ? Text("More windows share the tile you're working in; step through them with a shortcut")
                                : Text("More windows float where they open and join when a tile frees up"))
                }
            }

            Section {
                ForEach(status.displays) { d in
                    DisplayLayoutRow(display: d, layout: Binding(
                        get: { s.value.layout(for: d.id) },
                        set: { s.value.layouts[d.id] = $0 }))
                }
            } header: {
                Text("Layouts")
            } footer: {
                Text("Picking a display's layout again, or pressing its shortcut again, evens out tiles you resized.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }

            Section("Appearance") {
                SliderRow("Space between windows", subtitle: "Also kept along the display edges", value: $s.value.gap,
                          in: 0...24, step: 2) { "\(Int($0).formatted()) pt" }
                LabeledContent {
                    HighlightPicker(style: $s.value.highlight, color: highlightColor(v))
                } label: {
                    RowLabel("Highlight", subtitle: "Marks the windows Auto Tiling arranges")
                }
                Toggle(isOn: $s.value.highlightUsesAccent) { RowLabel("Use the accent color") }
                ColorRow("Highlight color", color: $s.value.highlightColor, supportsOpacity: false)
                    .disabled(v.highlightUsesAccent)
                EdgeReserveRow(reserve: $s.value.reserve, displays: status.displays)
            }

            Section("Mouse") {
                Toggle(isOn: $s.value.dragToSwap) {
                    RowLabel("Drag a window onto another to swap them", subtitle: "Hold ⌥ while you drop to float the window instead")
                }
                Toggle(isOn: $s.value.quickActionsAboveWindows) {
                    RowLabel("Quick actions above windows",
                             subtitle: "Point at the top edge of a tiled window to make it main, float it or send it to another display")
                }
                Toggle(isOn: $s.value.focusFollowsMouse) {
                    RowLabel("Activate windows on hover", subtitle: "The window under the pointer comes forward after a short pause")
                }
                SliderRow("Hover delay", value: $s.value.focusDelay, in: 100...1000, step: 50) {
                    Duration.milliseconds(Int($0)).formatted(.units(allowed: [.seconds, .milliseconds], width: .abbreviated,
                                                                    fractionalPart: .show(length: 2)))
                }
                .disabled(!v.focusFollowsMouse)
            }

            Section("Focus modes") {
                ModeRow(symbol: "arrow.up.left.and.arrow.down.right", title: "Focus",
                        detail: "Zooms the focused window to fill its display. Turn it off and the layout comes back.",
                        shortcut: v.focusModeShortcut)
                ModeRow(symbol: "eye.slash", title: "No peek",
                        detail: "Dims every window except the one you're using, for privacy on calls and in public.",
                        shortcut: v.noPeekShortcut)
                SliderRow("Darkness", value: $s.value.noPeekDarkness, in: 0.3...0.9, step: 0.05) {
                    $0.formatted(.percent.precision(.fractionLength(0)))
                }
                Toggle(isOn: $s.value.noPeekBlur) { RowLabel("Blur the dimmed windows") }
                ModeRow(symbol: "rectangle.inset.filled", title: "Clean Space",
                        detail: "For sharing your screen: the window fills its display and a plain backdrop covers everything else there.",
                        shortcut: v.cleanSpaceShortcut)
                ModeRow(symbol: "rectangle.split.2x2", title: "Tab View",
                        detail: "A switcher that shows each display's layout, with minimized windows below. Hold the modifiers, press the key to move on, let go to switch.",
                        shortcut: v.tabViewShortcut, hold: true)
            }

            Section("Keyboard") {
                Toggle(isOn: $s.value.keyboardShortcuts) { RowLabel("Keyboard shortcuts") }
                Group {
                    ShortcutRow("Grid layout", shortcut: $s.value.gridShortcut)
                    ShortcutRow("Columns layout", shortcut: $s.value.columnsShortcut)
                    ShortcutRow("Rows layout", shortcut: $s.value.rowsShortcut)
                    ShortcutRow("Side layout", shortcut: $s.value.sideShortcut)
                    ShortcutRow("Swap with the window on the left", subtitle: "At the display's edge the window moves to the next display",
                                shortcut: $s.value.swapLeft)
                    ShortcutRow("Swap with the window on the right", shortcut: $s.value.swapRight)
                    ShortcutRow("Swap with the window above", shortcut: $s.value.swapUp)
                    ShortcutRow("Swap with the window below", shortcut: $s.value.swapDown)
                    ShortcutRow("Make main window", shortcut: $s.value.makeMainShortcut)
                    ShortcutRow("Pause or resume tiling", shortcut: $s.value.pauseShortcut)
                }
                Group {
                    ShortcutRow("Next window in the stack", shortcut: $s.value.nextInStackShortcut)
                    ShortcutRow("Previous window in the stack", shortcut: $s.value.previousInStackShortcut)
                    ShortcutRow("Float or tile the window", shortcut: $s.value.floatShortcut)
                    ShortcutRow("Send to the next display", shortcut: $s.value.sendToDisplayShortcut)
                    ShortcutRow("Focus", shortcut: $s.value.focusModeShortcut)
                    ShortcutRow("No peek", shortcut: $s.value.noPeekShortcut)
                    ShortcutRow("Clean Space", shortcut: $s.value.cleanSpaceShortcut)
                    ShortcutRow("Tab View", subtitle: "Hold its modifier keys while you press the key again", shortcut: $s.value.tabViewShortcut)
                }
                .disabled(!v.keyboardShortcuts)
            }

            Section("Apps") {
                ExcludedAppsEditor("Don't tile these apps", apps: $s.value.excludedApps)
                LearnedSizesRow(module: module)
            }

            Section("Setups") {
                LabeledContent {
                    Button("Open Workspaces") { ModuleRegistry.shared.showSettings?("workspaces") }
                } label: {
                    RowLabel("Save and reopen app arrangements",
                             subtitle: "Workspaces launches a set of apps and puts their windows on each display; Auto Tiling keeps them tiled")
                }
            }
        }
        .onAppear { module.engine.publish() }
    }

    private func highlightColor(_ v: AutoTilingSettings) -> Color {
        v.highlightUsesAccent ? .accentColor : v.highlightColor.color
    }
}

// MARK: - Hero

/// A live miniature of the main display: its layout with the windows it tiles now (sample
/// windows while there are none), the highlight, gaps and edge reserve from the settings.
private struct AutoTilingHero: View {
    let module: AutoTilingModule

    var body: some View {
        let s = module.settings.value
        let status = module.engine.status
        let display = status.mainDisplay
        let kind = display?.kind ?? s.defaultLayout.kind
        HeroCard(tint: .indigo) {
            HStack(alignment: .center, spacing: 22) {
                HeroDesktop(display: display, settings: s, status: status, enabled: module.isEnabled)
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        title(kind: kind, display: display?.name)
                            .font(.system(size: 15, weight: .semibold))
                        subtitle(status: status, display: display, enabled: module.isEnabled)
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(TileLayoutKind.allCases) { k in
                            LayoutChoice(kind: k, selected: k == kind, shape: display?.shape ?? .landscape,
                                         main: (display?.main ?? s.defaultLayout.main).fraction,
                                         keys: s.keyboardShortcuts ? s.layoutShortcut(k)?.keys : nil) {
                                guard let display else { return }
                                var choice = s.layout(for: display.id)
                                choice.kind = k
                                module.settings.value.layouts[display.id] = choice
                            }
                        }
                        if s.keyboardShortcuts, let shortcut = s.layoutShortcut(kind) {
                            Keycaps(shortcut)
                                .frame(height: 54)
                                .padding(.leading, 6)
                                .help(Text("Shortcut for this layout", comment: "Auto Tiling hero: tooltip on the keycaps"))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func title(kind: TileLayoutKind, display: String?) -> Text {
        if let display {
            Text("\(kind.title) on \(display)", comment: "Auto Tiling hero: a layout name, then a display name")
        } else {
            Text(verbatim: kind.title)
        }
    }

    private func subtitle(status: TilingStatus, display: TilingStatus.Display?, enabled: Bool) -> Text {
        if !enabled { return Text("Turn on Auto Tiling and every window you open takes its place in the layout.") }
        if !status.running { return Text("Waiting for Accessibility access to arrange windows.") }
        if status.stageManager { return Text("Paused while Stage Manager is on.") }
        if status.paused { return Text("Paused. Windows stay where they are.") }
        let count = display?.tiles.count ?? 0
        let stacked = display?.tiles.reduce(0) { $0 + max(0, $1.apps.count - 1) } ?? 0
        if count == 0 { return Text("No windows on this display yet. New ones are tiled as they open.") }
        if stacked > 0 {
            return Text("\(count) tiles, \(stacked) more windows stacked.", comment: "Auto Tiling hero: tiles on the main display, then stacked windows")
        }
        return Text("\(count) windows tiled. Each display keeps its own layout.", comment: "Auto Tiling hero")
    }
}

/// The miniature desktop in the hero.
private struct HeroDesktop: View {
    let display: TilingStatus.Display?
    let settings: AutoTilingSettings
    let status: TilingStatus
    let enabled: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let aspect = min(max(display?.aspect ?? 1.6, 0.6), 2.6)
        let virtual = CGSize(width: (900 * aspect).rounded(), height: 900)
        let height: CGFloat = aspect < 1 ? 168 : 150
        let width = height * aspect
        let scale = width / virtual.width
        let tiles = liveTiles
        let kind = display?.kind ?? settings.defaultLayout.kind
        let main = (display?.main ?? settings.defaultLayout.main).fraction
        let shape = display?.shape ?? .landscape
        let reserve = display.flatMap { settings.reserve.applies(to: $0.id) ? settings.reserve : nil }
        let gap = settings.gapPoints
        let area = TileGeometry.area(visibleFrame: CGRect(x: 0, y: 40, width: virtual.width, height: virtual.height - 40),
                                     reserve: reserve, gap: gap)
        let frames = TileTree.make(kind, count: tiles.count, shape: shape, main: main).map { TileGeometry.frames($0, in: area, gap: gap) } ?? []
        let color = settings.highlightUsesAccent ? Color.accentColor : settings.highlightColor.color
        let tiling = enabled && status.isTiling
        ZStack(alignment: .topLeading) {
            DesktopWallpaper()
            Rectangle().fill(.white.opacity(0.22)).frame(height: 40)
            if let r = reserve, !r.isEmpty {
                reserveBands(r, size: virtual)
            }
            ForEach(Array(zip(frames.indices, frames)), id: \.0) { i, f in
                MiniWindow(apps: tiles[i], dark: scheme == .dark, radius: 26)
                    .frame(width: f.width, height: f.height)
                    .offset(x: f.minX, y: f.minY)
                HighlightShape(frame: f, radius: 26, style: settings.highlight, active: i == 0, color: color, gap: max(gap, 6) * 1.6)
                if tiles[i].count > 1 {
                    // In the miniature the gaps are too thin: the pips sit in the title bar.
                    StackPips(frame: f, count: tiles[i].count, gap: 8, color: color, scale: 3, centerY: f.minY + 35)
                }
            }
        }
        .frame(width: virtual.width, height: virtual.height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 40, style: .continuous))
        .scaleEffect(scale, anchor: .topLeading)
        .frame(width: width, height: height, alignment: .topLeading)
        .overlay {
            // Off, the hero shows what tiling looks like; dimmed only while tiling is held back.
            if enabled && status.running && !tiling {
                ZStack {
                    RoundedRectangle(cornerRadius: 40 * scale, style: .continuous).fill(.black.opacity(0.28))
                    Image(systemName: status.stageManager ? "square.stack.3d.forward.dottedline" : "pause.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .glassEffect(.regular, in: .circle)
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 40 * scale, style: .continuous).strokeBorder(.black.opacity(0.12)))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
        .animation(.smooth(duration: 0.3), value: frames)
        .accessibilityElement()
        .accessibilityLabel(Text("Layout preview"))
    }

    /// The windows of the main display's tiles, or sample apps while it has none.
    private var liveTiles: [[TilingStatus.App]] {
        let live = display?.tiles.map(\.apps).filter { !$0.isEmpty } ?? []
        if enabled && status.isTiling && !live.isEmpty { return live }
        let sample: [SampleApp] = [.safari, .notes, .terminal, .mail, .music]
        let n = min(max(display?.capacity ?? 3, 1), 3)
        return sample.prefix(n).map { [TilingStatus.App(bundleID: $0.bundleID, name: $0.name)] }
    }

    private func reserveBands(_ r: EdgeReserve, size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            let color = Color.white.opacity(0.16)
            if r.top > 0 { Rectangle().fill(color).frame(width: size.width, height: r.top).offset(y: 40) }
            if r.bottom > 0 { Rectangle().fill(color).frame(width: size.width, height: r.bottom).offset(y: size.height - r.bottom) }
            if r.left > 0 { Rectangle().fill(color).frame(width: r.left, height: size.height).offset(y: 0) }
            if r.right > 0 { Rectangle().fill(color).frame(width: r.right, height: size.height).offset(x: size.width - r.right) }
        }
    }
}

/// A window at hero scale: title bar and the app's icon.
private struct MiniWindow: View {
    let apps: [TilingStatus.App]
    let dark: Bool
    let radius: CGFloat

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height) * 0.34
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: radius, style: .continuous).fill(dark ? Color(white: 0.2) : .white)
                Rectangle().fill(dark ? Color(white: 0.25) : Color(white: 0.94)).frame(height: 70)
                HStack(spacing: 14) {
                    ForEach(0..<3, id: \.self) { i in
                        Circle().fill([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18),
                                       Color(red: 0.16, green: 0.79, blue: 0.25)][i]).frame(width: 22, height: 22)
                    }
                    Spacer()
                }
                .padding(.leading, 28).frame(height: 70)
                icon.frame(width: side, height: side).frame(maxWidth: .infinity, maxHeight: .infinity).padding(.top, 50)
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
        }
    }

    @ViewBuilder private var icon: some View {
        if let image = AppIcons.icon(bundleID: apps.first?.bundleID) {
            Image(nsImage: image).resizable().interpolation(.high)
        } else {
            Image(systemName: "macwindow").resizable().scaledToFit().foregroundStyle(.secondary)
        }
    }
}

/// A layout button: diagram, name and shortcut.
private struct LayoutChoice: View {
    let kind: TileLayoutKind
    let selected: Bool
    var shape: DisplayShape = .landscape
    var main = 0.5
    var keys: [String]?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                LayoutDiagram(kind: kind, count: shape == .ultrawide ? 5 : 4, shape: shape, main: main, selected: selected)
                    .frame(width: shape == .portrait ? 34 : 64, height: shape == .portrait ? 54 : 40)
                    .frame(width: 70, height: 54)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: selected ? 2 : 1))
                Text(verbatim: kind.title)
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .fixedSize()
            }
        }
        .buttonStyle(.plain)
        .help(keys.map { Text("\(kind.title) — \($0.joined())", comment: "Tooltip: a layout name and its shortcut") } ?? Text(verbatim: kind.title))
        .accessibilityLabel(Text(verbatim: kind.title))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Rows

/// One display's layout: four layout buttons and the main window size.
private struct DisplayLayoutRow: View {
    let display: TilingStatus.Display
    @Binding var layout: DisplayLayout

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(.secondary).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: display.name).fontWeight(.medium)
                    Text("\(display.shape.title) · up to \(display.capacity) windows",
                         comment: "Auto Tiling: the display's shape, then how many windows it tiles")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                HStack(spacing: 8) {
                    Text("Main window").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize()
                    Picker(selection: $layout.main) {
                        ForEach(MainSize.allCases) { Text(verbatim: $0.title).tag($0) }
                    } label: { Text("Main window") }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .fixedSize()
                }
                .disabled(!layout.kind.hasMainWindow)
                .opacity(layout.kind.hasMainWindow ? 1 : 0.5)
                .help(layout.kind.hasMainWindow ? Text("How much of the display the main window takes")
                                                : Text("Columns and Rows share the display evenly"))
            }
            HStack(spacing: 10) {
                ForEach(TileLayoutKind.allCases) { k in
                    LayoutChoice(kind: k, selected: layout.kind == k, shape: display.shape, main: layout.main.fraction) {
                        layout.kind = k
                    }
                }
            }
            .padding(.leading, 32)
        }
        .padding(.vertical, 4)
    }

    private var symbol: String {
        if display.shape == .portrait { return "rectangle.portrait" }
        return display.isBuiltIn ? "laptopcomputer" : "display"
    }
}

/// The four highlight styles as small pictures.
private struct HighlightPicker: View {
    @Binding var style: HighlightStyle
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            ForEach(HighlightStyle.allCases) { h in
                Button { style = h } label: {
                    VStack(spacing: 5) {
                        thumbnail(h)
                            .frame(width: 64, height: 40)
                            .padding(5)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
                            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(style == h ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: style == h ? 2 : 1))
                        Text(verbatim: h.title).font(.system(size: 10.5, weight: style == h ? .semibold : .regular))
                            .foregroundStyle(style == h ? Color.accentColor : .secondary)
                            .fixedSize()
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: h.title))
            }
        }
    }

    private func thumbnail(_ h: HighlightStyle) -> some View {
        let a = CGRect(x: 3, y: 3, width: 33, height: 34), b = CGRect(x: 40, y: 3, width: 21, height: 34)
        return ZStack(alignment: .topLeading) {
            ForEach([a, b], id: \.minX) { f in
                RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.primary.opacity(0.16))
                    .frame(width: f.width, height: f.height).offset(x: f.minX, y: f.minY)
            }
            HighlightShape(frame: a, radius: 4, style: h, active: true, color: color, gap: 4)
            HighlightShape(frame: b, radius: 4, style: h, active: false, color: color, gap: 4)
        }
        .frame(width: 64, height: 40, alignment: .topLeading)
    }
}

/// Room kept free along display edges.
private struct EdgeReserveRow: View {
    @Binding var reserve: EdgeReserve
    let displays: [TilingStatus.Display]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RowLabel("Keep room along screen edges", subtitle: "For a dock or menu bar from another app; windows stay clear of it")
            HStack(spacing: 16) {
                field(Text("Top", comment: "Screen edge"), value: $reserve.top)
                field(Text("Bottom", comment: "Screen edge"), value: $reserve.bottom)
                field(Text("Left", comment: "Screen edge"), value: $reserve.left)
                field(Text("Right", comment: "Screen edge"), value: $reserve.right)
            }
            Picker(selection: $reserve.display) {
                Text("Every display").tag(String?.none)
                ForEach(displays) { d in Text(verbatim: d.name).tag(String?.some(d.id)) }
            } label: {
                Text("Keep it on")
            }
            .fixedSize()
        }
        .padding(.vertical, 2)
    }

    private func field(_ title: Text, value: Binding<Double>) -> some View {
        let clamped = Binding(get: { value.wrappedValue }, set: { value.wrappedValue = min(max(($0).rounded(), 0), 400) })
        return HStack(spacing: 5) {
            title.foregroundStyle(.secondary).font(.system(size: 12))
            TextField(value: clamped, format: .number) { title }
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 48)
            Stepper(value: clamped, in: 0...400, step: 4) { title }.labelsHidden()
        }
    }
}

/// A focus mode: what it does and its shortcut.
private struct ModeRow: View {
    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let shortcut: Shortcut?
    var hold = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Tint.indigo.color)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Tint.indigo.color.opacity(0.12)))
            RowLabel(title, subtitle: detail)
            Spacer(minLength: 12)
            if let shortcut {
                HStack(spacing: 4) {
                    if hold { Text("Hold", comment: "Keycap label: hold down the keys that follow").font(.system(size: 11)).foregroundStyle(.secondary) }
                    Keycaps(shortcut)
                }
            } else {
                Text("No shortcut", comment: "A feature without a keyboard shortcut; assign one below")
                    .font(.system(size: 11.5)).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Learned minimum sizes, with a way to forget them.
private struct LearnedSizesRow: View {
    let module: AutoTilingModule

    var body: some View {
        let count = module.learned.value.count
        LabeledContent {
            Button("Forget") { module.engine.forgetLearnedSizes() }
                .disabled(count == 0)
        } label: {
            RowLabel(title: Text("Learned minimum sizes"),
                     subtitle: count == 0
                        ? Text("None yet. When an app won't get as small as its tile, Auto Tiling remembers how small it goes.")
                        : Text("\(count) apps. Kept only on this Mac.", comment: "Number of apps whose minimum window size is known"))
        }
    }
}
