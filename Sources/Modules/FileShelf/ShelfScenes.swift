import AppKit
import MacToysCore
import SwiftUI
import UniformTypeIdentifiers

/// Offscreen scenes of shelves with believable sample items, for snapshots and the README.
@MainActor
enum ShelfScenes {
    static var all: [PreviewScene] {
        [
            PreviewScene("pile", size: CGSize(width: 380, height: 300)) {
                let model = sampleModel(Array(samples.prefix(5)))
                return AnyView(stage { shelf(model) })
            },
            PreviewScene("grid", size: CGSize(width: 520, height: 600)) {
                let model = sampleModel(samples, expanded: true)
                model.selection = [samples[1].id]
                model.hoveredItem = samples[4].id
                return AnyView(stage { shelf(model) })
            },
            PreviewScene("list", size: CGSize(width: 520, height: 470)) {
                let model = sampleModel(Array(samples.prefix(7)), expanded: true, layout: .list)
                model.selection = [samples[3].id]
                return AnyView(stage { shelf(model) })
            },
            PreviewScene("drop", size: CGSize(width: 560, height: 420)) {
                let model = sampleModel([samples[0], samples[6], samples[4]], expanded: true)
                model.isDropTarget = true
                model.dropCount = 2
                return AnyView(stage {
                    shelf(model)
                        .overlay(alignment: .topLeading) { DragGhost().offset(x: 150, y: 150) }
                })
            },
            PreviewScene("two-shelves", size: CGSize(width: 780, height: 520)) {
                let invoices = sampleModel(invoiceSamples, expanded: true, layout: .list)
                invoices.shelf.title = "Invoices – October"
                invoices.shelf.pinned = true
                let photos = sampleModel([samples[0], samples[2], samples[1]])
                photos.isHovering = true
                return AnyView(stage {
                    HStack(alignment: .top, spacing: 40) {
                        shelf(invoices)
                        shelf(photos).padding(.top, 30)
                    }
                })
            },
            PreviewScene("empty", size: CGSize(width: 320, height: 280)) {
                let model = sampleModel([])
                model.isHovering = true
                return AnyView(stage { shelf(model) })
            },
        ]
    }

    // MARK: Composition

    private static func stage<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        content().frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static func shelf(_ model: ShelfModel) -> some View {
        let size = ShelfGeometry.size(expanded: model.shelf.expanded, itemCount: model.items.count, layout: model.layout)
        return ShelfView(model: model, floating: true).frame(width: size.width, height: size.height)
    }

    private static func sampleModel(_ items: [ShelfItem], expanded: Bool = false, layout: ShelfLayout = .grid) -> ShelfModel {
        let model = ShelfModel(shelf: Shelf(items: items, expanded: expanded), layout: layout)
        for item in items { model.thumbnails[item.id] = SampleArt.thumbnail(for: item) }
        return model
    }

    // MARK: Sample items

    private static let desktop = "/Users/demo/Desktop/"

    private static func file(_ name: String, _ type: UTType, _ bytes: Int64?, folder: Bool = false) -> ShelfItem {
        var item = ShelfItem(kind: .file, url: URL(fileURLWithPath: desktop + name), name: name)
        item.byteSize = bytes
        item.contentType = type.identifier
        item.isDirectory = folder
        return item
    }

    private static let samples: [ShelfItem] = {
        var text = ShelfItem(kind: .text, url: URL(fileURLWithPath: "/tmp/Launch checklist.txt"), name: "Launch checklist – Friday.txt", owned: true)
        text.preview = "Launch checklist – Friday\n• Final copy review with Maya\n• Export hero images @2x\n• Book room 4B for the demo\n• Send press kit to Jonas"
        text.byteSize = 164
        text.contentType = UTType.plainText.identifier
        var link = ShelfItem(kind: .link, url: URL(fileURLWithPath: "/tmp/Human Interface Guidelines.webloc"),
                             name: "Human Interface Guidelines.webloc", owned: true)
        link.link = URL(string: "https://developer.apple.com/design/human-interface-guidelines")
        link.preview = "Human Interface Guidelines"
        return [
            file("Q3 Board Report.pdf", .pdf, 2_412_000),
            file("IMG_4821.HEIC", .heic, 3_104_000),
            file("IMG_4822.HEIC", .heic, 2_876_000),
            file("Site Assets.zip", .zip, 48_630_000),
            text,
            link,
            file("Brand Guidelines.pdf", .pdf, 6_215_000),
            file("Wireframes", .folder, nil, folder: true),
        ]
    }()

