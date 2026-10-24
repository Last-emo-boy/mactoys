import AppKit
import MacToysCore
import PreviewKit
import SwiftUI

/// Offscreen scenes of the Peek window (design 07) with sample files.
@MainActor
enum PeekScenes {
    static var all: [PreviewScene] {
        [
            PreviewScene("image", size: CGSize(width: 760, height: 560)) {
                let model = PeekModel()
                model.drawsWindowButtons = true
                model.items = sampleItems(["IMG_4815.HEIC", "IMG_4821.HEIC", "IMG_4822.HEIC", "IMG_4830.HEIC", "IMG_4831.mov", "notes.txt"], index: 2)
                model.defaultApp = "Photos"
                if let photo = PreviewSamples.gradientImage(width: 1200, height: 800), let framed = matted(photo, in: CGSize(width: 1520, height: 950)) {
                    model.content = .image(framed, .dark)
                }
                model.fields = [PeekField(label: "Size", value: "4.2 MB"), PeekField(label: "Dimensions", value: "4032 × 3024"),
                                PeekField(label: "Modified", value: "Today 21:10"), PeekField(label: "Type", value: "HEIF image")]
                return AnyView(window(model))
            },
            PreviewScene("code", size: CGSize(width: 900, height: 640)) {
                let model = PeekModel()
                model.drawsWindowButtons = true
                model.items = sampleItems(["Package.swift", "WordCounter.swift", "README.md"], index: 1)
                model.defaultApp = "Xcode"
                let options = CodeOptions(theme: .light, lineNumbers: true, wrap: false, fontSize: 12)
                let html = CodeRenderer.page(text: PreviewSamples.swiftCode, language: .swift, title: "WordCounter.swift", options: options)
                // The window is inset by 16 pt; the content sits between the header and the footer.
                let contentSize = CGSize(width: 900 - 32, height: 640 - 32 - PeekView.headerHeight - PeekView.footerHeight - 2)
                if let image = HTMLSnapshotter.snapshotBlocking(html: html, size: contentSize) {
                    model.content = .image(image, .dark)
                }
                model.fields = [PeekField(label: "Size", value: "1 KB"), PeekField(label: "Lines", value: "25"),
                                PeekField(label: "Language", value: "Swift"), PeekField(label: "Modified", value: "Yesterday 18:42"),
                                PeekField(label: "Type", value: "Swift Source")]
                return AnyView(window(model))
            },
        ]
    }

    private static func sampleItems(_ names: [String], index: Int) -> PeekItems {
        PeekItems(names.map { URL(fileURLWithPath: "/Users/demo/Pictures/\($0)") }, index: index)
    }

    private static func window(_ model: PeekModel) -> some View {
        PeekView(model: model)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.black.opacity(0.12)))
            .padding(16)
            .environment(\.colorScheme, .light)
    }

    /// The photo centered on Peek's dark canvas with a margin, like the design board.
    private static func matted(_ image: CGImage, in size: CGSize) -> CGImage? {
        guard let ctx = ImageUtil.context(width: Int(size.width), height: Int(size.height)) else { return nil }
        ctx.setFillColor(CGColor(srgbRed: 0.07, green: 0.07, blue: 0.08, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        let fitted = ImageUtil.fit(CGSize(width: image.width, height: image.height), in: CGSize(width: size.width - 240, height: size.height - 160))
        let rect = CGRect(x: (size.width - fitted.width) / 2, y: (size.height - fitted.height) / 2, width: fitted.width, height: fitted.height)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.clip()
        ctx.draw(image, in: rect)
        return ctx.makeImage()
    }
}
