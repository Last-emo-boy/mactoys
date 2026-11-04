import AppKit
import AVFoundation
import MacToysCore
import SwiftUI

/// What a mirror shows: the live camera, or a drawn sample frame for snapshots and the settings hero.
enum MirrorFeed {
    case live(MirrorCamera)
    case sample(SamplePortrait.Light)
}

/// The mirror picture with its framing (zoom, center), mirroring and optional grid.
struct MirrorVideo: View {
    let feed: MirrorFeed
    let framing: MirrorFraming
    let mirrored: Bool
    var showGrid = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                switch feed {
                case .live(let camera):
                    LivePreview(session: camera.session, source: camera.sourceSize, framing: framing, mirrored: mirrored)
                case .sample(let light):
                    let source = SamplePortrait.sourceSize
                    let frame = framing.layerFrame(source: source, view: geo.size)
                    SamplePortrait(light: light)
                        .frame(width: frame.width, height: frame.height)
                        .scaleEffect(x: mirrored ? -1 : 1, y: 1)
                        .position(x: mirrored ? geo.size.width - frame.midX : frame.midX, y: frame.midY)
                }
                if showGrid { MirrorGrid() }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .background(Color.black)
    }
}

/// Rule-of-thirds lines with a soft shadow so they read on light and dark pictures.
struct MirrorGrid: View {
    var body: some View {
        Canvas { ctx, size in
            var path = Path()
            for i in 1...2 {
                let x = size.width * CGFloat(i) / 3, y = size.height * CGFloat(i) / 3
                path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height))
                path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y))
            }
            ctx.stroke(path, with: .color(.black.opacity(0.25)), lineWidth: 2)
            ctx.stroke(path, with: .color(.white.opacity(0.55)), lineWidth: 0.75)
        }
        .allowsHitTesting(false)
    }
}

/// Hosts an `AVCaptureVideoPreviewLayer` laid out by `MirrorFraming`.
private struct LivePreview: NSViewRepresentable {
    let session: AVCaptureSession
    let source: CGSize
    let framing: MirrorFraming
    let mirrored: Bool

    func makeNSView(context: Context) -> PreviewLayerView {
        PreviewLayerView(session: session)
    }

    func updateNSView(_ view: PreviewLayerView, context: Context) {
        view.source = source
        view.framing = framing
        view.mirrored = mirrored
        view.needsLayout = true
    }
}

final class PreviewLayerView: NSView {
    let previewLayer: AVCaptureVideoPreviewLayer
    var source = CGSize(width: 16, height: 9)
    var framing = MirrorFraming.standard
    var mirrored = true

    init(session: AVCaptureSession) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        previewLayer.videoGravity = .resize
        layer?.addSublayer(previewLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        let view = bounds.size
        var f = framing.layerFrame(source: source, view: view)
        if mirrored { f.origin.x = view.width - f.maxX }
        // Layer geometry has a bottom-left origin here; the framing is top-left.
        f.origin.y = view.height - f.maxY
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = f
        if let connection = previewLayer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirrored
        }
        CATransaction.commit()
    }

    // Clicks belong to the SwiftUI views around it (drag to pan, double-click).
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A generated "camera frame": a soft, faceless gradient portrait in a room with a window,
/// drawn in a 16:9 source. Stands in for the camera in snapshots and the settings hero.
struct SamplePortrait: View {
    enum Light { case good, dim }

