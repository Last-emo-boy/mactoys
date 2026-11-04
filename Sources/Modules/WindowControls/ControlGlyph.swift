import MacToysCore
import SwiftUI

/// A small drawing of what a control does: a screen with the window where the control puts it
/// (two screens when it moves the window to another display). Drawn by running the control's
/// steps on a reference display, so custom controls get a true picture too.
struct ControlGlyph: View {
    enum Style { case dark, light }

    let steps: [ControlStep]
    var cycling = false
    var style: Style = .dark
    var highlighted = false

    init(_ control: WindowControl, style: Style = .dark, highlighted: Bool = false) {
        self.steps = control.chainMode == .cycle ? Array(control.steps.prefix(1)) : control.steps
        self.cycling = control.chainMode == .cycle && control.steps.count > 1
        self.style = style
        self.highlighted = highlighted
    }

    init(steps: [ControlStep], style: Style = .dark, highlighted: Bool = false) {
        self.steps = steps
        self.style = style
        self.highlighted = highlighted
    }

    // A 16:10 reference display and a second one to its right.
    private static let screenA = DisplayBox(key: "a", id: 1, name: "", frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
                                            visible: CGRect(x: 0, y: 0, width: 1600, height: 1000), isMain: true)
    private static let screenB = DisplayBox(key: "b", id: 2, name: "", frame: CGRect(x: 1600, y: 0, width: 1600, height: 1000),
                                            visible: CGRect(x: 1600, y: 0, width: 1600, height: 1000), isMain: false)
    private static let start = CGRect(x: 520, y: 330, width: 560, height: 340)

    /// The window's frame after the steps, and whether it ended up on the second display.
    static func result(of steps: [ControlStep]) -> (frame: CGRect, onSecond: Bool) {
        let ctx = PlanContext(displays: [screenA, screenB], spacing: .none)
        let f = ControlPlanner.plan(steps, frame: start, context: ctx) ?? start
        return (f, f.midX >= screenB.frame.minX)
    }

    var body: some View {
        let (frame, second) = Self.result(of: steps)
        Canvas { ctx, size in
            if second {
                let gap = size.width * 0.1
                let w = (size.width - gap) / 2
                let h = min(size.height, w * 0.625)
                let y = (size.height - h) / 2
                let left = CGRect(x: 0, y: y, width: w, height: h)
                let right = CGRect(x: w + gap, y: y, width: w, height: h)
                drawScreen(&ctx, left, dim: true)
                drawScreen(&ctx, right, dim: false)
                let local = frame.offsetBy(dx: -Self.screenB.frame.minX, dy: 0)
                drawWindow(&ctx, local, in: right)
                var arrow = Path()
                arrow.move(to: CGPoint(x: left.maxX + gap * 0.2, y: size.height / 2))
                arrow.addLine(to: CGPoint(x: right.minX - gap * 0.2, y: size.height / 2))
                ctx.stroke(arrow, with: .color(windowColor), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
            } else {
                let h = min(size.height, size.width * 0.625)
                let w = h / 0.625
                let screen = CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
                drawScreen(&ctx, screen, dim: false)
                drawWindow(&ctx, frame, in: screen)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if cycling {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 7, weight: .heavy))
                    .foregroundStyle(style == .dark ? Color.black.opacity(0.8) : .white)
                    .padding(1.5)
                    .background(Circle().fill(windowColor))
                    .offset(x: 3, y: 3)
            }
        }
        .accessibilityHidden(true)
    }

    private var screenStroke: Color { style == .dark ? .white.opacity(0.42) : .primary.opacity(0.32) }
    private var screenFill: Color { style == .dark ? .white.opacity(0.06) : .primary.opacity(0.04) }
    private var windowColor: Color {
        highlighted ? .accentColor : (style == .dark ? .white.opacity(0.88) : .primary.opacity(0.62))
    }

    private func drawScreen(_ ctx: inout GraphicsContext, _ r: CGRect, dim: Bool) {
        let shape = Path(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerRadius: max(1.5, r.height * 0.1), style: .continuous)
        ctx.fill(shape, with: .color(screenFill))
        ctx.stroke(shape, with: .color(dim ? screenStroke.opacity(0.55) : screenStroke), lineWidth: 1)
    }

    /// `frame` is in reference-display points; `screen` is where that display is drawn.
    private func drawWindow(_ ctx: inout GraphicsContext, _ frame: CGRect, in screen: CGRect) {
        let ref = Self.screenA.frame
        let sx = screen.width / ref.width, sy = screen.height / ref.height
        let inset: CGFloat = max(1.5, screen.height * 0.08)
        var r = CGRect(x: screen.minX + frame.minX * sx, y: screen.minY + frame.minY * sy,
                       width: frame.width * sx, height: frame.height * sy)
        r = r.insetBy(dx: min(inset, r.width / 4), dy: min(inset, r.height / 4))
        ctx.fill(Path(roundedRect: r, cornerRadius: max(1, min(r.width, r.height) * 0.12), style: .continuous),
                 with: .color(windowColor))
    }
}
