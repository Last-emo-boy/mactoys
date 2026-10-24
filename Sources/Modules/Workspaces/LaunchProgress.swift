import AppKit
import MacToysCore
import SwiftUI
import UniformTypeIdentifiers

/// Small floating status window while a workspace launches. It never takes focus from the apps
/// being launched; it closes itself when everything is in place (if set) or with Done/Cancel.
@MainActor
final class LaunchProgressPanel {
    private var panel: NSPanel?
    private var closeWork: DispatchWorkItem?

    func show(_ session: LaunchSession, onDismiss: @escaping () -> Void) {
        closeWork?.cancel()
        let view = LaunchProgressView(session: session, onDismiss: onDismiss)
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let p = panel ?? makePanel()
        p.contentView = host
        let screen = NSScreen.main ?? NSScreen.screens.first
        let vf = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        p.setFrame(CGRect(x: vf.maxX - size.width - 16, y: vf.maxY - size.height - 16, width: size.width, height: size.height),
                   display: true)
        p.orderFrontRegardless()
        panel = p
    }

    /// Re-fits the panel after rows changed height.
    func refit() {
        guard let p = panel, let host = p.contentView else { return }
        let size = host.fittingSize
        var f = p.frame
        f.origin.y += f.height - size.height
        f.size = size
        p.setFrame(f, display: true)
    }

    func close(after delay: TimeInterval = 0) {
        closeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.panel?.orderOut(nil)
            self?.panel?.contentView = nil
        }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 360, height: 200),
                        styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.standardWindowButton(.closeButton)?.isHidden = true
        p.standardWindowButton(.miniaturizeButton)?.isHidden = true
        p.standardWindowButton(.zoomButton)?.isHidden = true
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.title = "Launching workspace"
        return p
    }
}

/// Per-app launch status: spinner, check mark or failure reason.
struct LaunchProgressView: View {
    let session: LaunchSession
    var onDismiss: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ModuleIcon(symbol: "rectangle.split.2x2.fill", tint: .blue, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.isFinished ? "“\(session.workspaceName)”" : "Launching “\(session.workspaceName)”")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(session.summary).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
            }
            VStack(spacing: 0) {
                ForEach(Array(session.rows.enumerated()), id: \.element.id) { i, row in
                    if i > 0 { Divider().padding(.leading, 40) }
                    HStack(spacing: 10) {
                        Image(nsImage: AppIcons.icon(path: row.appPath)).resizable().frame(width: 22, height: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                            Text(row.status.isFinal && !row.status.isSuccess ? row.status.label : row.detail)
                                .font(.system(size: 11))
                                .foregroundStyle(failed(row.status) ? Color.red : Color.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        StatusMark(status: row.status)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                }
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
            HStack {
                Spacer()
                Button(session.isFinished ? "Done" : "Cancel") {
                    if !session.isFinished { session.cancel() }
                    onDismiss()
                }
                .keyboardShortcut(session.isFinished ? .defaultAction : .cancelAction)
            }
        }
        .padding(16)
        .frame(width: 360)
        .background(.regularMaterial)
    }

    private func failed(_ s: LaunchSession.Status) -> Bool {
        if case .failed = s { true } else { false }
    }
}

private struct StatusMark: View {
    let status: LaunchSession.Status

    var body: some View {
        Group {
            switch status {
            case .waiting:
                Image(systemName: "circle.dotted").foregroundStyle(.tertiary)
            case .launching, .arranging:
                ProgressView().controlSize(.small)
            case .launched, .moved:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed(let why):
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red).help(why)
            case .cancelled:
                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 15))
        .frame(width: 20, height: 20)
        .help(status.label)
    }
}

/// App icons and a representative color per app, cached.
@MainActor
enum AppIcons {
    private static var icons: [String: NSImage] = [:]
    private static var colors: [String: NSColor] = [:]

    static func icon(path: String) -> NSImage {
        if let cached = icons[path] { return cached }
        // Resolve links (e.g. /Applications/Safari.app) so the icon has no alias badge.
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let image = FileManager.default.fileExists(atPath: resolved) ? NSWorkspace.shared.icon(forFile: resolved)
            : NSWorkspace.shared.icon(for: .application)
        icons[path] = image
        return image
    }

    /// The icon's average color, nudged to a readable tile color.
    static func color(path: String) -> NSColor {
        if let cached = colors[path] { return cached }
        let color = averageColor(of: icon(path: path)) ?? Tint.blue.nsColor
        colors[path] = color
        return color
    }

    private static func averageColor(of image: NSImage) -> NSColor? {
        let side = 16
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: side * 4, bitsPerPixel: 32),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        image.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.bitmapData else { return nil }
        var r = 0.0, g = 0.0, b = 0.0, weight = 0.0
        for i in 0..<(side * side) {
            let a = Double(data[i * 4 + 3]) / 255
            guard a > 0.5 else { continue }
            let pr = Double(data[i * 4]) / 255 / a, pg = Double(data[i * 4 + 1]) / 255 / a, pb = Double(data[i * 4 + 2]) / 255 / a
            // Saturated pixels say more about an icon than its white or gray parts.
            let sat = max(pr, pg, pb) - min(pr, pg, pb)
            let w = 0.15 + sat
            r += pr * w; g += pg * w; b += pb * w; weight += w
        }
        guard weight > 0 else { return nil }
        let base = NSColor(srgbRed: r / weight, green: g / weight, blue: b / weight, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        base.usingColorSpace(.sRGB)?.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        return NSColor(hue: h, saturation: min(1, s * 1.15), brightness: min(max(v, 0.18), 0.82), alpha: 1)
    }
}
