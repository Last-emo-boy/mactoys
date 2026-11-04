import AppKit
import MacToysCore
import SwiftUI

/// The dark glass surface of the Optimizer's floating cards and drop zone. Falls back to a solid
/// surface with Reduce Transparency and draws a stronger edge with Increase Contrast.
struct OverlaySurface: ViewModifier {
    var cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        Group {
            if reduceTransparency {
                content
                    .background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color(red: 0.12, green: 0.12, blue: 0.14)))
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(0.18), lineWidth: 1))
                    .environment(\.colorScheme, .dark)
            } else {
                GlassPanel(cornerRadius: cornerRadius) { content }
            }
        }
        .overlay {
            if contrast == .increased {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(.white.opacity(0.6), lineWidth: 1)
            }
        }
        .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
    }
}

extension View {
    func overlaySurface(cornerRadius: CGFloat = 22) -> some View {
        modifier(OverlaySurface(cornerRadius: cornerRadius))
    }
}

/// "−74 %" in a capsule: green when smaller.
struct SavingBadge: View {
    let saving: Double

    var body: some View {
        Text(verbatim: Self.text(saving))
            .font(.system(size: 11.5, weight: .bold).monospacedDigit())
            .foregroundStyle(saving > 0 ? Color(red: 0.35, green: 0.92, blue: 0.5) : .white.opacity(0.7))
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(saving > 0 ? Color.green.opacity(0.2) : .white.opacity(0.1)))
            .fixedSize()
    }

    /// The saving as a signed percentage: "−74 %".
    static func text(_ saving: Double, locale: Locale = .current) -> String {
        let percent = (abs(saving)).formatted(.percent.precision(.fractionLength(0)).locale(locale))
        return saving > 0 ? "−\(percent)" : (saving < 0 ? "+\(percent)" : percent)
    }
}

/// "4.2 MB → 1.1 MB".
struct SizeChange: View {
    let before: Int64
    let after: Int64?

    var body: some View {
        HStack(spacing: 5) {
            Text(verbatim: FileSize.format(before)).foregroundStyle(.white.opacity(after == nil ? 0.85 : 0.55))
            if let after {
                Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.45))
                Text(verbatim: FileSize.format(after)).foregroundStyle(.white)
            }
        }
        .font(.system(size: 12, weight: .medium).monospacedDigit())
        .lineLimit(1)
    }
}

/// A job's thumbnail, or a tinted placeholder for its kind while it loads.
struct JobThumbnail: View {
    let image: CGImage?
    let kind: MediaKind
    var size: CGFloat = 56
    var cornerRadius: CGFloat = 10

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
            } else {
                LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.06)], startPoint: .top, endPoint: .bottom)
                Image(systemName: kind.symbol)
                    .font(.system(size: size * 0.36, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
    }
}

/// A round icon button on a card.
struct CardIconButton: View {
    let symbol: String
    let label: Text
    var prominent = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white.opacity(hovering ? 1 : 0.85))
                .frame(width: 30, height: 30)
                .background(Circle().fill(prominent ? Tint.green.color.opacity(0.85) : .white.opacity(hovering ? 0.2 : 0.11)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

/// A slim progress bar in the module tint.
struct SlimProgress: View {
    let value: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12))
                if let value {
                    Capsule().fill(Tint.green.gradient)
                        .frame(width: max(6, geo.size.width * min(1, max(0, value))))
                } else if reduceMotion {
                    // No sliding: the whole track breathes instead.
                    Capsule().fill(Tint.green.color)
                        .phaseAnimator([0.25, 0.7]) { bar, opacity in bar.opacity(opacity) } animation: { _ in .easeInOut(duration: 1.2) }
                } else {
                    Capsule().fill(Tint.green.color.opacity(0.7)).frame(width: geo.size.width * 0.3)
                        .phaseAnimator([0.0, 1.0]) { bar, phase in
                            bar.offset(x: (geo.size.width * 0.7) * phase)
                        } animation: { _ in .easeInOut(duration: 0.9) }
                }
            }
        }
        .frame(height: 5)
    }
}

/// A key-capable-without-activation hosting view: buttons work on the first click, and the pointer
/// entering or leaving is reported even while MacToys isn't the active app.
final class OverlayHostingView<Content: View>: NSHostingView<Content> {
    var onHover: ((Bool) -> Void)?
    private var area: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(a)
        area = a
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHover?(false)
    }
}
