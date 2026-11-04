import AppKit
import MacToysCore
import Observation
import SwiftUI

/// Live numbers for the arrangement card.
@MainActor
@Observable
final class ArrangeModel {
    var hiddenCount = 0
    var alwaysHiddenCount = 0
    var alwaysHiddenSection = false
    var chevronStyle: ChevronStyle = .chevron
    var problem: OrderProblem?

    @ObservationIgnored var onDone: () -> Void = {}
}

/// The arrangement card: a glass card under the chevron explaining ⌘-drag, shown the first time the
/// module is turned on and from the settings page. While it's open, both sections are shown and the
/// dividers are drawn in the accent color.
@MainActor
final class OnboardingController {
    let model = ArrangeModel()
    private var panel: OverlayPanel?

    var isVisible: Bool { panel?.isVisible == true }
    var windowID: CGWindowID? { panel.map { CGWindowID($0.windowNumber) } }

    func contains(_ p: CGPoint) -> Bool {
        guard let panel, panel.isVisible else { return false }
        return panel.frame.insetBy(dx: -10, dy: -10).contains(p)
    }

    func show(on screen: NSScreen, menuBarHeight: CGFloat, anchor: CGRect?) {
        let p = panel ?? makePanel()
        let size = p.contentView?.fittingSize ?? CGSize(width: 360, height: 300)
        let vf = screen.frame
        let anchorX = anchor?.midX ?? vf.maxX - 120
        let x = min(max(vf.minX + 8, anchorX - size.width + 36), vf.maxX - size.width - 8)
        let frame = CGRect(x: x, y: vf.maxY - menuBarHeight - 4 - size.height, width: size.width, height: size.height)
        p.setFrame(frame, display: true)
        if let host = p.contentView as? FirstMouseHostingView<ArrangeCard> {
            host.rootView = ArrangeCard(model: model, caretX: anchorX - frame.minX)
        }
        guard !p.isVisible else { return }
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            p.animator().alphaValue = 1
        }
    }

    func hide() {
        guard let p = panel, p.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            p.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { if p.alphaValue < 0.01 { p.orderOut(nil) } }
        })
    }

    func tearDown() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }

    private func makePanel() -> OverlayPanel {
        let p = OverlayPanel(frame: CGRect(x: 0, y: 0, width: 360, height: 300), interactive: true, acceptsKey: false, level: .statusBar)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = FirstMouseHostingView(rootView: ArrangeCard(model: model, caretX: nil))
        host.sizingOptions = []
        p.contentView = host
        panel = p
        return p
    }
}

/// "Arrange your menu bar": a miniature of the drag, the steps, live counts and Done.
struct ArrangeCard: View {
    let model: ArrangeModel
    /// Where the caret points, from the card's left edge; nil for no caret.
    var caretX: CGFloat?

