import AppKit
import MacToysCore
import SwiftUI

/// Snapshot scenes: the palette under a window's green button, keyboard mode, the custom controls
/// editor and the saved layouts list.
@MainActor
enum WindowControlsPreviews {
    static var scenes: [PreviewScene] {
        [
            PreviewScene("palette", size: CGSize(width: 1440, height: 900)) { AnyView(PalettePreview()) },
            PreviewScene("keyboard", size: CGSize(width: 1440, height: 900)) { AnyView(KeyboardPreview()) },
            PreviewScene("controls-editor", size: CGSize(width: 920, height: 640), wallpaper: false) { AnyView(EditorPreview()) },
            PreviewScene("layouts", size: CGSize(width: 780, height: 430), wallpaper: false) { AnyView(LayoutsPreview()) },
        ]
    }

    /// A throwaway settings store, so previews never touch the user's settings.
    static func sampleSettings(_ s: WindowControlsSettings) -> Persisted<WindowControlsSettings> {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mactoys-windowcontrols-preview-\(UUID().uuidString)")
        return Persisted("windowcontrols", default: s, store: SettingsStore(directory: dir))
    }

    // MARK: Sample data

    static let builtIn = LayoutDisplay(key: "610-41262-0", name: "Built-in Retina Display",
                                       frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                       visible: CGRect(x: 0, y: 33, width: 1512, height: 949), isMain: true)
    static let studio = LayoutDisplay(key: "1552-44854-2049", name: "Studio Display",
                                      frame: CGRect(x: 1512, y: -240, width: 2560, height: 1440),
                                      visible: CGRect(x: 1512, y: -215, width: 2560, height: 1415), isMain: false)

    private static func window(_ bundle: String, _ app: String, _ index: Int = 0, _ title: String,
                               _ frame: CGRect, on display: LayoutDisplay) -> SavedWindow {
        SavedWindow(bundleID: bundle, appName: app, index: index, title: title, frame: frame, displayKey: display.key)
    }

    static var sampleLayouts: [SavedLayout] {
        let day: TimeInterval = 86_400
        let now = Date()
        return [
            SavedLayout(name: "Desk", displays: [builtIn, studio], windows: [
                window("com.apple.dt.Xcode", "Xcode", 0, "mactoys — WindowControls.swift",
                       CGRect(x: 1520, y: -207, width: 1696, height: 1399), on: studio),
                window("com.apple.iphonesimulator", "Simulator", 0, "iPhone 17 Pro",
                       CGRect(x: 3224, y: -207, width: 840, height: 1399), on: studio),
                window("com.apple.Safari", "Safari", 0, "Developer Documentation",
                       CGRect(x: 8, y: 41, width: 744, height: 933), on: builtIn),
                window("com.apple.Notes", "Notes", 0, "Release checklist", CGRect(x: 760, y: 41, width: 744, height: 462), on: builtIn),
                window("com.apple.MobileSMS", "Messages", 0, "Design team", CGRect(x: 760, y: 511, width: 744, height: 463), on: builtIn),
            ], created: now.addingTimeInterval(-2 * 3600), autoRestore: true, isAutomatic: true),
            SavedLayout(name: "Writing", displays: [builtIn], windows: [
                window("com.apple.iWork.Pages", "Pages", 0, "Chapter 4", CGRect(x: 512, y: 41, width: 488, height: 933), on: builtIn),
                window("com.apple.Notes", "Notes", 0, "Outline", CGRect(x: 8, y: 41, width: 496, height: 933), on: builtIn),
                window("com.apple.Safari", "Safari", 0, "Thesaurus", CGRect(x: 1008, y: 41, width: 496, height: 933), on: builtIn),
            ], created: now.addingTimeInterval(-3 * day)),
            SavedLayout(name: "Code review", displays: [builtIn, studio], windows: [
                window("com.github.GitHubClient", "GitHub Desktop", 0, "mactoys", CGRect(x: 1520, y: -207, width: 1272, height: 1399), on: studio),
                window("com.apple.dt.Xcode", "Xcode", 0, "Diff", CGRect(x: 2800, y: -207, width: 1264, height: 1399), on: studio),
                window("com.apple.Terminal", "Terminal", 0, "zsh", CGRect(x: 8, y: 41, width: 1496, height: 933), on: builtIn),
            ], created: now.addingTimeInterval(-9 * day)),
        ]
    }

    /// Two controls a user might add: a chain and a pinned size.
    static let customControls: [WindowControl] = [
        WindowControl(name: "Writing column", steps: [.display(.main), .resize(.points(900), .fraction(1), anchor: .center)],
                      shortcut: Shortcut(0x0D, [.control, .option, .command]), inPalette: true, inKeyboard: true),
        WindowControl(name: "Video corner", steps: [.resize(.points(640), .points(360), anchor: .bottomRight)],
                      inPalette: true, inKeyboard: false),
    ]
}

