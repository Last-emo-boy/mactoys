import AppKit
import Carbon.HIToolbox
import MacToysCore

/// Runs Mouse Without Borders on this Mac: decides when the pointer crosses to another Mac,
/// streams input while it controls one, posts input while it is controlled, and keeps the
/// clipboard, layout and screen savers in sync.
@MainActor
final class MWBController {
    enum Mode: Equatable {
        case local
        case controlling(UUID)
        case controlled(by: UUID)
    }

    static let tapID = "mwb.input"
    /// Below Keyboard Manager (100), so remapped keys are what gets sent.
    static let tapPriority = 10
    /// Marks the few events this module posts locally (to end a drag), so capture skips them.
    static let localMarker: Int64 = KeySynth.marker + 1

    private(set) var mode: Mode = .local
    let myID: UUID
    let network: MWBNetwork
    let transfers = MWBTransferCenter()
    private let injector = MWBInjector()
    private let clipboard = MWBClipboardSync()
    private(set) var peerInfo: [UUID: MWBMachineInfo] = [:]
    var settings: MWBSettings {
        didSet { settingsChanged(from: oldValue) }
    }

    private var running = false
    private var virtual = CGPoint.zero
    private var park = CGPoint.zero
    private var swallowKeyUps: Set<Int64> = []
    private var swallowButtonUps: Set<Int64> = []
    private var lastLocalInput = Date()
    private var activityTimer: Timer?
    private var screenObserver: NSObjectProtocol?
    private var dragChangeCount = 0
    private var clipboardFile: (url: URL, sentTo: Set<UUID>)?
    private var lockPressedAt: Date?
    private let log = Log.for("mwb")

    /// The UI should refresh.
    var onChange: (() -> Void)?
    /// A layout from another Mac (or an auto-added machine) should be saved.
    var onLayoutChange: ((MachineLayout) -> Void)?

    init(myID: UUID, settings: MWBSettings) {
        self.myID = myID
        self.settings = settings
        network = MWBNetwork(identity: .init(machineID: myID, name: MWBSystem.computerName))
        network.onConnected = { [weak self] hello in self?.connected(hello) }
        network.onDisconnected = { [weak self] id, _ in self?.disconnected(id) }
        network.onMessage = { [weak self] id, message in self?.received(message, from: id) }
        network.onChange = { [weak self] in self?.onChange?() }
        transfers.transmit = { [weak self] message, peer, completion in
            self?.network.send(message, to: peer, completion: completion) ?? false
        }
        transfers.onReceived = { [weak self] t, url in self?.fileReceived(t, at: url) }
        transfers.onFailed = { [weak self] t in
            guard self?.settings.showStatusMessages == true else { return }
            if case .failed(let why) = t.state { HUD.show("\(t.name): \(why)", symbol: "exclamationmark.triangle") }
        }
        clipboard.onLocalChange = { [weak self] payload in self?.localClipboardChanged(payload) }
    }

