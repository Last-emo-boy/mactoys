import AppKit
import MacToysCore
import SwiftUI

/// The rules of a keyboard-cleaning session: how long it lasts and the esc-three-times escape.
struct CleanKeyboardSession: Equatable, Sendable {
    let start: Date
    let duration: TimeInterval
    /// Presses of esc that count toward stopping early.
    private(set) var escapes: [Date] = []

    static let escapesToStop = 3
    /// The three presses must come within this many seconds.
    static let escapeWindow: TimeInterval = 2

    init(start: Date, duration: TimeInterval) {
        self.start = start
        self.duration = max(1, duration)
    }

    var end: Date { start.addingTimeInterval(duration) }

    /// Whole seconds left, rounded up (shows 30 at the start, 1 in the last second, 0 when over).
    func secondsLeft(at now: Date) -> Int {
        max(0, Int((end.timeIntervalSince(now)).rounded(.up)))
    }

    /// 0 at the start … 1 when over.
    func progress(at now: Date) -> Double {
        min(1, max(0, now.timeIntervalSince(start) / duration))
    }

    func isOver(at now: Date) -> Bool { now >= end }

    /// Counts an esc press; true when that makes three in a row within the window.
    mutating func registerEscape(at now: Date) -> Bool {
        escapes = escapes.filter { now.timeIntervalSince($0) <= Self.escapeWindow }
        escapes.append(now)
        return escapes.count >= Self.escapesToStop
    }

    /// Another key between esc presses starts the count again.
    mutating func registerOtherKey() { escapes.removeAll() }

    var escapeCount: Int { escapes.count }

    /// "0:27".
    static func clock(_ seconds: Int, locale: Locale = .current) -> String {
        Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond).locale(locale))
    }
}

/// Runs a session: swallows every key (and media key) through the shared event tap and shows the
/// countdown on every screen.
@MainActor
final class CleanKeyboardController {
    @Observable
    final class State {
        var session: CleanKeyboardSession
        var now: Date
        init(session: CleanKeyboardSession) { self.session = session; self.now = session.start }
    }

    private static let tapID = "switches.cleankeyboard"
    private var state: State?
    private var panels: [OverlayPanel] = []
    private var timer: Timer?
    var isRunning: Bool { state != nil }
    var onFinish: (() -> Void)?

    func start(seconds: Int) {
        guard state == nil else { return }
        guard AXIsProcessTrusted() else {
            HUD.show("Accessibility permission needed", symbol: "exclamationmark.shield")
            PermissionCenter.shared.request(.accessibility)
            return
        }
        let s = State(session: CleanKeyboardSession(start: Date(), duration: TimeInterval(seconds)))
        state = s
        InputTap.shared.add(Self.tapID, priority: 1000, events: [.keyDown, .keyUp, .flagsChanged, InputTap.systemDefined],
                            includeSynthetic: true) { [weak self] type, event in
            if type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == 53 {
                if event.getIntegerValueField(.keyboardEventAutorepeat) == 0, self?.state?.session.registerEscape(at: Date()) == true {
                    DispatchQueue.main.async { self?.stop() }
                }
            } else if type == .keyDown {
                self?.state?.session.registerOtherKey()
            }
            return .consume
        }
        for screen in NSScreen.screens {
            let panel = OverlayPanel(frame: screen.frame, interactive: true, level: .screenSaver)
            panel.setContent(CleanKeyboardOverlay(state: s))
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                panel.animator().alphaValue = 1
            }
            panels.append(panel)
        }
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let state = self.state else { return }
                state.now = Date()
                if state.session.isOver(at: state.now) { self.stop() }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        guard state != nil else { return }
        InputTap.shared.remove(Self.tapID)
        timer?.invalidate()
        timer = nil
        state = nil
        for p in panels {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.2
                p.animator().alphaValue = 0
            }, completionHandler: { p.orderOut(nil) })
        }
        panels.removeAll()
        HUD.show("Keyboard unlocked", symbol: "keyboard")
        onFinish?()
    }
}

/// The countdown: a ring around the seconds left, on a dimmed screen that also swallows clicks.
struct CleanKeyboardOverlay: View {
    let state: CleanKeyboardController.State
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let left = state.session.secondsLeft(at: state.now)
        let progress = state.session.progress(at: state.now)
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            GlassPanel(cornerRadius: 34) {
                VStack(spacing: 18) {
                    ZStack {
                        Circle().stroke(.white.opacity(0.12), lineWidth: 10)
                        Circle()
                            .trim(from: 0, to: 1 - progress)
                            .stroke(Tint.mint.color, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(reduceMotion ? nil : .linear(duration: 0.25), value: progress)
                        VStack(spacing: 2) {
                            Text(verbatim: CleanKeyboardSession.clock(left))
                                .font(.system(size: 54, weight: .bold, design: .rounded).monospacedDigit())
                                .contentTransition(.numericText(countsDown: true))
                            Image(systemName: "keyboard").font(.system(size: 20, weight: .medium)).foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 190, height: 190)
                    VStack(spacing: 6) {
                        Text("Keyboard locked for cleaning").font(.system(size: 19, weight: .semibold))
                        Text("Wipe away. Keys, media keys and clicks on this screen do nothing until the time is up.")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 8) {
                        Text("To stop early, press").foregroundStyle(.secondary)
                        HStack(spacing: 4) {
                            ForEach(0..<CleanKeyboardSession.escapesToStop, id: \.self) { i in
                                Keycaps(["esc"], dark: true)
                                    .opacity(i < state.session.escapeCount ? 0.35 : 1)
                            }
                        }
                    }
                    .font(.system(size: 12.5))
                }
                .padding(.horizontal, 40)
                .padding(.vertical, 34)
                .frame(width: 440)
                .foregroundStyle(.white)
            }
        }
    }
}
