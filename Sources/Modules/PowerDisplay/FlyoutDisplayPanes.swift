import AppKit
import MacToysCore
import SwiftUI

/// The sections behind a display's disclosure button.
enum DisplayPane: String, CaseIterable, Sendable {
    case resolution, color, arrange

    var title: LocalizedStringKey {
        switch self {
        case .resolution: "Resolution"
        case .color: "Color"
        case .arrange: "Arrange"
        }
    }

    var symbol: String {
        switch self {
        case .resolution: "rectangle.arrowtriangle.2.outward"
        case .color: "paintpalette"
        case .arrange: "rectangle.3.group"
        }
    }
}

/// A small capsule badge: "HiDPI", "Native", "Main".
struct FlyoutBadge: View {
    let text: Text
    var tint: Color?

    var body: some View {
        text.font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(tint ?? .white.opacity(0.78))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill((tint ?? .white).opacity(tint == nil ? 0.12 : 0.18)))
            .fixedSize()
    }
}

/// The label of a flyout menu button: text and an up-down chevron in a rounded chip.
struct FlyoutChipLabel: View {
    let text: Text
    var symbol: String?

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold)) }
            text.lineLimit(1)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(0.08)))
    }
}

/// A quiet chip button for the panes ("Make Main", "Show").
struct FlyoutChipButton: View {
    let title: Text
    var symbol: String?
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold)) }
                title.lineLimit(1)
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(active ? AnyShapeStyle(Color.accentColor.opacity(0.85)) : AnyShapeStyle(.white.opacity(0.08))))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
    }
}

/// Tabs and content for one display's resolution, color and arrangement.
struct DisplayPanes: View {
    let module: PowerDisplayModule
    @Bindable var monitor: MonitorState

    private var pane: DisplayPane { module.store.panes[monitor.id] ?? .resolution }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
            tabs
            Group {
                switch pane {
                case .resolution: ResolutionPane(module: module, monitor: monitor)
                case .color: ColorPane(module: module, monitor: monitor)
                case .arrange: ArrangePane(module: module, monitor: monitor)
                }
            }
            .transition(.opacity)
            .id(pane)
        }
    }

    private var tabs: some View {
        HStack(spacing: 2) {
            ForEach(DisplayPane.allCases, id: \.self) { p in
                Button {
                    withAnimation(.smooth(duration: 0.18)) { module.store.panes[monitor.id] = p }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: p.symbol).font(.system(size: 10.5, weight: .semibold))
                        Text(p.title).lineLimit(1).minimumScaleFactor(0.85)
                    }
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(pane == p ? .white : .white.opacity(0.62))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(pane == p ? 0.16 : 0)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.black.opacity(0.18)))
    }
}

/// A row in a pane: icon, title, trailing control.
private struct PaneRow<Trailing: View>: View {
    let symbol: String
    let title: Text
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 16)
            title.font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 8)
            trailing
        }
    }
}

// MARK: - Resolution

struct ResolutionPane: View {
    let module: PowerDisplayModule
    @Bindable var monitor: MonitorState

