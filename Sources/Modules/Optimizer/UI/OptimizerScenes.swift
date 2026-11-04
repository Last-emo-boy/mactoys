import AppKit
import MacToysCore
import SwiftUI

/// Offscreen previews of every overlay, filled with believable sample jobs.
@MainActor
enum OptimizerScenes {
    static var all: [PreviewScene] {
        [
            PreviewScene("cards", size: CGSize(width: 460, height: 540)) {
                AnyView(stack(sampleCenter([screenshotJob(), videoJob(progress: 0.42), pdfJob()]), hovered: true))
            },
            PreviewScene("card-image", size: CGSize(width: 420, height: 200)) {
                AnyView(stack(sampleCenter([screenshotJob()]), hovered: true))
            },
            PreviewScene("card-video", size: CGSize(width: 420, height: 170)) {
                AnyView(stack(sampleCenter([videoJob(progress: 0.42)]), hovered: false))
            },
            PreviewScene("card-pdf", size: CGSize(width: 420, height: 150)) {
                AnyView(stack(sampleCenter([pdfJob()]), hovered: false))
            },
            PreviewScene("card-states", size: CGSize(width: 420, height: 420)) {
                AnyView(stack(sampleCenter([clipboardJob(), unchangedJob(), failedJob()]), hovered: false))
            },
            PreviewScene("batch", size: CGSize(width: 420, height: 470)) {
                let (center, _) = batchCenter()
                return AnyView(stack(center, hovered: true))
            },
            PreviewScene("dropzone", size: CGSize(width: 420, height: 360)) {
                AnyView(dropZone(targeted: nil))
            },
            PreviewScene("dropzone-targeted", size: CGSize(width: 420, height: 360)) {
                AnyView(dropZone(targeted: .optimize))
            },
            PreviewScene("watchfolders", size: CGSize(width: 700, height: 520), wallpaper: false) {
                AnyView(WatchFoldersPreview())
            },
        ]
    }

    // MARK: Composition

