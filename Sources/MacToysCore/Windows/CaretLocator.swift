import AppKit
import ApplicationServices

/// Where the text insertion point is in the frontmost app, read through Accessibility.
///
///     if let caret = CaretLocator.caretRect() { … }   // global top-left coordinates
///
/// Uses the focused element's selected text range and `AXBoundsForRange`. Returns nil when
/// the app doesn't expose it (many Electron and game windows) or Accessibility is not granted.
public enum CaretLocator {
    /// Bounds of the caret (or the selection) in global top-left coordinates.
    public static func caretRect() -> CGRect? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        guard let focused: AXUIElement = system.ax(kAXFocusedUIElementAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(focused, 0.25)
        guard let rangeValue: AXValue = focused.ax(kAXSelectedTextRangeAttribute) else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &range) else { return nil }

        if let rect = bounds(of: range, in: focused), plausible(rect) {
            return rect
        }
        // Some apps report an empty rect for a zero-length range: measure the character
        // before the caret and put the caret at its trailing edge.
        if range.length == 0, range.location > 0,
           let rect = bounds(of: CFRange(location: range.location - 1, length: 1), in: focused), plausible(rect) {
            return CGRect(x: rect.maxX, y: rect.minY, width: 1, height: rect.height)
        }
        return nil
    }

    private static func bounds(of range: CFRange, in element: AXUIElement) -> CGRect? {
        var r = range
        guard let param = AXValueCreate(.cfRange, &r) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         param, &out) == .success,
              let out, CFGetTypeID(out) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        // CFGetTypeID checked above, so the cast cannot fail.
        guard AXValueGetValue(out as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    /// Rejects the zero or off-screen rects some apps return instead of failing.
    private static func plausible(_ rect: CGRect) -> Bool {
        guard rect.height > 1, rect.height < 400, rect.origin != .zero else { return false }
        return NSScreen.screens.contains { $0.axFrame.insetBy(dx: -2, dy: -2).intersects(rect) }
    }
}
