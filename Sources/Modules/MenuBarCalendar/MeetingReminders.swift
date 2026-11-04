import AppKit
import MacToysCore
import SwiftUI

/// Shows meeting reminders: glass banners at the top right, or one large card for the next meeting.
@MainActor
final class ReminderPresenter {
    private struct Shown {
        let event: AgendaEvent
        let panel: NSPanel
    }

    private var banners: [Shown] = []
    private var fullScreen: (event: AgendaEvent, panel: ReminderOverlayPanel)?
    private var expiry: Timer?
    var onJoin: ((AgendaEvent) -> Void)?

    static let bannerSize = CGSize(width: 380, height: 112)

    var isShowingAny: Bool { !banners.isEmpty || fullScreen != nil }

    func show(_ event: AgendaEvent, style: ReminderStyle, sound: Bool) {
        guard !banners.contains(where: { $0.event.id == event.id }), fullScreen?.event.id != event.id else { return }
        if sound { NSSound(named: "Glass")?.play() }
        switch style {
        case .banner: showBanner(event)
        case .fullScreen: showFullScreen(event)
        }
        scheduleExpiry()
    }

    func dismissAll() {
        for b in banners { b.panel.orderOut(nil) }
        banners.removeAll()
        fullScreen?.panel.orderOut(nil)
        fullScreen = nil
        expiry?.invalidate()
        expiry = nil
    }

    func dismiss(_ id: String) {
        if let i = banners.firstIndex(where: { $0.event.id == id }) {
            let panel = banners[i].panel
            banners.remove(at: i)
            fade(panel)
            layoutBanners()
        }
        if fullScreen?.event.id == id {
            fade(fullScreen!.panel)
            fullScreen = nil
        }
        if !isShowingAny { expiry?.invalidate(); expiry = nil }
    }

    // MARK: Banner

    private func showBanner(_ event: AgendaEvent) {
        let panel = OverlayPanel(frame: CGRect(origin: .zero, size: Self.bannerSize), interactive: true, level: .statusBar)
        panel.collectionBehavior.insert(.ignoresCycle)
        panel.hasShadow = false
        panel.setContent(MeetingBanner(event: event, now: nil,
                                       join: { [weak self] in self?.join(event) },
                                       dismiss: { [weak self] in self?.dismiss(event.id) }))
        banners.append(Shown(event: event, panel: panel))
        if banners.count > 3 {
            let oldest = banners.removeFirst()
            oldest.panel.orderOut(nil)
        }
        layoutBanners()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.1 : 0.25
            panel.animator().alphaValue = 1
        }
    }

    /// Newest on top, under the menu bar at the right of the main screen.
    private func layoutBanners() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let vf = screen.visibleFrame
        var top = vf.maxY - 8
        for shown in banners.reversed() {
            let frame = CGRect(x: vf.maxX - Self.bannerSize.width - 10, y: top - Self.bannerSize.height,
                               width: Self.bannerSize.width, height: Self.bannerSize.height)
            shown.panel.setFrame(frame, display: true)
            top -= Self.bannerSize.height - 8
        }
    }

    // MARK: Full screen

    private func showFullScreen(_ event: AgendaEvent) {
        fullScreen?.panel.orderOut(nil)
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let panel = ReminderOverlayPanel(frame: screen.frame)
        panel.onEscape = { [weak self] in self?.dismiss(event.id) }
        panel.onReturn = { [weak self] in
            if event.videoLink != nil { self?.join(event) } else { self?.dismiss(event.id) }
        }
        panel.setContent(MeetingFullScreen(event: event, now: nil,
                                           join: { [weak self] in self?.join(event) },
                                           dismiss: { [weak self] in self?.dismiss(event.id) }))
        fullScreen = (event, panel)
        panel.alphaValue = 0
        panel.present()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.1 : 0.3
            panel.animator().alphaValue = 1
        }
    }

    private func join(_ event: AgendaEvent) {
        onJoin?(event)
        dismiss(event.id)
    }

    private func fade(_ panel: NSPanel) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.orderOut(nil) })
    }

    /// Reminders go away by themselves ten minutes after the meeting started (or when it ends).
    private func scheduleExpiry() {
        guard expiry == nil else { return }
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = Date()
                let stale = (self.banners.map(\.event) + [self.fullScreen?.event].compactMap { $0 })
                    .filter { now > min($0.end, $0.start.addingTimeInterval(600)) }
                for e in stale { self.dismiss(e.id) }
            }
        }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        expiry = t
    }
}

/// Covers the screen; takes the keyboard for Return (join) and Esc (dismiss).
final class ReminderOverlayPanel: OverlayPanel {
    var onEscape: (() -> Void)?
    var onReturn: (() -> Void)?

    init(frame: CGRect) {
        super.init(frame: frame, interactive: true, acceptsKey: true, level: .modalPanel)
    }

