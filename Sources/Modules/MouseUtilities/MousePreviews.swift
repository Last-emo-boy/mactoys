import MacToysCore
import SwiftUI

/// The design boards' wallpaper, filling the whole preview (including under the toolbar area).
struct PreviewStage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.09, green: 0.13, blue: 0.36), Color(red: 0.24, green: 0.17, blue: 0.56),
                                    Color(red: 0.6, green: 0.25, blue: 0.53), Color(red: 0.88, green: 0.54, blue: 0.42)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            content
        }
        .ignoresSafeArea()
    }
}

/// A stand-in app window for previews.
private struct FakeWindow: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(Color(red: 1, green: 0.37, blue: 0.34)).frame(width: 10, height: 10)
                Circle().fill(Color(red: 1, green: 0.74, blue: 0.18)).frame(width: 10, height: 10)
                Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.25)).frame(width: 10, height: 10)
            }
            .padding(10)
            VStack(alignment: .leading, spacing: 10) {
                RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.12)).frame(width: 220, height: 10)
                RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.08)).frame(width: 300, height: 8)
                RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.08)).frame(width: 260, height: 8)
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 6).fill(Color(red: 0.37, green: 0.36, blue: 0.9)).frame(width: 120, height: 70)
                    RoundedRectangle(cornerRadius: 6).fill(Color(red: 0.2, green: 0.78, blue: 0.35)).frame(width: 120, height: 70)
                    RoundedRectangle(cornerRadius: 6).fill(Color(red: 0.04, green: 0.52, blue: 1)).frame(width: 120, height: 70)
                }
                .padding(.top, 6)
            }
            .padding(.horizontal, 18)
            Spacer()
        }
        .frame(width: 440, height: 260)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.97)))
        .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
    }
}

private struct PointerGlyph: View {
    var body: some View {
        Image(systemName: "cursorarrow")
            .font(.system(size: 22))
            .foregroundStyle(.black)
            .background(Image(systemName: "cursorarrow").font(.system(size: 25, weight: .bold)).foregroundStyle(.white))
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
    }
}

/// Find My Mouse: dimmed screen, clear spotlight with the pointer, thin outer ring.
struct SpotlightPreview: View {
    let settings: FindMyMouseSettings

    var body: some View {
        GeometryReader { geo in
            let c = CGPoint(x: geo.size.width * 0.5, y: geo.size.height * 0.5)
            let r = CGFloat(settings.spotlightRadius)
            ZStack {
                FakeWindow().position(x: geo.size.width * 0.35, y: geo.size.height * 0.4)
                Path { p in
                    p.addRect(CGRect(origin: .zero, size: geo.size))
                    p.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
                }
                .fill(settings.backdropColor.color, style: FillStyle(eoFill: true))
                Circle().fill(settings.spotlightColor.color).frame(width: r * 2, height: r * 2).position(c)
                Circle().strokeBorder(Color.white.opacity(0.55), lineWidth: 1.5)
                    .frame(width: r * 2.9, height: r * 2.9).position(c)
                PointerGlyph().position(x: c.x + 6, y: c.y + 9)
            }
        }
    }
}

/// Mouse Highlighter, Ripple mode: a click pulse, a held ring, and the right-release crosshairs.
struct HighlighterPreview: View {
    let settings: HighlighterSettings

    var body: some View {
        GeometryReader { geo in
            let size = CGFloat(settings.rippleSize)
            let width = 1.5 + 4 * settings.rippleIntensity
            let click = CGPoint(x: geo.size.width * 0.3, y: geo.size.height * 0.55)
            let hold = CGPoint(x: geo.size.width * 0.62, y: geo.size.height * 0.4)
            let release = CGPoint(x: geo.size.width * 0.78, y: geo.size.height * 0.72)
            ZStack {
                FakeWindow().position(x: geo.size.width * 0.45, y: geo.size.height * 0.5)
                ForEach(0..<3) { i in
                    let scale = 0.45 + Double(i) * 0.3
                    Circle()
                        .strokeBorder(settings.primaryColor.color.opacity(1 - Double(i) * 0.3), lineWidth: width)
                        .frame(width: size * scale, height: size * scale)
                        .position(click)
                }
                Circle()
                    .strokeBorder(settings.primaryColor.color, lineWidth: 2 + 2 * settings.rippleIntensity)
                    .frame(width: size * 0.64, height: size * 0.64)
                    .position(hold)
                PointerGlyph().position(x: hold.x + 6, y: hold.y + 9)
                Path { p in
                    let h = size * 0.6
                    p.move(to: CGPoint(x: release.x - h, y: release.y)); p.addLine(to: CGPoint(x: release.x - h * 0.3, y: release.y))
                    p.move(to: CGPoint(x: release.x + h * 0.3, y: release.y)); p.addLine(to: CGPoint(x: release.x + h, y: release.y))
                    p.move(to: CGPoint(x: release.x, y: release.y - h)); p.addLine(to: CGPoint(x: release.x, y: release.y - h * 0.3))
                    p.move(to: CGPoint(x: release.x, y: release.y + h * 0.3)); p.addLine(to: CGPoint(x: release.x, y: release.y + h))
                }
                .stroke(settings.secondaryColor.color, style: StrokeStyle(lineWidth: 2 + 2 * settings.rippleIntensity, lineCap: .round))
                Text("click · hold · right-click release")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.8))
                    .position(x: geo.size.width / 2, y: geo.size.height - 24)
            }
        }
    }
}

/// Mouse Jump with two displays, as in the design.
struct MouseJumpPreview: View {
    let settings: MouseJumpSettings

    var body: some View {
        let model = MouseJumpModel(
            frames: [(CGRect(x: 0, y: 0, width: 1512, height: 982), 1, "Built-in Retina Display"),
                     (CGRect(x: 1512, y: 262, width: 1280, height: 720), 2, "Studio Display")],
            primary: 0, pointer: CGPoint(x: 820, y: 470), settings: settings, maxSize: CGSize(width: 560, height: 300))
        MouseJumpView(model: model)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Crosshairs through the pointer.
struct CrosshairsPreview: View {
    let settings: CrosshairsSettings

    var body: some View {
        GeometryReader { geo in
            let c = CGPoint(x: geo.size.width * 0.56, y: geo.size.height * 0.46)
            let arms = CrosshairGeometry.arms(center: c, bounds: CGRect(origin: .zero, size: geo.size),
                                              radius: settings.centerRadius, thickness: max(settings.thickness, 1),
                                              length: settings.fixedLength ? settings.length : nil,
                                              orientation: settings.orientation)
            let b = CGFloat(settings.borderSize)
            ZStack {
                FakeWindow().position(x: geo.size.width * 0.42, y: geo.size.height * 0.5)
                ZStack {
                    ForEach(Array(arms.enumerated()), id: \.offset) { _, arm in
                        Rectangle().fill(settings.borderColor.color)
                            .frame(width: arm.width + 2 * b, height: arm.height + 2 * b).position(x: arm.midX, y: arm.midY)
                    }
                    ForEach(Array(arms.enumerated()), id: \.offset) { _, arm in
                        Rectangle().fill(settings.color.color)
                            .frame(width: arm.width, height: arm.height).position(x: arm.midX, y: arm.midY)
                    }
                }
                .opacity(settings.opacity)
                PointerGlyph().position(x: c.x + 6, y: c.y + 9)
            }
        }
    }
}