    static let width: CGFloat = 364

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ModuleIcon(symbol: "menubar.rectangle", tint: .cyan, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Arrange your menu bar").font(.system(size: 15, weight: .bold))
                    Text("Nothing is hidden until you move icons.").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.6))
                }
                Spacer(minLength: 0)
            }
            ArrangeIllustration(alwaysHidden: model.alwaysHiddenSection, chevron: model.chevronStyle)
                .frame(height: 64)
            VStack(alignment: .leading, spacing: 9) {
                StepRow(number: 1, text: Text("Hold \(Text(verbatim: "⌘").fontWeight(.bold)) and drag icons to the left of the \(Text(verbatim: "|").fontWeight(.bold)) divider to hide them.",
                                              comment: "Arrangement card step; the values are the Command key symbol and the divider glyph"))
                if model.alwaysHiddenSection {
                    StepRow(number: 2, text: Text("Drag icons past the \(Text(verbatim: "‖").fontWeight(.bold)) divider to keep them always hidden. \(Text(verbatim: "⌥"))-click the chevron to see those too.",
                                                  comment: "Arrangement card step; the values are the double divider glyph and the Option key symbol"))
                }
                StepRow(number: model.alwaysHiddenSection ? 3 : 2,
                        text: Text("Click the chevron to show or hide them, or turn on hover in Settings.", comment: "Arrangement card step"))
            }
            status
            HStack {
                Spacer()
                Button { model.onDone() } label: {
                    Text("Done", comment: "Arrangement card: finish arranging and hide the icons").frame(minWidth: 52)
                }
                .buttonStyle(GlassProminentButtonStyle())
            }
        }
        .padding(18)
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .barSurface(cornerRadius: 20)
        .overlay(alignment: .topLeading) {
            if let caretX {
                Caret().fill(.white.opacity(0.16)).frame(width: 18, height: 8)
                    .offset(x: min(max(caretX - 9, 18), Self.width - 36), y: -7)
            }
        }
        .padding(.top, 8)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var status: some View {
        if let problem = model.problem {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                (problem == .chevronLeftOfDivider
                     ? Text("The chevron must stay to the right of the divider, or hiding would hide it too. Drag it back with ⌘.")
                     : Text("The ‖ divider must stay to the left of the | divider. Drag it back with ⌘."))
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.yellow.opacity(0.14)))
        } else {
            HStack(spacing: 14) {
                CountChip(count: model.hiddenCount, label: Text("hidden", comment: "Arrangement card counter label, after a number"), symbol: "eye.slash")
                if model.alwaysHiddenSection {
                    CountChip(count: model.alwaysHiddenCount, label: Text("always hidden", comment: "Arrangement card counter label, after a number"),
                              symbol: "eye.slash.fill")
                }
            }
        }
    }
}

private struct StepRow: View {
    let number: Int
    let text: Text

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(number, format: .number)
                .font(.system(size: 11, weight: .bold).monospacedDigit())
                .frame(width: 19, height: 19)
                .background(Circle().fill(Tint.cyan.color.opacity(0.9)))
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            text.font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.88))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct CountChip: View {
    let count: Int
    let label: Text
    let symbol: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
            Text(count, format: .number).font(.system(size: 13, weight: .bold).monospacedDigit())
                .contentTransition(.numericText())
            label.font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
        }
    }
}

private struct Caret: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// A short stretch of menu bar: an icon being ⌘-dragged from the shown side across the divider.
struct ArrangeIllustration: View {
    let alwaysHidden: Bool
    let chevron: ChevronStyle

    var body: some View {
        ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.07))
                RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.08))
                HStack(spacing: 13) {
                    if alwaysHidden {
                        mini("key.horizontal.fill", faded: true)
                        divider(double: true)
                    }
                    mini("shippingbox.fill", faded: true)
                    mini("music.note", faded: true)
                    DropSlot()
                        .overlay(alignment: .topLeading) {
                            // The dragged icon, lifted, on its way into the gap with ⌘ held.
                            HStack(spacing: 5) {
                                Image(systemName: "arrow.left").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.75))
                                Image(systemName: "cloud.fill")
                                    .font(.system(size: 12, weight: .medium))
                                    .frame(width: 28, height: 22)
                                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Tint.cyan.color))
                                    .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                                Keycaps(["⌘"], dark: true).scaleEffect(0.8)
                            }
                            .fixedSize()
                            .offset(x: 16, y: 16)
                        }
                    divider(double: false)
                    Image(systemName: chevron.symbol(collapsed: false)).font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.9))
                    mini("cup.and.saucer.fill", faded: false)
                    mini("wifi", faded: false)
                    mini("battery.75percent", faded: false)
                    Text(verbatim: MockSamples.time).font(.system(size: 12, weight: .medium).monospacedDigit())
                }
                .padding(.horizontal, 14)
                .offset(y: -8)
        }
        .accessibilityHidden(true)
    }

    private func mini(_ symbol: String, faded: Bool) -> some View {
        Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(faded ? 0.45 : 0.9))
    }

    private func divider(double: Bool) -> some View {
        HStack(spacing: 2.5) {
            Capsule().frame(width: 1.8, height: 15)
            if double { Capsule().frame(width: 1.8, height: 15) }
        }
        .foregroundStyle(Color.accentColor)
    }
}

/// The gap the dragged icon is about to drop into.
private struct DropSlot: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .strokeBorder(.white.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            .frame(width: 18, height: 16)
    }
}