    var body: some View {
        if let catalog = monitor.modes, !catalog.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                summary(catalog)
                if !catalog.favorites.isEmpty { favorites(catalog) }
                ModeList(module: module, monitor: monitor, catalog: catalog)
            }
        } else {
            Text("This display doesn't offer other resolutions.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var isBuiltIn: Bool { monitor.snapshot.kind == .builtIn }

    private func summary(_ catalog: ModeCatalog) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                if let c = catalog.current {
                    HStack(spacing: 6) {
                        Text(verbatim: c.resolution.title).font(.system(size: 14, weight: .semibold)).monospacedDigit()
                        if c.isHiDPI { FlyoutBadge(text: Text(verbatim: "HiDPI"), tint: nil) }
                    }
                    Text(c.isHiDPI ? "\(String(c.pixelWidth)) × \(String(c.pixelHeight)) pixels" : "Pixel for pixel",
                         comment: "Under the current resolution: its backing pixel size (width × height), or that it isn't scaled")
                        .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Spacer(minLength: 8)
            let rates = catalog.refreshRates
            if rates.count > 1 {
                Menu {
                    ForEach(rates, id: \.self) { r in
                        Button {
                            module.switchRefresh(r, on: monitor)
                        } label: {
                            let title = RefreshFormat.title(r, proMotion: RefreshFormat.isProMotion(r, builtIn: isBuiltIn, rates: rates))
                            if r == catalog.current?.refreshRate { Label(title, systemImage: "checkmark") } else { Text(verbatim: title) }
                        }
                    }
                } label: {
                    FlyoutChipLabel(text: Text(verbatim: rateTitle(catalog.current?.refreshRate ?? 0, rates: rates)),
                                    symbol: "waveform.path.ecg")
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .help("Refresh rate")
            } else if let r = rates.first, r > 0 {
                Text(verbatim: rateTitle(r, rates: rates)).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            }
        }
    }

    private func rateTitle(_ r: Double, rates: [Double]) -> String {
        RefreshFormat.title(r, proMotion: RefreshFormat.isProMotion(r, builtIn: isBuiltIn, rates: rates))
    }

    private func favorites(_ catalog: ModeCatalog) -> some View {
        ChipFlow(spacing: 6, lineSpacing: 6) {
            ForEach(catalog.favorites) { e in
                Button {
                    if let mode = catalog.mode(for: e.key) { module.switchMode(mode, on: monitor) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "star.fill").font(.system(size: 8.5)).foregroundStyle(Tint.yellow.color)
                        Text(verbatim: e.key.title).monospacedDigit()
                        if e.isHiDPI { Text(verbatim: "HiDPI").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary) }
                    }
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(.white.opacity(e.isCurrent ? 0.2 : 0.08)))
                    .overlay(Capsule(style: .circular).strokeBorder(.white.opacity(e.isCurrent ? 0.35 : 0), lineWidth: 1))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(e.isCurrent ? Text("Current resolution") : Text("Switch to this resolution"))
            }
        }
    }
}

/// Chips in rows, wrapping onto the next row when one doesn't fit.
struct ChipFlow: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrange(width: bounds.width, subviews: subviews).frames
        for (view, frame) in zip(subviews, frames) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                       proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let ideal = view.sizeThatFits(.unspecified)
            let w = min(ideal.width, width)
            if x > 0 && x + w > width {
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            frames.append(CGRect(x: x, y: y, width: w, height: ideal.height))
            widest = max(widest, x + w)
            x += w + spacing
            rowHeight = max(rowHeight, ideal.height)
        }
        return (frames, CGSize(width: widest, height: y + rowHeight))
    }
}