/// A menu bar strip for the scene desktops.
private struct MockMenuBar: View {
    let app: String

    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: "apple.logo").font(.system(size: 14, weight: .semibold))
            Text(verbatim: app).font(.system(size: 13, weight: .bold))
            ForEach(["File", "Edit", "View", "Window", "Help"], id: \.self) { Text(verbatim: $0).font(.system(size: 13)) }
            Spacer()
            Image(systemName: "wifi").font(.system(size: 13, weight: .semibold))
            Image(systemName: "battery.75percent").font(.system(size: 14))
            Text(verbatim: PreviewScene.menuBarClock(hour: 21, minute: 41)).font(.system(size: 13))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .frame(height: 30)
        .background(.black.opacity(0.18))
    }
}

/// The palette open under a Notes window's green button, the right half chosen on the grid.
private struct PalettePreview: View {
    var body: some View {
        let visible = CGRect(x: 0, y: 30, width: 1440, height: 870)
        let grid = GridSpec(columns: 6, rows: 4)
        let selection = grid.unitRect(from: GridCell(column: 3, row: 0), to: GridCell(column: 5, row: 3))
        let target = Placement.frame(for: selection, in: visible, spacing: Spacing(gap: 8, margin: 8))
        let model = HeroPalette.model(grid: grid, selection: selection,
                                      displays: [DisplayChoice(index: 1, name: "Studio Display")])
        model.gridSize = PaletteLayout.gridSize(for: visible)
        model.current = UnitRect(x: 90.0 / 1440, y: 74.0 / 870, width: 600.0 / 1440, height: 470.0 / 870)
        model.targetSize = target.size
        let window = CGRect(x: 90, y: 104, width: 600, height: 470)
        return ZStack(alignment: .topLeading) {
            Color.clear
            MockMenuBar(app: "Notes")
            MockAppWindow(title: "Field notes", accent: .orange, sidebar: true, hoverZoom: true)
                .frame(width: window.width, height: window.height)
                .offset(x: window.minX, y: window.minY)
            TargetOutline(label: "\(Int(target.width)) × \(Int(target.height))")
                .frame(width: target.width, height: target.height)
                .offset(x: target.minX, y: target.minY)
            PaletteView(model: model)
                .fixedSize()
                .offset(x: window.minX + 54 - 12 - PaletteLayout.shadowInset, y: window.minY + 33 - PaletteLayout.shadowInset)
        }
    }
}

/// Keyboard mode arranging a Mail window on the left half, with the cheat sheet.
private struct KeyboardPreview: View {
    @State private var model: KeyboardHUDModel = {
        let m = KeyboardHUDModel()
        m.appName = "Mail"
        m.appIcon = NSWorkspace.shared.icon(forFile: "/System/Applications/Mail.app")
        m.windowTitle = "Inbox — 12 unread"
        m.lastAction = BuiltInControls.title("left-half")
        var controls = BuiltInControls.all.filter(\.inKeyboard)
        controls.insert(WindowControlsPreviews.customControls[0], at: 5)
        m.controls = controls.prefix(9).enumerated().map { KeyboardHUDModel.NumberedControl(number: $0.offset + 1, control: $0.element) }
        m.multipleDisplays = true
        m.canUndo = true
        return m
    }()

    var body: some View {
        let visible = CGRect(x: 0, y: 30, width: 1440, height: 870)
        let left = Placement.frame(for: UnitRect(x: 0, y: 0, width: 0.5, height: 1), in: visible, spacing: Spacing(gap: 8, margin: 8))
        ZStack(alignment: .topLeading) {
            Color.clear
            MockMenuBar(app: "Mail")
            MockAppWindow(title: "Calendar", accent: .red)
                .frame(width: 640, height: 470)
                .offset(x: 760, y: 90)
            MockAppWindow(title: "Inbox — 12 unread", accent: .blue, sidebar: true)
                .frame(width: left.width, height: left.height)
                .offset(x: left.minX, y: left.minY)
            WindowRing()
                .frame(width: left.width + 20, height: left.height + 20)
                .offset(x: left.minX - 10, y: left.minY - 10)
            KeyboardHUDView(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 44)
        }
    }
}

/// The custom controls editor with a two-step chain selected.
private struct EditorPreview: View {
    private let settings: Persisted<WindowControlsSettings>
    private let state = ControlsEditorState()

    init() {
        var s = WindowControlsSettings()
        s.controls += WindowControlsPreviews.customControls
        settings = WindowControlsPreviews.sampleSettings(s)
        state.selection = WindowControlsPreviews.customControls[0].id
    }

    var body: some View {
        HostedToolWindowChrome(title: String(localized: "Custom Controls", comment: "Window title: the Window Controls editor"),
                               symbol: "macwindow.on.rectangle", tint: .green, actions: { EmptyView() }) {
            ControlsEditorView(settings: settings, state: state)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.controlActiveState, .key)
    }
}

/// The saved layouts list with three layouts, one saved automatically.
private struct LayoutsPreview: View {
    private let settings: Persisted<WindowControlsSettings>

    init() {
        var s = WindowControlsSettings()
        s.layouts = WindowControlsPreviews.sampleLayouts
        settings = WindowControlsPreviews.sampleSettings(s)
    }

    var body: some View {
        Form {
            Section("Saved layouts") {
                LayoutList(settings: settings, actions: LayoutActions(),
                           currentKey: DisplayArrangement.key([WindowControlsPreviews.builtIn, WindowControlsPreviews.studio]))
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
