import AppKit
import MacToysCore
import SwiftUI

/// Sample screens and captures for the preview scenes: believable app windows drawn in SwiftUI
/// and rendered to images, so every overlay can be checked offscreen.
@MainActor
enum ScreenshotPreviews {
    static let desktopSize = CGSize(width: 1280, height: 800)
    /// Where the dashboard window sits on the sample desktop (points, top-left origin).
    static let dashboardFrame = CGRect(x: 268, y: 92, width: 960, height: 600)
    static let notesFrame = CGRect(x: 52, y: 168, width: 380, height: 470)
    /// When the sample captures were taken: just before the menu bar clock, so titles stay put.
    static let sampleDate = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 4,
                                                                       hour: 14, minute: 31, second: 58)) ?? Date()

    static func scenes(module: ScreenshotModule) -> [PreviewScene] {
        [
            PreviewScene("area", size: desktopSize, wallpaper: false) { onDesktop { areaScene(adjusting: false, size: $0) } },
            PreviewScene("area-previous", size: desktopSize, wallpaper: false) { onDesktop { areaScene(adjusting: true, size: $0) } },
            PreviewScene("window", size: desktopSize, wallpaper: false) { onDesktop { windowScene(size: $0) } },
            PreviewScene("quickaccess", size: desktopSize, wallpaper: false) { onDesktop { quickAccessScene(size: $0) } },
            PreviewScene("annotate", size: framedSize(annotateSize), wallpaper: false) {
                framed(annotateScene(module: module), size: annotateSize)
            },
            PreviewScene("beautified", size: framedSize(beautifiedSize), wallpaper: false) { AnyView(beautifiedScene) },
            PreviewScene("pin", size: desktopSize, wallpaper: false) { onDesktop { pinScene(size: $0) } },
            PreviewScene("history", size: framedSize(historySize), wallpaper: false) { framed(historyScene, size: historySize) },
            PreviewScene("timer", size: CGSize(width: 780, height: 476), wallpaper: false) { onDesktop { timerScene(size: $0) } },
        ]
    }

    static let annotateSize = CGSize(width: 1280, height: 820)
    static let historySize = CGSize(width: 1000, height: 680)
    static let beautifiedSize = CGSize(width: 1200, height: 675)

    /// A desktop scene laid out at the snapshot's full size: the snapshot window adds its title bar
    /// to the scene height, and the desktop runs under it.
    private static func onDesktop<V: View>(@ViewBuilder _ content: @escaping (CGSize) -> V) -> AnyView {
        AnyView(GeometryReader { proxy in content(proxy.size) }.ignoresSafeArea())
    }

    /// Room around a window shown on the wallpaper.
    private static func framedSize(_ window: CGSize) -> CGSize {
        CGSize(width: window.width + 120, height: window.height + 80)
    }

    /// A tool window on the wallpaper, centered in the whole snapshot.
    private static func framed<V: View>(_ window: V, size: CGSize) -> AnyView {
        AnyView(window
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.black.opacity(0.18), lineWidth: 0.5))
            .compositingGroup()
            .shadow(color: .black.opacity(0.4), radius: 30, y: 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { BackdropSwatch(backdrop: .preset(.dusk)) }
            .ignoresSafeArea())
    }

    // MARK: Images

    private static var cache: [String: CGImage] = [:]

    private static func render<V: View>(_ key: String, size: CGSize, @ViewBuilder _ view: () -> V) -> CGImage? {
        if let hit = cache[key] { return hit }
        let renderer = ImageRenderer(content: view().frame(width: size.width, height: size.height).environment(\.colorScheme, .light))
        renderer.scale = 2
        guard let image = renderer.cgImage else { return nil }
        cache[key] = image
        return image
    }

    static var desktop: CGImage? { desktop(desktopSize) }

    /// The sample desktop at any size: the windows keep their places, the wallpaper fills the rest.
    static func desktop(_ size: CGSize) -> CGImage? {
        render("desktop-\(Int(size.width))x\(Int(size.height))", size: size) { SampleDesktop() }
    }

    /// The dashboard window alone, as a window capture (transparent corners, shadow).
    static var dashboardWindow: CGImage? {
        if let hit = cache["dashboardWindow"] { return hit }
        guard let raw = render("dashboardRaw", size: dashboardFrame.size, { SampleDashboardWindow() }),
              let rounded = roundCorners(raw, radius: 12 * 2),
              let framed = WindowFramer.compose(rounded, scale: 2, shadow: true, padding: 0) else { return nil }
        cache["dashboardWindow"] = framed
        return framed
    }

    static var notesWindow: CGImage? {
        if let hit = cache["notesWindow"] { return hit }
        guard let raw = render("notesRaw", size: notesFrame.size, { SampleNotesWindow() }),
              let rounded = roundCorners(raw, radius: 12 * 2),
              let framed = WindowFramer.compose(rounded, scale: 2, shadow: true, padding: 0) else { return nil }
        cache["notesWindow"] = framed
        return framed
    }

    /// An area of the desktop (points).
    static func area(_ r: CGRect) -> CGImage? {
        desktop?.cropping(to: AreaGeometry.pixelRect(r, scale: 2))
    }

    static var codeSnippet: CGImage? {
        render("code", size: CGSize(width: 460, height: 236)) { SampleCodeSnippet() }
    }

    /// The KPI cards and chart of the dashboard, as an area capture.
    static var chartArea: CGRect {
        CGRect(x: dashboardFrame.minX + 204, y: dashboardFrame.minY + 120, width: 732, height: 300)
    }

    private static func roundCorners(_ image: CGImage, radius: CGFloat) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let r = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.clip()
        ctx.draw(image, in: r)
        return ctx.makeImage()
    }

    // MARK: Scenes

    private static func desktopBackground(_ size: CGSize) -> some View {
        Group {
            if let desktop = desktop(size) { Image(decorative: desktop, scale: 2) } else { Color.black }
        }
        .frame(width: size.width, height: size.height)
    }

    private static func display(_ size: CGSize) -> SelectionModel.Display {
        SelectionModel.Display(screen: nil, axFrame: CGRect(origin: .zero, size: size), scale: 2, snapshot: desktop(size),
                               name: "Built-in Retina Display")
    }

    static func areaScene(adjusting: Bool, size: CGSize) -> some View {
        let model = SelectionModel(mode: .area, displays: [display(size)], frozen: true, showMagnifier: true, showCrosshair: true,
                                   canSwitchMode: true)
        model.active = 0
        model.selectionDisplay = 0
        let r = chartArea
        model.selection = r
        if adjusting {
            model.adjusting = true
            model.pointer = CGPoint(x: r.midX + 40, y: r.minY - 60)
        } else {
            model.dragging = true
            model.pointer = CGPoint(x: r.maxX, y: r.maxY)
            if let desktop = desktop(size) {
                model.loupe = LoupeCard.patch(of: desktop, centerX: Int(r.maxX * 2), centerY: Int(r.maxY * 2),
                                              cells: SelectionModel.loupeCells)
            }
        }
        return ZStack(alignment: .topLeading) {
            desktopBackground(size)
            SelectionOverlayView(model: model, index: 0)
        }
    }

    static func windowScene(size: CGSize) -> some View {
        let model = SelectionModel(mode: .window, displays: [display(size)], frozen: true, showMagnifier: true, showCrosshair: true,
                                   canSwitchMode: true)
        model.active = 0
        model.pointer = CGPoint(x: 700, y: 400)
        model.hoveredWindow = CaptureWindow(id: 1, pid: 0, app: "Safari", title: "Q3 Overview — Northwind Analytics",
                                            frame: dashboardFrame, bundleID: "com.apple.Safari")
        return ZStack(alignment: .topLeading) {
            desktopBackground(size)
            SelectionOverlayView(model: model, index: 0)
        }
    }

    private static func sampleItems() -> [CaptureItem] {
        var items: [CaptureItem] = []
        if let img = area(chartArea) { items.append(CaptureItem(image: img, scale: 2, kind: .area, date: sampleDate)) }
        if let img = notesWindow { items.append(CaptureItem(image: img, scale: 2, kind: .window, date: sampleDate)) }
        if let img = codeSnippet {
            let item = CaptureItem(image: img, scale: 2, kind: .area, date: sampleDate)
            var style = BeautifyStyle()
            style.backdrop = .preset(.ocean)
            style.padding = 40
            item.document.beautify = style
            items.append(item)
        }
        return items
    }

    static func quickAccessScene(size: CGSize) -> some View {
        let items = sampleItems()
        let width = OverlaySize.medium.width
        let sizes = items.map { QuickAccessLayout.cardSize(image: $0.pointSize, width: width) }
        // Cocoa frames in the "screen" below a 24 pt menu bar; flipped for SwiftUI below.
        let visible = CGRect(x: 0, y: 0, width: size.width, height: size.height - 24)
        let frames = QuickAccessLayout.frames(sizes: sizes, corner: .bottomLeft, in: visible)
        let models = items.enumerated().map { i, item in
            let model = QuickAccessCardModel(item: item, thumbnail: QuickAccessController.thumbnail(item, width: width))
            model.hovering = i == 0
            return model
        }
        return ZStack(alignment: .topLeading) {
            desktopBackground(size)
            ForEach(Array(zip(models, frames).enumerated()), id: \.offset) { _, pair in
                QuickAccessCardView(model: pair.0, actions: QuickAccessActions())
                    .frame(width: pair.1.width, height: pair.1.height)
                    .compositingGroup()
                    .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
                    .position(x: pair.1.midX, y: size.height - pair.1.midY)
            }
        }
    }

    static func annotatedDocumentItem() -> CaptureItem? {
        guard let img = area(CGRect(x: dashboardFrame.minX + 180, y: dashboardFrame.minY + 44, width: 780, height: 556)) else {
            return nil
        }
        let item = CaptureItem(image: img, scale: 2, kind: .area, date: sampleDate)
        let red = MarkupPalette.colors[0], yellow = MarkupPalette.colors[2], blue = MarkupPalette.colors[4]
        item.document.items = [
            MarkupItem(shape: .highlighter([CGPoint(x: 34, y: 482), CGPoint(x: 160, y: 482)]), color: yellow, size: .large),
            MarkupItem(shape: .rectangle(CGRect(x: 17, y: 78, width: 188, height: 108), filled: false), color: red, size: .medium),
            MarkupItem(shape: .arrow(from: CGPoint(x: 322, y: 298), to: CGPoint(x: 150, y: 192), bend: -38), color: red, size: .medium),
            MarkupItem(shape: .text(MarkupText(origin: CGPoint(x: 330, y: 304), string: "Best quarter so far", style: .solid)),
                       color: red, size: .medium),
            MarkupItem(shape: .counter(center: CGPoint(x: 17, y: 78), number: 1), color: blue, size: .medium),
            MarkupItem(shape: .counter(center: CGPoint(x: 638, y: 232), number: 2), color: blue, size: .medium),
            MarkupItem(shape: .ellipse(CGRect(x: 640, y: 228, width: 88, height: 50), filled: false), color: blue, size: .small),
            MarkupItem(shape: .pixelate(CGRect(x: 580, y: 470, width: 166, height: 23)), color: red, size: .medium),
        ]
        var style = BeautifyStyle()
        style.backdrop = .preset(.aurora)
        style.padding = 48
        style.cornerRadius = 12
        item.document.beautify = style
        return item
    }

    static func annotateScene(module: ScreenshotModule) -> some View {
        Group {
            if let item = annotatedDocumentItem() {
                let model = AnnotateModel(item: item, settings: module.settings.value)
                model.tool = .arrow
                model.canUndo = true
                model.selection = item.document.items[2].id
                model.curvedArrows = true
                return AnyView(AnnotateView(model: model, chrome: true))
            }
            return AnyView(Color.clear)
        }
    }

    static var beautifiedScene: some View {
        let image: CGImage? = annotatedDocumentItem().map { item in
            item.document.beautify?.aspect = .sixteenNine
            item.document.beautify?.padding = 56
            return item.rendered
        }
        // The exported image, shown at its own size the way a viewer would.
        return Group {
            if let image { Image(decorative: image, scale: CGFloat(image.width) / beautifiedSize.width) }
        }
        .frame(width: beautifiedSize.width, height: beautifiedSize.height)
        .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
        .ignoresSafeArea()
    }

    static func pinScene(size: CGSize) -> some View {
        let model = PinModel(image: codeSnippet.map { NSImage(cgImage: $0, size: CGSize(width: 460, height: 236)) } ?? NSImage())
        model.hovering = true
        return ZStack(alignment: .topLeading) {
            desktopBackground(size)
            PinView(model: model, actions: PinActions())
                .frame(width: 460, height: 236)
                .compositingGroup()
                .shadow(color: .black.opacity(0.45), radius: 22, y: 10)
                .position(x: 960, y: 560)
        }
    }

    static var historyScene: some View {
        let history = CaptureHistory(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("MacToys Screenshot Preview", isDirectory: true))
        var entries: [HistoryEntry] = []
        // Today at the menu bar clock's time, so the tiles read the same whenever this renders.
        let now = Calendar.current.date(bySettingHour: 14, minute: 32, second: 0, of: Date()) ?? Date()
        func add(_ image: CGImage?, kind: CaptureKind, minutesAgo: Double, beautify: BackdropPreset? = nil) {
            guard let image else { return }
            let item = CaptureItem(image: image, scale: 2, kind: kind)
            if let beautify {
                var style = BeautifyStyle()
                style.backdrop = .preset(beautify)
                style.padding = 36
                item.document.beautify = style
            }
            let rendered = item.rendered
            let id = UUID()
            entries.append(HistoryEntry(id: id, date: now.addingTimeInterval(-minutesAgo * 60), kind: kind,
                                        pixelWidth: image.width, pixelHeight: image.height, scale: 2,
                                        bytes: Int64(image.width * image.height) / 3, savedPath: nil))
            if let thumb = CaptureHistory.thumbnail(rendered) { history.setThumbnail(NSImage(cgImage: thumb, size: .zero), for: id) }
        }
        add(area(chartArea), kind: .area, minutesAgo: 4)
        add(notesWindow, kind: .window, minutesAgo: 18)
        add(codeSnippet, kind: .area, minutesAgo: 41, beautify: .ocean)
        add(desktop, kind: .screen, minutesAgo: 75)
        add(dashboardWindow, kind: .window, minutesAgo: 60 * 26, beautify: .dusk)
        add(area(CGRect(x: dashboardFrame.minX + 204, y: dashboardFrame.minY + 430, width: 520, height: 150)), kind: .area,
            minutesAgo: 60 * 27)
        add(area(CGRect(x: 0, y: 0, width: 640, height: 24)), kind: .area, minutesAgo: 60 * 28)
        history.setPreviewEntries(entries)
        return HistoryView(history: history, actions: HistoryActions(), areaShortcut: ScreenshotSettings().areaShortcut, chrome: true)
    }

    /// The countdown over the dashboard's content.
    static func timerScene(size: CGSize) -> some View {
        let model = Countdown.Model(seconds: 5)
        model.remaining = 3
        model.progress = 0.6
        let crop = CGRect(x: dashboardFrame.minX + 180, y: dashboardFrame.minY + 44, width: size.width, height: size.height)
        return ZStack {
            if let img = area(crop) {
                Image(decorative: img, scale: 2)
            }
            CountdownView(model: model) {}
                .frame(width: 168, height: 196)
        }
        .frame(width: size.width, height: size.height)
    }
}

