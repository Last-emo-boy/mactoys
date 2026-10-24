import AppKit
import MacToysCore
import SwiftUI
import UniformTypeIdentifiers

/// The machine matrix: up to four Macs in a row or a 2×2 grid. Drag a Mac onto another slot to
/// rearrange; drop a file on a Mac to send it there.
struct MachineMatrixView: View {
    struct Tile: Identifiable, Equatable {
        let id: UUID
        let name: String
        let status: MWBStatus
        let isThisMac: Bool
        /// Driven by the keyboard and mouse right now.
        let isActive: Bool
        let detail: String
        let displayCount: Int
    }

    let tiles: [Tile?]
    let singleRow: Bool
    let wrap: Bool
    var onMove: ((Int, Int) -> Void)?
    var onDropFile: ((UUID, URL) -> Void)?
    var onRemove: ((UUID) -> Void)?
    @State private var targeted: Int?

    var body: some View {
        let slots = (0..<4).map { $0 < tiles.count ? tiles[$0] : nil }
        HStack(spacing: 10) {
            if wrap { wrapMark }
            if singleRow {
                HStack(spacing: 12) { ForEach(0..<4, id: \.self) { slot($0, slots[$0]) } }
            } else {
                Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                    GridRow { slot(0, slots[0]); slot(1, slots[1]) }
                    GridRow { slot(2, slots[2]); slot(3, slots[3]) }
                }
            }
            if wrap { wrapMark }
        }
        .frame(maxWidth: .infinity)
    }

    private var wrapMark: some View {
        Image(systemName: "arrow.triangle.2.circlepath")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .help("Wrap mouse: the ends connect")
    }

    @ViewBuilder private func slot(_ index: Int, _ tile: Tile?) -> some View {
        Group {
            if let tile { tileView(tile, index: index) } else { emptySlot(index) }
        }
        .frame(width: 148, height: 104)
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(targeted == index ? Color.accentColor : .clear, lineWidth: 2))
        .onDrop(of: [.fileURL, .plainText], isTargeted: Binding(get: { targeted == index },
                                                                 set: { targeted = $0 ? index : (targeted == index ? nil : targeted) })) { providers in
            drop(providers, on: index, tile: tile)
        }
    }

    private func tileView(_ t: Tile, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top) {
                Image(systemName: t.displayCount > 1 ? "display.2" : (t.isThisMac ? "laptopcomputer" : "desktopcomputer"))
                    .font(.system(size: 19))
                    .frame(height: 22, alignment: .leading)
                    .foregroundStyle(t.isActive ? Color.accentColor : .primary)
                Spacer()
                Text("\(index + 1)")
                    .font(.system(size: 10.5, weight: .bold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.primary.opacity(0.07)))
            }
            Text(t.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
            HStack(spacing: 5) {
                Circle().fill(RGBA(hex: t.status.colorHex)?.color ?? .gray).frame(width: 7, height: 7)
                Text(t.isThisMac ? "This Mac" : t.status.title).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(t.detail).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1)
        }
        .padding(11)
        .frame(width: 148, height: 104, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(t.isActive ? Color.accentColor.opacity(0.1) : Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(t.isActive ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.1)))
        .onDrag { NSItemProvider(object: "mwb-slot:\(index)" as NSString) }
        .contextMenu {
            if !t.isThisMac, let onRemove {
                Button("Remove from layout") { onRemove(t.id) }
            }
        }
    }

    private func emptySlot(_ index: Int) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
            .foregroundStyle(Color.primary.opacity(0.2))
            .overlay(Text("Empty").font(.system(size: 11)).foregroundStyle(.tertiary))
    }

    private func drop(_ providers: [NSItemProvider], on index: Int, tile: Tile?) -> Bool {
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                guard let tile, !tile.isThisMac, let onDropFile else { return false }
                let id = tile.id
                _ = p.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                    guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    DispatchQueue.main.async { onDropFile(id, url) }
                }
                return true
            }
            if p.canLoadObject(ofClass: NSString.self) {
                _ = p.loadObject(ofClass: NSString.self) { object, _ in
                    guard let s = object as? String, s.hasPrefix("mwb-slot:"), let from = Int(s.dropFirst(9)) else { return }
                    DispatchQueue.main.async { onMove?(from, index) }
                }
                return true
            }
        }
        return false
    }
}