    static let sourceSize = CGSize(width: 1920, height: 1080)
    var light: Light = .good

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            func rect(_ x: CGFloat, _ y: CGFloat, _ rw: CGFloat, _ rh: CGFloat) -> CGRect {
                CGRect(x: x * w, y: y * h, width: rw * w, height: rh * h)
            }
            // Wall: warm at the bottom, cool toward a ceiling.
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
                Gradient(colors: [Color(red: 0.66, green: 0.71, blue: 0.74), Color(red: 0.86, green: 0.80, blue: 0.72),
                                  Color(red: 0.72, green: 0.60, blue: 0.50)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))
            // A window on the left, the main light source.
            var glow = ctx
            glow.addFilter(.blur(radius: w * 0.03))
            glow.fill(Path(roundedRect: rect(0.04, 0.10, 0.20, 0.62), cornerRadius: w * 0.01),
                      with: .linearGradient(Gradient(colors: [Color(red: 0.99, green: 0.98, blue: 0.93), Color(red: 0.86, green: 0.93, blue: 0.98)]),
                                            startPoint: CGPoint(x: 0.04 * w, y: 0.1 * h), endPoint: CGPoint(x: 0.24 * w, y: 0.72 * h)))
            glow.fill(Path(ellipseIn: rect(-0.05, 0.05, 0.55, 0.85)), with: .color(Color(red: 1, green: 0.97, blue: 0.9).opacity(0.35)))
            // A shelf and a plant on the right, out of focus.
            var bokeh = ctx
            bokeh.addFilter(.blur(radius: w * 0.012))
            bokeh.fill(Path(rect(0.74, 0.46, 0.24, 0.02)), with: .color(Color(red: 0.45, green: 0.33, blue: 0.25)))
            bokeh.fill(Path(roundedRect: rect(0.80, 0.36, 0.06, 0.10), cornerRadius: w * 0.006), with: .color(Color(red: 0.80, green: 0.47, blue: 0.36)))
            for (i, leaf) in [(0.83, 0.20, 0.05), (0.79, 0.25, 0.045), (0.86, 0.26, 0.05), (0.82, 0.30, 0.04)].enumerated() {
                let shade = Color(red: 0.25 + 0.04 * Double(i), green: 0.47 + 0.03 * Double(i), blue: 0.33)
                bokeh.fill(Path(ellipseIn: rect(leaf.0 - leaf.2 / 2, leaf.1, leaf.2, leaf.2 * 1.6)), with: .color(shade))
            }
            bokeh.fill(Path(roundedRect: rect(0.92, 0.30, 0.035, 0.16), cornerRadius: w * 0.004), with: .color(Color(red: 0.30, green: 0.38, blue: 0.55)))
            bokeh.fill(Path(roundedRect: rect(0.955, 0.33, 0.03, 0.13), cornerRadius: w * 0.004), with: .color(Color(red: 0.78, green: 0.68, blue: 0.46)))