// MARK: - Sample content

/// Wallpaper, menu bar and two app windows.
struct SampleDesktop: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            BackdropSwatch(backdrop: .preset(.dusk))
            SampleNotesWindow()
                .frame(width: ScreenshotPreviews.notesFrame.width, height: ScreenshotPreviews.notesFrame.height)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .compositingGroup()
                .shadow(color: .black.opacity(0.35), radius: 20, y: 10)
                .offset(x: ScreenshotPreviews.notesFrame.minX, y: ScreenshotPreviews.notesFrame.minY)
            SampleDashboardWindow()
                .frame(width: ScreenshotPreviews.dashboardFrame.width, height: ScreenshotPreviews.dashboardFrame.height)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .compositingGroup()
                .shadow(color: .black.opacity(0.42), radius: 26, y: 14)
                .offset(x: ScreenshotPreviews.dashboardFrame.minX, y: ScreenshotPreviews.dashboardFrame.minY)
            menuBar
        }
    }

    private var menuBar: some View {
        HStack(spacing: 18) {
            Image(systemName: "apple.logo").font(.system(size: 13, weight: .semibold))
            Text(verbatim: "Safari").font(.system(size: 13, weight: .bold))
            ForEach(["File", "Edit", "View", "History", "Bookmarks", "Window", "Help"], id: \.self) {
                Text(verbatim: $0).font(.system(size: 13))
            }
            Spacer()
            Image(systemName: "battery.75percent")
            Image(systemName: "wifi")
            Image(systemName: "magnifyingglass")
            Text(verbatim: "Wed 4 Nov  14:32").font(.system(size: 13))
        }
        .font(.system(size: 13))
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .frame(height: 24)
        .background(.black.opacity(0.18))
    }
}

