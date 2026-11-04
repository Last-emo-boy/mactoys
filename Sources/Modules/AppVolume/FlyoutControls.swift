import AppKit
import MacToysCore
import SwiftUI

extension View {
    /// The flyout's inner card: a faint white fill on the dark glass.
    func flyoutCard(padding: CGFloat = 12, highlighted: Bool = false) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(highlighted ? 0.09 : 0.06)))
    }
}

/// A wide capsule slider (Control Center style) for 0…`maximum`. Past 100 % the fill turns the
/// module tint, with a tick at 100 % that the value snaps to.
struct VolumeSlider: View {
    @Binding var value: Double
    var maximum: Double = 1
    var dimmed = false
    var height: CGFloat = 20
    var label: Text
    /// Called when the pointer enters (true) or leaves (false), for scroll-wheel steps.
    var onHover: ((Bool) -> Void)?
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let step = 0.05

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let unityX = maximum > 1 ? w / maximum : w
            let fill = max(height, w * min(value, maximum) / maximum)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.13))
                Capsule()
                    .fill(LinearGradient(stops: gradientStops(width: fill, unityX: unityX),
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: fill)
                    .opacity(dimmed || value <= 0 ? 0.35 : 1)
                if maximum > 1 {
                    Capsule()
                        .fill(value > 1 ? Color.black.opacity(0.25) : Color.white.opacity(0.35))
                        .frame(width: 1.5, height: height * 0.45)
                        .offset(x: unityX - 0.75)
                }
            }
            .overlay(Capsule().strokeBorder(.white.opacity(focused ? 0.45 : 0), lineWidth: 1.5))
            .contentShape(Capsule())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                var v = max(0, min(maximum, g.location.x / max(1, w) * maximum))
                if maximum > 1, abs(v - 1) < maximum * 0.025 { v = 1 }
                value = (v * 100).rounded() / 100
            })
        }
        .frame(height: height)
        .onHover { onHover?($0) }
        .focusable(NSApplication.shared.isFullKeyboardAccessEnabled)
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { value = max(0, value - step); return .handled }
        .onKeyPress(.rightArrow) { value = min(maximum, value + step); return .handled }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(Text(verbatim: value.formatted(.percent.precision(.fractionLength(0)))))
        .accessibilityAdjustableAction { direction in
            value = direction == .increment ? min(maximum, value + step) : max(0, value - step)
        }
    }

    /// White up to 100 %, then the tint for the boost.
    private func gradientStops(width: CGFloat, unityX: CGFloat) -> [Gradient.Stop] {
        let white = Color.white.opacity(0.92)
        guard value > 1, width > 0 else { return [.init(color: white, location: 0), .init(color: white, location: 1)] }
        let u = min(1, unityX / width)
        let boost = Tint.purple.color
        return [.init(color: white, location: 0), .init(color: white, location: u),
                .init(color: Color(nsColor: Tint.purple.nsColor.blended(withFraction: 0.35, of: .white) ?? .systemPurple), location: min(1, u + 0.001)),
                .init(color: boost, location: 1)]
    }
}

/// Speaker (or mic) button that shows and toggles mute.
struct MuteButton: View {
    let muted: Bool
    var input = false
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            TintedSymbol(name: symbol, size: 12, color: muted ? .systemOrange : NSColor.white.withAlphaComponent(0.6))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(muted ? Text("Unmute") : Text("Mute"))
        .accessibilityLabel(muted ? Text("Unmute") : Text("Mute"))
    }

    private var symbol: String {
        if input { return muted ? "mic.slash.fill" : "mic.fill" }
        return muted ? "speaker.slash.fill" : "speaker.wave.2.fill"
    }
}

/// Two thin bars (left over right) with a green-to-red ramp.
struct LevelMeter: View {
    let levels: LevelStore
    let key: String

    var body: some View {
        let level = levels.levels[key] ?? .silent
        VStack(spacing: 2) {
            bar(level.left)
            bar(level.right)
        }
        .frame(width: 44)
        .accessibilityHidden(true)
    }

    private func bar(_ value: Float) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.1))
                LinearGradient(stops: [.init(color: Color(red: 0.2, green: 0.82, blue: 0.42), location: 0),
                                       .init(color: Color(red: 0.2, green: 0.82, blue: 0.42), location: 0.62),
                                       .init(color: Color(red: 1, green: 0.8, blue: 0.2), location: 0.84),
                                       .init(color: Color(red: 1, green: 0.32, blue: 0.27), location: 1)],
                               startPoint: .leading, endPoint: .trailing)
                    .mask(alignment: .leading) {
                        Capsule().frame(width: geo.size.width * CGFloat(min(1, max(0, value))))
                    }
            }
        }
        .frame(height: 3)
    }
}