/// Sample matrix for offscreen previews.
struct MWBMatrixPreview: View {
    var body: some View {
        let me = UUID(), studio = UUID(), air = UUID()
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                ModuleIcon(symbol: "display.2", tint: .orange, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Device layout").font(.headline)
                    Text("Drag Macs to arrange them · drop a file on a Mac to send it").font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Spacer()
                Label("2 connected", systemImage: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(.green)
            }
            MachineMatrixView(tiles: [
                .init(id: me, name: "w33d’s MacBook Pro", status: .connected, isThisMac: true, isActive: false,
                      detail: "192.168.1.12", displayCount: 1),
                .init(id: studio, name: "Studio", status: .connected, isThisMac: false, isActive: true,
                      detail: "192.168.1.20", displayCount: 2),
                .init(id: air, name: "MacBook Air", status: .handshaking, isThisMac: false, isActive: false,
                      detail: "Handshaking", displayCount: 1),
                nil,
            ], singleRow: true, wrap: true)
            HStack(spacing: 14) {
                ForEach([MWBStatus.connected, .connecting, .handshaking, .invalidKey, .timeout], id: \.self) { s in
                    HStack(spacing: 5) {
                        Circle().fill(RGBA(hex: s.colorHex)?.color ?? .gray).frame(width: 7, height: 7)
                        Text(s.title).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea()
    }
}

struct MWBSettingsView: View {
    let module: MouseWithoutBordersModule
    @State private var revealKey = false
    @State private var confirmNewKey = false
    @State private var otherKey = ""
    @State private var otherHost = ""
    @State private var connectError: String?
    @State private var newHost = ""

    var body: some View {
        @Bindable var s = module.settings
        let _ = module.live.revision
        SettingsPage(module: module) {
            hero(s.value)
        } content: {
            securitySection
            Section("Layout") {
                Toggle(isOn: $s.value.layout.singleRow) {
                    RowLabel("Devices in a single row", subtitle: "Otherwise a 2×2 grid: slots 1 2 on top, 3 4 below.")
                }
                .onChange(of: s.value.layout.singleRow) { _, _ in s.value.layout.revision = Date().timeIntervalSince1970 }
                Toggle(isOn: $s.value.wrapMouse) {
                    RowLabel("Wrap mouse", subtitle: "Past the last Mac the pointer comes back on the first, and the other way round.")
                }
                Toggle(isOn: $s.value.autoAddMachines) {
                    RowLabel("Add Macs that connect to free slots", subtitle: "Macs with the same security key join the layout automatically.")
                }
            }
            Section("Easy Mouse") {
                Toggle(isOn: $s.value.easyMouse) {
                    RowLabel("Switch Macs at the screen edge", subtitle: "Move the pointer past the edge toward the neighboring Mac.")
                }
                Picker("Switch", selection: $s.value.easyMouseModifier) {
                    ForEach(MWBSettings.EasyMouseModifier.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .disabled(!s.value.easyMouse)
                Toggle(isOn: $s.value.blockCorners) {
                    RowLabel("Block switching at screen corners", subtitle: "Avoids switching by accident when reaching for a corner.")
                }
                Toggle(isOn: $s.value.disableEasyMouseInFullScreen) {
                    RowLabel("Don’t switch while an app is full screen on this Mac")
                }
                if s.value.disableEasyMouseInFullScreen {
                    ExcludedAppsEditor("Full-screen apps that still allow switching", apps: $s.value.fullScreenIgnoredApps)
                }
                Toggle(isOn: $s.value.hidePointerAtEdge) {
                    RowLabel("Hide this Mac’s pointer while controlling another", subtitle: "Otherwise it waits at the edge where it left.")
                }
            }
            Section("Clipboard and files") {
                Toggle(isOn: $s.value.shareClipboard) {
                    RowLabel("Share clipboard", subtitle: "Text and images go to every Mac; a copied file goes to the Mac you move to.")
                }
                Toggle(isOn: $s.value.transferFiles) {
                    RowLabel("Transfer files", subtitle: "Copy and paste a single file, drag one across the screen edge, or drop it on a Mac above. Received files go to Downloads.")
                }
                SliderRow("File size limit", value: $s.value.maxFileSizeMB, in: 1...1000, step: 1) { "\(Int($0)) MB" }
                    .disabled(!s.value.transferFiles)
                sendFileRow
                transfersList
            }
            Section("Other Macs") {
                Toggle(isOn: $s.value.blockScreenSaver) {
                    RowLabel("Block the screen saver on other Macs", subtitle: "While you use any Mac of the group.")
                }
                Toggle(isOn: $s.value.showStatusMessages) { RowLabel("Show clipboard and connection messages") }
            }
            Section("Shortcuts") {
                ShortcutRow("Switch to Mac 1", shortcut: $s.value.machine1Shortcut)
                ShortcutRow("Switch to Mac 2", shortcut: $s.value.machine2Shortcut)
                ShortcutRow("Switch to Mac 3", shortcut: $s.value.machine3Shortcut)
                ShortcutRow("Switch to Mac 4", shortcut: $s.value.machine4Shortcut)
                ShortcutRow("Toggle Easy Mouse", shortcut: $s.value.easyMouseShortcut)
                ShortcutRow("Lock all Macs", subtitle: "Press twice.", shortcut: $s.value.lockShortcut)
                ShortcutRow("Reconnect", shortcut: $s.value.reconnectShortcut)
            }
            connectionsSection
        }
        .alert("Generate a new security key?", isPresented: $confirmNewKey) {
            Button("New Key", role: .destructive) { module.generateNewKey() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every Mac disconnects until you enter the new key on them.")
        }
    }

    private func hero(_ v: MWBSettings) -> some View {
        HeroCard(tint: .orange) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Device layout").font(.headline)
                    Spacer()
                    let n = module.connectedCount
                    Label(n == 0 ? "No other Macs connected" : "\(n) connected",
                          systemImage: n == 0 ? "circle.dotted" : "checkmark.circle.fill")
                        .font(.system(size: 12)).foregroundStyle(n == 0 ? Color.secondary : Color.green)
                    Button("Refresh connections") { module.controller?.reconnect() }.controlSize(.small)
                }
                MachineMatrixView(
                    tiles: module.tiles(), singleRow: v.layout.singleRow, wrap: v.wrapMouse,
                    onMove: { from, to in
                        module.settings.update {
                            $0.layout.move(from: from, to: to)
                            $0.layout.revision = Date().timeIntervalSince1970
                        }
                    },
                    onDropFile: { id, url in module.controller?.send(file: url, to: id) },
                    onRemove: { id in
                        module.settings.update {
                            $0.layout.remove(id)
                            $0.layout.revision = Date().timeIntervalSince1970
                        }
                    })
                Text("Drag a Mac onto another slot to rearrange. Drop a file on a Mac to send it.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private var securitySection: some View {
        Section("Security key") {
            LabeledContent {
                HStack(spacing: 8) {
                    let key = module.securityKey ?? ""
                    Text(revealKey ? SecurityKey.formatted(key) : String(repeating: "•", count: 19))
                        .font(.system(size: 13, design: .monospaced))
                        .textSelection(.enabled)
                    Button { revealKey.toggle() } label: { Image(systemName: revealKey ? "eye.slash" : "eye") }
                        .buttonStyle(.borderless)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(SecurityKey.formatted(key), forType: .string)
                    }
                    Button("New Key…") { confirmNewKey = true }
                }
            } label: {
                RowLabel("This group’s key", subtitle: "Enter it on your other Macs. Only Macs with the key can connect; everything is encrypted.")
            }
            VStack(alignment: .leading, spacing: 8) {
                RowLabel("Connect to another Mac", subtitle: "Enter the key shown on that Mac. The address is optional: Macs on the same network find each other.")
                HStack {
                    TextField("Security key", text: $otherKey, prompt: Text("ABCD-EFGH-JKLM-NPQR"))
                        .font(.system(size: 12.5, design: .monospaced))
                    TextField("Address", text: $otherHost, prompt: Text("Name or IP (optional)"))
                        .frame(width: 180)
                    Button("Connect") {
                        connectError = module.connect(key: otherKey, host: otherHost)
                        if connectError == nil { otherKey = ""; otherHost = "" }
                    }
                    .disabled(otherKey.isEmpty)
                }
                if let connectError { Text(connectError).font(.system(size: 11.5)).foregroundStyle(.red) }
            }
        }
    }

    private var sendFileRow: some View {
        let others = module.tiles().compactMap { $0 }.filter { !$0.isThisMac && $0.status == .connected }
        return LabeledContent {
            Menu("Send File…") {
                ForEach(others) { t in
                    Button(t.name) {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = false
                        if panel.runModal() == .OK, let url = panel.url { module.controller?.send(file: url, to: t.id) }
                    }
                }
            }
            .fixedSize()
            .disabled(others.isEmpty || !module.settings.value.transferFiles)
        } label: {
            RowLabel("Send a file", subtitle: "Saved in the Downloads folder of the other Mac.")
        }
    }

    @ViewBuilder private var transfersList: some View {
        if let transfers = module.controller?.transfers, !transfers.transfers.isEmpty {
            ForEach(transfers.transfers.prefix(6)) { t in
                HStack(spacing: 10) {
                    Image(systemName: t.direction == .incoming ? "arrow.down.doc" : "arrow.up.doc").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(t.name).lineLimit(1).truncationMode(.middle)
                        switch t.state {
                        case .running:
                            ProgressView(value: t.fraction).controlSize(.small)
                        case .done:
                            Text("\(t.direction == .incoming ? "From" : "To") \(t.peerName) · \(ByteCountFormatter.string(fromByteCount: Int64(t.size), countStyle: .file))")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        case .failed(let why):
                            Text(why).font(.system(size: 11)).foregroundStyle(.red)
                        case .cancelled:
                            Text("Cancelled").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if t.state == .running {
                        Button { transfers.cancel(t.id) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless)
                    } else if let url = t.savedURL {
                        Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "magnifyingglass.circle") }
                            .buttonStyle(.borderless).help("Show in Finder")
                    }
                }
            }
            Button("Clear finished") { transfers.clearFinished() }.buttonStyle(.borderless).controlSize(.small)
        }
    }

    private var connectionsSection: some View {
        @Bindable var s = module.settings
        let net = module.controller?.network
        return Section("Connections") {
            LabeledContent {
                Text(([MWBSystem.computerName] + Subnet.localIPv4Addresses()).joined(separator: " · ")
                     + (net?.listeningPort.map { " · port \($0)" } ?? ""))
                    .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            } label: { RowLabel("This Mac") }
            ForEach(s.value.manualHosts, id: \.self) { host in
                HStack {
                    let st = net?.hostStatus[host] ?? .notConnected
                    Circle().fill(RGBA(hex: st.colorHex)?.color ?? .gray).frame(width: 7, height: 7)
                    Text(host).font(.system(size: 12, design: .monospaced))
                    Text(st.title).font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button { s.value.manualHosts.removeAll { $0 == host } } label: { Image(systemName: "minus.circle.fill") }
                        .buttonStyle(.borderless)
                }
            }
            HStack {
                TextField("Add a Mac by address", text: $newHost, prompt: Text("192.168.1.20 or studio.local"))
                    .onSubmit(addHost)
                Button("Add", action: addHost).disabled(newHost.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Toggle(isOn: $s.value.sameSubnetOnly) {
                RowLabel("Same subnet only", subtitle: "Refuse Macs outside this Mac’s local network.")
            }
            LabeledContent {
                TextField("", value: $s.value.port, format: .number.grouping(.never)).frame(width: 80).multilineTextAlignment(.trailing)
            } label: {
                RowLabel("Port", subtitle: "Used when connecting by address (default 15101). Bonjour finds Macs on any port.")
            }
        }
    }

    private func addHost() {
        let h = newHost.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty, !module.settings.value.manualHosts.contains(h) else { return }
        module.settings.value.manualHosts.append(h)
        newHost = ""
    }
}