/// A browser window with an analytics dashboard.
struct SampleDashboardWindow: View {
    var body: some View {
        VStack(spacing: 0) {
            titleBar
            HStack(spacing: 0) {
                sidebar
                content
            }
        }
        .background(Color.white)
    }

    private var titleBar: some View {
        HStack(spacing: 8) {
            ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18),
                     Color(red: 0.16, green: 0.79, blue: 0.25)], id: \.self) { Circle().fill($0).frame(width: 12, height: 12) }
            Image(systemName: "sidebar.left").foregroundStyle(.secondary).padding(.leading, 14)
            Image(systemName: "chevron.left").foregroundStyle(.secondary).padding(.leading, 8)
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "lock.fill").font(.system(size: 10))
                Text(verbatim: "analytics.northwind.app/overview")
            }
            .font(.system(size: 12.5))
            .foregroundStyle(Color(white: 0.3))
            .frame(width: 340, height: 28)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.9)))
            Spacer()
            Image(systemName: "square.and.arrow.up").foregroundStyle(.secondary)
            Image(systemName: "plus").foregroundStyle(.secondary).padding(.leading, 10)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(Color(white: 0.965))
        .overlay(alignment: .bottom) { Rectangle().fill(Color(white: 0.86)).frame(height: 1) }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 6).fill(Tint.indigo.gradient).frame(width: 22, height: 22)
                    .overlay(Image(systemName: "chart.line.uptrend.xyaxis").font(.system(size: 11, weight: .bold)).foregroundStyle(.white))
                Text(verbatim: "Northwind").font(.system(size: 14, weight: .bold))
            }
            .padding(.bottom, 14)
            ForEach(Array([("square.grid.2x2", "Overview"), ("doc.text.magnifyingglass", "Reports"), ("line.3.horizontal.decrease", "Funnels"),
                           ("person.2", "Customers"), ("bell", "Alerts"), ("gearshape", "Settings")].enumerated()), id: \.offset) { i, entry in
                HStack(spacing: 9) {
                    Image(systemName: entry.0).frame(width: 18)
                    Text(verbatim: entry.1)
                    Spacer()
                }
                .font(.system(size: 13, weight: i == 0 ? .semibold : .regular))
                .foregroundStyle(i == 0 ? Tint.indigo.color : Color(white: 0.3))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 7).fill(i == 0 ? Tint.indigo.color.opacity(0.1) : .clear))
            }
            Spacer()
        }
        .padding(16)
        .frame(width: 180)
        .background(Color(white: 0.975))
        .overlay(alignment: .trailing) { Rectangle().fill(Color(white: 0.9)).frame(width: 1) }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: "Q3 Overview").font(.system(size: 22, weight: .bold))
                    Text(verbatim: "Jul 1 – Sep 30, 2026 · All regions").font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(verbatim: "Export").font(.system(size: 12.5, weight: .medium))
                    .padding(.horizontal, 12).frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 7).strokeBorder(Color(white: 0.85)))
            }
            HStack(spacing: 12) {
                kpi("Revenue", "$482.1K", "+12.4%", up: true)
                kpi("Active users", "12,408", "+3.1%", up: true)
                kpi("Conversion", "3.8%", "−0.2%", up: false)
                kpi("Avg. order", "$64.20", "+5.6%", up: true)
            }
            chart
            table
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func kpi(_ title: String, _ value: String, _ delta: String, up: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: title).font(.system(size: 12)).foregroundStyle(.secondary)
            Text(verbatim: value).font(.system(size: 21, weight: .semibold).monospacedDigit())
            Text(verbatim: delta).font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(up ? Color(red: 0.12, green: 0.6, blue: 0.3) : Color(red: 0.85, green: 0.25, blue: 0.2))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.975)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(white: 0.9)))
    }

    private var chart: some View {
        let values: [CGFloat] = [0.32, 0.38, 0.35, 0.47, 0.44, 0.52, 0.5, 0.61, 0.58, 0.7, 0.66, 0.82, 0.78]
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(verbatim: "Revenue by week").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(verbatim: "Weekly").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                let pts = values.enumerated().map { CGPoint(x: w * CGFloat($0.offset) / CGFloat(values.count - 1), y: h * (1 - $0.element)) }
                ZStack {
                    ForEach(0..<4, id: \.self) { i in
                        Rectangle().fill(Color(white: 0.92)).frame(height: 1).position(x: w / 2, y: h * CGFloat(i) / 3)
                    }
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: h))
                        for pt in pts { p.addLine(to: pt) }
                        p.addLine(to: CGPoint(x: w, y: h))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [Tint.indigo.color.opacity(0.22), Tint.indigo.color.opacity(0.02)],
                                         startPoint: .top, endPoint: .bottom))
                    Path { p in
                        p.move(to: pts[0])
                        for pt in pts.dropFirst() { p.addLine(to: pt) }
                    }
                    .stroke(Tint.indigo.color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    Circle().fill(.white).frame(width: 9, height: 9).overlay(Circle().strokeBorder(Tint.indigo.color, lineWidth: 2.5))
                        .position(pts[11])
                }
            }
            .frame(height: 120)
            HStack {
                ForEach(["Jul", "Aug", "Sep"], id: \.self) { Text(verbatim: $0); if $0 != "Sep" { Spacer() } }
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(white: 0.9)))
    }

    private var table: some View {
        VStack(spacing: 0) {
            ForEach(Array([("/pricing", "18,204", "4.2%", "maria.lopez@northwind.app"),
                           ("/docs/getting-started", "12,980", "3.1%", "j.chen@northwind.app"),
                           ("/blog/q3-launch", "9,431", "2.7%", "sam.okafor@northwind.app")].enumerated()), id: \.offset) { i, row in
                HStack {
                    Text(verbatim: row.0).font(.system(size: 12.5, design: .monospaced))
                    Spacer()
                    Text(verbatim: row.1).font(.system(size: 12.5).monospacedDigit()).frame(width: 70, alignment: .trailing)
                    Text(verbatim: row.2).font(.system(size: 12.5).monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .trailing)
                    Text(verbatim: row.3).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 190, alignment: .trailing)
                }
                .padding(.horizontal, 14)
                .frame(height: 30)
                if i < 2 { Rectangle().fill(Color(white: 0.92)).frame(height: 1) }
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.985)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(white: 0.9)))
    }
}

