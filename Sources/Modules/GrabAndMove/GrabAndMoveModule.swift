import MacToysCore
import SwiftUI

/// Grab And Move: hold the activation modifier (⌃⌘ by default) and left-drag anywhere in a window
/// to move it, or right-drag to resize it from the nearest edge or corner.
///
/// URL actions: `mactoys://grabandmove/open` (also `settings`) shows the settings page.
@MainActor
public final class GrabAndMoveModule: ToyModule {
    public let info = ModuleInfo(
        id: "grabandmove", name: "Grab And Move",
        summary: "Hold a modifier and drag anywhere in a window to move it, or right-drag to resize.",
        symbol: "arrow.up.and.down.and.arrow.left.and.right", tint: .mint, category: .windowing,
        permissions: [.accessibility], enabledByDefault: false,
        keywords: ["drag", "move window", "resize", "alt drag", "modifier"])

    let settings = Persisted("grabandmove", default: GrabAndMoveSettings())
    private lazy var controller = GrabController(settings: settings)
    private var running = false

    public init() {
        settings.onChange { [weak self] _ in
            guard let self, self.running else { return }
            self.controller.refreshConfig()
        }
    }

    public func start() {
        guard !running else { return }
        running = true
        controller.start()
    }

    public func stop() {
        guard running else { return }
        running = false
        controller.stop()
    }

    public func settingsView() -> AnyView {
        AnyView(GrabAndMoveSettingsView(module: self))
    }

    public var shortcutBindings: [ShortcutBinding] {
        let s = settings.value
        var list = [ShortcutBinding("Move a window", keys: ["Hold"] + s.activation.keys + ["Drag"])]
        if s.resizeWithRightDrag {
            list.append(ShortcutBinding("Resize a window", keys: ["Hold"] + s.activation.keys + ["Right-drag"]))
        }
        return list
    }

    public func handle(_ command: AppCommand) -> Bool {
        switch command.action {
        case "open", "show", "settings":
            ModuleRegistry.shared.showSettings?(info.id)
            return true
        default:
            return false
        }
    }

    public var previewScenes: [PreviewScene] {
        [PreviewScene("hud", size: CGSize(width: 900, height: 560)) { AnyView(GrabAndMovePreview()) }]
    }
}

struct GrabAndMoveSettingsView: View {
    let module: GrabAndMoveModule

    var body: some View {
        @Bindable var s = module.settings
        let v = s.value
        SettingsPage(module: module) {
            HeroCard(tint: .mint) {
                HStack(spacing: 28) {
                    gesture("Move", keys: v.activation.keys + ["Drag"], symbol: "arrow.up.and.down.and.arrow.left.and.right")
                    if v.resizeWithRightDrag {
                        gesture("Resize", keys: v.activation.keys + ["Right-drag"], symbol: "arrow.up.left.and.arrow.down.right")
                    }
                    Spacer(minLength: 0)
                    Text("Grab a window anywhere — no need to aim for the title bar or a thin border.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(maxWidth: 260, alignment: .trailing)
                        .multilineTextAlignment(.trailing)
                }
            }
        } content: {
            Section("Activation") {
                Picker(selection: $s.value.activation) {
                    ForEach(GrabAndMoveSettings.Activation.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: {
                    RowLabel("Activation modifier", subtitle: "Hold it, then drag inside any window")
                }
                Toggle(isOn: $s.value.resizeWithRightDrag) {
                    RowLabel("Resize windows with the modifier + right-drag",
                             subtitle: "Resizes from the edge or corner nearest to where you start")
                }
                Toggle(isOn: $s.value.bringToFront) {
                    RowLabel("Bring the window to the front when grabbing it")
                }
            }
            Section("Overlay") {
                Toggle(isOn: $s.value.showGeometry) {
                    RowLabel("Show window geometry", subtitle: "Position and size next to the pointer while dragging")
                }
            }
            Section("Excluded apps") {
                ExcludedAppsEditor("Excluded apps", apps: $s.value.excludedApps)
                ExcludedAppsEditor("Excluded apps (for modifier)", apps: $s.value.excludedForModifierApps)
                Text("While an app in the second list is in front, the modifier and clicks reach it as usual — useful for games and apps with their own modifier-drag gestures.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        }
    }

    private func gesture(_ title: String, keys: [String], symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.system(size: 13, weight: .semibold))
            Keycaps(["Hold"] + keys)
        }
    }
}

/// Snapshot scene: a window being dragged with the geometry readout next to the pointer.
private struct GrabAndMovePreview: View {
    @State private var model: GeometryReadoutModel = {
        let m = GeometryReadoutModel()
        m.frame = CGRect(x: 412, y: 188, width: 1280, height: 820)
        return m
    }()

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                HStack(spacing: 7) {
                    ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0.opacity(0.85)).frame(width: 12, height: 12) }
                    Spacer()
                    Text("Notes").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Color(white: 0.94))
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(0..<7, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 3).fill(Color(white: 0.87)).frame(width: CGFloat(420 - i * 41), height: 8)
                    }
                    Spacer()
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white)
            }
            .frame(width: 560, height: 360)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 26, y: 12)
            .position(x: 400, y: 250)
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 22))
                .foregroundStyle(.white)
                .shadow(radius: 2)
                .position(x: 470, y: 290)
            GeometryReadout(model: model)
                .position(x: 640, y: 335)
        }
    }
}
