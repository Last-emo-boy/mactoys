import AppKit
import MacToysCore
import SwiftUI

/// The Window Controls settings page.
struct WindowControlsSettingsView: View {
    let module: WindowControlsModule

    var body: some View {
        @Bindable var s = module.settings
        let v = s.value
        SettingsPage(module: module) {
            WindowControlsHero(module: module)
        } content: {
            Section("Zoom button palette") {
                Toggle(isOn: $s.value.paletteEnabled) {
                    RowLabel("Show the palette when the pointer rests on a window's green button",
                             subtitle: "A grid to drag out any size, your controls, and your other displays")
                }
                Group {
                    SliderRow("Hover delay", value: $s.value.hoverDelay, in: 0.1...1.0, step: 0.05) {
                        Measurement(value: $0, unit: UnitDuration.seconds)
                            .formatted(.measurement(width: .narrow, numberFormatStyle: .number.precision(.fractionLength(2))))
                    }
                    LabeledContent {
                        HStack(spacing: 8) {
                            Stepper(value: $s.value.gridColumns, in: 2...12) {
                                Text(verbatim: "\(v.gridColumns)").monospacedDigit().frame(minWidth: 18, alignment: .trailing)
                            }
                            Text(verbatim: "×").foregroundStyle(.secondary)
                            Stepper(value: $s.value.gridRows, in: 2...12) {
                                Text(verbatim: "\(v.gridRows)").monospacedDigit().frame(minWidth: 18, alignment: .trailing)
                            }
                        }
                        .fixedSize()
                    } label: {
                        RowLabel("Grid", subtitle: "Columns × rows of the resize grid")
                    }
                    Toggle(isOn: $s.value.swapGridOnPortrait) {
                        RowLabel(title: Text("Turn the grid on portrait displays"),
                                 subtitle: Text("A \(v.gridColumns) × \(v.gridRows) grid becomes \(v.gridRows) × \(v.gridColumns) on a display standing upright",
                                                comment: "Window Controls: grid columns × rows, then the same swapped"))
                    }
                    Toggle(isOn: $s.value.showPreview) {
                        RowLabel("Outline where the window will go", subtitle: "While you drag across the grid or point at a control")
                    }
                }
                .disabled(!v.paletteEnabled)
                Toggle(isOn: $s.value.doubleClickFills) {
                    RowLabel("Double-click the green button to fill the screen",
                             subtitle: "Double-click again to put the window back. A single click waits a moment to tell the two apart, then works as usual.")
                }
            }

            Section("Keyboard mode") {
                ShortcutRow("Keyboard mode", subtitle: "Arrange the focused window with the arrows, Space, Return and number keys",
                            shortcut: $s.value.keyboardShortcut)
                Toggle(isOn: $s.value.stayInKeyboardMode) {
                    RowLabel("Stay in keyboard mode after each move", subtitle: "Esc, a click or 20 seconds without a key leave it")
                }
                Toggle(isOn: $s.value.showCheatSheet) {
                    RowLabel("Show the list of keys")
                }
                SliderRow("Nudge distance", subtitle: "⌥-arrows; with ⇧ the window moves 1 pt", value: $s.value.nudgeStep, in: 2...100, step: 1) {
                    String(localized: "\(Int($0)) pt", comment: "A distance in points")
                }
                SliderRow("Resize step", subtitle: "⇧-arrows make the window narrower, wider, shorter or taller",
                          value: $s.value.resizeStep, in: 8...240, step: 4) {
                    String(localized: "\(Int($0)) pt", comment: "A distance in points")
                }
            }

            Section("Custom controls") {
                ControlTiles(module: module)
            }

            Section("Saved layouts") {
                LayoutList(settings: module.settings, actions: LayoutActions(
                    restore: { module.restoreLayout($0) }, update: { module.updateLayout($0) },
                    delete: { module.deleteLayout($0) }, save: { module.saveLayout(name: nil) }))
                ShortcutRow("Save layout", subtitle: "Saves the windows on screen as a new layout", shortcut: $s.value.saveLayoutShortcut)
                ShortcutRow("Restore layout", subtitle: "Restores the newest layout saved for the displays connected now",
                            shortcut: $s.value.restoreLayoutShortcut)
                Toggle(isOn: $s.value.autoSaveOnDisconnect) {
                    RowLabel("Save the windows when a display disconnects",
                             subtitle: "Unplugging a monitor keeps how your windows were arranged on it")
                }
                Toggle(isOn: $s.value.autoRestoreLayouts) {
                    RowLabel("Restore layouts when their displays come back",
                             subtitle: "Plugging the monitor back in puts the windows where they were. Missing apps and windows are skipped.")
                }
                InfoBar(.info, title: "Want the apps opened too?",
                        message: "Workspaces launches apps into saved positions; saved layouts arrange windows that are already open.",
                        actionTitle: "Open Workspaces") {
                    ModuleRegistry.shared.showSettings?("workspaces")
                }
            }

            Section("Window placement") {
                SliderRow("Gap between windows", value: $s.value.gap, in: 0...40, step: 1) {
                    String(localized: "\(Int($0)) pt", comment: "A distance in points")
                }
                SliderRow("Margin at the screen edges", subtitle: "Windows never cover the menu bar, the notch or the Dock",
                          value: $s.value.edgeMargin, in: 0...40, step: 1) {
                    String(localized: "\(Int($0)) pt", comment: "A distance in points")
                }
                Toggle(isOn: $s.value.bringToFront) {
                    RowLabel("Bring windows to the front when arranging them",
                             subtitle: "Also windows arranged from the palette while in the background")
                }
                if ModuleRegistry.shared.module("autotile") != nil {
                    Text("On a display Auto Tiling arranges, Window Controls leaves the tiled windows alone and says so.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Excluded apps") {
                ExcludedAppsEditor("Apps Window Controls leaves alone", apps: $s.value.excludedApps)
            }

            Section("Other ways to use it") {
                LabeledContent {
                    VStack(alignment: .trailing, spacing: 3) {
                        ForEach(["keyboard", "control?name=Left Half", "save-layout?name=…", "restore-layout?name=…"], id: \.self) { a in
                            Text(verbatim: "mactoys://windowcontrols/\(a)")
                        }
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                } label: {
                    RowLabel("URLs", subtitle: "From scripts, Shortcuts or other apps")
                }
            }
        }
    }
}

// MARK: - Hero

/// The hero: a miniature desktop with the palette open under a window's green button, drawn from
/// the current grid and spacing, and the ways in.
private struct WindowControlsHero: View {
    let module: WindowControlsModule

    var body: some View {
        let s = module.settings.value
        HeroCard(tint: .green) {
            HStack(alignment: .center, spacing: 24) {
                HeroDesktop(settings: s)
                    .frame(width: 340, height: 212)
                VStack(alignment: .leading, spacing: 9) {
                    Text("Rest the pointer on any window's green button")
                        .font(.system(size: 14, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Drag across the grid to size the window to those cells, or pick a half, a third or a custom size. Keyboard mode does the same with arrows and number keys.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button("Keyboard Mode") { module.enterKeyboardMode() }
                            .buttonStyle(.borderedProminent)
                        Keycaps(s.keyboardShortcut)
                    }
                    .padding(.top, 2)
                    Button("Edit Controls…") { module.openControlsEditor() }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// A small desktop: a window, the palette under its green button with a grid selection, and the
/// outline of where the window will go.
struct HeroDesktop: View {
    let settings: WindowControlsSettings

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let menuBar: CGFloat = 9
            let visible = CGRect(x: 0, y: menuBar, width: size.width, height: size.height - menuBar)
            // The real spacing scaled to the miniature (a 1512-point-wide display).
            let k = size.width / 1512
            let spacing = Spacing(gap: CGFloat(settings.gap) * k, margin: CGFloat(settings.edgeMargin) * k)
            let grid = GridSpec(columns: settings.gridColumns, rows: settings.gridRows)
            let selection = grid.unitRect(from: GridCell(column: grid.columns / 2, row: 0),
                                          to: GridCell(column: grid.columns - 1, row: grid.rows - 1))
            let target = Placement.frame(for: selection, in: visible, spacing: spacing)
            let windowOrigin = CGPoint(x: (size.width * 0.05).rounded(), y: menuBar + 10)
            let scale: CGFloat = 0.44
            MiniWallpaper()
                .overlay(alignment: .topLeading) {
                    ZStack(alignment: .topLeading) {
                        Rectangle().fill(.white.opacity(0.28)).frame(height: menuBar)
                        MockAppWindow(title: "Field notes", accent: .orange, compact: true, hoverZoom: true)
                            .frame(width: size.width * 0.5, height: size.height * 0.56)
                            .offset(x: windowOrigin.x, y: windowOrigin.y)
                        TargetOutlineMini()
                            .frame(width: target.width, height: target.height)
                            .offset(x: target.minX, y: target.minY)
                    }
                }
                .overlay(alignment: .topLeading) {
                    // Hangs under the green button, as the real one does.
                    PaletteView(model: HeroPalette.model(grid: grid, selection: selection))
                        .fixedSize()
                        .scaleEffect(scale, anchor: .topLeading)
                        .offset(x: windowOrigin.x + 14 - PaletteLayout.shadowInset * scale,
                                y: windowOrigin.y + 17 - PaletteLayout.shadowInset * scale)
                        .allowsHitTesting(false)
                }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.black.opacity(0.12)))
        }
        .accessibilityElement()
        .accessibilityLabel(Text("A window with the Window Controls palette open under its green button",
                                 comment: "Accessibility: the hero illustration"))
    }
}

/// Sample palette state for the hero and the snapshot scenes.
@MainActor
enum HeroPalette {
    static func model(grid: GridSpec, selection: UnitRect?, controls: [WindowControl] = BuiltInControls.all.filter(\.inPalette),
                      displays: [DisplayChoice] = []) -> PaletteModel {
        let m = PaletteModel()
        m.appName = "Notes"
        m.windowTitle = "Field notes"
        m.appIcon = NSWorkspace.shared.icon(forFile: "/System/Applications/Notes.app")
        m.grid = grid
        m.gridSize = PaletteLayout.gridSize(for: CGRect(x: 0, y: 0, width: 1512, height: 949))
        m.current = UnitRect(x: 0.05, y: 0.04, width: 0.5, height: 0.58)
        m.controls = controls
        m.displays = displays
        if let selection {
            m.dragStart = GridCell(column: Int((selection.x * Double(grid.columns)).rounded()), row: Int((selection.y * Double(grid.rows)).rounded()))
            m.dragEnd = GridCell(column: Int((selection.maxX * Double(grid.columns)).rounded()) - 1,
                                 row: Int((selection.maxY * Double(grid.rows)).rounded()) - 1)
        }
        return m
    }
}

private struct TargetOutlineMini: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(Color.accentColor.opacity(0.2))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 1.5))
    }
}

/// The wallpaper used behind miniature desktops.
struct MiniWallpaper: View {
    var body: some View {
        LinearGradient(colors: [Color(red: 0.09, green: 0.13, blue: 0.36), Color(red: 0.24, green: 0.17, blue: 0.56),
                                Color(red: 0.6, green: 0.25, blue: 0.53), Color(red: 0.88, green: 0.54, blue: 0.42)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: - Custom controls

/// Every control as a small tile; a tile opens the editor on it.
private struct ControlTiles: View {
    let module: WindowControlsModule

    var body: some View {
        let s = module.settings.value
        let numbers = Dictionary(uniqueKeysWithValues: s.keyboardControls.enumerated().map { ($0.element.id, $0.offset + 1) })
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 116, maximum: 160), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(s.controls) { c in
                    Button { module.openControlsEditor(selecting: c.id) } label: {
                        VStack(spacing: 6) {
                            ControlGlyph(c, style: .light)
                                .frame(width: 44, height: 28)
                            Text(verbatim: c.displayName)
                                .font(.system(size: 11))
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity)
                        }
                        .padding(.vertical, 9)
                        .padding(.horizontal, 6)
                        .frame(maxWidth: .infinity, minHeight: 74, alignment: .top)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.04)))
                        .overlay(alignment: .topTrailing) { badges(c, number: numbers[c.id]).padding(5) }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(Text(verbatim: c.shortcut.map { "\(c.displayName)  \($0.description)" } ?? c.displayName))
                }
            }
            HStack(spacing: 10) {
                Text("\(s.paletteControls.count) in the palette · \(s.keyboardControls.count) numbered in keyboard mode",
                     comment: "Window Controls: how many controls show in the palette and in keyboard mode")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                Spacer()
                Button("Edit Controls…") { module.openControlsEditor() }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func badges(_ c: WindowControl, number: Int?) -> some View {
        HStack(spacing: 3) {
            if c.shortcut != nil {
                Image(systemName: "command").font(.system(size: 8.5, weight: .semibold)).foregroundStyle(.secondary)
            }
            if let number {
                Text(verbatim: "\(number)")
                    .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
                    .background(RoundedRectangle(cornerRadius: 3.5, style: .continuous).strokeBorder(.secondary.opacity(0.45)))
            }
        }
    }
}

// MARK: - Saved layouts

/// What the layout list can ask the module to do.
struct LayoutActions {
    var restore: (UUID) -> Void = { _ in }
    var update: (UUID) -> Void = { _ in }
    var delete: (UUID) -> Void = { _ in }
    var save: () -> Void = {}
}

/// Saved layouts with a miniature of each arrangement.
struct LayoutList: View {
    let settings: Persisted<WindowControlsSettings>
    let actions: LayoutActions
    /// The arrangement connected now, to mark its layouts (nil in previews to use the first layout's).
    var currentKey: String? = nil
    @State private var renaming: UUID?
    @State private var newName = ""

