import AppKit
import MacToysCore
import SwiftUI

/// Sample displays and scenes for `MacToys --snapshot … --only powerdisplay`.
@MainActor
enum PowerDisplayPreviews {
    // MARK: Sample displays

    /// A 16" MacBook Pro panel: notch-height modes (1.55:1) and 16:10 modes, ProMotion rates.
    static let builtInModes: [DisplayModeInfo] = {
        let rates = [120, 60, 59.94, 50, 48, 47.95]
        let sizes: [(Int, Int)] = [(1728, 1117), (2056, 1329), (1496, 967), (1312, 848), (1168, 755),
                                   (1728, 1080), (2056, 1285), (1496, 935), (1312, 820), (1168, 730), (1280, 800)]
        var out: [DisplayModeInfo] = []
        var id: Int32 = 0
        for (w, h) in sizes {
            for r in rates {
                let native = w == 1728 && h == 1117
                out.append(DisplayModeInfo(width: w, height: h, pixelWidth: w * 2, pixelHeight: h * 2, refreshRate: r,
                                           ioFlags: 0x3 | (native ? DisplayModeInfo.nativeFlag : 0) | (native && r == 120 ? DisplayModeInfo.defaultFlag : 0),
                                           modeID: id))
                id += 1
            }
        }
        for r in rates {
            out.append(DisplayModeInfo(width: 3456, height: 2234, pixelWidth: 3456, pixelHeight: 2234, refreshRate: r,
                                       ioFlags: 0x3 | DisplayModeInfo.nativeFlag, modeID: id))
            id += 1
        }
        return out
    }()

    /// A 27" 4K monitor: HiDPI "looks like" modes, its native 3840 × 2160 and a few legacy sizes.
    static let externalModes: [DisplayModeInfo] = {
        var out: [DisplayModeInfo] = []
        var id: Int32 = 200
        func add(_ w: Int, _ h: Int, _ pw: Int, _ ph: Int, _ rates: [Double], flags: UInt32 = 0x3) {
            for r in rates {
                out.append(DisplayModeInfo(width: w, height: h, pixelWidth: pw, pixelHeight: ph, refreshRate: r, ioFlags: flags, modeID: id))
                id += 1
            }
        }
        for (w, h) in [(3200, 1800), (3008, 1692), (2560, 1440), (2304, 1296), (1920, 1080), (1600, 900), (1280, 720)] {
            add(w, h, w * 2, h * 2, [60, 50])
        }
        add(3840, 2160, 3840, 2160, [60, 50, 30, 24], flags: 0x3 | DisplayModeInfo.nativeFlag | DisplayModeInfo.defaultFlag)
        add(2560, 1440, 2560, 1440, [60])
        add(1920, 1080, 1920, 1080, [60, 50])
        add(4096, 2160, 4096, 2160, [60, 24])
        add(1280, 1024, 1280, 1024, [60])
        add(1024, 768, 1024, 768, [60])
        return out
    }()

    static let builtInID = "1552-41041-0"
    static let externalID = "4268-41204-808530508"

    struct Options {
        var linked = false
        var expanded: DisplayPane?
        var dimmed = false
    }

