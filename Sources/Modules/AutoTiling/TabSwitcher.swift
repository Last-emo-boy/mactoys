import AppKit
import MacToysCore
import Observation
import SwiftUI

/// What Tab View shows: a map of every display's tiles and the minimized windows below.
@MainActor
@Observable
final class TabSwitcherModel {
    struct Item: Identifiable {
        let id: CGWindowID
        let app: String
        let title: String
        let icon: NSImage?
        /// Frame within its display, 0…1 on both axes (top-left origin).
        let frame: CGRect
        let isFloating: Bool
        /// Windows in the same tile (1 for a tile of its own), and this one's place in it.
        let stackCount: Int
        let stackIndex: Int
    }

    struct Screen: Identifiable {
        let id: String
        let name: String
        let aspect: CGFloat
        let kind: TileLayoutKind
        let items: [Item]
    }

    var screens: [Screen] = []
    var minimized: [Item] = []
    /// Selection order: displays left to right, tiles in order, floating windows, then minimized.
    var order: [CGWindowID] = []
    var selection = 0
    /// Shown while the switcher was opened with the keyboard and its modifiers are held.
    var holdKeys: [String] = []
    @ObservationIgnored var onChoose: ((CGWindowID) -> Void)?

    var selectedID: CGWindowID? { order.indices.contains(selection) ? order[selection] : nil }

    func step(_ by: Int) {
        guard !order.isEmpty else { return }
        selection = ((selection + by) % order.count + order.count) % order.count
    }
}

/// The Tab View panel.
struct TabSwitcherView: View {
    @Bindable var model: TabSwitcherModel
    var mapHeight: CGFloat = 168
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GlassPanel(cornerRadius: 26) {
            VStack(alignment: .leading, spacing: 16) {
                header
                HStack(alignment: .top, spacing: 20) {
                    ForEach(model.screens) { screen in ScreenMapView(screen: screen, model: model, height: mapHeight) }
                }
                if !model.minimized.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Minimized", comment: "Tab View: heading above minimized windows")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.55))
                            .textCase(.uppercase)
                        FlowRow(items: model.minimized, model: model)
                    }
                }
            }
            .padding(20)
        }
        .scaleEffect(shown || reduceMotion ? 1 : 0.96)
        .opacity(shown ? 1 : 0)
        .onAppear { withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .snappy(duration: 0.22)) { shown = true } }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.split.2x2.fill").font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Tint.indigo.color)
            Text("Windows", comment: "Tab View: title of the window map").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
            if let id = model.selectedID, let item = (model.screens.flatMap(\.items) + model.minimized).first(where: { $0.id == id }) {
                Text(verbatim: item.title.isEmpty ? item.app : "\(item.app) — \(item.title)")
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.6)).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 16)
            if !model.holdKeys.isEmpty {
                HStack(spacing: 6) {
                    Keycaps(["⇥"], dark: true)
                    Text("next", comment: "Tab View hint: Tab moves to the next window").foregroundStyle(.white.opacity(0.55))
                    Text(verbatim: "·").foregroundStyle(.white.opacity(0.3))
                    Text("release \(model.holdKeys.joined()) to switch",
                         comment: "Tab View hint; %@ is the modifier keys being held, like ⌃⌥")
                        .foregroundStyle(.white.opacity(0.55))
                }
                .font(.system(size: 11.5))
            }
        }
    }
}

private struct ScreenMapView: View {
    let screen: TabSwitcherModel.Screen
    let model: TabSwitcherModel
    let height: CGFloat

