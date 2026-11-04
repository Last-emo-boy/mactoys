import AppKit
import MacToysCore
import SwiftUI

/// Offscreen scenes: the switches in the menu bar menu, the settings grid, the cleaning countdown.
@MainActor
enum SwitchesScenes {
    static var all: [PreviewScene] {
        [
            PreviewScene("flyout", size: CGSize(width: 440, height: 640), wallpaper: false) {
                AnyView(desktop { flyout().padding(.top, 36) })
            },
            PreviewScene("grid", size: CGSize(width: 720, height: 420), wallpaper: false) {
                AnyView(SwitchesGrid(tiles: sampleTiles(), columns: 5)
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
                    .ignoresSafeArea())
            },
            PreviewScene("clean-keyboard", size: CGSize(width: 960, height: 600), wallpaper: false) {
                let start = Date()
                var session = CleanKeyboardSession(start: start, duration: 30)
                _ = session.registerEscape(at: start.addingTimeInterval(7.6))
                let state = CleanKeyboardController.State(session: session)
                state.now = start.addingTimeInterval(8.2)
                return AnyView(desktop { CleanKeyboardOverlay(state: state) })
            },
        ]
    }

    static func sampleTiles() -> [SwitchTile] {
        func tile(_ kind: SwitchKind, on: Bool, detail: String? = nil) -> SwitchTile {
            SwitchTile(id: kind.rawValue, title: kind.title, symbol: kind.symbol, tint: kind.tint, isToggle: kind.isToggle,
                       isOn: on, detail: detail, action: {})
        }
        return [
            tile(.hideDesktopIcons, on: true),
            tile(.showHiddenFiles, on: false),
            tile(.autohideDock, on: true),
            tile(.darkMode, on: true),
            tile(.keepAwake, on: false),
            tile(.muteMicrophone, on: false),
            SwitchTile(id: "bt.airpods", title: "Maya’s AirPods Pro", symbol: BluetoothKind.airpodsPro.symbol, tint: .blue,
                       isToggle: true, isOn: true, detail: nil, action: {}),
            tile(.doNotDisturb, on: false),
            tile(.lowPowerMode, on: false),
            tile(.cleanKeyboard, on: false),
        ]
    }

    /// The MacToys menu bar menu with the switches in it.
    private static func flyout() -> some View {
        let rows: [SwitchTile] = {
            func tile(_ kind: SwitchKind, on: Bool, detail: String? = nil) -> SwitchTile {
                SwitchTile(id: kind.rawValue, title: kind.title, symbol: kind.symbol, tint: kind.tint, isToggle: true,
                           isOn: on, detail: detail, action: {})
            }
            return [
                tile(.hideDesktopIcons, on: true, detail: "⌃⌥⌘H"),
                tile(.showHiddenFiles, on: false),
                tile(.autohideDock, on: true),
                tile(.darkMode, on: true),
                tile(.keepAwake, on: false),
                tile(.muteMicrophone, on: false, detail: "MacBook Pro Microphone"),
                SwitchTile(id: "bt", title: "Maya’s AirPods Pro", symbol: BluetoothKind.airpodsPro.symbol, tint: .blue,
                           isToggle: true, isOn: true, detail: String(localized: "Connected", comment: "Bluetooth device state"), action: {}),
            ]
        }()
        let actions: [SwitchKind] = [.screenSaver, .lockScreen, .cleanKeyboard]
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(LinearGradient(colors: [Tint.pink.color, Tint.purple.color, Tint.blue.color], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 26, height: 26)
                    .overlay(Image(systemName: "square.grid.2x2.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white))
                Text(verbatim: "MacToys").font(.system(size: 14, weight: .bold))
                Spacer()
            }
            HStack(spacing: 8) {
                ForEach(actions) { kind in
                    VStack(spacing: 8) {
                        ModuleIcon(symbol: kind.symbol, tint: kind.tint, size: 30)
                        Text(verbatim: kind.title).font(.system(size: 11.5, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .padding(.vertical, 12).padding(.horizontal, 6)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.5)))
                }
            }
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                    if i > 0 { Divider().opacity(0.5) }
                    FlyoutSwitchRow(tile: row)
                }
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.5)))
        }
        .padding(14)
        .frame(width: 380)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
        }
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.15)))
    }

    static func desktop<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background {
                LinearGradient(colors: [Color(red: 0.09, green: 0.13, blue: 0.36), Color(red: 0.24, green: 0.17, blue: 0.56),
                                        Color(red: 0.6, green: 0.25, blue: 0.53), Color(red: 0.88, green: 0.54, blue: 0.42)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .ignoresSafeArea()
            }
            .ignoresSafeArea()
    }
}
