import MacToysCore
import SwiftUI

/// The settings hero: a miniature desktop and trackpad playing the gestures that are on — the
/// fingers travel, the glass preview appears, the window lands in it. A still frame (mid-swipe,
/// preview showing) in snapshots and with Reduce Motion, where the steps change without motion.
struct GestureHero: View {
    let settings: WindowGesturesSettings
    @Environment(\.drawsControlsForSnapshot) private var snapshot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    static let stepDuration: TimeInterval = 3.4

    var body: some View {
        let steps = HeroStep.steps(for: settings)
        HeroCard(tint: .cyan) {
            if steps.isEmpty {
                HStack(spacing: 14) {
                    Image(systemName: "hand.raised.slash").font(.system(size: 26)).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("No title bar gestures are on").font(.headline)
                        Text("Pick an action for a gesture below to start using it.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            } else if snapshot || !isEnabled {
                HeroFrame(step: steps[0], t: 0.47, index: 0, count: steps.count)
            } else if reduceMotion {
                TimelineView(.periodic(from: .now, by: Self.stepDuration)) { context in
                    let i = Int(context.date.timeIntervalSinceReferenceDate / Self.stepDuration) % steps.count
                    HeroFrame(step: steps[i], t: 0.47, index: i, count: steps.count)
                        .animation(.easeInOut(duration: 0.3), value: i)
                }
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    let elapsed = context.date.timeIntervalSinceReferenceDate
                    let i = Int(elapsed / Self.stepDuration) % steps.count
                    let t = elapsed.truncatingRemainder(dividingBy: Self.stepDuration) / Self.stepDuration
                    HeroFrame(step: steps[i], t: t, index: i, count: steps.count)
                }
            }
        }
    }
}

/// One gesture the hero plays.
struct HeroStep: Equatable {
    enum Effect: Equatable {
        /// The window moves to `target` (unit coordinates of the work area).
        case move(target: CGRect, tile: Tile?)
        /// The close ring fills, then the window goes.
        case close(quitting: Bool)
        case minimize
    }

    let glyph: GestureGlyph.Kind
    let keys: [String]
    let title: Text
    let detail: Text
    /// The window's frame before the gesture (unit coordinates of the work area).
    let start: CGRect
    let effect: Effect

    static let floating = CGRect(x: 0.2, y: 0.12, width: 0.56, height: 0.72)

    static func steps(for s: WindowGesturesSettings) -> [HeroStep] {
        let swipe = GestureCatalog.Word.swipe
        var list: [HeroStep] = []
        if s.swipeToHalves {
            list.append(HeroStep(glyph: .swipe(.left), keys: [swipe, "←"], title: Text("Swipe left on a title bar"),
                                 detail: s.cycleSizes ? Text("The window takes the left half. Swipe again for a third, then two thirds.")
                                     : Text("The window takes the left half of the screen."),
                                 start: floating, effect: .move(target: CGRect(x: 0, y: 0, width: 0.5, height: 1), tile: .half(.left))))
        }
        if s.cornerSwipes {
            list.append(HeroStep(glyph: .corner(.right, .up), keys: [swipe, "→", "↑"], title: Text("Swipe right, then up"),
                                 detail: Text("A corner swipe tiles to that quarter. Swipe again for a sixth."),
                                 start: floating, effect: .move(target: CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5),
                                                                tile: .quarter(.right, top: true))))
        }
        switch s.swipeUp {
        case .fill:
            list.append(HeroStep(glyph: .swipe(.up), keys: [swipe, "↑"], title: Text("Swipe up"),
                                 detail: Text("The window fills the screen, menu bar and Dock left clear."),
                                 start: floating, effect: .move(target: CGRect(x: 0, y: 0, width: 1, height: 1), tile: .fill)))
        case .fullScreen:
            list.append(HeroStep(glyph: .swipe(.up), keys: [swipe, "↑"], title: Text("Swipe up"),
                                 detail: Text("The window enters full screen. Swipe down on it to leave."),
                                 start: floating, effect: .move(target: CGRect(x: 0, y: -0.1, width: 1, height: 1.2), tile: nil)))
        case .nothing:
            break
        }
        if s.pinchIn == .closeWindow || s.pinchIn == .quitApp {
            let quitting = s.pinchIn == .quitApp
            list.append(HeroStep(glyph: .pinchIn, keys: [GestureCatalog.Word.pinchIn],
                                 title: s.confirmClose ? Text("Pinch in and hold") : Text("Pinch in"),
                                 detail: quitting
                                     ? (s.confirmClose ? Text("The app quits once the ring fills — lift early to keep it.") : Text("The app quits."))
                                     : (s.confirmClose ? Text("The window closes once the ring fills — lift early to keep it.") : Text("The window closes.")),
                                 start: floating, effect: .close(quitting: quitting)))
        } else if s.swipeDown != .nothing {
            list.append(HeroStep(glyph: .swipe(.down), keys: [swipe, "↓"], title: Text("Swipe down"),
                                 detail: Text("Restores a tiled window; swipe down again to minimize it."),
                                 start: floating, effect: .minimize))
        }
        return list
    }
}

