import AppKit
import MacToysCore
import SwiftUI

/// Everything in the bar's panel: the capsule, or a result card in its place.
struct BarRootView: View {
    static let space = "textactions.bar"
    let model: BarModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let card = model.card {
                ResultCardView(card: card, scale: model.scale, copied: model.cardCopied, keyboard: model.keyboardMode) {
                    model.onCardAction?($0)
                }
                .transition(.opacity)
            } else {
                ActionBarView(model: model)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.14), value: model.card == nil)
        .scaleEffect(model.isShown || reduceMotion ? 1 : 0.92, anchor: model.below ? .top : .bottom)
        .opacity(model.isShown ? 1 : 0)
        .animation(reduceMotion ? .easeOut(duration: 0.12) : .snappy(duration: 0.22), value: model.isShown)
        .fixedSize()
        .padding(BarMetrics.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: model.below ? .top : .bottom)
        .coordinateSpace(.named(Self.space))
        .environment(\.colorScheme, .dark)
    }
}

/// The capsule of action buttons, with a caption naming the pointed-at action.
struct ActionBarView: View {
    let model: BarModel

    var body: some View {
        let s = model.scale
        VStack(spacing: BarMetrics.captionSpacing * s) {
            if model.hasCaptionBand && !model.below { caption }
            capsule
            if model.hasCaptionBand && model.below { caption }
        }
    }

    private var capsule: some View {
        let s = model.scale
        let items = model.current
        return HStack(spacing: 2 * s) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if item.kind == .more { BarDivider(scale: s) }
                BarButton(item: item, index: index, model: model)
                if item.kind == .back { BarDivider(scale: s) }
            }
        }
        .padding(4 * s)
        .background { BarGlass(shape: Capsule()) }
    }

    private var captionText: String? {
        if let done = model.doneCaption { return done }
        guard let item = model.captionItem else { return nil }
        return model.style == .icons || item.face != nil || item.kind == .more || item.kind == .back ? item.title : nil
    }

    private var caption: some View {
        let s = model.scale
        let text = captionText
        return Text(verbatim: text ?? " ")
            .font(.system(size: 11.5 * s, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 9 * s)
            .frame(height: BarMetrics.captionHeight * s)
            .background(Capsule().fill(Color.black.opacity(0.66)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
            .opacity(text == nil ? 0 : 1)
            .animation(.easeOut(duration: 0.12), value: text)
            .accessibilityHidden(true)
    }
}

struct BarDivider: View {
    let scale: CGFloat

    var body: some View {
        Rectangle()
            .fill(.white.opacity(0.16))
            .frame(width: 1, height: 16 * scale)
            .padding(.horizontal, 1)
    }
}

/// One action in the capsule.
struct BarButton: View {
    let item: BarItem
    let index: Int
    let model: BarModel

    var body: some View {
        let s = model.scale
        Button {
            model.onActivate?(item)
        } label: {
            label(s)
                .frame(height: BarMetrics.buttonHeight * s)
                .contentShape(Capsule())
        }
        .buttonStyle(BarButtonStyle(selected: model.keyboardMode && model.highlighted == index, hovered: model.hovered == index))
        .accessibilityLabel(Text(verbatim: item.title))
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(BarRootView.space))
        } action: { frame in
            model.itemFrames[index] = frame
        }
    }

    @ViewBuilder
    private func label(_ s: CGFloat) -> some View {
        if model.busyID == item.id {
            ProgressView()
                .controlSize(.small)
                .frame(width: BarMetrics.iconWidth * s)
        } else if model.doneID == item.id {
            Image(systemName: "checkmark")
                .font(.system(size: 14 * s, weight: .bold))
                .foregroundStyle(Color(red: 0.42, green: 0.9, blue: 0.55))
                .frame(minWidth: BarMetrics.iconWidth * s)
                .transition(.scale.combined(with: .opacity))
        } else if item.kind == .more || item.kind == .back {
            Image(systemName: item.symbol ?? "chevron.right")
                .font(.system(size: 11 * s, weight: .bold))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: BarMetrics.chevronWidth * s)
        } else if let face = item.face {
            Text(verbatim: face)
                .font(item.monospaced ? .system(size: 12 * s, weight: .medium, design: .monospaced)
                                      : .system(size: 12.5 * s, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 10 * s)
        } else {
            switch model.style {
            case .icons:
                icon(size: 15 * s)
                    .frame(width: BarMetrics.iconWidth * s)
            case .iconsAndLabels:
                HStack(spacing: 6 * s) {
                    icon(size: 13 * s)
                    title(s)
                }
                .padding(.horizontal, 10 * s)
            case .labels:
                title(s)
                    .padding(.horizontal, 11 * s)
            }
        }
    }

    private func icon(size: CGFloat) -> some View {
        Image(systemName: item.symbol ?? "bolt")
            .font(.system(size: size, weight: .medium))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.white)
    }

    private func title(_ s: CGFloat) -> some View {
        Text(verbatim: item.title)
            .font(.system(size: 12.5 * s, weight: .medium))
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize()
    }
}

struct BarButtonStyle: ButtonStyle {
    let selected: Bool
    let hovered: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                Capsule().fill(fill(pressed: configuration.isPressed))
            }
            .animation(.easeOut(duration: 0.1), value: hovered)
            .animation(.easeOut(duration: 0.1), value: selected)
    }

    private func fill(pressed: Bool) -> Color {
        if selected { return Color.accentColor }
        if pressed { return .white.opacity(0.28) }
        if hovered { return .white.opacity(0.16) }
        return .clear
    }
}

/// The dark Liquid Glass of MacToys overlays, in any shape; solid with Reduce Transparency,
/// a stronger edge with Increase Contrast.
struct BarGlass<S: InsettableShape>: View {
    let shape: S
    var shadow = true
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Group {
            if reduceTransparency {
                shape.fill(Color(red: 0.13, green: 0.13, blue: 0.15))
            } else {
                shape.fill(Color(red: 0.11, green: 0.11, blue: 0.13).opacity(0.55))
                    .glassEffect(.regular, in: shape)
            }
        }
        .overlay(shape.strokeBorder(.white.opacity(contrast == .increased ? 0.45 : 0.14), lineWidth: 1))
        .shadow(color: .black.opacity(shadow ? 0.3 : 0), radius: 10, y: 4)
    }
}
