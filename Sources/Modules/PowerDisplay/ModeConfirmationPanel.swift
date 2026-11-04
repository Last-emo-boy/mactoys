import AppKit
import MacToysCore
import SwiftUI

/// What the "Keep this resolution?" prompt shows.
struct ModeConfirmationInfo: Equatable {
    var displayID: CGDirectDisplayID
    var displayName: String
    /// "2560 × 1440 · HiDPI · 60 Hz".
    var modeTitle: String
    var deadline: Date
}

/// The prompt: a countdown ring, the new mode, Revert (Esc) and Keep (Return).
struct ModeConfirmationView: View {
    let info: ModeConfirmationInfo
    var duration: TimeInterval = ModeConfirmation.duration
    /// Fixed time for snapshots; nil follows the clock.
    var frozenNow: Date?
    let keep: () -> Void
    let revert: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GlassPanel(cornerRadius: 24) {
            TimelineView(.periodic(from: .now, by: reduceMotion ? 1 : 0.1)) { context in
                content(now: frozenNow ?? context.date)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 20)
            .foregroundStyle(.white)
            // Darker than other glass: this prompt has to be read over whatever the new mode shows.
            .background(Color.black.opacity(0.45))
        }
        .frame(width: 360)
    }

    private func content(now: Date) -> some View {
        let left = max(0, info.deadline.timeIntervalSince(now))
        let seconds = Int(left.rounded(.up))
        return VStack(spacing: 14) {
            ZStack {
                Circle().stroke(.white.opacity(0.14), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: max(0, min(1, left / duration)))
                    .stroke(Tint.yellow.color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(seconds, format: .number)
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
            }
            .frame(width: 64, height: 64)
            VStack(spacing: 5) {
                Text("Keep this resolution?").font(.system(size: 17, weight: .bold))
                Text(verbatim: "\(info.displayName) · \(info.modeTitle)")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                Text("Switching back in \(seconds) seconds unless you keep it.",
                     comment: "Resolution confirmation countdown; the placeholder is a number of seconds")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button(action: revert) {
                    Text("Revert", comment: "Button: go back to the previous resolution")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(GlassCapsuleButtonStyle(prominent: false))
                .keyboardShortcut(.cancelAction)
                Button(action: keep) {
                    Text("Keep", comment: "Button: keep the new resolution").frame(maxWidth: .infinity)
                }
                .buttonStyle(GlassCapsuleButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
    }
}

/// Capsule buttons for dark glass panels: a quiet one and an accent one.
struct GlassCapsuleButtonStyle: ButtonStyle {
    var prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.vertical, 8)
            .padding(.horizontal, 14)
            .background(Capsule().fill(prominent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.white.opacity(0.12))))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule())
    }
}

/// Shows the prompt on the changed display and, when that isn't the main display, on the main
/// display too (in case the changed one shows nothing).
@MainActor
final class ModeConfirmationPresenter {
    private var panels: [(CGDirectDisplayID, OverlayPanel)] = []
    private var info: ModeConfirmationInfo?
    private var keep: (() -> Void)?
    private var revert: (() -> Void)?
    private var showWork: DispatchWorkItem?

    var isShowing: Bool { info != nil }

    func show(_ info: ModeConfirmationInfo, keep: @escaping () -> Void, revert: @escaping () -> Void) {
        dismiss()
        self.info = info
        self.keep = keep
        self.revert = revert
        // Give the window server a moment to settle the new screen frames.
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.layout() } }
        showWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    /// Places the prompt; after screens changed, moves it only if its screens moved.
    func layout() {
        guard let info else { return }
        var targets = [info.displayID]
        let main = CGMainDisplayID()
        if main != info.displayID { targets.append(main) }
        let size = CGSize(width: 360, height: 280)
        let frames: [(CGDirectDisplayID, CGRect)] = targets.compactMap { id in
            guard let screen = NSScreen.screens.first(where: { $0.displayID == id }) else { return nil }
            return (id, CGRect(x: (screen.frame.midX - size.width / 2).rounded(), y: (screen.frame.midY - size.height / 2).rounded(),
                               width: size.width, height: size.height))
        }
        if !panels.isEmpty && frames.map(\.0) == panels.map(\.0) && zip(frames, panels).allSatisfy({ $0.1 == $1.1.frame }) { return }
        for (_, p) in panels { p.orderOut(nil) }
        panels.removeAll()
        for (id, frame) in frames {
            let panel = OverlayPanel(frame: frame, interactive: true, acceptsKey: true, level: .modalPanel)
            panel.setContent(ModeConfirmationView(info: info, keep: { [weak self] in self?.keep?() },
                                                  revert: { [weak self] in self?.revert?() })
                .frame(maxWidth: .infinity, maxHeight: .infinity))
            panel.alphaValue = 0
            panels.append((id, panel))
        }
        for (i, (_, panel)) in panels.enumerated() {
            if i == 0 { panel.present() } else { panel.orderFrontRegardless() }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
                panel.animator().alphaValue = 1
            }
        }
    }

    func dismiss() {
        showWork?.cancel()
        showWork = nil
        for (_, p) in panels { p.orderOut(nil) }
        panels.removeAll()
        info = nil
        keep = nil
        revert = nil
    }
}