/// One frame of the hero at time `t` (0…1) of a step.
private struct HeroFrame: View {
    let step: HeroStep
    let t: Double
    let index: Int
    let count: Int

    var body: some View {
        HStack(alignment: .center, spacing: 22) {
            MiniDesktop(step: step, t: t)
                .frame(width: 264, height: 166)
            MiniTrackpad(glyph: step.glyph, t: t)
                .frame(width: 128, height: 90)
            VStack(alignment: .leading, spacing: 7) {
                Keycaps(step.keys)
                step.title.font(.system(size: 15, weight: .semibold))
                step.detail.font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if count > 1 {
                    HStack(spacing: 5) {
                        ForEach(0..<count, id: \.self) { i in
                            Capsule().fill(i == index ? Tint.cyan.color : Color.secondary.opacity(0.3))
                                .frame(width: i == index ? 16 : 6, height: 6)
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Timing inside a step: when the fingers move, the preview shows and the window lands.
private enum HeroTiming {
    static func ease(_ x: Double) -> Double {
        let c = min(max(x, 0), 1)
        return c * c * (3 - 2 * c)
    }
    /// Finger travel, 0…1.
    static func fingers(_ t: Double) -> Double { ease((t - 0.1) / 0.38) }
    /// Fingers on the trackpad (fade in, lift).
    static func touch(_ t: Double) -> Double { min(ease(t / 0.08), 1 - ease((t - 0.5) / 0.06)) }
    /// Preview opacity.
    static func preview(_ t: Double) -> Double { min(ease((t - 0.26) / 0.1), 1 - ease((t - 0.62) / 0.12)) }
    /// Window travel to the target, 0…1, then back before the next step.
    static func window(_ t: Double) -> Double { min(ease((t - 0.5) / 0.14), 1 - ease((t - 0.92) / 0.08)) }
}

/// A desktop the size of a thumbnail with one window.
private struct MiniDesktop: View {
    let step: HeroStep
    let t: Double
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let menu: CGFloat = 9, dockH: CGFloat = 14
            let work = CGRect(x: 4, y: menu + 3, width: size.width - 8, height: size.height - menu - dockH - 8)
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [Color(red: 0.13, green: 0.17, blue: 0.42), Color(red: 0.3, green: 0.2, blue: 0.58),
                                        Color(red: 0.66, green: 0.3, blue: 0.55), Color(red: 0.9, green: 0.58, blue: 0.45)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Rectangle().fill(.white.opacity(0.22)).frame(height: menu)
                dock.position(x: size.width / 2, y: size.height - dockH / 2 - 3)
                content(work: work)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.black.opacity(0.12)))
            .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        }
    }

    private var dock: some View {
        HStack(spacing: 3) {
            ForEach(0..<7, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill([Color.blue, .orange, .green, .pink, .purple, .teal, .gray][i].opacity(0.9))
                    .frame(width: 8, height: 8)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.white.opacity(0.28)))
    }

    @ViewBuilder private func content(work: CGRect) -> some View {
        let start = Self.place(step.start, in: work)
        switch step.effect {
        case let .move(target, _):
            let end = Self.place(target, in: work).insetBy(dx: 1, dy: 1)
            let w = HeroTiming.window(t)
            let preview = HeroTiming.preview(t)
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.accentColor.opacity(0.25))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 1.5))
                .frame(width: end.width, height: end.height)
                .offset(x: end.minX, y: end.minY)
                .opacity(preview)
            MiniWindow(dark: scheme == .dark)
                .frame(width: Self.mix(start.width, end.width, w), height: Self.mix(start.height, end.height, w))
                .offset(x: Self.mix(start.minX, end.minX, w), y: Self.mix(start.minY, end.minY, w))
            pointer(at: CGPoint(x: Self.mix(start.midX, end.midX, w), y: Self.mix(start.minY, end.minY, w) + 6))
        case .close(let quitting):
            let fade = 1 - HeroTiming.ease((t - 0.56) / 0.1) + HeroTiming.ease((t - 0.9) / 0.08)
            MiniWindow(dark: scheme == .dark)
                .frame(width: start.width, height: start.height)
                .offset(x: start.minX, y: start.minY)
                .scaleEffect(0.9 + 0.1 * min(1, fade), anchor: .center)
                .opacity(min(1, fade))
            ring(quitting: quitting).position(x: start.midX, y: start.midY).opacity(HeroTiming.preview(t))
            pointer(at: CGPoint(x: start.midX, y: start.minY + 6)).opacity(min(1, fade))
        case .minimize:
            let w = HeroTiming.window(t)
            MiniWindow(dark: scheme == .dark)
                .frame(width: start.width, height: start.height)
                .scaleEffect(1 - 0.75 * w, anchor: .bottom)
                .offset(x: start.minX, y: start.minY + w * 30)
                .opacity(1 - w * 0.8)
        }
    }

    private func ring(quitting: Bool) -> some View {
        let p = HeroTiming.ease((t - 0.2) / 0.32)
        return ZStack {
            Circle().fill(Color(white: 0.12).opacity(0.78))
            Circle().stroke(.white.opacity(0.18), lineWidth: 2.5).padding(5)
            Circle().trim(from: 0, to: max(0.001, p))
                .stroke(p >= 1 ? Color.red : .white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90)).padding(5)
            Image(systemName: quitting ? "power" : "xmark").font(.system(size: 10, weight: .bold))
                .foregroundStyle(p >= 1 ? Color.red : .white)
        }
        .frame(width: 34, height: 34)
    }