    var body: some View {
        @Bindable var s = settings
        let layouts = s.value.layouts.sorted { $0.created > $1.created }
        let here = currentKey ?? DisplayArrangement.key(Screens.layoutDisplays())
        VStack(alignment: .leading, spacing: 0) {
            if layouts.isEmpty {
                HStack(spacing: 14) {
                    Image(systemName: "rectangle.3.group")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(.secondary)
                        .frame(width: 84)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("No saved layouts", comment: "Window Controls: the layout list is empty").fontWeight(.medium)
                        Text("Arrange your windows, then save them here or with a shortcut. When you unplug a display, the windows on it are saved for you.",
                             comment: "Window Controls: what to do when there are no saved layouts")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 8)
            }
            ForEach(layouts) { layout in
                row(layout, current: layout.arrangementKey == here)
                Divider().padding(.leading, 96)
            }
            HStack {
                Spacer()
                Button("Save Current Layout") { actions.save() }
            }
            .padding(.top, 10)
        }
        .alert(Text("Rename Layout", comment: "Alert title: rename a saved window layout"),
               isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(text: $newName) { Text("Name", comment: "Field: the layout's name") }
            Button("Rename") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                if let id = renaming, !name.isEmpty, let i = settings.value.layouts.firstIndex(where: { $0.id == id }) {
                    settings.value.layouts[i].name = name
                }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private func row(_ layout: SavedLayout, current: Bool) -> some View {
        HStack(spacing: 12) {
            LayoutMiniature(layout: layout)
                .frame(width: 84, height: 52)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(verbatim: layout.name).fontWeight(.medium).lineLimit(1)
                    if layout.isAutomatic {
                        badge(Text("Saved automatically", comment: "Badge: the layout was saved when a display disconnected"), color: .secondary)
                    }
                    if current {
                        badge(Text("These displays", comment: "Badge: the layout was saved for the displays connected now"), color: Tint.green.color)
                    }
                }
                Text(summary(layout))
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if layout.autoRestore {
                    Label {
                        Text("Restores when these displays connect", comment: "Window Controls: the layout comes back on its own")
                    } icon: {
                        Image(systemName: "arrow.uturn.backward.circle")
                    }
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Button { actions.restore(layout.id) } label: {
                Text("Restore", comment: "Button: restore the saved window layout")
            }
            Menu {
                Button("Rename…") {
                    newName = layout.name
                    renaming = layout.id
                }
                Button("Update to Current Windows") { actions.update(layout.id) }
                Toggle(isOn: Binding(get: { layout.autoRestore }, set: { on in
                    if let i = settings.value.layouts.firstIndex(where: { $0.id == layout.id }) { settings.value.layouts[i].autoRestore = on }
                })) {
                    Text("Restore When These Displays Connect", comment: "Menu item: restore the layout on its own")
                }
                Divider()
                Button("Delete", role: .destructive) { actions.delete(layout.id) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 8)
    }

    private func badge(_ text: Text, color: Color) -> some View {
        text.font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(color.opacity(0.12)))
            .fixedSize()
    }

    private func summary(_ layout: SavedLayout) -> String {
        let displays = DisplayArrangement.name(of: layout.displays)
        return String(localized: "\(layout.windows.count) windows · \(layout.appCount) apps · \(displays)",
                      comment: "Saved layout summary: windows, apps, then the names of its displays")
    }
}

/// A miniature of a saved arrangement: its displays, and each window in its app's color.
struct LayoutMiniature: View {
    let layout: SavedLayout

    var body: some View {
        Canvas { ctx, size in
            let union = layout.displays.map(\.frame).reduce(CGRect.null) { $0.union($1) }
            guard !union.isNull, union.width > 0, union.height > 0 else { return }
            let scale = min((size.width - 2) / union.width, (size.height - 2) / union.height)
            let ox = (size.width - union.width * scale) / 2, oy = (size.height - union.height * scale) / 2
            func map(_ r: CGRect) -> CGRect {
                CGRect(x: ox + (r.minX - union.minX) * scale, y: oy + (r.minY - union.minY) * scale,
                       width: r.width * scale, height: r.height * scale)
            }
            for d in layout.displays {
                let r = map(d.frame).insetBy(dx: 0.5, dy: 0.5)
                let shape = Path(roundedRect: r, cornerRadius: 3, style: .continuous)
                ctx.fill(shape, with: .color(.primary.opacity(0.07)))
                ctx.stroke(shape, with: .color(.primary.opacity(0.3)), lineWidth: 1)
            }
            // Back to front, so the frontmost window is drawn last.
            for w in layout.windows.reversed() {
                let r = map(w.frame).insetBy(dx: 0.6, dy: 0.6)
                guard r.width > 1, r.height > 1 else { continue }
                let shape = Path(roundedRect: r, cornerRadius: 1.8, style: .continuous)
                ctx.fill(shape, with: .color(AppColor.color(for: w.bundleID)))
                ctx.stroke(shape, with: .color(.white.opacity(0.7)), lineWidth: 0.6)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A steady color per app for miniatures.
enum AppColor {
    private static let tints: [Tint] = [.blue, .orange, .teal, .purple, .pink, .green, .indigo, .yellow, .mint, .red]

    static func color(for bundleID: String) -> Color { tints[index(for: bundleID)].color }

    /// Stable across launches (Swift's own hashing is seeded per process).
    static func index(for bundleID: String) -> Int {
        var h: UInt32 = 5381
        for b in bundleID.utf8 { h = (h &* 33) &+ UInt32(b) }
        return Int(h % UInt32(tints.count))
    }
}

// MARK: - Mock window

/// A plain app window drawn in code, for the hero and the snapshot scenes.
struct MockAppWindow: View {
    let title: String
    var accent: Color = .blue
    var compact = false
    var sidebar = false
    /// Rings the green button, as when the pointer rests on it.
    var hoverZoom = false

    var body: some View {
        let bar: CGFloat = compact ? 14 : 38
        let light: CGFloat = compact ? 4.5 : 12
        VStack(spacing: 0) {
            ZStack {
                HStack(spacing: compact ? 3 : 8) {
                    Circle().fill(Color(red: 1, green: 0.37, blue: 0.34)).frame(width: light, height: light)
                    Circle().fill(Color(red: 1, green: 0.74, blue: 0.18)).frame(width: light, height: light)
                    Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.25)).frame(width: light, height: light)
                        .overlay {
                            if hoverZoom {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.system(size: light * 0.55, weight: .black))
                                    .foregroundStyle(.black.opacity(0.55))
                            }
                        }
                    Spacer()
                }
                if !compact {
                    Text(verbatim: title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.black.opacity(0.72))
                }
            }
            .padding(.horizontal, compact ? 5 : 14)
            .frame(height: bar)
            .background(Color(white: 0.955))
            HStack(spacing: 0) {
                if sidebar {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(0..<6, id: \.self) { i in
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 3).fill(i == 0 ? accent : Color.black.opacity(0.16)).frame(width: 12, height: 12)
                                Capsule().fill(Color.black.opacity(0.13)).frame(width: CGFloat(54 + (i * 13) % 30), height: 7)
                            }
                        }
                        Spacer()
                    }
                    .padding(14)
                    .frame(width: 150)
                    .frame(maxHeight: .infinity)
                    .background(Color(white: 0.93))
                }
                VStack(alignment: .leading, spacing: compact ? 4 : 11) {
                    Capsule().fill(accent.opacity(0.75)).frame(width: compact ? 40 : 160, height: compact ? 4 : 10)
                    ForEach(0..<(compact ? 6 : 12), id: \.self) { i in
                        Capsule().fill(Color.black.opacity(0.1))
                            .frame(width: CGFloat(compact ? 34 + (i * 17) % 50 : 140 + (i * 47) % 220), height: compact ? 3 : 7)
                    }
                    Spacer(minLength: 0)
                }
                .padding(compact ? 7 : 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: compact ? 5 : 12, style: .continuous))
        .shadow(color: .black.opacity(0.28), radius: compact ? 6 : 22, y: compact ? 3 : 10)
        .environment(\.colorScheme, .light)
    }
}
