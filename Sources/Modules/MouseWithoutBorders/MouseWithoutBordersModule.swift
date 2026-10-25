import AppKit
import MacToysCore
import Observation
import SwiftUI

/// Bumped whenever connection state changes, so SwiftUI redraws the settings page.
@MainActor
@Observable
final class MWBLiveState {
    var revision = 0
}

@MainActor
public final class MouseWithoutBordersModule: ToyModule {
    public let info = ModuleInfo(
        id: "mwb", name: "Mouse Without Borders",
        summary: "Control several Macs with one keyboard and mouse, and share the clipboard.",
        symbol: "display.2", tint: .orange, category: .inputOutput,
        permissions: [.accessibility], enabledByDefault: false,
        keywords: ["multiple computers", "kvm", "share mouse", "share keyboard", "clipboard", "file transfer", "network"])

    static let keychainAccount = "mwb.securityKey"

    let settings = Persisted("mwb", default: MWBSettings())
    let live = MWBLiveState()
    private(set) var controller: MWBController?
    private var running = false
    private var observing = false

    public init() {}

    /// Used until the first start saves an id.
    private let provisionalID = UUID()

    /// This Mac's id in the group.
    var machineID: UUID { UUID(uuidString: settings.value.machineID) ?? provisionalID }

    /// Saves the id on first start so it stays the same across launches.
    private func ensureMachineID() -> UUID {
        if let id = UUID(uuidString: settings.value.machineID) { return id }
        settings.value.machineID = provisionalID.uuidString
        settings.flush()
        return provisionalID
    }

    var securityKey: String? { Keychain.get(Self.keychainAccount) }

    /// Stores a new key and reconnects with it. Returns false for an invalid key.
    @discardableResult
    func setSecurityKey(_ raw: String) -> Bool {
        guard let key = SecurityKey.normalize(raw) else { return false }
        Keychain.set(key, for: Self.keychainAccount)
        controller?.setSecret(key)
        bump()
        return true
    }

    func generateNewKey() {
        setSecurityKey(SecurityKey.generate())
    }

    public func start() {
        guard !running else { return }
        running = true
        let id = ensureMachineID()
        if securityKey == nil { Keychain.set(SecurityKey.generate(), for: Self.keychainAccount) }
        settings.update { s in
            s.layout = s.layout.normalized
            if !s.layout.contains(id) {
                s.layout.add(MachineSlot(id: id, name: MWBSystem.computerName))
                s.layout.revision = Date().timeIntervalSince1970
            }
        }
        let controller = self.controller ?? MWBController(myID: id, settings: settings.value)
        controller.onChange = { [weak self] in self?.bump() }
        controller.onLayoutChange = { [weak self] layout in self?.settings.value.layout = layout }
        controller.onToggleEasyMouse = { [weak self] in self?.toggleEasyMouse() }
        controller.settings = settings.value
        self.controller = controller
        if !observing {
            observing = true
            settings.onChange { [weak self] value in
                guard let self, self.running else { return }
                self.controller?.settings = value
                self.registerHotkeys()
                self.bump()
            }
        }
        controller.start(secret: securityKey)
        registerHotkeys()
        bump()
    }

    public func stop() {
        guard running else { return }
        running = false
        HotkeyCenter.shared.unregister(prefix: "mwb.")
        controller?.stop()
        settings.flush()
        bump()
    }

    private func bump() { live.revision &+= 1 }

    private func registerHotkeys() {
        let s = settings.value
        for (i, shortcut) in s.machineShortcuts.enumerated() {
            HotkeyCenter.shared.register("mwb.machine\(i + 1)", shortcut) { [weak self] in self?.controller?.switchToMachine(i) }
        }
        HotkeyCenter.shared.register("mwb.easymouse", s.easyMouseShortcut) { [weak self] in self?.toggleEasyMouse() }
        HotkeyCenter.shared.register("mwb.lock", s.lockShortcut) { [weak self] in self?.controller?.lockPressed() }
        HotkeyCenter.shared.register("mwb.reconnect", s.reconnectShortcut) { [weak self] in self?.controller?.reconnect() }
    }

    func toggleEasyMouse() {
        settings.value.easyMouse.toggle()
        HUD.show(settings.value.easyMouse ? "Easy Mouse on" : "Easy Mouse off", symbol: "cursorarrow.motionlines")
    }

    /// Connects to another Mac using its key (and, optionally, its address).
    func connect(key: String, host: String) -> String? {
        guard SecurityKey.normalize(key) != nil else {
            return String(localized: "Security keys have at least 16 letters and digits.")
        }
        setSecurityKey(key)
        let h = host.trimmingCharacters(in: .whitespaces)
        if !h.isEmpty && !settings.value.manualHosts.contains(h) { settings.value.manualHosts.append(h) }
        if !h.isEmpty { controller?.network.connect(host: h) }
        return nil
    }

