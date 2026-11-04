import MacToysCore
import SwiftUI

/// A preset drawn as a miniature display: its zones with a symbol for what each one holds, the
/// main zone emphasized. Ultrawide presets keep their wide shape.
struct PresetDiagram: View {
    let preset: LayoutPreset
    /// The display the preset would go on (workflows take its shape).
    let reference: CGSize
    var highlighted = false

    var body: some View {
        GeometryReader { geo in
            let shape = preset.referenceSize ?? reference
            let box = Self.fit(shape, in: CGRect(origin: .zero, size: geo.size).insetBy(dx: 6, dy: 6))
            let unit = preset.grid.unitRects
            let symbols = preset.zoneSymbols
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.black.opacity(0.35))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.white.opacity(0.12)))
                    .frame(width: box.width + 6, height: box.height + 6)
                    .position(x: box.midX, y: box.midY)
                ForEach(unit.indices, id: \.self) { i in
                    let r = CGRect(x: box.minX + unit[i].minX * box.width, y: box.minY + unit[i].minY * box.height,
                                   width: unit[i].width * box.width, height: unit[i].height * box.height)
                        .insetBy(dx: 1.5, dy: 1.5)
                    zone(r, symbol: symbols.indices.contains(i) ? symbols[i] : nil, primary: i == preset.primaryZone)
                }
            }
        }
    }

    private func zone(_ r: CGRect, symbol: String?, primary: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        let tint = highlighted ? Color.accentColor : Color(red: 0.36, green: 0.52, blue: 1)
        return shape
            .fill(tint.opacity(primary ? 0.62 : 0.3))
            .overlay(shape.strokeBorder(Color.white.opacity(primary ? 0.45 : 0.2), lineWidth: 1))
            .overlay {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: max(7, min(15, min(r.width, r.height) * 0.36)), weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Color.white.opacity(primary ? 0.95 : 0.72))
                        .opacity(min(r.width, r.height) >= 14 ? 1 : 0)
                }
            }
            .frame(width: max(0, r.width), height: max(0, r.height))
            .position(x: r.midX, y: r.midY)
    }

    /// The largest rectangle of `shape`'s aspect ratio centered in `box`.
    static func fit(_ shape: CGSize, in box: CGRect) -> CGRect {
        guard shape.width > 0, shape.height > 0 else { return box }
        let scale = min(box.width / shape.width, box.height / shape.height)
        let size = CGSize(width: shape.width * scale, height: shape.height * scale)
        return CGRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height)
    }
}

/// A preset in the gallery: its diagram, name, one-line description and, for ultrawide ones,
/// the display shapes it suits. Clicking it adds the layout and applies it.
struct PresetCard: View {
    let preset: LayoutPreset
    let reference: CGSize
    let width: CGFloat
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                PresetDiagram(preset: preset, reference: reference, highlighted: hovering)
                    .frame(width: width, height: 88)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.055)))
                    .overlay(alignment: .bottomTrailing) {
                        if let aspect = preset.aspectLabel {
                            Text(verbatim: aspect)
                                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                                .foregroundStyle(Color.white.opacity(0.7))
                                .padding(.horizontal, 5).padding(.vertical, 1.5)
                                .background(Capsule().fill(Color.black.opacity(0.35)))
                                .padding(5)
                                .fixedSize()
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(hovering ? Color.accentColor : Color.white.opacity(0.1), lineWidth: hovering ? 2 : 1))
                Text(verbatim: preset.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: preset.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.58))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: width, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(Text(verbatim: preset.summary))
        .accessibilityLabel(Text(verbatim: preset.title))
        .accessibilityHint(Text(verbatim: preset.summary))
    }
}