/// Every resolution, grouped by aspect ratio, current one checked, favorites starred.
struct ModeList: View {
    let module: PowerDisplayModule
    let monitor: MonitorState
    let catalog: ModeCatalog
    static let maxHeight: CGFloat = 214

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(catalog.groups) { group in
                    HStack(spacing: 6) {
                        Text(verbatim: group.aspect.title()).font(.system(size: 10.5, weight: .bold)).foregroundStyle(.secondary)
                        if group.isNative {
                            Text("Native shape", comment: "Mode list: the aspect ratio of the panel itself")
                                .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, group.id == catalog.groups.first?.id ? 2 : 8)
                    .padding(.bottom, 2)
                    ForEach(group.entries) { e in row(e) }
                }
            }
            .padding(.vertical, 2)
        }
        .frame(height: min(Self.maxHeight, estimatedHeight))
        .scrollIndicators(.automatic)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.black.opacity(0.16)))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var estimatedHeight: CGFloat {
        CGFloat(catalog.entries.count) * 25 + CGFloat(catalog.groups.count) * 24 + 6
    }

    private func row(_ e: ResolutionEntry) -> some View {
        HStack(spacing: 0) {
            Button {
                if let mode = catalog.mode(for: e.key) { module.switchMode(mode, on: monitor) }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "checkmark").font(.system(size: 9.5, weight: .bold))
                        .opacity(e.isCurrent ? 1 : 0).frame(width: 12)
                    Text(verbatim: e.key.title).font(.system(size: 12.5, weight: e.isCurrent ? .semibold : .regular)).monospacedDigit()
                    if e.isHiDPI { FlyoutBadge(text: Text(verbatim: "HiDPI"), tint: nil) }
                    if e.isNative { FlyoutBadge(text: Text("Native", comment: "Badge: the panel's own resolution"), tint: Tint.yellow.color) }
                    Spacer(minLength: 6)
                    // The rate only where it differs from the current one ("up to 120 Hz" stands out).
                    if let top = e.refreshRates.first, top > 0,
                       RefreshFormat.rounded(top) != RefreshFormat.rounded(catalog.current?.refreshRate ?? top) {
                        Text(verbatim: RefreshFormat.title(top)).font(.system(size: 10.5)).foregroundStyle(.tertiary).monospacedDigit()
                    }
                }
                .padding(.leading, 6)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(e.isDefault ? Text("The display's default resolution") : Text(verbatim: "\(e.key.pixelWidth) × \(e.key.pixelHeight)"))
            Button {
                module.toggleFavorite(e.key, on: monitor)
            } label: {
                Image(systemName: e.isFavorite ? "star.fill" : "star")
                    .font(.system(size: 10.5))
                    .foregroundStyle(e.isFavorite ? Tint.yellow.color : .white.opacity(0.32))
                    .frame(width: 26, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(e.isFavorite ? Text("Remove from favorites") : Text("Add to favorites"))
        }
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.white.opacity(e.isCurrent ? 0.12 : 0)))
        .padding(.horizontal, 3)
    }
}

// MARK: - Color

struct ColorPane: View {
    let module: PowerDisplayModule
    @Bindable var monitor: MonitorState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PaneRow(symbol: "paintpalette", title: Text("Color profile")) {
                Menu {
                    let list = module.colorProfiles(for: monitor)
                    ForEach(list) { p in
                        Button {
                            module.setColorProfile(p.url, on: monitor)
                        } label: {
                            let isFactory = p.url == monitor.factoryProfile
                            let title = isFactory ? String(localized: "\(p.name) (display's own)", comment: "Color profile menu: the profile the display came with") : p.name
                            if p.url.standardizedFileURL == monitor.colorProfile?.standardizedFileURL { Label(title, systemImage: "checkmark") }
                            else { Text(verbatim: title) }
                        }
                        if p.url == monitor.factoryProfile && list.count > 1 { Divider() }
                    }
                } label: {
                    FlyoutChipLabel(text: Text(verbatim: module.profileName(monitor.colorProfile) ?? "—"))
                        .frame(maxWidth: 190, alignment: .trailing)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize(horizontal: false, vertical: true)
            }
            if NightShift.isAvailable {
                PaneRow(symbol: "moon", title: Text("Night Shift")) {
                    Toggle("Night Shift", isOn: Binding(get: { module.store.nightShiftOn ?? false },
                                                        set: { _ in module.toggleNightShift() }))
                        .toggleStyle(.adaptiveSwitch).controlSize(.small).labelsHidden()
                }
            }
            if monitor.facts.supportsExtraBrightness {
                PaneRow(symbol: "sun.max.trianglebadge.exclamationmark", title: Text("Extra brightness")) {
                    Toggle("Extra brightness", isOn: Binding(get: { module.settings.value.extraBrightness },
                                                             set: { module.setExtraBrightness($0) }))
                        .toggleStyle(.adaptiveSwitch).controlSize(.small).labelsHidden()
                }
                Text("Uses the panel's HDR headroom: the brightness slider continues past 100 %. Uses more power and warms the display.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 26)
            }
        }
    }
}

// MARK: - Arrange