    // MARK: - Status for the UI

    var connectedCount: Int { controller?.network.peers.count ?? 0 }

    func status(of id: UUID) -> MWBStatus {
        if id == machineID { return .connected }
        return controller?.network.status[id] ?? .notConnected
    }

    func tiles() -> [MachineMatrixView.Tile?] {
        let me = machineID
        var layout = settings.value.layout.normalized
        // Before the first start the layout may not list this Mac yet.
        if !layout.contains(me) { layout.add(MachineSlot(id: me, name: MWBSystem.computerName)) }
        return layout.slots.map { slot in
            guard let slot else { return nil }
            let isMe = slot.id == me
            let info = controller?.peerInfo[slot.id]
            return MachineMatrixView.Tile(
                id: slot.id, name: isMe ? MWBSystem.computerName : (info?.name ?? slot.name), status: status(of: slot.id),
                isThisMac: isMe, isActive: activeMachine == slot.id,
                detail: isMe ? (Subnet.localIPv4Addresses().first ?? String(localized: "This Mac"))
                    : (controller?.network.address(of: slot.id) ?? status(of: slot.id).title),
                displayCount: isMe ? NSScreen.screens.count : (info?.displays.count ?? 0))
        }
    }

    /// The machine the keyboard and mouse currently drive.
    var activeMachine: UUID? {
        guard let controller else { return nil }
        switch controller.mode {
        case .local, .controlled: return machineID
        case .controlling(let id): return id
        }
    }

    // MARK: - ToyModule

    public func settingsView() -> AnyView {
        AnyView(MWBSettingsView(module: self))
    }

    public var quickActions: [QuickAction] {
        [
            QuickAction(id: "mwb.easymouse", title: "Easy Mouse", symbol: "cursorarrow.motionlines", tint: .orange,
                        shortcut: settings.value.easyMouseShortcut,
                        isOn: { [weak self] in self?.settings.value.easyMouse ?? false },
                        detail: { [weak self] in
                            let n = self?.connectedCount ?? 0
                            return n == 0 ? String(localized: "No other Macs connected")
                                : String(localized: "\(n) other Macs connected", comment: "Number of connected Macs besides this one")
                        },
                        perform: { [weak self] in self?.toggleEasyMouse() }),
            QuickAction(id: "mwb.reconnect", title: "Reconnect Macs", symbol: "arrow.triangle.2.circlepath", tint: .orange,
                        shortcut: settings.value.reconnectShortcut) { [weak self] in self?.controller?.reconnect() },
        ]
    }

    public var shortcutBindings: [ShortcutBinding] {
        let s = settings.value
        var list = s.machineShortcuts.enumerated().map { ShortcutBinding("Switch to Mac \($0.offset + 1)", $0.element) }
        list += [ShortcutBinding("Toggle Easy Mouse", s.easyMouseShortcut),
                 ShortcutBinding("Lock all Macs (press twice)", s.lockShortcut),
                 ShortcutBinding("Reconnect", s.reconnectShortcut)]
        return list.filter { !$0.keys.isEmpty }
    }

    /// `mactoys://mwb/<action>`: `open`/`settings`, `reconnect`, `easymouse` (`?on=1|0`), `lock`
    /// (locks every Mac), `switch?machine=1…4`, `send?file=/path[&machine=1…4]`, `newkey`.
    public func handle(_ command: AppCommand) -> Bool {
        switch command.action {
        case "open", "settings":
            ModuleRegistry.shared.showSettings?(info.id)
        case "reconnect":
            controller?.reconnect()
        case "easymouse":
            if let on = command.parameters["on"] { settings.value.easyMouse = ["1", "true", "yes", "on"].contains(on.lowercased()) }
            else { toggleEasyMouse() }
        case "lock":
            controller?.network.broadcast(.lockScreen)
            MWBSystem.lockScreen()
        case "switch":
            guard let n = command.parameters["machine"].flatMap(Int.init), (1...4).contains(n) else { return false }
            controller?.switchToMachine(n - 1)
        case "send":
            guard let file = command.files.first, let controller else { return false }
            let slots = settings.value.layout.normalized.slots
            let target: UUID?
            if let n = command.parameters["machine"].flatMap(Int.init), (1...4).contains(n) { target = slots[n - 1]?.id }
            else { target = controller.network.connectedIDs.first }
            guard let target, target != machineID else { return false }
            controller.send(file: file, to: target)
        case "newkey":
            generateNewKey()
        default:
            return false
        }
        return true
    }

    public var previewScenes: [PreviewScene] {
        [PreviewScene("matrix", size: CGSize(width: 760, height: 240), wallpaper: false) {
            AnyView(MWBMatrixPreview())
        }]
    }
}
