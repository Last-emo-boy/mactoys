import AppKit
import MacToysCore
import Observation
import SwiftUI

/// What the separate bar shows.
@MainActor
@Observable
final class HiddenBarModel {
    var hidden: [BarEntry] = []
    var alwaysHidden: [BarEntry] = []
    var hovered: String?
    /// Items open directly with Accessibility; otherwise a click shows them in the menu bar.
    var canOpenDirectly = true
    var searchEnabled = false

    @ObservationIgnored var onActivate: (String) -> Void = { _ in }
    @ObservationIgnored var onSearch: () -> Void = {}

    var hoveredEntry: BarEntry? { (hidden + alwaysHidden).first { $0.id == hovered } }
}

/// The separate bar: hidden items in a glass strip under the menu bar, for displays where they
/// wouldn't fit beside the notch (or by choice). Clicking an item opens it through Accessibility.
@MainActor
final class HiddenBarController {
    let model = HiddenBarModel()
    private var panel: OverlayPanel?

    var isVisible: Bool { panel?.isVisible == true }
    var windowID: CGWindowID? { panel.map { CGWindowID($0.windowNumber) } }

    /// Whether a point (Cocoa coordinates) is over the bar, with a little slack.
    func contains(_ p: CGPoint) -> Bool {
        guard let panel, panel.isVisible else { return false }
        return panel.frame.insetBy(dx: -10, dy: -10).contains(p)
    }

    /// Shows the bar under the menu bar of `screen`, its right edge under `anchor` (the chevron).
    func show(on screen: NSScreen, menuBarHeight: CGFloat, anchor: CGRect?) {
        let p = panel ?? makePanel()
        let size = fittingSize(p)
        let vf = screen.frame
        let right = min((anchor?.maxX ?? vf.maxX - 12) + 10, vf.maxX - 8)
        let x = max(vf.minX + 8, right - size.width)
        let top = vf.maxY - menuBarHeight - 6
        let frame = CGRect(x: x, y: top - size.height, width: size.width, height: size.height)
        let wasVisible = p.isVisible
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if wasVisible {
            p.setFrame(frame, display: true)
            return
        }
        p.setFrame(reduceMotion ? frame : frame.offsetBy(dx: 0, dy: 6), display: false)
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().alphaValue = 1
            if !reduceMotion { p.animator().setFrame(frame, display: true) }
        }
    }

    /// Re-fits the bar after its entries changed (names arriving from Accessibility).
    func refit() {
        guard let panel, panel.isVisible else { return }
        let size = fittingSize(panel)
        var f = panel.frame
        let right = f.maxX, top = f.maxY
        f.size = size
        f.origin = CGPoint(x: right - size.width, y: top - size.height)
        panel.setFrame(f, display: true)
    }

    func hide() {
        guard let p = panel, p.isVisible else { return }
        model.hovered = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
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
        let p = OverlayPanel(frame: CGRect(x: 0, y: 0, width: 300, height: 60), interactive: true, acceptsKey: false, level: .statusBar)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = FirstMouseHostingView(rootView: HiddenBarView(model: model))
        host.sizingOptions = []
        p.contentView = host
        panel = p
        return p
    }

    private func fittingSize(_ p: NSPanel) -> CGSize {
        let size = p.contentView?.fittingSize ?? CGSize(width: 300, height: 60)
        return CGSize(width: ceil(max(120, size.width)), height: ceil(max(44, size.height)))
    }
}

/// A hosting view that takes the first click, so buttons in non-key overlay panels react at once.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The bar's content: icon buttons in a glass strip, the always-hidden ones after a thin divider,
/// and a caption naming the item under the pointer.
struct HiddenBarView: View {
    @Bindable var model: HiddenBarModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// At most this many icons per row; more wrap to a second row.
    static let perRow = 18

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if model.hidden.isEmpty && model.alwaysHidden.isEmpty {
                empty
            } else {
                rows
                caption
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .padding(.bottom, 6)
        .fixedSize()
        .barSurface(cornerRadius: 14)
        .foregroundStyle(.white)
        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: model.hovered)
    }

    private enum Cell: Identifiable {
        case item(BarEntry, faded: Bool)
        case divider(Int)
        case search

        var id: String {
            switch self {
            case .item(let e, _): e.id
            case .divider(let n): "divider-\(n)"
            case .search: "search"
            }
        }
    }

    private var cells: [Cell] {
        var cells = model.hidden.map { Cell.item($0, faded: false) }
        if !model.alwaysHidden.isEmpty {
            if !cells.isEmpty { cells.append(.divider(0)) }
            cells += model.alwaysHidden.map { Cell.item($0, faded: true) }
        }
        if model.searchEnabled {
            cells.append(.divider(1))
            cells.append(.search)
        }
        return cells
    }

    private var rows: some View {
        let all = cells
        let chunks = stride(from: 0, to: all.count, by: Self.perRow).map { Array(all[$0..<min($0 + Self.perRow, all.count)]) }
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(chunks.enumerated()), id: \.offset) { _, chunk in
                HStack(spacing: 2) {
                    ForEach(chunk) { cell in
                        switch cell {
                        case .item(let entry, let faded): BarItemButton(entry: entry, faded: faded, model: model)
                        case .divider: sectionDivider
                        case .search: searchButton
                        }
                    }
                }
            }
        }
    }

    private var searchButton: some View {
        Button { model.onSearch() } label: {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text("Search menu bar items", comment: "Help tag on the separate bar's search button"))
        .accessibilityLabel(Text("Search menu bar items", comment: "Help tag on the separate bar's search button"))
    }

    private var sectionDivider: some View {
        Capsule().fill(.white.opacity(0.22)).frame(width: 1.5, height: 18).padding(.horizontal, 4)
    }

    private var caption: some View {
        Group {
            if let entry = model.hoveredEntry {
                HStack(spacing: 6) {
                    Text(verbatim: entry.title).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                    if entry.title != entry.appName {
                        Text(verbatim: entry.appName).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                    }
                    if entry.section == .alwaysHidden {
                        Text(entry.section.title).font(.system(size: 10.5, weight: .medium))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(.white.opacity(0.12)))
                    }
                }
            } else if model.canOpenDirectly {
                Text("\(model.hidden.count + model.alwaysHidden.count) hidden items · click one to open it",
                     comment: "Separate menu bar: caption when no item is under the pointer; the number counts hidden icons")
                    .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.55))
            } else {
                Text("Click an item to show it in the menu bar", comment: "Separate menu bar caption without Accessibility access")
                    .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 16)
    }

    private var empty: some View {
        HStack(spacing: 10) {
            Image(systemName: "menubar.rectangle").font(.system(size: 16, weight: .medium)).foregroundStyle(.white.opacity(0.7))
            VStack(alignment: .leading, spacing: 1) {
                Text("No hidden icons").font(.system(size: 12.5, weight: .semibold))
                Text("Hold ⌘ and drag icons left of the divider to hide them.")
                    .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }
}

private struct BarItemButton: View {
    let entry: BarEntry
    let faded: Bool
    let model: HiddenBarModel

    var body: some View {
        let hovered = model.hovered == entry.id
        Button { model.onActivate(entry.id) } label: {
            EntryIcon(icon: entry.icon, size: 18)
                .opacity(faded && !hovered ? 0.75 : 1)
                .frame(width: 32, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(hovered ? 0.16 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { model.hovered = entry.id } else if model.hovered == entry.id { model.hovered = nil }
        }
        .accessibilityLabel(Text(verbatim: entry.title))
        .help(Text(verbatim: entry.title == entry.appName ? entry.title : "\(entry.title) — \(entry.appName)"))
    }
}