/// A notes window with a launch checklist.
struct SampleNotesWindow: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18),
                         Color(red: 0.16, green: 0.79, blue: 0.25)], id: \.self) { Circle().fill($0).frame(width: 12, height: 12) }
                Spacer()
                Image(systemName: "square.and.pencil").foregroundStyle(Color(red: 0.85, green: 0.65, blue: 0.1))
            }
            .padding(.horizontal, 16)
            .frame(height: 42)
            VStack(alignment: .leading, spacing: 12) {
                Text(verbatim: "Launch checklist").font(.system(size: 22, weight: .bold))
                Text(verbatim: "Wednesday 4 November 2026 at 09:12").font(.system(size: 11.5)).foregroundStyle(.secondary)
                ForEach(Array([("Final QA pass on 0.9.4", true), ("Update screenshots in the docs", true),
                               ("Record the demo video", false), ("Send release notes to the team", false),
                               ("Post the announcement", false), ("Celebrate 🎉", false)].enumerated()), id: \.offset) { _, entry in
                    HStack(spacing: 10) {
                        Image(systemName: entry.1 ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 17))
                            .foregroundStyle(entry.1 ? Color(red: 0.95, green: 0.7, blue: 0.1) : Color(white: 0.7))
                        Text(verbatim: entry.0)
                            .font(.system(size: 14))
                            .strikethrough(entry.1, color: Color(white: 0.6))
                            .foregroundStyle(entry.1 ? Color(white: 0.55) : Color(white: 0.15))
                    }
                }
                Text(verbatim: "Hero shot: the annotate window with the aurora background, 16:9.")
                    .font(.system(size: 13.5))
                    .foregroundStyle(Color(white: 0.25))
                    .padding(.top, 8)
            }
            .padding(.horizontal, 26)
            .padding(.top, 6)
            Spacer()
        }
        .background(Color(red: 1, green: 0.995, blue: 0.97))
    }
}