    /// A module with two sample displays, on throwaway settings.
    static func sampleModule(_ o: Options = Options()) -> PowerDisplayModule {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mactoys-preview-\(UUID().uuidString)")
        let module = PowerDisplayModule(store: SettingsStore(directory: dir))
        let builtIn = MonitorSnapshot(id: builtInID, number: 1, name: "Built-in Liquid Retina XDR Display", displayID: 1,
                                      kind: .builtIn, transport: "Built-in", capabilities: nil,
                                      readings: [.brightness: FeatureReading(current: o.dimmed ? 100 : 72, maximum: 100)],
                                      options: [:], rotation: 0)
        let caps = DDCCapabilities.parse("(prot(monitor)type(LCD)model(U2723QE)cmds(01 02 03 07 0C E3 F3)vcp(02 04 05 08 10 12 14(01 04 05 06 08 09 0B 0C) 16 18 1A 60(0F 11 1B) 62 AA(01 02) D6(01 04 05) DF)mccs_ver(2.1))")
        let dell = MonitorSnapshot(id: externalID, number: 2, name: "DELL U2723QE", displayID: 2, kind: .ddc,
                                   transport: "DDC/CI · USB-C", capabilities: caps,
                                   readings: [.brightness: FeatureReading(current: o.dimmed ? 0 : 55, maximum: 100),
                                              .contrast: FeatureReading(current: 75, maximum: 100),
                                              .volume: FeatureReading(current: 30, maximum: 100),
                                              .inputSource: FeatureReading(current: 0x1B, maximum: 0x1B)],
                                   options: [.inputSource: [0x0F, 0x11, 0x1B]], rotation: 0)
        let a = MonitorState(builtIn), b = MonitorState(dell)
        a.facts = DisplayFacts(isMain: true, mirrorOf: nil, bounds: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                               edrPotential: 16, gammaCapacity: 1024)
        b.facts = DisplayFacts(isMain: false, mirrorOf: nil, bounds: CGRect(x: 1728, y: -400, width: 2560, height: 1440),
                               edrPotential: 1, gammaCapacity: 1024)
        let colorLCD = URL(fileURLWithPath: "/Library/ColorSync/Profiles/Displays/Color LCD-37D8832A-2D66-02CA-B9F7-8F30A301B230.icc")
        let dellICC = URL(fileURLWithPath: "/Library/ColorSync/Profiles/Displays/DELL U2723QE-6A1F2C9E-4E0B-4A57-9C11-0D3B7E5AA210.icc")
        a.factoryProfile = colorLCD
        a.colorProfile = colorLCD
        b.factoryProfile = dellICC
        b.colorProfile = URL(fileURLWithPath: "/System/Library/ColorSync/Profiles/Display P3.icc")
        module.store.colorProfiles = [
            ColorProfile(url: colorLCD, name: "Color LCD"), ColorProfile(url: dellICC, name: "DELL U2723QE"),
            ColorProfile(url: URL(fileURLWithPath: "/System/Library/ColorSync/Profiles/Display P3.icc"), name: "Display P3"),
            ColorProfile(url: URL(fileURLWithPath: "/System/Library/ColorSync/Profiles/sRGB Profile.icc"), name: "sRGB IEC61966-2.1"),
            ColorProfile(url: URL(fileURLWithPath: "/System/Library/ColorSync/Profiles/AdobeRGB1998.icc"), name: "Adobe RGB (1998)"),
        ]
        let favorites = ["2560x1440/5120x2880", "1920x1080/3840x2160", "3840x2160/3840x2160"]
        module.settings.value.monitors[dell.id] = MonitorPrefs(showInputSource: true, favoriteModes: favorites)
        a.modes = ModeCatalog(modes: builtInModes, current: builtInModes.first { $0.width == 1728 && $0.height == 1117 && $0.refreshRate == 120 },
                              favorites: [])
        b.modes = ModeCatalog(modes: externalModes, current: externalModes.first { $0.width == 2560 && $0.isHiDPI && $0.refreshRate == 60 },
                              favorites: favorites)
        module.store.monitors = [a, b]
        module.store.visibleMonitors = [a, b]
        module.store.hasScanned = true
        module.store.nightShiftOn = false
        module.settings.value.profiles = [DisplayProfileRecord(id: 1, name: "Work"), DisplayProfileRecord(id: 2, name: "Movie")]
        module.settings.value.lastAppliedProfile = 1
        module.settings.value.linkedBrightness = o.linked
        module.settings.value.virtualDisplays = [VirtualDisplayConfig(name: "Stream 1080p", width: 3840, height: 2160)]
        if o.dimmed {
            module.settings.value.extraBrightness = true
            a.boost = 0.55
            b.softDim = 0.45
        }
        if let pane = o.expanded {
            let id = pane == .color ? builtIn.id : dell.id
            module.store.expanded = [id]
            module.store.panes[id] = pane
        }
        return module
    }