/// A slider around a center detent (balance, preamp), with optional end labels.
struct CenteredSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = -1...1
    var step: Double = 0.05
    var leading: Text?
    var trailing: Text?
    let label: Text
    let valueText: (Double) -> String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            if let leading { leading.font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary) }
            GeometryReader { geo in
                let w = geo.size.width
                let t = (min(max(value, range.lowerBound), range.upperBound) - range.lowerBound) / (range.upperBound - range.lowerBound)
                let x = t * w
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.13)).frame(height: 4)
                    Rectangle().fill(.white.opacity(0.4)).frame(width: 1.5, height: 10).offset(x: w / 2 - 0.75)
                    Capsule().fill(.white.opacity(0.75))
                        .frame(width: abs(x - w / 2), height: 4)
                        .offset(x: min(x, w / 2))
                    Circle().fill(.white)
                        .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                        .frame(width: 14, height: 14)
                        .overlay(Circle().strokeBorder(.white.opacity(focused ? 0.9 : 0), lineWidth: 2).padding(-3))
                        .offset(x: x - 7)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    let span = range.upperBound - range.lowerBound
                    var v = range.lowerBound + max(0, min(1, g.location.x / max(1, w))) * span
                    if abs(v) < span * 0.025 { v = 0 }
                    value = (v / step).rounded() * step
                })
            }
            .frame(height: 16)
            if let trailing { trailing.font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary) }
        }
        .focusable(NSApplication.shared.isFullKeyboardAccessEnabled)
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { nudge(-1); return .handled }
        .onKeyPress(.rightArrow) { nudge(1); return .handled }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(Text(verbatim: valueText(value)))
        .accessibilityAdjustableAction { d in nudge(d == .increment ? 1 : -1) }
    }

    private func nudge(_ direction: Double) {
        value = min(range.upperBound, max(range.lowerBound, ((value + direction * step) / step).rounded() * step))
    }
}

enum BalanceText {
    static func describe(_ value: Double) -> String {
        let pct = Int((abs(value) * 100).rounded())
        if pct == 0 { return String(localized: "Centered", comment: "Balance value") }
        return value < 0 ? String(localized: "Left \(pct)", comment: "Balance value; the number is a percentage toward the left")
            : String(localized: "Right \(pct)", comment: "Balance value; the number is a percentage toward the right")
    }
}

/// The equalizer's response curve with a draggable handle per band.
struct EQCurveView: View {
    let eq: EQSettings
    let bandCount: Int
    /// Called while dragging with the new gains (preset cleared by the caller when they differ).
    let onChange: ([Double]) -> Void
    @State private var dragging: Int?

    private static let drawRate = 48_000.0
    private let range = EQLayout.gainRange