struct ArrangePane: View {
    let module: PowerDisplayModule
    @Bindable var monitor: MonitorState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if module.store.monitors.count > 1 {
                PaneRow(symbol: "menubar.rectangle", title: Text("Main display")) {
                    if monitor.facts.isMain {
                        Text("Has the menu bar", comment: "Arrange pane: this display is the main display")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    } else {
                        FlyoutChipButton(title: Text("Make Main", comment: "Button: make this the main display")) { module.makeMain(monitor) }
                    }
                }
                mirrorRow
            }
            PaneRow(symbol: "rotate.right", title: Text("Rotation")) {
                Text(verbatim: Measurement(value: Double(monitor.snapshot.rotation), unit: UnitAngle.degrees)
                        .formatted(.measurement(width: .narrow)))
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).monospacedDigit()
                    .help("Change rotation in System Settings › Displays")
            }
            PaneRow(symbol: "pip", title: Text("Picture in Picture")) {
                let open = module.store.pipOpen.contains(monitor.id)
                FlyoutChipButton(title: open ? Text("Close", comment: "Button: close picture in picture") : Text("Show", comment: "Button: show this display in picture in picture"),
                                 symbol: open ? "pip.exit" : "pip.enter", active: open) { module.togglePiP(monitor) }
                    .help("A live, resizable window of this display. Needs Screen Recording permission.")
            }
            if monitor.snapshot.kind == .virtual, let config = virtualConfig {
                PaneRow(symbol: "rectangle.dashed", title: Text("Virtual display")) {
                    FlyoutChipButton(title: Text("Disconnect", comment: "Button: remove this virtual display")) {
                        module.setVirtualDisplay(config.id, connected: false)
                    }
                }
            }
        }
    }

    private var virtualConfig: VirtualDisplayConfig? {
        guard let id = module.virtualHandles.first(where: { $0.value.displayID == monitor.snapshot.displayID })?.key else { return nil }
        return module.settings.value.virtualDisplays.first { $0.id == id }
    }

    private var mirrorRow: some View {
        let sources = module.mirrorSources(for: monitor)
        let current = monitor.facts.mirrorOf.flatMap { id in module.store.monitors.first { $0.snapshot.displayID == id } }
        return PaneRow(symbol: "rectangle.on.rectangle", title: Text("Mirror")) {
            Menu {
                Button {
                    module.mirror(monitor, of: nil)
                } label: {
                    if current == nil { Label("Off", systemImage: "checkmark") } else { Text("Off", comment: "Mirroring: off") }
                }
                if !sources.isEmpty { Divider() }
                ForEach(sources) { s in
                    Button {
                        module.mirror(monitor, of: s)
                    } label: {
                        if current?.id == s.id { Label(s.name, systemImage: "checkmark") } else { Text(verbatim: s.name) }
                    }
                }
            } label: {
                FlyoutChipLabel(text: current.map { Text(verbatim: $0.name) } ?? Text("Off", comment: "Mirroring: off"))
                    .frame(maxWidth: 190, alignment: .trailing)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize(horizontal: false, vertical: true)
            .help("Show what another display shows")
        }
    }
}

// MARK: - Footer

/// Brightness sync, Night Shift and virtual displays, as compact chips.
struct FlyoutFooter: View {
    let module: PowerDisplayModule
    @Bindable var settings: Persisted<PowerDisplaySettings>

    init(module: PowerDisplayModule) {
        self.module = module
        self.settings = module.settings
    }

    private var showsSync: Bool { module.canLinkBrightness }
    private var showsNightShift: Bool { NightShift.isAvailable && settings.value.showNightShiftButton }
    private var showsVirtual: Bool { module.virtualDisplaysAvailable }

    var body: some View {
        if showsSync || showsNightShift || showsVirtual {
            // Labels go one chip at a time when they don't fit (long names, long translations).
            ViewThatFits(in: .horizontal) {
                chips(labels: 3)
                chips(labels: 2)
                chips(labels: 1)
                chips(labels: 0)
            }
        }
    }

    /// `labels`: how many chips keep their text, sync first, then Night Shift, then virtual displays.
    private func chips(labels: Int) -> some View {
        HStack(spacing: 6) {
            if showsSync { syncMenu(labels: labels >= 1) }
            if showsNightShift { nightShift(labels: labels >= 2) }
            Spacer(minLength: 0)
            if showsVirtual { virtualMenu(labels: labels >= 3) }
        }
        .padding(.horizontal, 2)
    }

