import AppKit
import SwiftUI

/// A transient glass pill near the bottom of the screen: "Always On Top · on".
@MainActor
public enum HUD {
    private static var panel: OverlayPanel?
    private static var hideWork: DispatchWorkItem?

    /// Localized message (string literals are extracted into the catalog).
    public static func show(_ text: String.LocalizationValue, symbol: String? = nil, duration: TimeInterval = 1.4) {
        show(String(localized: text) as String, symbol: symbol, duration: duration)
    }

    /// A message that is already localized or is runtime data.
    @_disfavoredOverload
    public static func show<S: StringProtocol>(_ message: S, symbol: String? = nil, duration: TimeInterval = 1.4) {
        let text = String(message)
        let screen = NSScreen.underMouse ?? NSScreen.main!
        let size = CGSize(width: 520, height: 80)
        let frame = CGRect(x: screen.frame.midX - size.width / 2, y: screen.frame.minY + 120,
                           width: size.width, height: size.height)
        let p = panel ?? OverlayPanel(frame: frame, level: .statusBar)
        p.setFrame(frame, display: false)
        p.setContent(HUDView(text: text, symbol: symbol))
        p.alphaValue = 1
        p.orderFrontRegardless()
        panel = p
        hideWork?.cancel()
        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                p.animator().alphaValue = 0
            }, completionHandler: { p.orderOut(nil) })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }
}

struct HUDView: View {
    let text: String
    let symbol: String?

    var body: some View {
        HStack(spacing: 10) {
            if let symbol { Image(systemName: symbol).font(.system(size: 15, weight: .semibold)) }
            Text(verbatim: text).font(.system(size: 14, weight: .semibold))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .glassEffect(.regular, in: .capsule)
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
