import AppKit
import MacToysCore
import Observation
import SwiftUI

/// A capture in this session: the original image and its editable document.
@MainActor
@Observable
final class CaptureItem: Identifiable {
    let id: UUID
    /// The original capture, never modified.
    let image: CGImage
    /// Image pixels per point.
    let scale: CGFloat
    let kind: CaptureKind
    let date: Date
    var document: MarkupDocument {
        didSet { if document != oldValue { cached = nil } }
    }
    /// Where the finished image was last written.
    var savedURL: URL?
    @ObservationIgnored let redactions: RedactionCache
    @ObservationIgnored private var cached: CGImage?

    init(id: UUID = UUID(), image: CGImage, scale: CGFloat, kind: CaptureKind, date: Date = Date(),
         document: MarkupDocument? = nil, savedURL: URL? = nil) {
        self.id = id
        self.image = image
        self.scale = scale
        self.kind = kind
        self.date = date
        let size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        self.document = document ?? MarkupDocument(imageSize: size, scale: scale)
        self.savedURL = savedURL
        redactions = RedactionCache(source: image, scale: scale)
    }

    /// The finished image at the capture's resolution (annotations, crop and background applied).
    var rendered: CGImage {
        if let cached { return cached }
        let result = Compositor.render(base: image, document: document, redactions: redactions) ?? image
        cached = result
        return result
    }

    /// The finished image as written to files and the pasteboard.
    func output(retina: Bool) -> CGImage {
        retina ? rendered : (Compositor.render(base: image, document: document, redactions: redactions, retina: false) ?? rendered)
    }

    /// Pixels per point of `output(retina:)`.
    func outputScale(retina: Bool) -> CGFloat {
        if document.beautify?.aspect.pixelWidth != nil { return 1 }
        return retina ? scale : 1
    }

    /// Size of the finished image in points.
    var pointSize: CGSize {
        let r = rendered
        return CGSize(width: CGFloat(r.width) / scale, height: CGFloat(r.height) / scale)
    }

    /// A title for windows: the saved file's name, or the date.
    var title: String {
        if let savedURL { return savedURL.deletingPathExtension().lastPathComponent }
        return FileNamer.baseName(template: FileNamer.defaultTemplate, date: date)
    }
}

// MARK: - Self-timer

/// Countdown before a timed capture: a ring and the seconds left. Clicking it cancels.
@MainActor
final class Countdown {
    @MainActor
    @Observable
    final class Model {
        var remaining: Int
        var progress: Double = 0
        let total: Int
        init(seconds: Int) {
            remaining = seconds
            total = seconds
        }
    }

    private let panel: OverlayPanel
    private let model: Model
    private var timer: Timer?
    private var completion: ((Bool) -> Void)?

    /// - Parameter center: Cocoa point the countdown is centered on.
    init(seconds: Int, center: CGPoint, completion: @escaping (Bool) -> Void) {
        model = Model(seconds: seconds)
        self.completion = completion
        let size = CGSize(width: 168, height: 196)
        panel = OverlayPanel(frame: CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                                           width: size.width, height: size.height),
                             interactive: true, acceptsKey: false, level: .screenSaver)
        let host = FirstMouseHostingView(rootView: CountdownView(model: model) { [weak self] in self?.end(false) })
        host.frame = CGRect(origin: .zero, size: size)
        panel.contentView = host
    }

    func start() {
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }
        withAnimation(.linear(duration: 1)) { model.progress = 1 / Double(model.total) }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        model.remaining -= 1
        if model.remaining <= 0 {
            end(true)
            return
        }
        NSSound(named: "Tink")?.play()
        let done = Double(model.total - model.remaining + 1) / Double(model.total)
        withAnimation(.linear(duration: 1)) { model.progress = done }
    }

    /// Stops; `fire` tells the completion whether to capture.
    func end(_ fire: Bool) {
        timer?.invalidate()
        timer = nil
        panel.orderOut(nil)
        panel.contentView = nil
        let callback = completion
        completion = nil
        // Let the window server drop the panel before anything captures the screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + (fire ? 0.12 : 0)) { callback?(fire) }
    }
}

struct CountdownView: View {
    let model: Countdown.Model
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().stroke(.white.opacity(0.14), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: model.progress)
                    .stroke(Tint.pink.color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(verbatim: "\(max(model.remaining, 0))")
                    .font(.system(size: 52, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.snappy, value: model.remaining)
            }
            .frame(width: 112, height: 112)
            Text("Click to cancel", comment: "Self-timer countdown before a screenshot")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
        }
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Color(red: 0.1, green: 0.1, blue: 0.12).opacity(0.6))
                .glassEffect(.regular, in: .rect(cornerRadius: 28))
        }
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(.white.opacity(0.14)))
        .environment(\.colorScheme, .dark)
        .contentShape(Rectangle())
        .onTapGesture(perform: cancel)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Takes the first click although its panel never becomes key.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