    var body: some View {
        let width = min(max(height * screen.aspect, height * 0.62), height * 3.2)
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.16, green: 0.2, blue: 0.42), Color(red: 0.38, green: 0.24, blue: 0.5)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing).opacity(0.75))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.14)))
                ForEach(tiles, id: \.id) { item in
                    card(item, width: width)
                }
            }
            .frame(width: width, height: height)
            HStack(spacing: 6) {
                Image(systemName: screen.kind.symbol).font(.system(size: 10.5, weight: .semibold))
                Text(verbatim: screen.name).lineLimit(1)
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.6))
        }
    }

    /// One card per tile (the selected member of a stack, else its front window), floating on top.
    private var tiles: [TabSwitcherModel.Item] {
        let selected = model.selectedID
        var shown: [TabSwitcherModel.Item] = []
        var seen: [CGRect] = []
        let tiled = screen.items.filter { !$0.isFloating }
        for item in tiled where !seen.contains(item.frame) {
            seen.append(item.frame)
            let members = tiled.filter { $0.frame == item.frame }
            shown.append(members.first { $0.id == selected } ?? item)
        }
        return shown + screen.items.filter(\.isFloating)
    }

    private func card(_ item: TabSwitcherModel.Item, width: CGFloat) -> some View {
        let inset: CGFloat = 4
        let rect = CGRect(x: item.frame.minX * width, y: item.frame.minY * height,
                          width: item.frame.width * width, height: item.frame.height * height).insetBy(dx: inset / 2, dy: inset / 2)
        let selected = model.selectedID == item.id
        return WindowCard(item: item, selected: selected, compact: rect.height < 54)
            .frame(width: max(rect.width, 8), height: max(rect.height, 8))
            .offset(x: rect.minX, y: rect.minY)
            .onTapGesture { model.onChoose?(item.id) }
    }
}

private struct WindowCard: View {
    let item: TabSwitcherModel.Item
    let selected: Bool
    let compact: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(selected ? Color.accentColor.opacity(0.32) : Color.white.opacity(item.isFloating ? 0.16 : 0.1))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : .white.opacity(0.18),
                                  style: StrokeStyle(lineWidth: selected ? 2.5 : 1, dash: item.isFloating && !selected ? [4, 3] : []))
            }
            .overlay {
                VStack(spacing: compact ? 2 : 6) {
                    icon.frame(width: compact ? 18 : 30, height: compact ? 18 : 30)
                    if !compact {
                        Text(verbatim: item.title.isEmpty ? item.app : item.title)
                            .font(.system(size: 11, weight: selected ? .semibold : .regular))
                            .foregroundStyle(.white.opacity(selected ? 1 : 0.75))
                            .lineLimit(1).truncationMode(.tail)
                            .padding(.horizontal, 6)
                    }
                }
            }
            .overlay(alignment: .topTrailing) {
                if item.stackCount > 1 {
                    Text(verbatim: "\(item.stackIndex + 1)/\(item.stackCount)")
                        .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(Capsule().fill(.black.opacity(0.35)))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(4)
                }
            }
            .shadow(color: .black.opacity(selected ? 0.3 : 0), radius: 8, y: 3)
            .animation(.snappy(duration: 0.15), value: selected)
    }

    @ViewBuilder private var icon: some View {
        if let image = item.icon {
            Image(nsImage: image).resizable().interpolation(.high)
        } else {
            Image(systemName: "macwindow").resizable().scaledToFit().foregroundStyle(.white.opacity(0.7))
        }
    }
}

/// Minimized windows as chips.
private struct FlowRow: View {
    let items: [TabSwitcherModel.Item]
    let model: TabSwitcherModel

    var body: some View {
        HStack(spacing: 8) {
            ForEach(items.prefix(8)) { item in
                let selected = model.selectedID == item.id
                HStack(spacing: 7) {
                    if let icon = item.icon { Image(nsImage: icon).resizable().frame(width: 18, height: 18) }
                    Text(verbatim: item.title.isEmpty ? item.app : item.title)
                        .font(.system(size: 11.5, weight: selected ? .semibold : .regular)).lineLimit(1)
                        .frame(maxWidth: 150, alignment: .leading)
                }
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(Capsule().fill(selected ? Color.accentColor.opacity(0.32) : .white.opacity(0.08)))
                .overlay(Capsule().strokeBorder(selected ? Color.accentColor : .white.opacity(0.14), lineWidth: selected ? 2 : 1))
                .foregroundStyle(.white.opacity(selected ? 1 : 0.8))
                .onTapGesture { model.onChoose?(item.id) }
            }
            if items.count > 8 {
                Text(verbatim: "+\(items.count - 8)").font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white.opacity(0.5))
            }
        }
    }
}

/// Icons for apps, cached by bundle id.
@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(bundleID: String?, pid: pid_t? = nil) -> NSImage? {
        if let bundleID, let hit = cache[bundleID] { return hit }
        var image = pid.flatMap { NSRunningApplication(processIdentifier: $0)?.icon }
        if image == nil, let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        }
        if let bundleID, let image { cache[bundleID] = image }
        return image
    }
}

