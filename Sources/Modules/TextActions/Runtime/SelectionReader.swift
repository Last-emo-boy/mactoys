import AppKit
import ApplicationServices
import MacToysCore

/// A selection read from another app.
struct SelectionSnapshot: @unchecked Sendable {
    var text: String
    /// Bounds of the selected text, global top-left; nil when the app doesn't report them.
    var bounds: CGRect?
    var isEditable: Bool
    /// The focused text element, for replacing through Accessibility.
    var element: AXUIElement?
    /// A standard text field or text view of an AppKit app, where setting the selected text
    /// through Accessibility is reliable and undoable.
    var isNativeTextControl: Bool
    var isSecure: Bool
    var pid: pid_t
    var appName: String?
    var bundleID: String?
    /// Read by pressing ⌘C.
    var viaClipboard = false

    static func empty(pid: pid_t, appName: String?, bundleID: String?) -> SelectionSnapshot {
        SelectionSnapshot(text: "", bounds: nil, isEditable: false, element: nil, isNativeTextControl: false, isSecure: false,
                          pid: pid, appName: appName, bundleID: bundleID)
    }
}

/// Reads the selection of the frontmost app through Accessibility.
enum SelectionReader {
    private static let timeout: Float = 0.35
    private static let textRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole]
    /// Apps whose text fields look standard but ignore a replaced selection.
    private static let pasteOnlyBundles: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "org.chromium.Chromium", "com.microsoft.edgemac",
        "com.brave.Browser", "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
        "org.mozilla.firefox", "com.apple.Safari", "com.apple.SafariTechnologyPreview",
    ]

    /// The focused element's selection. Blocks up to about a second on an unresponsive app:
    /// call it off the main thread.
    static func read(pid: pid_t, appName: String?, bundleID: String?, bundleURL: URL?) -> SelectionSnapshot? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        var focused: AXUIElement? = app.ax(kAXFocusedUIElementAttribute)
        if focused == nil {
            let system = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(system, timeout)
            focused = system.ax(kAXFocusedUIElementAttribute)
        }
        guard let element = focused else { return nil }
        AXUIElementSetMessagingTimeout(element, timeout)

        var snapshot = SelectionSnapshot.empty(pid: pid, appName: appName, bundleID: bundleID)
        snapshot.element = element
        let role: String? = element.ax(kAXRoleAttribute)
        let subrole: String? = element.ax(kAXSubroleAttribute)
        if subrole == kAXSecureTextFieldSubrole as String {
            snapshot.isSecure = true
            return snapshot
        }

        if let text: String = element.ax(kAXSelectedTextAttribute), !text.isEmpty {
            snapshot.text = text
            snapshot.bounds = rangeBounds(element) ?? markerSelection(element)?.bounds
        } else if let marked = markerSelection(element), !marked.text.isEmpty {
            snapshot.text = marked.text
            snapshot.bounds = marked.bounds
        }

        let selectedSettable = isSettable(element, kAXSelectedTextAttribute)
        let isTextRole = role.map(textRoles.contains) ?? false
        snapshot.isEditable = selectedSettable || (isTextRole && isSettable(element, kAXValueAttribute))
        snapshot.isNativeTextControl = isTextRole && selectedSettable
            && !(bundleID.map(pasteOnlyBundles.contains) ?? false) && !isElectron(bundleURL)
        return snapshot
    }

    private static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success && settable.boolValue
    }

    private static func isElectron(_ bundleURL: URL?) -> Bool {
        guard let bundleURL else { return false }
        let framework = bundleURL.appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
        return FileManager.default.fileExists(atPath: framework.path)
    }

    /// `AXBoundsForRange` of the selected range.
    private static func rangeBounds(_ element: AXUIElement) -> CGRect? {
        guard let rangeValue: AXValue = element.ax(kAXSelectedTextRangeAttribute) else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &range), range.length > 0 else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         rangeValue, &out) == .success else { return nil }
        return rect(out)
    }

    /// WebKit exposes selections in web content through text markers.
    private static func markerSelection(_ element: AXUIElement) -> (text: String, bounds: CGRect?)? {
        var marker: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, &marker) == .success,
              let marker else { return nil }
        var string: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, "AXStringForTextMarkerRange" as CFString, marker, &string) == .success,
              let text = string as? String else { return nil }
        var bounds: CFTypeRef?
        _ = AXUIElementCopyParameterizedAttributeValue(element, "AXBoundsForTextMarkerRange" as CFString, marker, &bounds)
        return (text, rect(bounds))
    }

    private static func rect(_ value: CFTypeRef?) -> CGRect? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var r = CGRect.zero
        // The type id was checked above, so this cast cannot fail.
        guard AXValueGetValue(value as! AXValue, .cgRect, &r) else { return nil }
        return r
    }

    /// Rejects the zero, huge or off-screen rects some apps return instead of failing.
    @MainActor
    static func plausible(_ rect: CGRect?) -> CGRect? {
        guard let rect, rect.height >= 4, rect.width >= 1, rect.origin != .zero else { return nil }
        let screens = NSScreen.screens.map(\.axFrame)
        guard screens.contains(where: { $0.insetBy(dx: -2, dy: -2).intersects(rect) }) else { return nil }
        // A selection taller than every screen is a whole-document range; the pointer is better.
        guard rect.height < (screens.map(\.height).max() ?? 4000) else { return nil }
        return rect
    }

    /// Presses ⌘C in the frontmost app, reads the copied text and puts the clipboard back.
    @MainActor
    static func copySelection() async -> String? {
        let pb = NSPasteboard.general
        let saved = ClipboardSnapshot.capture(pb)
        let before = pb.changeCount
        if ClipboardHistory.shared.isRunning { ClipboardHistory.shared.ignoreNextChange = true }
        KeySynth.copy()
        for _ in 0..<20 where pb.changeCount == before {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard pb.changeCount != before else { return nil }
        // Let the app finish writing every representation before reading and restoring.
        try? await Task.sleep(for: .milliseconds(30))
        let text = pb.string(forType: .string)
        saved.restore(pb)
        return text
    }
}