    private func pointer(at p: CGPoint) -> some View {
        Image(systemName: "cursorarrow")
            .font(.system(size: 11))
            .foregroundStyle(.black)
            .background(Image(systemName: "cursorarrow").font(.system(size: 13)).foregroundStyle(.white))
            .position(x: p.x + 3, y: p.y + 5)
    }

    static func place(_ unit: CGRect, in work: CGRect) -> CGRect {
        CGRect(x: work.minX + unit.minX * work.width, y: work.minY + unit.minY * work.height,
               width: unit.width * work.width, height: unit.height * work.height)
    }

    static func mix(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat { a + (b - a) * CGFloat(t) }
}

/// A tiny app window: title bar with the three buttons, a sidebar and lines of text.
private struct MiniWindow: View {
    let dark: Bool

    var body: some View {
        let bar = dark ? Color(white: 0.24) : Color(white: 0.93)
        let body = dark ? Color(white: 0.16) : .white
        let line = dark ? Color(white: 0.3) : Color(white: 0.86)
        VStack(spacing: 0) {
            HStack(spacing: 2.5) {
                ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0.opacity(0.9)).frame(width: 4, height: 4) }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 5)
            .frame(height: 11)
            .background(bar)
            HStack(spacing: 0) {
                Rectangle().fill(bar.opacity(0.7)).frame(width: 18)
                VStack(alignment: .leading, spacing: 3.5) {
                    ForEach(0..<6, id: \.self) { i in
                        Capsule().fill(line).frame(height: 2.5).frame(maxWidth: i % 3 == 2 ? 40 : .infinity)
                    }
                    Spacer(minLength: 0)
                }
                .padding(6)
            }
            .background(body)
        }
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .shadow(color: .black.opacity(0.28), radius: 4, y: 2)
    }
}

