import AppKit
import MacToysCore
import SwiftUI

/// Offscreen scenes of the mirror with a drawn camera frame, for snapshots and the README.
@MainActor
enum MirrorScenes {
    static let sampleDevices = [
        MirrorDevice(id: "builtin", name: "MacBook Pro Camera", kind: .builtIn),
        MirrorDevice(id: "iphone", name: "Maya’s iPhone Camera", kind: .continuity),
        MirrorDevice(id: "desk", name: "Maya’s iPhone Desk View Camera", kind: .deskView),
        MirrorDevice(id: "studio", name: "Studio Display Camera", kind: .external),
    ]

    static var all: [PreviewScene] {
        [
            PreviewScene("panel", size: CGSize(width: 580, height: 440), wallpaper: false) {
                let m = module { $0.zoom = 1.25; $0.centerY = 0.42 }
                m.camera.preview(status: .running, devices: sampleDevices, active: sampleDevices[0])
                return AnyView(dropped(m))
            },
            PreviewScene("picker", size: CGSize(width: 580, height: 440), wallpaper: false) {
                let m = module { $0.showGrid = true }
                m.camera.preview(status: .running, devices: sampleDevices, active: sampleDevices[1])
                m.ui.pickerOpen = true
                return AnyView(dropped(m))
            },
            PreviewScene("light-check", size: CGSize(width: 580, height: 440), wallpaper: false) {
                let m = module { $0.zoom = 1.25; $0.centerY = 0.42 }
                m.camera.preview(status: .running, devices: sampleDevices, active: sampleDevices[0], hint: .aBitDark)
                return AnyView(dropped(m, light: .dim))
            },
            PreviewScene("permission", size: CGSize(width: 580, height: 440), wallpaper: false) {
                let m = module { _ in }
                m.camera.preview(status: .needsPermission(denied: false), devices: [], active: nil)
                return AnyView(dropped(m))
            },
            PreviewScene("floating", size: CGSize(width: 980, height: 600), wallpaper: false) {
                AnyView(floatingDesktop())
            },
        ]
    }

    /// A throwaway module whose settings live in a temporary folder.
    private static func module(_ configure: (inout MirrorSettings) -> Void) -> CameraMirrorModule {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mactoys-preview-\(UUID().uuidString)")
        let m = CameraMirrorModule(store: SettingsStore(directory: dir))
        var s = MirrorSettings()
        configure(&s)
        m.settings.value = s
        m.ui.presented = true
        return m
    }

    /// The menu bar with the camera icon highlighted and the mirror dropped under it.
    private static func dropped(_ m: CameraMirrorModule, light: SamplePortrait.Light = .good) -> some View {
        desktop {
            VStack(alignment: .trailing, spacing: 6) {
                MenuBarStrip(highlighted: true)
                MirrorPanelView(module: m, feed: .sample(light))
                    .padding(.trailing, 50)
            }
        }
    }

    /// The design boards' wallpaper under the whole scene, title bar area included.
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

    /// Three floating mirrors on a desktop next to a call window: circle, rounded with its controls, rectangle.
    private static func floatingDesktop() -> some View {
        let circle = module { $0.shape = .circle; $0.zoom = 1.6; $0.centerY = 0.4 }
        let rounded = module { $0.shape = .rounded; $0.aspect = .fourThree; $0.zoom = 1.15; $0.centerY = 0.42 }
        let rect = module { $0.shape = .rectangle; $0.aspect = .sixteenNine; $0.opacity = 0.85 }
        for m in [circle, rounded, rect] { m.camera.preview(status: .running, devices: sampleDevices, active: sampleDevices[0]) }
        rounded.camera.preview(status: .running, devices: sampleDevices, active: sampleDevices[0], hint: .good)
        return desktop {
            VStack(spacing: 0) {
                MenuBarStrip(highlighted: false)
                ZStack(alignment: .topLeading) {
                    CallWindow()
                        .frame(width: 470, height: 330)
                        .offset(x: 40, y: 70)
                    floating(circle, size: CGSize(width: 200, height: 200))
                        .offset(x: 580, y: 56)
                    floating(rounded, size: CGSize(width: 280, height: 210), controls: true)
                        .offset(x: 640, y: 300)
                    floating(rect, size: CGSize(width: 240, height: 135))
                        .offset(x: 330, y: 400)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private static func floating(_ m: CameraMirrorModule, size: CGSize, controls: Bool = false) -> some View {
        MirrorFloatingView(module: m, feed: .sample(.good), forceControls: controls)
            .frame(width: size.width, height: size.height)
            .opacity(m.settings.value.opacity)
            .compositingGroup()
            .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
    }
}

/// The right end of a menu bar: the mirror's camera icon, Wi-Fi, battery and the clock.
private struct MenuBarStrip: View {
    let highlighted: Bool

    var body: some View {
        HStack(spacing: 16) {
            Spacer()
            Image(systemName: "web.camera")
                .frame(width: 30, height: 22)
                .background(Capsule().fill(.white.opacity(highlighted ? 0.22 : 0)))
            Image(systemName: "battery.75percent")
            Image(systemName: "wifi")
            Text(verbatim: PreviewScene.menuBarClock(hour: 9, minute: 41))
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .frame(height: 28)
        .background(.black.opacity(0.18))
    }
}

/// A stand-in video call window behind the floating mirrors: a grid of tinted tiles with names.
private struct CallWindow: View {
    private let people: [(String, Color)] = [("Jonas", Color(red: 0.36, green: 0.44, blue: 0.62)),
                                             ("Priya", Color(red: 0.55, green: 0.38, blue: 0.48)),
                                             ("Sam", Color(red: 0.30, green: 0.52, blue: 0.48)),
                                             ("Elena", Color(red: 0.62, green: 0.48, blue: 0.32))]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18),
                         Color(red: 0.16, green: 0.79, blue: 0.25)], id: \.self) { Circle().fill($0).frame(width: 12, height: 12) }
                Spacer()
                Text(verbatim: "Design review · 4 people").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                Spacer()
                Spacer().frame(width: 52)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                ForEach(0..<2, id: \.self) { row in
                    GridRow {
                        ForEach(0..<2, id: \.self) { col in
                            let p = people[row * 2 + col]
                            ZStack(alignment: .bottomLeading) {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(LinearGradient(colors: [p.1.opacity(0.9), p.1.opacity(0.55)], startPoint: .top, endPoint: .bottom))
                                Circle().fill(.white.opacity(0.22)).frame(width: 54, height: 54)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                Text(verbatim: p.0).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                    .background(Capsule().fill(.black.opacity(0.35)))
                                    .padding(8)
                            }
                        }
                    }
                }
            }
            .padding(8)
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(white: 0.11)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.1)))
        .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
    }
}