    private static func stack(_ center: JobCenter, hovered: Bool) -> some View {
        ResultStackView(center: center, corner: .bottomRight, forceActions: hovered)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static func dropZone(targeted: DropTarget?) -> some View {
        let model = DropZoneModel()
        model.visible = true
        model.targeted = targeted
        model.convertFormat = .jpeg
        return DropZoneView(model: model, onDrop: { _, _ in })
            .frame(width: DropZoneController.size.width, height: DropZoneController.size.height)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static func sampleCenter(_ jobs: [OptimizationJob], batches: [JobBatch] = []) -> JobCenter {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("MacToys Optimizer Preview", isDirectory: true)
        let center = JobCenter(backups: BackupStore(root: temp.appendingPathComponent("Backups")), scratch: temp,
                               clipboardFolder: temp.appendingPathComponent("Clipboard"))
        center.loadPreview(jobs, batches: batches)
        return center
    }

    // MARK: Sample jobs

    private static func screenshotJob() -> OptimizationJob {
        let job = OptimizationJob(origin: .file(URL(fileURLWithPath: "/Users/ada/Desktop/Screenshot 2026-11-04 at 21.14.08.png")),
                                  kind: .image, name: "Screenshot 2026-11-04 at 21.14.08.png")
        job.state = .done
        job.originalSize = 2_412_884
        job.resultSize = 611_302
        job.resultURL = URL(fileURLWithPath: "/Users/ada/Desktop/Screenshot 2026-11-04 at 21.14.08.png")
        job.replacedOriginal = true
        job.detail = JobCenter.imageDetail(EncodedImage(data: Data(), format: .png, pixelSize: CGSize(width: 2880, height: 1800),
                                                        colors: 256, lossless: false))
        job.thumbnail = render(ScreenshotThumbnail())
        return job
    }

    private static func videoJob(progress: Double) -> OptimizationJob {
        let job = OptimizationJob(origin: .file(URL(fileURLWithPath: "/Users/ada/Desktop/Screen Recording 2026-11-04 at 21.20.31.mov")),
                                  kind: .video, name: "Screen Recording 2026-11-04 at 21.20.31.mov")
        job.state = .working(progress)
        job.originalSize = 186_400_000
        job.startedAt = Date().addingTimeInterval(-31)
        job.thumbnail = render(VideoThumbnail())
        return job
    }

    private static func pdfJob() -> OptimizationJob {
        let job = OptimizationJob(origin: .file(URL(fileURLWithPath: "/Users/ada/Downloads/Quarterly Report Q3.pdf")),
                                  kind: .pdf, name: "Quarterly Report Q3.pdf")
        job.state = .done
        job.originalSize = 24_630_112
        job.resultSize = 3_112_870
        job.resultURL = URL(fileURLWithPath: "/Users/ada/Downloads/Quarterly Report Q3.pdf")
        job.replacedOriginal = true
        job.detail = JobCenter.pdfDetail(pages: 12, resolution: 150)
        job.thumbnail = render(PageThumbnail())
        return job
    }

    private static func clipboardJob() -> OptimizationJob {
        let job = OptimizationJob(origin: .clipboard, kind: .image,
                                  name: String(localized: "Clipboard image", comment: "Optimizer: result card title for a copied image"))
        job.state = .done
        job.originalSize = 1_843_200
        job.resultSize = 402_118
        job.resultURL = URL(fileURLWithPath: "/tmp/Clipboard 2026-11-04 at 21.31.02.png")
        job.detail = JobCenter.imageDetail(EncodedImage(data: Data(), format: .png, pixelSize: CGSize(width: 1440, height: 900),
                                                        colors: 212, lossless: false))
        job.thumbnail = render(ScreenshotThumbnail(accent: Color(red: 0.95, green: 0.45, blue: 0.3)))
        return job
    }

    private static func unchangedJob() -> OptimizationJob {
        let job = OptimizationJob(origin: .file(URL(fileURLWithPath: "/Users/ada/Downloads/logo-mark.png")), kind: .image, name: "logo-mark.png")
        job.state = .unchanged
        job.originalSize = 18_204
        job.thumbnail = render(LogoThumbnail())
        return job
    }

    private static func failedJob() -> OptimizationJob {
        let job = OptimizationJob(origin: .file(URL(fileURLWithPath: "/Users/ada/Downloads/Signed Lease Agreement.pdf")),
                                  kind: .pdf, name: "Signed Lease Agreement.pdf")
        job.state = .failed(PDFOptimizer.Failure.locked.errorDescription ?? "")
        job.originalSize = 2_204_311
        job.thumbnail = render(PageThumbnail(locked: true))
        return job
    }

    private static func batchCenter() -> (JobCenter, JobBatch) {
        let names = ["IMG_4821.HEIC", "IMG_4822.HEIC", "IMG_4830.HEIC", "IMG_4831.HEIC", "IMG_4840.HEIC", "IMG_4841.HEIC",
                     "IMG_4855.HEIC", "IMG_4856.HEIC", "IMG_4860.HEIC", "IMG_4861.HEIC", "IMG_4862.HEIC", "IMG_4870.HEIC"]
        let sizes: [Int64] = [3_811_220, 4_102_884, 2_998_102, 3_502_110, 4_420_000, 3_120_500, 2_810_330, 3_330_000,
                              3_905_441, 2_604_002, 3_001_998, 3_777_100]
        let savings = [0.58, 0.61, 0.55, 0.63, 0.66, 0.52, 0.6]
        let hues: [Double] = [0.08, 0.55, 0.33, 0.95, 0.62, 0.12, 0.45, 0.75, 0.02, 0.5, 0.3, 0.85]
        var jobs: [OptimizationJob] = []
        for (i, name) in names.enumerated() {
            let job = OptimizationJob(origin: .file(URL(fileURLWithPath: "/Users/ada/Pictures/Lisbon/\(name)")), kind: .image, name: name)
            job.originalSize = sizes[i]
            if i < savings.count {
                job.state = .done
                job.resultSize = Int64(Double(sizes[i]) * (1 - savings[i]))
                job.replacedOriginal = true
            } else if i == savings.count {
                job.state = .working(nil)
            } else {
                job.state = .queued
            }
            job.thumbnail = render(PhotoThumbnail(hue: hues[i]))
            jobs.append(job)
        }
        let batch = JobBatch(id: UUID(), jobIDs: jobs.map(\.id))
        for job in jobs { job.batchID = batch.id }
        return (sampleCenter(jobs, batches: [batch]), batch)
    }

    private static func render(_ view: some View) -> CGImage? {
        let renderer = ImageRenderer(content: view.frame(width: 64, height: 64))
        renderer.scale = 2
        return renderer.cgImage
    }
}

// MARK: Sample thumbnails

/// A window with a toolbar and text, like a screenshot.
private struct ScreenshotThumbnail: View {
    var accent = Color(red: 0.25, green: 0.48, blue: 0.95)

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.3, green: 0.3, blue: 0.62), Color(red: 0.85, green: 0.55, blue: 0.5)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(alignment: .leading, spacing: 2.5) {
                HStack(spacing: 2) {
                    ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0).frame(width: 3, height: 3) }
                }
                .padding(.bottom, 1)
                RoundedRectangle(cornerRadius: 1.5).fill(accent).frame(width: 30, height: 5)
                ForEach([40.0, 34, 22], id: \.self) { w in
                    RoundedRectangle(cornerRadius: 1).fill(Color(white: 0.8)).frame(width: w, height: 2.5)
                }
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2).fill(accent.opacity(0.25)).frame(width: 19, height: 9)
                    RoundedRectangle(cornerRadius: 2).fill(Color(white: 0.9)).frame(width: 19, height: 9)
                }
            }
            .padding(5)
            .frame(width: 52, height: 50, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 4).fill(.white))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .padding(.top, 9)
        }
    }
}