    override func cancelOperation(_ sender: Any?) { onEscape?() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { onReturn?() } else { super.keyDown(with: event) }
    }
}

/// The banner: calendar color, "Starts in 2 min", title, time and service, Join and Dismiss.
struct MeetingBanner: View {
    let event: AgendaEvent
    /// Fixed for previews; nil follows the clock.
    let now: Date?
    let join: () -> Void
    let dismiss: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let current = now ?? context.date
            GlassPanel(cornerRadius: 20) {
                HStack(alignment: .center, spacing: 12) {
                    ZStack {
                        Circle().fill(event.color.color.opacity(0.25))
                        Image(systemName: event.videoLink != nil ? "video.fill" : "calendar")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(event.color.color)
                    }
                    .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: event.relativeStart(now: current).capitalizedFirst)
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(event.color.color)
                        Text(verbatim: event.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        Text(verbatim: subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    VStack(spacing: 6) {
                        if event.videoLink != nil {
                            Button(action: join) {
                                Text("Join", comment: "Button: join the video call")
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .frame(minWidth: 62)
                                    .frame(height: 28)
                                    .background(Capsule().fill(Tint.green.color))
                                    .foregroundStyle(.white)
                            }
                            .buttonStyle(.plain)
                        }
                        Button(action: dismiss) {
                            Text("Dismiss", comment: "Button: close the meeting reminder")
                                .font(.system(size: 12, weight: .medium))
                                .frame(minWidth: 62)
                                .frame(height: 26)
                                .background(Capsule().fill(.white.opacity(0.12)))
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .foregroundStyle(.white)
            }
            .padding(6)
        }
    }

    private var subtitle: String {
        let time = event.timeText(on: event.start, calendar: .current)
        if let service = event.videoLink?.service.name { return "\(time) · \(service)" }
        if let location = event.location, !location.isEmpty { return "\(time) · \(location)" }
        return time
    }
}

/// The full-screen reminder: a dimmed desktop with one big card.
struct MeetingFullScreen: View {
    let event: AgendaEvent
    let now: Date?
    let join: () -> Void
    let dismiss: () -> Void
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let current = now ?? context.date
            ZStack {
                Color.black.opacity(0.5).ignoresSafeArea()
                GlassPanel(cornerRadius: 28) {
                    VStack(spacing: 14) {
                        HStack(spacing: 6) {
                            Circle().fill(event.color.color).frame(width: 8, height: 8)
                            Text(verbatim: event.calendarTitle).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                        }
                        Text(verbatim: event.title)
                            .font(.system(size: 28, weight: .bold))
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(verbatim: event.relativeStart(now: current).capitalizedFirst)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(event.color.color)
                        Text(verbatim: details).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        HStack(spacing: 10) {
                            Button(action: dismiss) {
                                Text("Dismiss", comment: "Button: close the meeting reminder")
                                    .font(.system(size: 14, weight: .semibold))
                                    .frame(minWidth: 120).frame(height: 40)
                                    .background(Capsule().fill(.white.opacity(0.14)))
                            }
                            .buttonStyle(.plain)
                            if let link = event.videoLink {
                                Button(action: join) {
                                    Label {
                                        Text("Join with \(link.service.name)", comment: "Button; the placeholder is a video call service like Zoom")
                                    } icon: {
                                        Image(systemName: "video.fill")
                                    }
                                    .font(.system(size: 14, weight: .semibold))
                                    .padding(.horizontal, 18)
                                    .frame(minWidth: 160).frame(height: 40)
                                    .background(Capsule().fill(Tint.green.color))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.top, 6)
                        .foregroundStyle(.white)
                        HStack(spacing: 14) {
                            if event.videoLink != nil {
                                HStack(spacing: 4) { Keycaps(["↩"], dark: true); Text("Join") }
                            }
                            HStack(spacing: 4) { Keycaps(["esc"], dark: true); Text("Dismiss", comment: "Keyboard hint: Esc closes the reminder") }
                        }
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 36)
                    .padding(.vertical, 30)
                    .frame(width: 520)
                    .foregroundStyle(.white)
                }
                .scaleEffect(appeared || reduceMotion ? 1 : 0.94)
                .opacity(appeared ? 1 : 0)
            }
        }
        .onAppear { withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .smooth(duration: 0.3)) { appeared = true } }
    }

    private var details: String {
        var parts = [event.timeText(on: event.start, calendar: .current)]
        if let location = event.location, !location.isEmpty, event.videoLink?.url.absoluteString != location { parts.append(location) }
        if event.attendees > 1 {
            parts.append(String(localized: "\(event.attendees) people", comment: "Number of people invited to a meeting"))
        }
        return parts.joined(separator: " · ")
    }
}

extension String {
    /// "in 5 min" → "In 5 min" (sentence start), in a locale-safe way.
    var capitalizedFirst: String {
        guard let first else { return self }
        return String(first).uppercased(with: .current) + dropFirst()
    }
}
