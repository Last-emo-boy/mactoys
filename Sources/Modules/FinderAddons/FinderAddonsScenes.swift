import AppKit
import MacToysCore
import PreviewKit
import SwiftUI

/// Offscreen scenes: what the Quick Look extensions produce, in a Quick Look-style window.
@MainActor
enum FinderAddonsScenes {
    static var all: [PreviewScene] {
        [
            PreviewScene("markdown", size: CGSize(width: 860, height: 660)) {
                let html = MarkdownRenderer.page(PreviewSamples.markdown, title: "RELEASE.md", theme: .light, fontSize: 14)
                let image = HTMLSnapshotter.snapshotBlocking(html: html, size: CGSize(width: 800, height: 580))
                return AnyView(QuickLookFrame(title: "RELEASE.md", image: image, dark: false, background: .white))
            },
            PreviewScene("gcode", size: CGSize(width: 860, height: 660)) {
                let path = GCodeParser.parse(PreviewSamples.vaseGCode())
                let image = ToolpathRenderer.render(path, size: CGSize(width: 1600, height: 1160))
                return AnyView(QuickLookFrame(title: "twisted-vase.gcode", image: image, dark: true,
                                              background: Color(red: 0.086, green: 0.094, blue: 0.114)))
            },
            PreviewScene("stl", size: CGSize(width: 860, height: 660)) {
                let mesh = PreviewSamples.gearMesh()
                let image = STLRenderer.render(mesh, size: CGSize(width: 1600, height: 1160),
                                               color: HexColor.cgColor(FinderAddonsSettings().stlColor),
                                               background: HexColor.cgColor(FinderAddonsSettings().stlBackground))
                return AnyView(QuickLookFrame(title: "gear.stl", image: image, dark: true,
                                              background: Color(cgColor: HexColor.cgColor(FinderAddonsSettings().stlBackground))))
            },
        ]
    }
}

/// A Quick Look panel stand-in: title bar and the rendered content.
struct QuickLookFrame: View {
    let title: String
    let image: CGImage?
    let dark: Bool
    let background: Color

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach([Color.red, .yellow, .green], id: \.self) { c in
                    Circle().fill(c.opacity(0.85)).frame(width: 12, height: 12)
                }
                Spacer()
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                Image(systemName: "square.and.arrow.up").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(.bar)
            Divider()
            Group {
                if let image {
                    Image(decorative: image, scale: 2).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Text("No preview").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(background)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.black.opacity(0.15)))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
        .padding(30)
        .environment(\.colorScheme, dark ? .dark : .light)
    }
}