    private var syncTitle: Text {
        if module.isLinked { return Text("Linked", comment: "Brightness sync: one slider for all displays") }
        if let source = module.syncSourceMonitor {
            return Text("Follows \(source.name)", comment: "Brightness sync: other displays follow this display's brightness")
        }
        return Text("Independent", comment: "Brightness sync: every display on its own")
    }

    private func syncMenu(labels: Bool) -> some View {
        Menu {
            Button {
                settings.value.linkedBrightness = false
                module.setSyncSource(nil)
            } label: {
                checked(!module.isLinked && module.syncSourceMonitor == nil, Text("Independent", comment: "Brightness sync: every display on its own"))
            }
            Button {
                module.setSyncSource(nil)
                settings.value.linkedBrightness = true
            } label: {
                checked(module.isLinked, Text("Linked: one slider for all", comment: "Brightness sync menu item"))
            }
            Divider()
            ForEach(module.brightnessMonitors) { m in
                Button {
                    module.setSyncSource(m.id)
                } label: {
                    checked(!module.isLinked && module.syncSourceMonitor?.id == m.id,
                            Text("Follow \(m.name)", comment: "Brightness sync menu item: other displays follow this one, keeping their distance"))
                }
            }
        } label: {
            footerChip(symbol: module.isLinked ? "link" : (module.syncSourceMonitor != nil ? "arrow.triangle.branch" : "link"),
                       text: labels ? syncTitle : nil, on: module.isLinked || module.syncSourceMonitor != nil, chevron: true)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("Brightness sync")
    }

    @ViewBuilder
    private func checked(_ on: Bool, _ text: Text) -> some View {
        if on { Label { text } icon: { Image(systemName: "checkmark") } } else { text }
    }

    private func nightShift(labels: Bool) -> some View {
        let on = module.store.nightShiftOn ?? false
        return Button { module.toggleNightShift() } label: {
            footerChip(symbol: on ? "moon.fill" : "moon", text: labels ? Text("Night Shift") : nil, on: on, chevron: false)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Night Shift")
        .accessibilityValue(on ? Text("On") : Text("Off"))
    }

    private func virtualMenu(labels: Bool) -> some View {
        let configs = settings.value.virtualDisplays
        let connected = module.store.connectedVirtual
        return Menu {
            if !configs.isEmpty {
                ForEach(configs) { c in
                    Button {
                        module.setVirtualDisplay(c.id, connected: !connected.contains(c.id))
                    } label: {
                        checked(connected.contains(c.id), Text(verbatim: "\(c.name) — \(c.width) × \(c.height)"))
                    }
                }
                Divider()
            }
            Menu("New Virtual Display") {
                ForEach(VirtualDisplayPreset.all.prefix(6)) { p in
                    Button {
                        module.addVirtualDisplay(width: p.width, height: p.height)
                    } label: {
                        Text("\(String(p.width)) × \(String(p.height)) · looks like \(String(p.width / 2)) × \(String(p.height / 2))",
                             comment: "New virtual display menu item: pixel size (width × height), then the HiDPI desktop size")
                    }
                }
            }
            Button("Edit Virtual Displays…") {
                module.closeFlyout()
                ModuleRegistry.shared.showSettings?(module.info.id)
            }
        } label: {
            footerChip(symbol: "rectangle.dashed.badge.record", text: labels ? Text("Virtual", comment: "Flyout footer: virtual displays menu") : nil,
                       on: !connected.isEmpty, chevron: true)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("Virtual displays")
    }

    private func footerChip(symbol: String, text: Text?, on: Bool, chevron: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(on ? Tint.yellow.color : .white.opacity(0.85))
            if let text { text.lineLimit(1) }
            if chevron { Image(systemName: "chevron.up.chevron.down").font(.system(size: 8.5, weight: .semibold)).foregroundStyle(.secondary) }
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Capsule().fill(.white.opacity(on ? 0.14 : 0.07)))
        .contentShape(Capsule())
    }
}