    private static let invoiceSamples: [ShelfItem] = [
        file("Invoice 2026-118 Northwind.pdf", .pdf, 184_000),
        file("Invoice 2026-119 Fabrikam.pdf", .pdf, 201_000),
        file("Receipt – Studio rent.pdf", .pdf, 96_000),
        file("Expenses October.numbers", UTType(filenameExtension: "numbers") ?? .spreadsheet, 412_000),
    ]
}

/// A drag in progress over the drop scene: two files and a count badge under an arrow pointer.
private struct DragGhost: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            ZStack {
                Image(nsImage: SampleArt.photo(.sunset))
                    .resizable().aspectRatio(contentMode: .fit).frame(width: 58)
                    .padding(2).background(.white).clipShape(RoundedRectangle(cornerRadius: 4))
                    .rotationEffect(.degrees(-6)).offset(x: -10, y: 4)
                Image(nsImage: SampleArt.page(accent: .orange))
                    .resizable().aspectRatio(contentMode: .fit).frame(height: 62)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .rotationEffect(.degrees(5)).offset(x: 12)
            }
            .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
            .opacity(0.85)
            Text(verbatim: "2")
                .font(.system(size: 12, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(minWidth: 22, minHeight: 22)
                .background(Circle().fill(Color.red))
                .offset(x: 52, y: -8)
            Image(systemName: "cursorarrow")
                .font(.system(size: 26))
                .foregroundStyle(.black)
                .background(Image(systemName: "cursorarrow").font(.system(size: 30, weight: .black)).foregroundStyle(.white))
                .offset(x: 22, y: 30)
        }
        .frame(width: 100, height: 90)
    }
}

/// Sample pictures drawn in code: photos, document pages, file-type icons.
@MainActor
enum SampleArt {
    enum Palette { case sunset, lake }

    static func thumbnail(for item: ShelfItem) -> ShelfThumbnail {
        switch item.name {
        case "IMG_4821.HEIC": return ShelfThumbnail(image: photo(.sunset), isIcon: false)
        case "IMG_4822.HEIC": return ShelfThumbnail(image: photo(.lake), isIcon: false)
        case "Q3 Board Report.pdf": return ShelfThumbnail(image: page(accent: .indigo), isIcon: false)
        case "Brand Guidelines.pdf": return ShelfThumbnail(image: page(accent: .orange), isIcon: false)
        default:
            if item.utType?.conforms(to: .pdf) == true { return ShelfThumbnail(image: page(accent: .teal), isIcon: false) }
            return ShelfThumbnail(image: NSWorkspace.shared.icon(for: item.utType ?? .data), isIcon: true)
        }
    }