/// A code editor excerpt (the pinned reference).
struct SampleCodeSnippet: View {
    private static let keyword = Color(red: 0.99, green: 0.37, blue: 0.64)
    private static let type = Color(red: 0.36, green: 0.85, blue: 0.99)
    private static let plain = Color(white: 0.9)
    private static let comment = Color(white: 0.5)
    private static let number = Color(red: 0.85, green: 0.79, blue: 0.48)

    private static let lines: [[(String, Color)]] = [
        [("// Frame the capture before it is shared", comment)],
        [("let ", keyword), ("layout = ", plain), ("BeautifyLayout", type), (".make(", plain)],
        [("    content: size,", plain)],
        [("    style: style,", plain)],
        [("    scale: ", plain), ("2", number), (")", plain)],
        [("guard ", keyword), ("layout.canvas.width > ", plain), ("0", number), (" else { ", plain), ("return nil", keyword), (" }", plain)],
        [("return ", keyword), ("Beautifier", type), (".render(image, layout)", plain)],
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(Self.lines.enumerated()), id: \.offset) { _, runs in
                Text(Self.attributed(runs)).lineLimit(1)
            }
        }
        .font(.system(size: 13, design: .monospaced))
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(red: 0.12, green: 0.12, blue: 0.15))
    }

    private static func attributed(_ runs: [(String, Color)]) -> AttributedString {
        var out = AttributedString()
        for (text, color) in runs {
            var run = AttributedString(text)
            run.foregroundColor = color
            out += run
        }
        return out
    }
}