/// A trackpad seen from above, with two fingers drawing the gesture.
private struct MiniTrackpad: View {
    let glyph: GestureGlyph.Kind
    let t: Double
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        ZStack {
            shape.fill(LinearGradient(colors: dark ? [Color(white: 0.33), Color(white: 0.25)] : [Color(white: 0.96), Color(white: 0.86)],
                                      startPoint: .top, endPoint: .bottom))
            shape.strokeBorder(.white.opacity(dark ? 0.12 : 0.8), lineWidth: 1).padding(1)
            shape.strokeBorder(.black.opacity(dark ? 0.4 : 0.14), lineWidth: 0.5)
            GeometryReader { geo in
                Canvas { ctx, size in draw(&ctx, size) }
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .shadow(color: .black.opacity(dark ? 0.4 : 0.12), radius: 6, y: 3)
        .accessibilityHidden(true)
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let p = HeroTiming.fingers(t)
        let touch = HeroTiming.touch(t)
        guard touch > 0.01 else { return }
        let tint = Tint.cyan.color
        func finger(_ at: CGPoint) {
            let r: CGFloat = 9
            let rect = CGRect(x: at.x - r, y: at.y - r, width: 2 * r, height: 2 * r)
            // A soft cyan glow where the finger touches, then the fingertip itself.
            ctx.fill(Path(ellipseIn: rect.insetBy(dx: -5, dy: -5)),
                     with: .radialGradient(Gradient(colors: [tint.opacity(0.35 * touch), tint.opacity(0)]),
                                           center: at, startRadius: r * 0.6, endRadius: r + 5))
            ctx.drawLayer { layer in
                layer.addFilter(.shadow(color: .black.opacity(0.22 * touch), radius: 2.5, y: 1.5))
                layer.fill(Path(ellipseIn: rect),
                           with: .linearGradient(Gradient(colors: [.white.opacity(touch), Color(white: 0.9).opacity(touch)]),
                                                 startPoint: CGPoint(x: at.x, y: rect.minY), endPoint: CGPoint(x: at.x, y: rect.maxY)))
            }
            ctx.stroke(Path(ellipseIn: rect.insetBy(dx: 0.75, dy: 0.75)), with: .color(tint.opacity(0.9 * touch)), lineWidth: 1.5)
        }
        func trail(_ from: CGPoint, _ to: CGPoint) {
            var path = Path()
            path.move(to: from)
            path.addLine(to: to)
            ctx.stroke(path, with: .linearGradient(Gradient(colors: [tint.opacity(0), tint.opacity(0.5 * touch)]),
                                                   startPoint: from, endPoint: to),
                       style: StrokeStyle(lineWidth: 8, lineCap: .round))
        }
        func lerp(_ a: CGPoint, _ b: CGPoint, _ k: Double) -> CGPoint {
            CGPoint(x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k)
        }
        switch glyph {
        case .swipe(let d), .swipeAgain(let d):
            let v: CGVector = switch d {
            case .left: CGVector(dx: -1, dy: 0)
            case .right: CGVector(dx: 1, dy: 0)
            case .up: CGVector(dx: 0, dy: -1)
            case .down: CGVector(dx: 0, dy: 1)
            }
            let reach: CGFloat = d.isHorizontal ? 30 : 20
            let spread = d.isHorizontal ? CGVector(dx: 0, dy: 11) : CGVector(dx: 11, dy: 0)
            let from = c - v * reach, to = c + v * reach
            for s in [-1.0, 1.0] {
                let a = from + spread * s, b = lerp(a, to + spread * s, p)
                trail(a, b)
                finger(b)
            }
        case let .corner(first, second):
            let a: CGVector = first == .right ? CGVector(dx: 1, dy: 0) : CGVector(dx: -1, dy: 0)
            let b: CGVector = second == .up ? CGVector(dx: 0, dy: -1) : CGVector(dx: 0, dy: 1)
            let start = c - a * 26 - b * 12, corner = start + a * 44, end = corner + b * 26
            for s in [-1.0, 1.0] {
                let spread = CGVector(dx: -6, dy: 9) * s
                let k1 = min(1, p / 0.6), k2 = max(0, (p - 0.6) / 0.4)
                let mid = lerp(start + spread, corner + spread, k1)
                trail(start + spread, mid)
                let tip = k2 > 0 ? lerp(corner + spread, end + spread, k2) : mid
                if k2 > 0 { trail(corner + spread, tip) }
                finger(tip)
            }
        case .pinchIn, .pinchOut:
            let outer = CGVector(dx: 32, dy: 20), inner = CGVector(dx: 11, dy: 7)
            let pinchingIn = glyph == .pinchIn
            for s in [-1.0, 1.0] {
                let a = c + (pinchingIn ? outer : inner) * s, b = c + (pinchingIn ? inner : outer) * s
                let now = lerp(a, b, p)
                trail(a, now)
                finger(now)
            }
        case .doubleTap:
            for s in [-1.0, 1.0] { finger(c + CGVector(dx: 11, dy: 0) * s) }
        }
    }
}
