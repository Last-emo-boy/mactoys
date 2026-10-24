import AppKit
import MacToysCore
import SwiftUI

struct WindowHopperSettingsView: View {
    let module: WindowHopperModule

    var body: some View {
        @Bindable var s = module.settings
        SettingsPage(module: module) {
            HeroCard(tint: .indigo) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Text("Hold").font(.system(size: 13, weight: .semibold))
                        Keycaps(s.value.next.map { $0.modifiers.symbols } ?? [])
                        Text("and press").font(.system(size: 13, weight: .semibold))
                        Keycaps(s.value.next.map { [KeyCodes.name(for: $0.keyCode)] } ?? [])
                        Text("to hop between the windows of the app you're using").font(.system(size: 13, weight: .semibold))
                    }
                    Text("Keep pressing the key to move on, add ⇧ to go back, use the arrow keys or point at a window. Release to switch; esc closes without switching. It doesn't open when the app has fewer than two windows.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    WindowHopperPreview(previews: true)
                        .frame(width: 680, height: 240)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.75)))
                        .scaleEffect(0.62, anchor: .topLeading)
                        .frame(width: 680 * 0.62, height: 240 * 0.62, alignment: .topLeading)
                        .allowsHitTesting(false)
                }
            }
        } content: {
            Section("Shortcuts") {
                ShortcutRow("Next window", subtitle: "Its modifiers stay held while you hop", shortcut: $s.value.next)
                ShortcutRow("Previous window", shortcut: $s.value.previous)
            }
            Section("Windows") {
                Toggle(isOn: $s.value.includeMinimized) {
                    RowLabel("Include minimized windows", subtitle: "Switching to one brings it back from the Dock")
                }
                Toggle(isOn: $s.value.showPreviews) {
                    RowLabel("Show window previews",
                             subtitle: "Needs Screen Recording. Without it, windows are shown as app icons with their titles")
                }
            }
        }
    }
}

/// Snapshot scene and hero sample: Safari with three windows, the second selected.
struct WindowHopperPreview: View {
    let previews: Bool

    var body: some View {
        let model = Self.sampleModel(previews: previews)
        let size = HopperLogic.panelSize(count: model.cards.count, maxWidth: previews ? 800 : 1100)
        HopperHUD(model: model)
            .frame(width: size.width, height: size.height)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @MainActor static func sampleModel(previews: Bool) -> HopperModel {
        let m = HopperModel()
        m.appName = "Safari"
        let safari = URL(fileURLWithPath: "/Applications/Safari.app").resolvingSymlinksInPath().path
        m.appIcon = FileManager.default.fileExists(atPath: safari) ? NSWorkspace.shared.icon(forFile: safari)
            : NSImage(systemSymbolName: "safari", accessibilityDescription: nil)
        let titles = previews
            ? ["Apple Developer Documentation", "PowerToys 0.102 release notes", "GitHub — mactoys"]
            : ["Apple Developer Documentation", "PowerToys 0.102 release notes", "GitHub — mactoys",
               "Swift Forums", "Downloads"]
        m.cards = titles.enumerated().map { i, t in
            HopperModel.Card(id: CGWindowID(i + 1), title: t, isMinimized: !previews && i == titles.count - 1)
        }
        m.selection = 1
        m.showThumbnails = previews
        m.columns = HopperLogic.columns(count: titles.count, maxWidth: previews ? 800 : 1100)
        if previews {
            for (i, card) in m.cards.enumerated() {
                let r = ImageRenderer(content: MockPage(seed: i))
                r.scale = 2
                m.thumbnails[card.id] = r.nsImage
            }
        }
        return m
    }
}

/// A browser window drawn in code, used as a sample thumbnail.
private struct MockPage: View {
    let seed: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18),
                         Color(red: 0.16, green: 0.79, blue: 0.25)], id: \.self) { Circle().fill($0).frame(width: 6, height: 6) }
                Capsule().fill(Color.black.opacity(0.08)).frame(width: 90, height: 9).padding(.leading, 30)
            }
            .padding(.horizontal, 8)
            .frame(width: 200, height: 18, alignment: .leading)
            .background(Color(white: 0.92))
            VStack(alignment: .leading, spacing: 7) {
                Capsule().fill(Color.black.opacity(0.22)).frame(width: CGFloat(80 + seed * 14), height: 7)
                ForEach(0..<4, id: \.self) { i in
                    Capsule().fill(Color.black.opacity(0.1)).frame(width: CGFloat(170 - ((i + seed) * 23) % 60), height: 5)
                }
                RoundedRectangle(cornerRadius: 3)
                    .fill([Color.blue, Color.orange, Color.purple][seed % 3].opacity(0.25))
                    .frame(width: 120, height: 26)
            }
            .padding(12)
            Spacer(minLength: 0)
        }
        .frame(width: 200, height: 126)
        .background(Color(white: 0.985))
        .environment(\.colorScheme, .light)
    }
}