    /// A landscape photo: sky, sun, layered hills, water.
    static func photo(_ palette: Palette) -> NSImage {
        let w = 900, h = 600
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return NSImage() }
        let sky: [CGColor], hills: [CGColor], sun: CGColor
        switch palette {
        case .sunset:
            sky = [rgb(0.99, 0.80, 0.55), rgb(0.96, 0.52, 0.45), rgb(0.42, 0.30, 0.58)]
            hills = [rgb(0.55, 0.30, 0.45), rgb(0.36, 0.20, 0.38), rgb(0.20, 0.12, 0.25)]
            sun = rgb(1, 0.93, 0.78)
        case .lake:
            sky = [rgb(0.80, 0.91, 0.98), rgb(0.53, 0.75, 0.93), rgb(0.27, 0.50, 0.80)]
            hills = [rgb(0.42, 0.62, 0.66), rgb(0.24, 0.45, 0.47), rgb(0.12, 0.30, 0.33)]
            sun = rgb(1, 1, 0.95)
        }
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: sky.reversed() as CFArray, locations: [0, 0.6, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: h), options: [])
        ctx.setFillColor(sun)
        ctx.fillEllipse(in: CGRect(x: 560, y: 330, width: 120, height: 120))
        for (i, color) in hills.enumerated() {
            let base = 300 - CGFloat(i) * 70
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: 0, y: base))
            var x: CGFloat = 0
            var up = i % 2 == 0
            while x < CGFloat(w) {
                let step = CGFloat(140 + (i * 37) % 60)
                path.addQuadCurve(to: CGPoint(x: x + step, y: base + (up ? 60 : -10) - CGFloat(i) * 8),
                                  control: CGPoint(x: x + step / 2, y: base + (up ? 110 : 20)))
                x += step
                up.toggle()
            }
            path.addLine(to: CGPoint(x: CGFloat(w), y: 0))
            path.closeSubpath()
            ctx.setFillColor(color)
            ctx.addPath(path)
            ctx.fillPath()
        }
        if palette == .lake {
            ctx.setFillColor(rgb(0.30, 0.55, 0.78, 0.85))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: 110))
            ctx.setFillColor(rgb(1, 1, 1, 0.35))
            for row in 0..<5 { ctx.fill(CGRect(x: 120 + row * 90, y: 30 + row * 14, width: 160, height: 3)) }
        }
        return image(ctx, w, h)
    }

    /// A document page: a colored title band, headings, text lines and a bar chart.
    static func page(accent: Tint) -> NSImage {
        let w = 850, h = 1100
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return NSImage() }
        ctx.setFillColor(rgb(1, 1, 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(accent.nsColor.cgColor)
        ctx.fill(CGRect(x: 0, y: h - 250, width: w, height: 250))
        ctx.setFillColor(rgb(1, 1, 1, 0.92))
        ctx.fill(CGRect(x: 70, y: h - 150, width: 470, height: 44))
        ctx.setFillColor(rgb(1, 1, 1, 0.6))
        ctx.fill(CGRect(x: 70, y: h - 200, width: 300, height: 22))
        ctx.setFillColor(rgb(0.2, 0.2, 0.24))
        ctx.fill(CGRect(x: 70, y: h - 320, width: 260, height: 26))
        ctx.setFillColor(rgb(0.78, 0.78, 0.8))
        for i in 0..<5 {
            ctx.fill(CGRect(x: 70, y: h - 370 - i * 34, width: i == 4 ? 420 : 710, height: 14))
        }
        let bars: [CGFloat] = [0.45, 0.62, 0.55, 0.8, 0.92]
        for (i, v) in bars.enumerated() {
            ctx.setFillColor(accent.nsColor.withAlphaComponent(i == bars.count - 1 ? 1 : 0.45).cgColor)
            ctx.fill(CGRect(x: 90 + CGFloat(i) * 140, y: 170, width: 90, height: 360 * v))
        }
        ctx.setFillColor(rgb(0.85, 0.85, 0.87))
        ctx.fill(CGRect(x: 70, y: 160, width: 710, height: 3))
        for i in 0..<2 { ctx.setFillColor(rgb(0.78, 0.78, 0.8)); ctx.fill(CGRect(x: 70, y: 100 - i * 34, width: 640 - i * 200, height: 14)) }
        return image(ctx, w, h)
    }

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    private static func image(_ ctx: CGContext, _ w: Int, _ h: Int) -> NSImage {
        guard let cg = ctx.makeImage() else { return NSImage() }
        return NSImage(cgImage: cg, size: CGSize(width: w, height: h))
    }
}