/// Hold the shortcut's modifiers and press its key to step through every window in the layout
/// map; release to switch. ⇧ or the arrows go back, Return picks, Esc cancels.
@MainActor
final class TabSwitcher {
    private unowned let engine: TilingEngine
    private static let tapID = "autotile.tabview"
    let model = TabSwitcherModel()
    private var panel: OverlayPanel?
    private var shortcut: Shortcut?
    private var hold: Modifiers = []
    private(set) var isOpen = false
    private var listening = false
    private var mouseMonitor: Any?
    /// Key codes whose key-down was swallowed, so their key-up is swallowed too.
    private var swallowUp = [Bool](repeating: false, count: 128)

    private enum Key {
        static let escape: UInt16 = 53, returnKey: UInt16 = 36, enter: UInt16 = 76
        static let left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125, up: UInt16 = 126
    }

    init(engine: TilingEngine) {
        self.engine = engine
        model.onChoose = { [weak self] id in
            guard let self else { return }
            if let i = self.model.order.firstIndex(of: id) { self.model.selection = i }
            self.finish(choose: true)
        }
    }

    /// Listens for the shortcut while one is set. The handler reads `shortcut`, so a new one
    /// needs no new tap (settings change often while a slider moves).
    func configure(shortcut: Shortcut?, running: Bool) {
        self.shortcut = shortcut
        let wanted = running && shortcut != nil
        guard wanted != listening else { return }
        listening = wanted
        if wanted {
            InputTap.shared.add(Self.tapID, priority: 72, events: [.keyDown, .keyUp, .flagsChanged]) { [weak self] type, event in
                self?.handle(type, event) ?? .pass
            }
        } else {
            InputTap.shared.remove(Self.tapID)
            finish(choose: false)
        }
    }

    func stop() {
        listening = false
        InputTap.shared.remove(Self.tapID)
        finish(choose: false)
        panel?.close()
        panel = nil
        swallowUp = [Bool](repeating: false, count: 128)
    }

    // MARK: Tap (every key event: early exit first)

    private func handle(_ type: CGEventType, _ event: CGEvent) -> TapDecision {
        switch type {
        case .keyDown:
            let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            guard isOpen else {
                guard let s = shortcut, code == s.keyCode, s.matches(event) else { return .pass }
                let held = s.modifiers.subtracting(.shift)
                DispatchQueue.main.async { [weak self] in _ = self?.show(hold: held) }
                return swallow(code)
            }
            return keyWhileOpen(code, event)
        case .keyUp:
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            guard code >= 0, code < swallowUp.count, swallowUp[code] else { return .pass }
            swallowUp[code] = false
            return .consume
        case .flagsChanged:
            if isOpen, !hold.isEmpty, !Modifiers(event.flags).isSuperset(of: hold) {
                DispatchQueue.main.async { [weak self] in self?.finish(choose: true) }
            }
            return .pass
        default:
            return .pass
        }
    }

    private func keyWhileOpen(_ code: UInt16, _ event: CGEvent) -> TapDecision {
        if code == shortcut?.keyCode {
            let back = event.flags.contains(.maskShift) && shortcut?.modifiers.contains(.shift) == false
            model.step(back ? -1 : 1)
            return swallow(code)
        }
        switch code {
        case Key.escape:
            DispatchQueue.main.async { [weak self] in self?.finish(choose: false) }
        case Key.returnKey, Key.enter:
            DispatchQueue.main.async { [weak self] in self?.finish(choose: true) }
        case Key.left, Key.up:
            model.step(-1)
        case Key.right, Key.down:
            model.step(1)
        default:
            return .pass
        }
        return swallow(code)
    }

    private func swallow(_ code: UInt16) -> TapDecision {
        if Int(code) < swallowUp.count { swallowUp[Int(code)] = true }
        return .consume
    }

    // MARK: Switcher