    var body: some View {
        let freqs = EQLayout.frequencies(count: bandCount)
        let gains = EQCurve.gains(eq, count: bandCount)
        let sections = EQCurve.coefficients(EQSettings(isOn: true, gains: gains), count: bandCount, sampleRate: Self.drawRate)
        VStack(spacing: 4) {
            GeometryReader { geo in
                let size = geo.size
                ZStack {
                    Canvas { ctx, size in
                        draw(&ctx, size: size, freqs: freqs, gains: gains, sections: sections)
                    }
                    ForEach(freqs.indices, id: \.self) { i in
                        handle(i, gain: gains[i])
                            .position(x: x(freqs[i], size.width), y: y(gains[i], size.height))
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let band = dragging ?? nearest(g.startLocation.x, freqs: freqs, width: size.width)
                        dragging = band
                        var next = gains
                        next[band] = gain(atY: g.location.y, height: size.height)
                        if next != gains { onChange(next) }
                    }
                    .onEnded { _ in dragging = nil })
            }
            .frame(height: 92)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.black.opacity(0.18)))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .opacity(eq.isOn ? 1 : 0.55)
            GeometryReader { geo in
                ForEach(freqs.indices, id: \.self) { i in
                    Text(verbatim: EQCurve.label(freqs[i]))
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .position(x: x(freqs[i], geo.size.width), y: 6)
                }
            }
            .frame(height: 12)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Equalizer"))
        .overlay {
            // One adjustable element per band for VoiceOver.
            HStack(spacing: 0) {
                ForEach(freqs.indices, id: \.self) { i in
                    Color.clear
                        .accessibilityElement()
                        .accessibilityLabel(Text(verbatim: Measurement(value: freqs[i], unit: UnitFrequency.hertz)
                            .formatted(.measurement(width: .abbreviated, usage: .asProvided))))
                        .accessibilityValue(Text(verbatim: Self.dB(gains[i])))
                        .accessibilityAdjustableAction { d in
                            var next = gains
                            next[i] = min(range.upperBound, max(range.lowerBound, gains[i] + (d == .increment ? 1 : -1)))
                            onChange(next)
                        }
                }
            }
            .allowsHitTesting(false)
        }
    }

    static func dB(_ gain: Double) -> String {
        let v = gain.formatted(.number.precision(.fractionLength(0...1)).sign(strategy: .always(includingZero: false)))
        return String(localized: "\(v) dB", comment: "Equalizer band gain, e.g. '+3 dB'")
    }

    private func handle(_ i: Int, gain: Double) -> some View {
        let active = dragging == i
        return Circle()
            .fill(.white)
            .frame(width: active ? 12 : 9, height: active ? 12 : 9)
            .overlay(Circle().strokeBorder(Tint.purple.color, lineWidth: 2))
            .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
            .animation(.snappy(duration: 0.15), value: active)
            .allowsHitTesting(false)
    }

    private func draw(_ ctx: inout GraphicsContext, size: CGSize, freqs: [Double], gains: [Double],
                      sections: [BiquadCoefficients]) {
        // Grid: 0 dB, ±6 dB, and a faint line per band.
        for db in [-6.0, 6.0] {
            let yy = y(db, size.height)
            ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: yy)); $0.addLine(to: CGPoint(x: size.width, y: yy)) },
                       with: .color(.white.opacity(0.06)), lineWidth: 1)
        }
        for f in freqs {
            let xx = x(f, size.width)
            ctx.stroke(Path { $0.move(to: CGPoint(x: xx, y: 0)); $0.addLine(to: CGPoint(x: xx, y: size.height)) },
                       with: .color(.white.opacity(0.04)), lineWidth: 1)
        }
        let zero = y(0, size.height)
        ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: zero)); $0.addLine(to: CGPoint(x: size.width, y: zero)) },
                   with: .color(.white.opacity(0.22)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

        // The response, sampled on a log axis.
        let steps = 120
        var curve = Path()
        for s in 0...steps {
            let f = 20 * pow(1000, Double(s) / Double(steps))
            let db = EQCurve.response(sections, preamp: eq.preamp, at: f, sampleRate: Self.drawRate)
            let p = CGPoint(x: x(f, size.width), y: y(db, size.height))
            if s == 0 { curve.move(to: p) } else { curve.addLine(to: p) }
        }
        var area = curve
        area.addLine(to: CGPoint(x: size.width, y: zero))
        area.addLine(to: CGPoint(x: 0, y: zero))
        area.closeSubpath()
        let tint = Tint.purple.color
        ctx.fill(area, with: .linearGradient(Gradient(colors: [tint.opacity(0.6), tint.opacity(0.08), tint.opacity(0.6)]),
                                             startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: size.height)))
        ctx.stroke(curve, with: .color(Color(nsColor: Tint.purple.nsColor.blended(withFraction: 0.45, of: .white) ?? .white)),
                   style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
    }

    /// 20 Hz – 20 kHz on a log scale, inset so the end handles stay inside.
    private func x(_ f: Double, _ width: CGFloat) -> CGFloat {
        let inset: CGFloat = 12
        let t = log10(max(20, min(20_000, f)) / 20) / 3
        return inset + (width - 2 * inset) * t
    }

    private func y(_ db: Double, _ height: CGFloat) -> CGFloat {
        let inset: CGFloat = 8
        let t = (min(max(db, range.lowerBound), range.upperBound) - range.lowerBound) / (range.upperBound - range.lowerBound)
        return inset + (height - 2 * inset) * (1 - t)
    }

    private func gain(atY yy: CGFloat, height: CGFloat) -> Double {
        let inset: CGFloat = 8
        let t = 1 - (yy - inset) / max(1, height - 2 * inset)
        let db = range.lowerBound + Double(t) * (range.upperBound - range.lowerBound)
        return (min(max(db, range.lowerBound), range.upperBound) * 2).rounded() / 2
    }

    private func nearest(_ px: CGFloat, freqs: [Double], width: CGFloat) -> Int {
        freqs.indices.min { abs(x(freqs[$0], width) - px) < abs(x(freqs[$1], width) - px) } ?? 0
    }
}

/// The capsule label used by the flyout's menus (device, preset).
struct PillLabel: View {
    var symbol: String?
    let text: Text

    var body: some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold)) }
            text.lineLimit(1)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 8.5, weight: .semibold)).foregroundStyle(.secondary)
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(.white.opacity(0.09)))
    }
}

/// Buttons on the dark glass: a soft capsule, or a filled one for the main action.
struct GlassButtonStyle: ButtonStyle {
    var prominent: Tint?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(prominent.map { $0.color } ?? Color.white.opacity(0.12)))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}

/// An SF Symbol tinted through AppKit. Slashed symbols ("speaker.slash.fill") draw their slash as
/// a cut-out that SwiftUI's foreground style doesn't survive in offscreen layer renders; a
/// palette-configured `NSImage` draws the same in the app and in snapshots.
struct TintedSymbol: View {
    let name: String
    var size: CGFloat = 12
    var weight: NSFont.Weight = .semibold
    let color: NSColor

    var body: some View {
        if let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: weight)
                .applying(NSImage.SymbolConfiguration(paletteColors: [color]))) {
            Image(nsImage: image)
        } else {
            Image(systemName: name).font(.system(size: size, weight: .semibold))
        }
    }
}
