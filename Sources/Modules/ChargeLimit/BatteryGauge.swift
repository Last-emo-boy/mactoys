import MacToysCore
import SwiftUI

/// A battery drawn in SwiftUI: the current level, the range Charge Limit keeps it in (hatched) and the
/// limit marker with its label.
struct BatteryGauge: View {
    /// 0–100.
    var level: Int
    /// Lower bound and limit; nil hides the range.
    var range: ClosedRange<Int>?
    var fill: Color
    var bolt = false
    /// Show the percent labels above the range.
    var labels = true
    /// Show the level inside the battery (small sizes).
    var levelInside = false

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        GeometryReader { geo in
            let labelRow: CGFloat = labels && range != nil ? 22 : 0
            let bodyH = max(10, geo.size.height - labelRow)
            let nubW = max(3, bodyH * 0.075)
            let gap = max(1.5, bodyH * 0.035)
            let bodyW = geo.size.width - nubW - gap
            let line = max(1.5, bodyH * 0.03)
            let radius = bodyH * 0.24
            let inset = line + max(2, bodyH * 0.05)
            let innerW = bodyW - inset * 2
            let innerH = bodyH - inset * 2
            let innerRadius = max(2, radius - inset)
            let x = { (p: Int) in inset + innerW * CGFloat(min(max(p, 0), 100)) / 100 }

            ZStack(alignment: .topLeading) {
                if let range, labels {
                    limitLabels(range, x: x, width: bodyW)
                        .frame(width: bodyW, height: labelRow, alignment: .topLeading)
                }
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(Color.primary.opacity(0.045))
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(contrast == .increased ? 0.6 : 0.24), lineWidth: line)
                    // Level.
                    RoundedRectangle(cornerRadius: innerRadius, style: .continuous)
                        .fill(LinearGradient(colors: [fill.mix(with: .white, by: 0.28), fill], startPoint: .top, endPoint: .bottom))
                        .frame(width: innerW, height: innerH)
                        .mask(alignment: .leading) {
                            Rectangle().frame(width: innerW * CGFloat(min(max(level, 0), 100)) / 100)
                        }
                        .offset(x: inset, y: inset)
                    if let range {
                        band(range, x: x, inset: inset, innerH: innerH, innerW: innerW, innerRadius: innerRadius)
                    }
                    if bolt {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: innerH * 0.5, weight: .bold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                            .frame(width: max(innerH, x(level) - inset), height: innerH)
                            .offset(x: inset, y: inset)
                    }
                    if levelInside {
                        Text(verbatim: ChargeText.percent(level))
                            .font(.system(size: innerH * 0.55, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(Color.primary.opacity(0.85))
                            .frame(width: bodyW, height: bodyH)
                    }
                }
                .frame(width: bodyW, height: bodyH)
                .offset(y: labelRow)
                // Terminal.
                UnevenRoundedRectangle(cornerRadii: .init(topLeading: 0, bottomLeading: 0, bottomTrailing: nubW, topTrailing: nubW),
                                       style: .continuous)
                    .fill(Color.primary.opacity(contrast == .increased ? 0.6 : 0.24))
                    .frame(width: nubW, height: bodyH * 0.36)
                    .offset(x: bodyW + gap, y: labelRow + bodyH * 0.32)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Battery"))
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: Text {
        if let range {
            Text("\(ChargeText.percent(level)), kept between \(ChargeText.percent(range.lowerBound)) and \(ChargeText.percent(range.upperBound))",
                 comment: "Battery gauge accessibility value; placeholders are percentages")
        } else {
            Text(verbatim: ChargeText.percent(level))
        }
    }

    /// The hatched range and the limit line, clipped to the well.
    private func band(_ range: ClosedRange<Int>, x: (Int) -> CGFloat, inset: CGFloat, innerH: CGFloat, innerW: CGFloat,
                      innerRadius: CGFloat) -> some View {
        let lo = x(range.lowerBound), hi = x(range.upperBound)
        return ZStack(alignment: .topLeading) {
            Canvas { ctx, size in
                let rect = CGRect(x: lo - inset, y: 0, width: max(0, hi - lo), height: size.height)
                ctx.clip(to: Path(rect))
                ctx.fill(Path(rect), with: .color(Color.primary.opacity(0.08)))
                var stripes = Path()
                let step: CGFloat = 6
                var sx = rect.minX - size.height
                while sx < rect.maxX {
                    stripes.move(to: CGPoint(x: sx, y: size.height))
                    stripes.addLine(to: CGPoint(x: sx + size.height, y: 0))
                    sx += step
                }
                ctx.stroke(stripes, with: .color(Color.primary.opacity(0.2)), lineWidth: 1.4)
                // Lower bound: dashed; limit: solid.
                var lower = Path()
                lower.move(to: CGPoint(x: rect.minX, y: 0))
                lower.addLine(to: CGPoint(x: rect.minX, y: size.height))
                if range.lowerBound < range.upperBound {
                    ctx.stroke(lower, with: .color(Color.primary.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .frame(width: innerW, height: innerH)
            .clipShape(RoundedRectangle(cornerRadius: innerRadius, style: .continuous))
            .offset(x: inset, y: inset)
            Capsule()
                .fill(Color.primary.opacity(0.75))
                .frame(width: 2.5, height: innerH + inset * 1.4)
                .offset(x: hi - 1.25, y: inset * 0.3)
        }
    }

    /// "75 %" ahead of the range, "80 %" in a capsule over the limit line.
    private func limitLabels(_ range: ClosedRange<Int>, x: @escaping (Int) -> CGFloat, width: CGFloat) -> some View {
        let hi = min(max(x(range.upperBound), 20), width - 4)
        return ZStack {
            Text(verbatim: ChargeText.percent(range.upperBound))
                .font(.system(size: 11, weight: .bold).monospacedDigit())
                .foregroundStyle(Color(nsColor: .textBackgroundColor))
                .padding(.horizontal, 6)
                .padding(.vertical, 1.5)
                .background(Capsule().fill(Color.primary.opacity(0.8)))
                .fixedSize()
                .position(x: hi, y: 8)
            if range.lowerBound < range.upperBound {
                // Just ahead of the limit's capsule when the range is narrow.
                let trailing = min(x(range.lowerBound) - 3, hi - 24)
                Text(verbatim: ChargeText.percent(range.lowerBound))
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .frame(width: 64, alignment: .trailing)
                    .position(x: trailing - 32, y: 8)
            }
        }
    }
}