            // The person, slightly right of center like a laptop camera sees you.
            var body = ctx
            body.addFilter(.blur(radius: w * 0.0025))
            var shoulders = Path()
            shoulders.move(to: CGPoint(x: 0.27 * w, y: h))
            shoulders.addCurve(to: CGPoint(x: 0.43 * w, y: 0.70 * h), control1: CGPoint(x: 0.29 * w, y: 0.80 * h), control2: CGPoint(x: 0.35 * w, y: 0.72 * h))
            shoulders.addQuadCurve(to: CGPoint(x: 0.61 * w, y: 0.70 * h), control: CGPoint(x: 0.52 * w, y: 0.665 * h))
            shoulders.addCurve(to: CGPoint(x: 0.77 * w, y: h), control1: CGPoint(x: 0.69 * w, y: 0.72 * h), control2: CGPoint(x: 0.75 * w, y: 0.80 * h))
            shoulders.closeSubpath()
            body.fill(shoulders, with: .linearGradient(
                Gradient(colors: [Color(red: 0.36, green: 0.47, blue: 0.62), Color(red: 0.20, green: 0.27, blue: 0.40)]),
                startPoint: CGPoint(x: 0.3 * w, y: 0.7 * h), endPoint: CGPoint(x: 0.75 * w, y: h)))
            // Collar.
            var collar = Path()
            collar.move(to: CGPoint(x: 0.47 * w, y: 0.685 * h))
            collar.addQuadCurve(to: CGPoint(x: 0.57 * w, y: 0.685 * h), control: CGPoint(x: 0.52 * w, y: 0.76 * h))
            body.fill(collar, with: .color(Color(red: 0.93, green: 0.91, blue: 0.87)))
            // Neck.
            let skinLight = Color(red: 0.93, green: 0.76, blue: 0.64), skinShade = Color(red: 0.74, green: 0.54, blue: 0.43)
            body.fill(Path(roundedRect: rect(0.48, 0.52, 0.08, 0.19), cornerRadius: w * 0.02),
                      with: .linearGradient(Gradient(colors: [skinShade, skinLight.opacity(0.9)]),
                                            startPoint: CGPoint(x: 0.52 * w, y: 0.70 * h), endPoint: CGPoint(x: 0.52 * w, y: 0.52 * h)))
            // Head, lit from the window side.
            let head = rect(0.435, 0.20, 0.17, 0.40)
            body.fill(Path(ellipseIn: head), with: .radialGradient(
                Gradient(colors: [skinLight, Color(red: 0.86, green: 0.66, blue: 0.54), skinShade]),
                center: CGPoint(x: head.minX + head.width * 0.35, y: head.minY + head.height * 0.45),
                startRadius: 0, endRadius: head.width * 0.75))
            // Hair: the head's outline grown a little, cut along a soft hairline with a side part.
            let hw = head.width, hh = head.height
            var hairline = Path()
            hairline.move(to: CGPoint(x: head.minX - hw * 0.2, y: head.minY + hh * 0.56))
            hairline.addLine(to: CGPoint(x: head.minX + hw * 0.02, y: head.minY + hh * 0.56))
            hairline.addCurve(to: CGPoint(x: head.minX + hw * 0.36, y: head.minY + hh * 0.22),
                              control1: CGPoint(x: head.minX + hw * 0.08, y: head.minY + hh * 0.34),
                              control2: CGPoint(x: head.minX + hw * 0.2, y: head.minY + hh * 0.22))
            hairline.addCurve(to: CGPoint(x: head.maxX - hw * 0.02, y: head.minY + hh * 0.52),
                              control1: CGPoint(x: head.minX + hw * 0.62, y: head.minY + hh * 0.20),
                              control2: CGPoint(x: head.maxX - hw * 0.06, y: head.minY + hh * 0.30))
            hairline.addLine(to: CGPoint(x: head.maxX + hw * 0.2, y: head.minY + hh * 0.52))
            hairline.addLine(to: CGPoint(x: head.maxX + hw * 0.2, y: head.minY - hh * 0.3))
            hairline.addLine(to: CGPoint(x: head.minX - hw * 0.2, y: head.minY - hh * 0.3))
            hairline.closeSubpath()
            var hair = body
            hair.clip(to: hairline)
            let crown = CGRect(x: head.minX - hw * 0.05, y: head.minY - hh * 0.07, width: hw * 1.1, height: hh * 1.0)
            hair.fill(Path(ellipseIn: crown), with: .linearGradient(
                Gradient(colors: [Color(red: 0.40, green: 0.28, blue: 0.20), Color(red: 0.20, green: 0.13, blue: 0.10)]),
                startPoint: CGPoint(x: crown.minX, y: crown.minY), endPoint: CGPoint(x: crown.maxX, y: crown.midY)))
            // Rim light on the window side of the face and shoulder.
            var rim = ctx
            rim.addFilter(.blur(radius: w * 0.006))
            rim.stroke(Path(ellipseIn: head.insetBy(dx: w * 0.004, dy: h * 0.004)).trimmedPath(from: 0.30, to: 0.55),
                       with: .color(.white.opacity(0.35)), lineWidth: w * 0.004)

            // A gentle vignette, like a webcam lens.
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .radialGradient(
                Gradient(colors: [.clear, .black.opacity(light == .dim ? 0.55 : 0.22)]),
                center: CGPoint(x: w * 0.5, y: h * 0.5), startRadius: w * 0.3, endRadius: w * 0.75))
            if light == .dim {
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.05, green: 0.05, blue: 0.12).opacity(0.5)))
            }
        }
    }
}