    static func flyout(linked: Bool = false, expanded: DisplayPane? = nil, dimmed: Bool = false) -> some View {
        let module = sampleModule(Options(linked: linked, expanded: expanded, dimmed: dimmed))
        return PowerDisplayFlyout(module: module, expanded: linked)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 20)
    }

    // MARK: Resolution confirmation

    static func confirmation() -> some View {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let info = ModeConfirmationInfo(displayID: 2, displayName: "DELL U2723QE",
                                        modeTitle: "3008 × 1692 · HiDPI · 60 Hz",
                                        deadline: now.addingTimeInterval(11.2))
        return ZStack {
            SampleDesktop(dark: true, window: CGRect(x: 28, y: 46, width: 500, height: 300))
            ModeConfirmationView(info: info, frozenNow: now, keep: {}, revert: {})
        }
    }

    // MARK: Picture in picture

    static func pip() -> some View {
        ZStack(alignment: .bottomTrailing) {
            SampleDesktop(dark: false)
            PiPWindowPreview(name: "DELL U2723QE")
                .frame(width: 480, height: 270)
                .padding(28)
        }
    }

    // MARK: Settings

    /// The settings page with the sample displays, tall enough for every section.
    static func settings() -> some View {
        PowerDisplaySettingsView(module: sampleModule(Options(dimmed: true)))
            .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: Virtual displays

    static func virtualDisplays() -> some View {
        let module = sampleModule()
        module.settings.value.virtualDisplays = [
            VirtualDisplayConfig(name: "HiDPI for LG 24MP59G", width: 3840, height: 2160, hiDPI: true, mirroredBy: externalID),
            VirtualDisplayConfig(name: "Stream 1080p", width: 1920, height: 1080, hiDPI: false, enabled: false),
            VirtualDisplayConfig(name: "Ultrawide test", width: 5120, height: 2160, hiDPI: true),
        ]
        module.store.connectedVirtual = Set(module.settings.value.virtualDisplays.filter(\.enabled).map(\.id))
        return Form {
            VirtualDisplaysSection(module: module, previewEditing: module.settings.value.virtualDisplays.first?.id)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// A believable desktop behind preview overlays: wallpaper, menu bar and two app windows.
struct SampleDesktop: View {
    let dark: Bool
    var window = CGRect(x: 60, y: 70, width: 560, height: 360)

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(red: 0.09, green: 0.13, blue: 0.36), Color(red: 0.24, green: 0.17, blue: 0.56),
                                    Color(red: 0.6, green: 0.25, blue: 0.53), Color(red: 0.88, green: 0.54, blue: 0.42)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            HStack(spacing: 18) {
                Image(systemName: "apple.logo").font(.system(size: 13, weight: .medium))
                Text(verbatim: "Xcode").font(.system(size: 13, weight: .bold))
                ForEach(["File", "Edit", "View", "Find", "Navigate", "Editor", "Product"], id: \.self) {
                    Text(verbatim: $0).font(.system(size: 13))
                }
                Spacer()
                Image(systemName: "sun.max").font(.system(size: 13, weight: .medium))
                Image(systemName: "wifi").font(.system(size: 13, weight: .medium))
                Text(verbatim: "Wed 4 Nov  21:48").font(.system(size: 13))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 28)
            .background(.black.opacity(0.2))
            SampleCodeWindow(dark: dark)
                .frame(width: window.width, height: window.height)
                .offset(x: window.minX, y: window.minY)
        }
        .clipped()
    }
}

/// A code editor window drawn in code (for the PiP picture and the desktop).
struct SampleCodeWindow: View {
    let dark: Bool

    private let lines: [(Int, String, Color)] = [
        (0, "struct ContentView: View {", .purple), (1, "@State private var level = 0.72", .teal),
        (1, "var body: some View {", .purple), (2, "Slider(value: $level)", .blue),
        (3, ".padding(.horizontal, 16)", .gray), (2, "Text(level, format: .percent)", .blue),
        (1, "}", .gray), (0, "}", .gray),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18),
                         Color(red: 0.16, green: 0.79, blue: 0.25)], id: \.self) { Circle().fill($0).frame(width: 11, height: 11) }
                Spacer()
                Text(verbatim: "ContentView.swift").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(dark ? .white.opacity(0.85) : .black.opacity(0.75))
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(dark ? Color(white: 0.2) : Color(white: 0.95))
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(["Sources", "ContentView.swift", "Model.swift", "Assets"], id: \.self) {
                        Text(verbatim: $0).font(.system(size: 11)).foregroundStyle(dark ? .white.opacity(0.6) : .black.opacity(0.55))
                    }
                    Spacer()
                }
                .padding(10)
                .frame(width: 130, alignment: .leading)
                .background(dark ? Color(white: 0.17) : Color(white: 0.93))
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                        HStack(spacing: 10) {
                            Text(verbatim: "\(i + 1)").foregroundStyle(.gray.opacity(0.6)).frame(width: 16, alignment: .trailing)
                            Text(verbatim: String(repeating: "    ", count: l.0) + l.1).foregroundStyle(l.2)
                        }
                        .font(.system(size: 11.5, design: .monospaced))
                    }
                    Spacer()
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(dark ? Color(white: 0.13) : .white)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(.black.opacity(0.15), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
    }
}

/// The PiP window as drawn in previews: a live picture of another display, hovered.
struct PiPWindowPreview: View {
    let name: String

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let s = size.width / 900
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [Color(red: 0.12, green: 0.2, blue: 0.42), Color(red: 0.42, green: 0.22, blue: 0.5),
                                        Color(red: 0.78, green: 0.45, blue: 0.4)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                // The other display's menu bar.
                Rectangle().fill(.black.opacity(0.25)).frame(height: max(6, 28 * s))
                SampleCodeWindow(dark: true)
                    .frame(width: 560, height: 360)
                    .scaleEffect(s, anchor: .topLeading)
                    .frame(width: 560 * s, height: 360 * s, alignment: .topLeading)
                    .offset(x: size.width * 0.08, y: size.height * 0.17)
                Image(systemName: "cursorarrow").font(.system(size: 13)).foregroundStyle(.white)
                    .shadow(radius: 1).offset(x: size.width * 0.66, y: size.height * 0.62)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .overlay(alignment: .top) {
                ZStack {
                    HStack {
                        Circle().fill(Color(red: 1, green: 0.37, blue: 0.34)).frame(width: 12, height: 12)
                            .overlay(Image(systemName: "xmark").font(.system(size: 6.5, weight: .black)).foregroundStyle(.black.opacity(0.55)))
                        Spacer()
                    }
                    .padding(10)
                    .frame(maxHeight: .infinity, alignment: .top)
                    PiPHoverLabel(name: name).padding(.top, 10)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 24, y: 12)
        }
    }
}