/// Every item and type on a pasteboard, so borrowing it for ⌘C or a paste puts back exactly
/// what the user had (rich text, images, files, app-private types).
struct ClipboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]
    /// Too large to hold twice (videos as data): restoring then only clears our own text.
    private let tooLarge: Bool

    private static let byteLimit = 64 * 1024 * 1024

    /// Types clipboard managers skip (nspasteboard.org conventions).
    static let markers: [NSPasteboard.PasteboardType] = [
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
        NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"),
    ]

    static func capture(_ pb: NSPasteboard = .general) -> ClipboardSnapshot {
        var total = 0
        var items: [[NSPasteboard.PasteboardType: Data]] = []
        for item in pb.pasteboardItems ?? [] {
            var entry: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else { continue }
                total += data.count
                if total > byteLimit { return ClipboardSnapshot(items: [], tooLarge: true) }
                entry[type] = data
            }
            if !entry.isEmpty { items.append(entry) }
        }
        return ClipboardSnapshot(items: items, tooLarge: false)
    }

    /// Puts the captured items back (an empty clipboard stays empty).
    func restore(_ pb: NSPasteboard = .general) {
        guard !tooLarge else { return }
        pb.clearContents()
        guard !items.isEmpty else { return }
        pb.writeObjects(items.map { entry in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        })
    }

    /// Writes text marked as transient so clipboard managers leave it out.
    @MainActor
    static func writeTransient(_ text: String, to pb: NSPasteboard = .general) {
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        for marker in markers { item.setData(Data(), forType: marker) }
        pb.writeObjects([item])
    }
}

/// Replaces the selection in the app it came from.
@MainActor
enum TextReplacer {
    /// Through Accessibility in standard AppKit text controls (reliable and undoable there),
    /// otherwise by pasting and putting the clipboard back.
    static func replace(_ snapshot: SelectionSnapshot, with text: String, preferPaste: Bool) async {
        if !preferPaste, !snapshot.viaClipboard, snapshot.isNativeTextControl, let element = snapshot.element,
           AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success {
            return
        }
        await paste(text)
    }

    /// Pastes `text` with ⌘V and restores the clipboard afterwards.
    static func paste(_ text: String) async {
        let pb = NSPasteboard.general
        let saved = ClipboardSnapshot.capture(pb)
        if ClipboardHistory.shared.isRunning { ClipboardHistory.shared.ignoreNextChange = true }
        ClipboardSnapshot.writeTransient(text, to: pb)
        KeySynth.paste()
        // The target app reads the pasteboard asynchronously; give it time before restoring.
        try? await Task.sleep(for: .milliseconds(650))
        saved.restore(pb)
    }

    /// Puts text on the clipboard for the user to keep.
    static func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}
