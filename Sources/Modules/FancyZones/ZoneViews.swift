import AppKit
import MacToysCore
import SwiftUI

/// Colors and options for drawing zones.
struct ZoneStyle: Equatable {
    var highlight: Color
    var inactive: Color
    var border: Color
    var number: Color
    /// 0…1, applied to zone fills.
    var opacity: Double
    var showNumbers: Bool

    init(_ s: FancyZonesSettings) {
        switch s.zoneColors {
        case .system:
            highlight = Color(nsColor: .controlAccentColor)
            inactive = Color(white: 0.92)
            border = .white
            number = Color(white: 0.12)
        case .custom:
            highlight = s.highlightColor.color
            inactive = s.inactiveColor.color
            border = s.borderColor.color
            number = s.numberColor.color
        }
        opacity = max(0, min(1, s.opacity / 100))
        showNumbers = s.showZoneNumber
    }
}

/// Zones drawn at their positions inside a full-screen (or full-thumbnail) area.
struct ZoneFieldView: View {
    let zones: [CGRect]
    let highlighted: Set<Int>
    let style: ZoneStyle
    var cornerRadius: CGFloat = 10

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(zones.indices, id: \.self) { i in
                zone(i, zones[i], on: highlighted.contains(i))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func zone(_ i: Int, _ r: CGRect, on: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return shape
            .fill((on ? style.highlight : style.inactive).opacity(style.opacity))
            .overlay(shape.strokeBorder(on ? style.highlight : style.border.opacity(0.85), lineWidth: on ? 3 : 1.5))
            .overlay {
                if style.showNumbers {
                    Text(verbatim: "\(i + 1)")
                        .font(.system(size: max(14, min(110, min(r.width, r.height) * 0.3)), weight: .bold, design: .rounded))
                        .foregroundStyle(on ? .white : style.number.opacity(0.75))
                }
            }
            .frame(width: max(0, r.width), height: max(0, r.height))
            .position(x: r.midX, y: r.midY)
    }
}

/// A miniature of a layout as it would look on a display of `reference` size.
struct LayoutThumbnail: View {
    let layout: ZoneLayout
    let reference: CGSize
    var selected = false
    var fill = Color.white.opacity(0.17)
    var selectedFill = Color.accentColor.opacity(0.45)
    var stroke = Color.white

    var body: some View {
        GeometryReader { geo in
            let target = CGRect(origin: .zero, size: geo.size).insetBy(dx: 4, dy: 4)
            let source = CGRect(origin: .zero, size: reference)
            let zones = ZoneGeometry.scaled(layout.zones(in: source), from: source, to: target)
            ZStack(alignment: .topLeading) {
                if zones.isEmpty {
                    Capsule().fill(stroke.opacity(0.35)).frame(width: 10, height: 2).position(x: 14, y: 12)
                }
                ForEach(zones.indices, id: \.self) { i in
                    let r = zones[i].insetBy(dx: layout.effectiveSpacing > 0 ? 1.5 : 1, dy: layout.effectiveSpacing > 0 ? 1.5 : 1)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(selected ? selectedFill : fill)
                        .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .strokeBorder(stroke.opacity(layout.kind == .focus || layout.kind == .canvas ? 0.35 : 0.08)))
                        .frame(width: max(0, r.width), height: max(0, r.height))
                        .position(x: r.midX, y: r.midY)
                }
            }
        }
    }
}

/// Buttons on the editor's dark glass: accent-filled when prominent, faint white otherwise.
/// Drawn by hand so they look the same whether or not the panel is the key window.
struct GlassButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: prominent ? .semibold : .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(prominent ? Color.accentColor : Color.white.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(.white.opacity(prominent ? 0 : 0.1)))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Rectangle())
    }
}

/// The layout name shown briefly when the layout changes while zones are visible.
struct LayoutNameBadge: View {
    let name: String
    let textColor: Color
    let background: Color
    let textSize: CGFloat
    let padding: CGFloat

    var body: some View {
        Text(verbatim: name)
            .font(.system(size: textSize, weight: .semibold))
            .foregroundStyle(textColor)
            .lineLimit(1)
            .padding(.horizontal, padding * 1.6)
            .padding(.vertical, padding)
            .background(RoundedRectangle(cornerRadius: min(24, textSize * 0.45 + padding), style: .continuous)
                .fill(background.opacity(0.92)))
            .shadow(color: .black.opacity(0.3), radius: 18, y: 6)
            .fixedSize()
    }
}
