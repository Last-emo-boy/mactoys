import AppKit
import Carbon.HIToolbox
import MacToysCore

/// DemoType: types the next segment of a script into the frontmost app.
///
/// The script comes from the input file, or from the clipboard when its text starts with
/// `[start]`. Each press of the shortcut types one segment (segments end at `[end]`); ⌃⌥⇧7 goes
/// back one. While typing, your own keystrokes are held back; Esc stops, and so does switching
/// apps. In user-driven mode every key you press types the next few characters instead, and
/// Space at the end of a segment finishes it.
@MainActor
final class DemoTypeController {
    private var script: DemoTypeScript?
    private var scriptKey = ""
    private var segment = 0
    private var steps: [DemoTypeStep] = []
    private var position = 0
    private var typing: Task<Void, Never>?
    private var userDriven = false
    private var awaitingFinalSpace = false
    private var activationObserver: NSObjectProtocol?
    private var settings = ZoomItSettings()
    private let log = Log.for("zoomit")
    private static let tapID = "zoomit.demotype"

    var isActive: Bool { typing != nil || userDriven }

    /// The shortcut: types (or, while typing, stops).
    func trigger(settings: ZoomItSettings) {
        if isActive { stop(); return }
        self.settings = settings
        guard AXIsProcessTrusted() else {
            HUD.show("Accessibility permission needed", symbol: "exclamationmark.shield")
            PermissionCenter.shared.request(.accessibility)
            return
        }
        guard loadScript() else { return }
        guard let script, !script.segments.isEmpty else { return }
        if segment >= script.segments.count { segment = 0 }
        steps = DemoTypeStep.steps(of: script.segments[segment])
        position = 0
        installTap()
        observeAppSwitches()
        if settings.userDriven {
            userDriven = true
            HUD.show("DemoType · type to drive segment \(segment + 1) of \(script.segments.count)", symbol: "keyboard")
        } else {
            typing = Task { @MainActor [weak self] in await self?.typeAll() }
        }
    }

    /// ⌃⌥⇧7: the next press types the previous segment again.
    func back(settings: ZoomItSettings) {
        if isActive { stop() }
        self.settings = settings
        guard loadScript(), let script, !script.segments.isEmpty else { return }
        segment = max(0, min(segment, script.segments.count) - 1)
        HUD.show("DemoType · segment \(segment + 1) of \(script.segments.count) next", symbol: "backward.end")
    }

    func stop() {
        typing?.cancel()
        typing = nil
        userDriven = false
        awaitingFinalSpace = false
        InputTap.shared.remove(Self.tapID)
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
    }

    /// Forgets the position (the file changed, or the module stopped).
    func reset() {
        stop()
        script = nil
        scriptKey = ""
        segment = 0
    }

    // MARK: Script

    /// Loads the clipboard script (when it starts with `[start]`) or the input file, keeping
    /// the position while the source is unchanged.
    private func loadScript() -> Bool {
        if let text = NSPasteboard.general.string(forType: .string), let clip = DemoTypeScript.fromClipboard(text) {
            adopt(clip, key: "clipboard:\(text.hashValue)")
            return true
        }
        let path = (settings.demoTypeFile as NSString).expandingTildeInPath
        guard !path.isEmpty else {
            HUD.show("Choose a DemoType script in ZoomIt settings", symbol: "doc.text")
            ModuleRegistry.shared.showSettings?("zoomit")
            return false
        }
        let url = URL(fileURLWithPath: path)
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?
            .timeIntervalSince1970 ?? 0
        let key = "\(path)#\(modified)"
        if key == scriptKey, script != nil { return true }
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 1_048_576 else {
                HUD.show("The DemoType script is larger than 1 MB", symbol: "exclamationmark.triangle")
                return false
            }
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16)
                    ?? String(data: data, encoding: .isoLatin1) else {
                HUD.show("The DemoType script isn't text", symbol: "exclamationmark.triangle")
                return false
            }
            adopt(DemoTypeScript(text), key: key)
            return true
        } catch {
            log.error("DemoType file: \(error.localizedDescription, privacy: .public)")
            HUD.show("Couldn’t read the DemoType script", symbol: "exclamationmark.triangle")
            return false
        }
    }

    private func adopt(_ new: DemoTypeScript, key: String) {
        guard key != scriptKey else { return }
        script = new
        scriptKey = key
        segment = 0
    }

    // MARK: Typing

    private func typeAll() async {
        while position < steps.count, !Task.isCancelled {
            let step = steps[position]
            position += 1
            if case .pause(let seconds) = step {
                try? await Task.sleep(for: .seconds(seconds))
                continue
            }
            perform(step)
            let delay = DemoTypeStep.delay(speed: settings.typingSpeed, random: Double.random(in: 0...1))
            try? await Task.sleep(for: .seconds(step.isPaste ? max(delay, 0.3) : delay))
        }
        guard !Task.isCancelled else { return }
        finishSegment()
    }

    private func finishSegment() {
        segment += 1
        if let script, segment >= script.segments.count { segment = 0 }
        stop()
    }

    private func perform(_ step: DemoTypeStep) {
        switch step {
        case .character(let c):
            switch c {
            case "\n": KeySynth.tap(kVK_Return)
            case "\t": KeySynth.tap(kVK_Tab)
            default: KeySynth.type(String(c))
            }
        case .key(let k):
            switch k {
            case .enter: KeySynth.tap(kVK_Return)
            case .up: KeySynth.tap(kVK_UpArrow)
            case .down: KeySynth.tap(kVK_DownArrow)
            case .left: KeySynth.tap(kVK_LeftArrow)
            case .right: KeySynth.tap(kVK_RightArrow)
            }
        case .paste(let text):
            paste(text)
        case .pause:
            break
        }
    }

    /// Pastes through the clipboard, then puts the previous clipboard back.
    private func paste(_ text: String) {
        let pb = NSPasteboard.general
        let saved = ClipItem.current(from: pb)
        pb.clearContents()
        pb.setString(text, forType: .string)
        KeySynth.paste()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let saved { saved.write(to: pb) }
        }
    }

    // MARK: Input

    /// Holds back the user's keys while DemoType types (or drives typing in user-driven mode).
    private func installTap() {
        InputTap.shared.add(Self.tapID, priority: 90, events: [.keyDown, .keyUp]) { [weak self] type, event in
            self?.handle(type, event) ?? .pass
        }
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> TapDecision {
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        if code == kVK_Escape {
            if type == .keyDown { stop() }
            return .consume
        }
        guard userDriven else { return .consume }
        guard type == .keyDown, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return .consume }
        if awaitingFinalSpace {
            if code == kVK_Space { finishSegment() }
            return .consume
        }
        var budget = DemoTypeStep.charactersPerPress(speed: settings.typingSpeed)
        // Defer injection until the user's key event is gone, so ordering stays intact.
        var batch: [DemoTypeStep] = []
        while budget > 0, position < steps.count {
            let step = steps[position]
            position += 1
            if case .pause = step { continue }
            batch.append(step)
            budget -= 1
        }
        if position >= steps.count { awaitingFinalSpace = true }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { for step in batch { self?.perform(step) } }
        }
        return .consume
    }

    private func observeAppSwitches() {
        let initial = NSWorkspace.shared.frontmostApplication?.processIdentifier
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let self, app?.processIdentifier != initial else { return }
                self.stop()
            }
        }
    }
}

extension DemoTypeStep {
    var isPaste: Bool { if case .paste = self { true } else { false } }
}