    /// Opens Tab View. `hold`: modifiers whose release switches (empty: Return or a click).
    @discardableResult
    func show(hold: Modifiers) -> Bool {
        guard engine.isActive, !isOpen else { return false }
        engine.trackMinimizedWindows()
        fill()
        guard !model.order.isEmpty else {
            HUD.show("No windows to switch to", symbol: "macwindow")
            return false
        }
        self.hold = hold
        model.holdKeys = hold.symbols
        isOpen = true
        present()
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(choose: false) }
        }
        // Opened by a key whose modifiers were already let go: switch at once.
        if !hold.isEmpty, !Modifiers(NSEvent.modifierFlags).isSuperset(of: hold) { finish(choose: true) }
        return true
    }

    private func fill() {
        var screens: [TabSwitcherModel.Screen] = []
        var order: [CGWindowID] = []
        for d in engine.displays {
            let size = d.frame.size
            func relative(_ f: CGRect) -> CGRect {
                CGRect(x: (f.minX - d.frame.minX) / size.width, y: (f.minY - d.frame.minY) / size.height,
                       width: f.width / size.width, height: f.height / size.height)
                    .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            var items: [TabSwitcherModel.Item] = []
            let plan = engine.plans[d.key]
            for (i, stack) in engine.tiles(on: d.key).enumerated() {
                let tileFrame = plan.flatMap { $0.tileFrames.indices.contains(i) ? $0.tileFrames[i] : nil }
                for (depth, id) in stack.enumerated() {
                    guard let w = engine.window(id) else { continue }
                    items.append(item(w, frame: relative(tileFrame ?? w.frame), floating: false, count: stack.count, index: depth))
                    order.append(id)
                }
            }
            for id in engine.floatingWindows(on: d.key) {
                guard let w = engine.window(id) else { continue }
                items.append(item(w, frame: relative(w.frame), floating: true, count: 1, index: 0))
                order.append(id)
            }
            screens.append(.init(id: d.key, name: d.name, aspect: size.height > 0 ? size.width / size.height : 1.6,
                                 kind: engine.settings.value.layout(for: d.key).kind, items: items))
        }
        let minimized = engine.minimizedWindows.map { item($0, frame: .zero, floating: false, count: 1, index: 0) }
        order += minimized.map(\.id)
        model.screens = screens
        model.minimized = minimized
        model.order = order
        // Start on the window after the focused one, like ⌘⇥.
        if let focused = engine.focusedID, let i = order.firstIndex(of: focused) {
            model.selection = order.count > 1 ? (i + 1) % order.count : i
        } else {
            model.selection = 0
        }
    }

    private func item(_ w: TrackedWindow, frame: CGRect, floating: Bool, count: Int, index: Int) -> TabSwitcherModel.Item {
        AXUIElementSetMessagingTimeout(w.ref.element, 0.15)
        return .init(id: w.id, app: w.appName, title: w.ref.title ?? "", icon: AppIcons.icon(bundleID: w.bundleID, pid: w.pid),
                     frame: frame, isFloating: floating, stackCount: count, stackIndex: index)
    }

    private func present() {
        let screen = NSScreen.underMouse ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let vf = screen.visibleFrame
        let maps = model.screens.map { min(max($0.aspect, 0.62), 3.2) }
        var height: CGFloat = 168
        let spacing = CGFloat(max(maps.count - 1, 0)) * 20 + 40
        let natural = maps.reduce(0) { $0 + $1 * height } + spacing
        if natural > vf.width * 0.9 { height = max(90, (vf.width * 0.9 - spacing) / max(maps.reduce(0, +), 0.1)) }
        let width = max(maps.reduce(0) { $0 + $1 * height } + spacing, 420)
        let total = CGSize(width: width.rounded(), height: (height + 112 + (model.minimized.isEmpty ? 0 : 58)).rounded())
        let rect = CGRect(x: vf.midX - total.width / 2, y: vf.midY - total.height / 2, width: total.width, height: total.height)
        let p = panel ?? OverlayPanel(frame: rect, interactive: true, acceptsKey: false, level: .popUpMenu)
        p.setFrame(rect, display: false)
        p.setContent(TabSwitcherView(model: model, mapHeight: height).frame(maxWidth: .infinity, maxHeight: .infinity))
        p.alphaValue = 1
        p.orderFrontRegardless()
        panel = p
    }

    /// Closes Tab View; with `choose`, switches to the selected window.
    func finish(choose: Bool) {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        guard isOpen else { return }
        isOpen = false
        panel?.orderOut(nil)
        let chosen = model.selectedID
        model.screens = []
        model.minimized = []
        model.order = []
        guard choose, let chosen else { return }
        engine.activate(chosen)
    }
}