    func start(secret: String?) {
        guard !running else { return }
        running = true
        applyNetworkSettings()
        network.secret = secret
        network.start()
        if settings.shareClipboard { clipboard.start() }
        InputTap.shared.add(Self.tapID, priority: Self.tapPriority,
                            events: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                                     .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                     .otherMouseDown, .otherMouseUp, .scrollWheel, .keyDown, .keyUp, .flagsChanged,
                                     InputTap.systemDefined],
                            includeSynthetic: true) { [weak self] type, event in
            self?.handle(type, event) ?? .pass
        }
        activityTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.activityTick() }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.network.broadcast(.machineInfo(self?.machineInfo ?? MWBMachineInfo(name: "", displays: []))) }
        }
    }

    func stop() {
        guard running else { return }
        running = false
        endRemoteSession()
        InputTap.shared.remove(Self.tapID)
        clipboard.stop()
        transfers.cancelAll()
        network.stop()
        activityTimer?.invalidate()
        activityTimer = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        peerInfo = [:]
    }

    /// A new security key: every connection starts over with it.
    func setSecret(_ secret: String?) {
        network.secret = secret
        if running { network.reconnect() }
    }

    var machineInfo: MWBMachineInfo { MWBMachineInfo(name: MWBSystem.computerName, displays: MWBSystem.displays) }

    private func applyNetworkSettings() {
        network.sameSubnetOnly = settings.sameSubnetOnly
        network.manualHosts = settings.manualHosts
        network.preferredPort = UInt16(clamping: settings.port)
        transfers.maxBytes = settings.maxFileBytes
    }

    private func settingsChanged(from old: MWBSettings) {
        guard running else { return }
        applyNetworkSettings()
        if settings.shareClipboard != old.shareClipboard {
            if settings.shareClipboard { clipboard.start() } else { clipboard.stop() }
        }
        if settings.manualHosts != old.manualHosts {
            for host in settings.manualHosts where !old.manualHosts.contains(host) { network.connect(host: host) }
        }
        if settings.port != old.port || settings.sameSubnetOnly != old.sameSubnetOnly { network.reconnect() }
        if settings.layout != old.layout && settings.layout.revision > old.layout.revision {
            network.broadcast(.layout(layoutMessage))
        }
        if settings.hidePointerAtEdge != old.hidePointerAtEdge, case .controlling = mode {
            if settings.hidePointerAtEdge { MWBCursor.hide() } else { MWBCursor.show() }
        }
    }

    private var layoutMessage: MWBLayoutMessage {
        let l = settings.layout.normalized
        return MWBLayoutMessage(revision: l.revision, singleRow: l.singleRow, wrap: settings.wrapMouse, slots: l.slots)
    }

    func name(of id: UUID) -> String {
        if id == myID { return MWBSystem.computerName }
        return peerInfo[id]?.name ?? network.names[id] ?? settings.layout.machines.first { $0.id == id }?.name ?? "Mac"
    }

    // MARK: - Connections

    private func connected(_ hello: MWBHello) {
        network.send(.machineInfo(machineInfo), to: hello.machineID)
        var layout = settings.layout.normalized
        if !layout.contains(myID) { layout.add(MachineSlot(id: myID, name: MWBSystem.computerName)) }
        if settings.autoAddMachines && !layout.contains(hello.machineID) {
            if layout.add(MachineSlot(id: hello.machineID, name: hello.name)) {
                layout.revision = Date().timeIntervalSince1970
                onLayoutChange?(layout)
            }
        }
        network.send(.layout(layoutMessage), to: hello.machineID)
        status("\(hello.name) connected", symbol: "display.2")
        onChange?()
    }

    private func disconnected(_ id: UUID) {
        if mode == .controlling(id) { returnToLocal(at: park) }
        if mode == .controlled(by: id) {
            injector.releaseAll()
            mode = .local
        }
        transfers.peerDisconnected(id)
        let name = name(of: id)
        peerInfo[id] = nil
        status("\(name) disconnected", symbol: "display.trianglebadge.exclamationmark")
        onChange?()
    }

    // MARK: - Messages

    private func received(_ message: MWBMessage, from id: UUID) {
        if transfers.handle(message, from: id, peerName: name(of: id)) { return }
        switch message {
        case .machineInfo(let info):
            peerInfo[id] = info
            onChange?()
        case .layout(let l):
            adopt(l, from: id)
        case .enter(let x, let y):
            if case .controlling = mode { returnToLocal(at: park) }
            mode = .controlled(by: id)
            injector.enter(at: CGPoint(x: x, y: y))
            onChange?()
        case .leave:
            guard mode == .controlled(by: id) else { return }
            injector.releaseAll()
            mode = .local
            sendClipboardFile(to: id)
            onChange?()
        case .releaseControl:
            if mode == .controlling(id) {
                returnToLocal(at: park)
                status("\(name(of: id)) took over", symbol: "hand.raised")
            }
        case .mouseMove(let m):
            if mode == .controlled(by: id) { injector.move(m) }
        case .mouseButton(let b):
            if mode == .controlled(by: id) { injector.button(b) }
        case .scroll(let s):
            if mode == .controlled(by: id) { injector.scroll(s) }
        case .key(let k):
            if mode == .controlled(by: id) { injector.key(k) }
        case .mediaKey(let m):
            if mode == .controlled(by: id) { injector.media(m) }
        case .clipboardText(let text):
            guard settings.shareClipboard else { return }
            clipboard.applyText(text)
            status("Clipboard from \(name(of: id))", symbol: "doc.on.clipboard")
        case .clipboardImage(let png):
            guard settings.shareClipboard else { return }
            clipboard.applyImage(png)
            status("Image from \(name(of: id))", symbol: "photo")
        case .userActivity:
            MWBSystem.declareUserActivity()
        case .lockScreen:
            MWBSystem.lockScreen()
        case .hello, .authProof, .heartbeat, .fileStart, .fileChunk, .fileEnd, .fileCancel:
            break
        }
    }

    /// Takes a newer layout from another Mac. Ties go to the smaller machine id.
    private func adopt(_ l: MWBLayoutMessage, from id: UUID) {
        let mine = settings.layout
        let newer = l.revision > mine.revision || (l.revision == mine.revision && id.uuidString < myID.uuidString && l.slots != mine.slots)
        guard newer else { return }
        var layout = MachineLayout()
        layout.slots = l.slots
        layout.singleRow = l.singleRow
        layout.revision = l.revision
        layout = layout.normalized
        // Never drop this Mac from its own layout.
        if !layout.contains(myID) {
            layout.add(MachineSlot(id: myID, name: MWBSystem.computerName))
            layout.revision = max(l.revision, Date().timeIntervalSince1970)
        }
        onLayoutChange?(layout)
    }

    // MARK: - Event tap

    private func handle(_ type: CGEventType, _ event: CGEvent) -> TapDecision {
        let marker = event.getIntegerValueField(.eventSourceUserData)
        if marker == Self.localMarker { return .pass }
        let synthetic = marker == KeySynth.marker
        switch mode {
        case .local:
            guard !synthetic else { return .pass }
            lastLocalInput = Date()
            switch type {
            case .leftMouseDown:
                dragChangeCount = NSPasteboard(name: .drag).changeCount
            case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
                checkLocalEdge(event)
            default:
                break
            }
            return .pass
        case .controlled(let controller):
            guard !synthetic, isDeliberate(type, event) else { return .pass }
            // The person at this Mac uses it: hand control back.
            network.send(.releaseControl, to: controller)
            injector.releaseAll()
            mode = .local
            lastLocalInput = Date()
            onChange?()
            return .pass
        case .controlling(let remote):
            lastLocalInput = Date()
            return forward(type, event, to: remote)
        }
    }

    private func isDeliberate(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel: return true
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            return abs(event.getDoubleValueField(.mouseEventDeltaX)) + abs(event.getDoubleValueField(.mouseEventDeltaY)) >= 3
        default: return false
        }
    }

    private func easyMouseAllowed(_ flags: CGEventFlags) -> Bool {
        guard settings.easyMouse else { return false }
        switch settings.easyMouseModifier {
        case .none: return true
        case .control: return flags.contains(.maskControl)
        case .shift: return flags.contains(.maskShift)
        }
    }

    private func checkLocalEdge(_ event: CGEvent) {
        guard !network.peers.isEmpty, easyMouseAllowed(event.flags) else { return }
        let delta = CGVector(dx: event.getDoubleValueField(.mouseEventDeltaX), dy: event.getDoubleValueField(.mouseEventDeltaY))
        let displays = MWBSystem.displays
        let p = event.location
        guard let (direction, display) = EdgeMath.exit(from: p, delta: delta, displays: displays) else { return }
        if settings.blockCorners && EdgeMath.nearCorner(p, of: display, direction: direction) { return }
        guard let target = settings.layout.neighbor(of: myID, direction, wrap: settings.wrapMouse),
              network.isConnected(target), let info = peerInfo[target], !info.displays.isEmpty else { return }
        if settings.disableEasyMouseInFullScreen && MWBSystem.frontmostIsFullScreen(ignoring: settings.fullScreenIgnoredApps) { return }
        let entry = EdgeMath.entryPoint(exit: p, from: display, direction: direction, into: info.displays)
        beginControlling(target, entry: entry, localPoint: p, dragging: event.type == .leftMouseDragged)
    }

    /// Takes control of `target` with its pointer at `entry` (its coordinates).
    func beginControlling(_ target: UUID, entry: CGPoint, localPoint: CGPoint, dragging: Bool = false) {
        guard network.isConnected(target) else { return }
        if case .controlling(let old) = mode, old != target { network.send(.leave, to: old) }
        let wasLocal = mode == .local
        if case .controlled(let other) = mode {
            network.send(.releaseControl, to: other)
            injector.releaseAll()
        }
        mode = .controlling(target)
        virtual = entry
        if wasLocal {
            let display = ScreenGeometry.screen(containingAX: localPoint)?.axFrame ?? CGRect(origin: localPoint, size: CGSize(width: 1, height: 1))
            park = CGPoint(x: min(max(localPoint.x, display.minX + 2), display.maxX - 3),
                           y: min(max(localPoint.y, display.minY + 2), display.maxY - 3))
            if CGEventSource.buttonState(.hidSystemState, button: .left) || dragging { endLocalDrag(sendingFileTo: target) }
            CGAssociateMouseAndMouseCursorPosition(0)
            CGWarpMouseCursorPosition(park)
            if settings.hidePointerAtEdge { MWBCursor.hide() }
        }
        network.send(.enter(x: entry.x, y: entry.y), to: target)
        sendClipboardFile(to: target)
        status("→ \(name(of: target))", symbol: "arrow.right.circle")
        onChange?()
    }

    /// Back to this Mac, with the pointer at `p`.
    func returnToLocal(at p: CGPoint) {
        guard case .controlling(let remote) = mode else { return }
        network.send(.leave, to: remote)
        endRemoteSession()
        MouseSynth.warp(to: p)
        status("← \(MWBSystem.computerName)", symbol: "arrow.left.circle")
        onChange?()
    }

    /// Restores the local pointer and forgets swallowed keys.
    private func endRemoteSession() {
        if case .controlling = mode {
            CGAssociateMouseAndMouseCursorPosition(1)
            MWBCursor.show()
        }
        if case .controlled = mode { injector.releaseAll() }
        mode = .local
        swallowKeyUps = []
        swallowButtonUps = []
    }

    /// The button is held while crossing: end the local drag (cancelling it, for a file drag,
    /// and sending the file instead) so nothing stays pressed here.
    private func endLocalDrag(sendingFileTo target: UUID) {
        let drag = NSPasteboard(name: .drag)
        let draggedFile: URL? = drag.changeCount != dragChangeCount
            ? (drag.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first
            : nil
        if let file = draggedFile, settings.transferFiles {
            transfers.send(file: file, to: target, peerName: name(of: target), purpose: .send)
            status("Sending \(file.lastPathComponent) to \(name(of: target))", symbol: "arrow.up.doc")
            postLocalKey(kVK_Escape)
        }
        postLocalMouseUp(at: park)
        swallowButtonUps.insert(0)
    }

    /// Moves the pointer back to the park point with a posted move: unlike a warp, it doesn't
    /// suppress the next hardware events for a quarter second.
    private func repark() {
        guard let e = CGEvent(mouseEventSource: parkSource, mouseType: .mouseMoved, mouseCursorPosition: park,
                              mouseButton: .left) else { return }
        e.setIntegerValueField(.eventSourceUserData, value: Self.localMarker)
        e.post(tap: .cghidEventTap)
    }

    private let parkSource: CGEventSource? = {
        let source = CGEventSource(stateID: .hidSystemState)
        source?.localEventsSuppressionInterval = 0
        return source
    }()

    private func postLocalKey(_ code: Int) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: down) else { continue }
            e.setIntegerValueField(.eventSourceUserData, value: Self.localMarker)
            e.post(tap: .cghidEventTap)
        }
    }

    private func postLocalMouseUp(at p: CGPoint) {
        guard let e = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: .leftMouseUp,
                              mouseCursorPosition: p, mouseButton: .left) else { return }
        e.setIntegerValueField(.eventSourceUserData, value: Self.localMarker)
        e.post(tap: .cghidEventTap)
    }

    /// Controlling another Mac: everything goes there, nothing reaches local apps.
    private func forward(_ type: CGEventType, _ event: CGEvent, to remote: UUID) -> TapDecision {
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            let delta = CGVector(dx: event.getDoubleValueField(.mouseEventDeltaX), dy: event.getDoubleValueField(.mouseEventDeltaY))
            // Keep the local pointer parked even if the disassociation didn't hold (it is only
            // guaranteed for the frontmost app).
            let here = event.location
            if abs(here.x - park.x) + abs(here.y - park.y) > 2 { repark() }
            let displays = peerInfo[remote]?.displays ?? []
            let moved = EdgeMath.move(virtual, by: delta, within: displays)
            virtual = moved.point
            if let (direction, display) = moved.exit, crossFromRemote(remote, direction: direction, display: display, flags: event.flags) {
                return .consume
            }
            network.send(.mouseMove(MWBMouseMove(x: virtual.x, y: virtual.y, dx: delta.dx, dy: delta.dy)), to: remote)
            return .consume
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .rightMouseUp, .otherMouseUp:
            let button = event.getIntegerValueField(.mouseEventButtonNumber)
            let down = type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
            if !down && swallowButtonUps.remove(button) != nil { return .consume }
            network.send(.mouseButton(MWBMouseButton(button: UInt8(clamping: button), down: down,
                                                     clickCount: UInt8(clamping: event.getIntegerValueField(.mouseEventClickState)),
                                                     x: virtual.x, y: virtual.y)), to: remote)
            return .consume
        case .scrollWheel:
            network.send(.scroll(MWBScroll(
                dy: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1),
                dx: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2),
                lineDy: Int32(clamping: event.getIntegerValueField(.scrollWheelEventDeltaAxis1)),
                lineDx: Int32(clamping: event.getIntegerValueField(.scrollWheelEventDeltaAxis2)),
                phase: UInt8(clamping: event.getIntegerValueField(.scrollWheelEventScrollPhase)),
                momentumPhase: UInt8(clamping: event.getIntegerValueField(.scrollWheelEventMomentumPhase)),
                continuous: event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0)), to: remote)
            return .consume
        case .keyDown, .keyUp:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if type == .keyDown, event.getIntegerValueField(.keyboardEventAutorepeat) == 0, performShortcut(event) {
                swallowKeyUps.insert(code)
                return .consume
            }
            if swallowKeyUps.contains(code) {
                if type == .keyUp { swallowKeyUps.remove(code) }
                return .consume
            }
            network.send(.key(MWBKey(keyCode: UInt16(clamping: code), down: type == .keyDown, flags: event.flags.rawValue,
                                     autorepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)), to: remote)
            return .consume
        case .flagsChanged:
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            guard let down = Self.modifierIsDown(code: code, flags: event.flags) else { return .consume }
            network.send(.key(MWBKey(keyCode: UInt16(code), down: down, flags: event.flags.rawValue, autorepeat: false)), to: remote)
            return .consume
        case InputTap.systemDefined:
            guard let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else { return .pass }
            let state = (ns.data1 & 0xFF00) >> 8
            guard state == 0xA || state == 0xB else { return .pass }
            network.send(.mediaKey(MWBMediaKey(code: UInt8(clamping: (ns.data1 & 0xFFFF_0000) >> 16), down: state == 0xA,
                                               autorepeat: ns.data1 & 1 != 0)), to: remote)
            return .consume
        default:
            return .pass
        }
    }

    /// The virtual pointer left `remote`'s desktop: hand control to the neighbor in that
    /// direction (this Mac or another one). Returns false to stay.
    private func crossFromRemote(_ remote: UUID, direction: MachineLayout.Direction, display: CGRect, flags: CGEventFlags) -> Bool {
        guard easyMouseAllowed(flags) else { return false }
        if settings.blockCorners && EdgeMath.nearCorner(virtual, of: display, direction: direction) { return false }
        guard let next = settings.layout.neighbor(of: remote, direction, wrap: settings.wrapMouse) else { return false }
        if next == myID {
            returnToLocal(at: EdgeMath.entryPoint(exit: virtual, from: display, direction: direction, into: MWBSystem.displays))
            return true
        }
        guard network.isConnected(next), let info = peerInfo[next], !info.displays.isEmpty else { return false }
        beginControlling(next, entry: EdgeMath.entryPoint(exit: virtual, from: display, direction: direction, into: info.displays),
                         localPoint: park)
        return true
    }

    /// Device-dependent bit of each modifier key (left/right), to tell press from release.
    static func modifierIsDown(code: Int, flags: CGEventFlags) -> Bool? {
        let masks: [Int: UInt64] = [kVK_Control: 0x1, kVK_Shift: 0x2, kVK_RightShift: 0x4, kVK_Command: 0x8,
                                    kVK_RightCommand: 0x10, kVK_Option: 0x20, kVK_RightOption: 0x40, kVK_RightControl: 0x2000]
        if let m = masks[code] { return flags.rawValue & m != 0 }
        if code == kVK_Function { return flags.contains(.maskSecondaryFn) }
        return nil
    }

    // MARK: - Shortcuts

    /// MWB's own shortcuts while keys go to another Mac (global hotkeys don't fire then).
    private func performShortcut(_ event: CGEvent) -> Bool {
        for (i, s) in settings.machineShortcuts.enumerated() {
            if let s, s.matches(event) { switchToMachine(i); return true }
        }
        if let s = settings.easyMouseShortcut, s.matches(event) { toggleEasyMouse(); return true }
        if let s = settings.lockShortcut, s.matches(event) { lockPressed(); return true }
        if let s = settings.reconnectShortcut, s.matches(event) { reconnect(); return true }
        return false
    }

    /// Moves control to the machine in matrix slot `index` (0-based).
    func switchToMachine(_ index: Int) {
        let slots = settings.layout.normalized.slots
        guard slots.indices.contains(index), let slot = slots[index] else {
            HUD.show("No Mac in position \(index + 1)", symbol: "display.trianglebadge.exclamationmark")
            return
        }
        if slot.id == myID {
            let primary = MWBSystem.displays.first ?? .zero
            returnToLocal(at: CGPoint(x: primary.midX, y: primary.midY))
            return
        }
        guard network.isConnected(slot.id), let display = peerInfo[slot.id]?.displays.first else {
            HUD.show("\(slot.name) isn’t connected", symbol: "display.trianglebadge.exclamationmark")
            return
        }
        beginControlling(slot.id, entry: CGPoint(x: display.midX, y: display.midY), localPoint: mode == .local ? MouseSynth.location : park)
    }

    var onToggleEasyMouse: (() -> Void)?

    func toggleEasyMouse() { onToggleEasyMouse?() }

    /// Press the lock shortcut twice within 1.5 s to lock every Mac.
    func lockPressed() {
        if let t = lockPressedAt, Date().timeIntervalSince(t) < 1.5 {
            lockPressedAt = nil
            network.broadcast(.lockScreen)
            if case .controlling = mode { returnToLocal(at: park) }
            MWBSystem.lockScreen()
        } else {
            lockPressedAt = Date()
            HUD.show("Press again to lock all Macs", symbol: "lock")
        }
    }

    func reconnect() {
        if case .controlling = mode { returnToLocal(at: park) }
        network.reconnect()
        HUD.show("Reconnecting…", symbol: "arrow.triangle.2.circlepath")
    }

    // MARK: - Clipboard, files, activity

    private func localClipboardChanged(_ payload: MWBClipboardSync.Payload) {
        guard settings.shareClipboard, !network.peers.isEmpty else {
            if case .file(let url) = payload { clipboardFile = (url, []) }
            return
        }
        switch payload {
        case .text(let text):
            guard text.utf8.count <= MWBProtocol.maxClipboardText else { return }
            network.broadcast(.clipboardText(text))
        case .image(let png):
            if png.count <= MWBProtocol.maxClipboardImage {
                network.broadcast(.clipboardImage(png))
            } else {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("Clipboard Image.png")
                do {
                    try png.write(to: url, options: .atomic)
                    clipboardFile = (url, [])
                } catch {
                    log.error("Couldn’t stage clipboard image: \(error.localizedDescription, privacy: .public)")
                }
            }
        case .file(let url):
            // Files go to a Mac when control moves there, not to everyone right away.
            clipboardFile = settings.transferFiles ? (url, []) : nil
        }
    }

    private func sendClipboardFile(to peer: UUID) {
        guard settings.shareClipboard, settings.transferFiles, var f = clipboardFile, !f.sentTo.contains(peer) else { return }
        f.sentTo.insert(peer)
        clipboardFile = f
        transfers.send(file: f.url, to: peer, peerName: name(of: peer), purpose: .clipboard)
    }

    private func fileReceived(_ t: MWBTransferCenter.Transfer, at url: URL) {
        switch t.purpose {
        case .clipboard:
            clipboard.applyFile(url)
            // Received files can travel on to the next Mac.
            clipboardFile = (url, [t.peer])
            status("\(t.name) copied from \(t.peerName)", symbol: "doc.on.clipboard")
        case .send:
            Notifier.post("Received \(t.name)", "From \(t.peerName) · saved in Downloads")
            status("Received \(t.name)", symbol: "arrow.down.doc")
        }
    }

    /// Sends a file (Send File…, a drop on a machine in Settings, or the URL action).
    func send(file: URL, to peer: UUID) {
        guard settings.transferFiles else {
            HUD.show("File transfer is turned off", symbol: "exclamationmark.triangle")
            return
        }
        if transfers.send(file: file, to: peer, peerName: name(of: peer), purpose: .send) {
            status("Sending \(file.lastPathComponent) to \(name(of: peer))", symbol: "arrow.up.doc")
        }
    }

    private func activityTick() {
        guard settings.blockScreenSaver, !network.peers.isEmpty else { return }
        if Date().timeIntervalSince(lastLocalInput) < 60 || mode != .local { network.broadcast(.userActivity) }
    }

    private func status(_ text: String, symbol: String) {
        guard settings.showStatusMessages else { return }
        HUD.show(text, symbol: symbol, duration: 1.2)
    }
}