/// A dark code editor frame, like a screen recording.
private struct VideoThumbnail: View {
    var body: some View {
        ZStack {
            Color(red: 0.11, green: 0.12, blue: 0.16)
            VStack(alignment: .leading, spacing: 3.5) {
                ForEach(Array([(20.0, Color.pink), (36, .cyan), (28, .orange), (44, .mint), (18, .purple), (32, .cyan)].enumerated()),
                        id: \.offset) { i, item in
                    HStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 1).fill(Color.white.opacity(0.25)).frame(width: 4, height: 2.5)
                        RoundedRectangle(cornerRadius: 1).fill(item.1.opacity(0.85)).frame(width: item.0, height: 2.5)
                            .padding(.leading, Double(i % 3) * 4)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            Image(systemName: "play.fill").font(.system(size: 14)).foregroundStyle(.white.opacity(0.9))
                .padding(7).background(Circle().fill(.black.opacity(0.45)))
        }
    }
}

/// A report page with a chart and text.
private struct PageThumbnail: View {
    var locked = false

    var body: some View {
        ZStack {
            Color(red: 0.86, green: 0.87, blue: 0.9)
            VStack(alignment: .leading, spacing: 3) {
                RoundedRectangle(cornerRadius: 1).fill(Color(red: 0.15, green: 0.2, blue: 0.4)).frame(width: 24, height: 3.5)
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach([10.0, 16, 12, 20, 15], id: \.self) { h in
                        RoundedRectangle(cornerRadius: 0.5).fill(Color(red: 0.25, green: 0.55, blue: 0.95)).frame(width: 4, height: h)
                    }
                }
                .frame(height: 20, alignment: .bottom)
                ForEach([30.0, 34, 26, 32], id: \.self) { w in
                    RoundedRectangle(cornerRadius: 0.5).fill(Color(white: 0.75)).frame(width: w, height: 2)
                }
            }
            .padding(5)
            .frame(width: 42, height: 54, alignment: .topLeading)
            .background(Rectangle().fill(.white).shadow(color: .black.opacity(0.15), radius: 1.5, y: 1))
            if locked {
                Image(systemName: "lock.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .padding(6).background(Circle().fill(Color(red: 0.2, green: 0.2, blue: 0.25)))
                    .offset(x: 14, y: 16)
            }
        }
    }
}

private struct LogoThumbnail: View {
    var body: some View {
        ZStack {
            Color(white: 0.95)
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Tint.indigo.gradient).frame(width: 34, height: 34)
            Image(systemName: "sparkle").font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
        }
    }
}

/// A sunny photo tinted by `hue`.
private struct PhotoThumbnail: View {
    let hue: Double

    var body: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(colors: [Color(hue: hue, saturation: 0.45, brightness: 0.95), Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1),
                                                                                              saturation: 0.6, brightness: 0.75)],
                           startPoint: .top, endPoint: .bottom)
            Circle().fill(.white.opacity(0.85)).frame(width: 12).offset(x: 14, y: -38)
            Path { p in
                p.move(to: CGPoint(x: 0, y: 64))
                p.addLine(to: CGPoint(x: 18, y: 36))
                p.addLine(to: CGPoint(x: 34, y: 50))
                p.addLine(to: CGPoint(x: 50, y: 30))
                p.addLine(to: CGPoint(x: 64, y: 44))
                p.addLine(to: CGPoint(x: 64, y: 64))
                p.closeSubpath()
            }
            .fill(Color(hue: hue, saturation: 0.5, brightness: 0.35).opacity(0.85))
        }
    }
}

/// The watch folder list as it appears on the settings page.
private struct WatchFoldersPreview: View {
    @State private var folders: [WatchFolder] = [
        WatchFolder(path: "~/Desktop", enabled: true, kinds: [.image, .video], action: .optimize),
        WatchFolder(path: "~/Downloads", enabled: true, kinds: [.image, .pdf], action: .optimize),
        WatchFolder(path: "~/Pictures", enabled: true, kinds: [.image], action: .convert(.jpeg)),
        WatchFolder(path: "~/Documents", enabled: false, kinds: [.pdf], action: .optimize),
    ]

    var body: some View {
        Form {
            WatchFoldersSection(folders: $folders)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
