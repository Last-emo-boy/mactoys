import AppKit
import ApplicationServices

/// A window of another app, driven through the Accessibility API.
///
/// Frames are in **global top-left coordinates** (the AX / CoreGraphics space: origin at the
/// top-left of the primary display, y grows downward). Use `NSScreen.axFrame` to compare.
public struct WindowRef: Hashable, @unchecked Sendable {
    public let element: AXUIElement
    public let pid: pid_t

    public init(element: AXUIElement, pid: pid_t) {
        self.element = element
        self.pid = pid
    }

    public init?(element: AXUIElement) {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        self.init(element: element, pid: pid)
    }

    // MARK: Lookup

    /// The focused window of the frontmost app.
    public static func focused() -> WindowRef? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        if let win: AXUIElement = axApp.ax(kAXFocusedWindowAttribute) {
            return WindowRef(element: win, pid: app.processIdentifier)
        }
        return windows(of: app.processIdentifier).first
    }

    /// The window under a point (global top-left coordinates).
    public static func at(_ point: CGPoint) -> WindowRef? {
        let system = AXUIElementCreateSystemWide()
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
              var element = hit else { return nil }
        for _ in 0..<64 {
            if element.role == kAXWindowRole as String { return WindowRef(element: element) }
            if let win: AXUIElement = element.ax(kAXWindowAttribute) { return WindowRef(element: win) }
            guard let parent: AXUIElement = element.ax(kAXParentAttribute) else { break }
            element = parent
        }
        return nil
    }

    public static func windows(of pid: pid_t) -> [WindowRef] {
        let axApp = AXUIElementCreateApplication(pid)
        let list: [AXUIElement] = axApp.ax(kAXWindowsAttribute) ?? []
        return list.map { WindowRef(element: $0, pid: pid) }
    }

    /// Standard, on-screen-capable windows of every regular app.
    public static func allStandard() -> [WindowRef] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated }
            .flatMap { windows(of: $0.processIdentifier) }
            .filter { $0.isStandard }
    }

    /// Matches a CoreGraphics window id to its AX window.
    public static func with(windowID: CGWindowID) -> WindowRef? {
        guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]])?.first,
              let pid = info[kCGWindowOwnerPID as String] as? pid_t else { return nil }
        return windows(of: pid).first { $0.windowID == windowID }
    }

    // MARK: Attributes

    public var title: String? { element.ax(kAXTitleAttribute) }
    public var role: String? { element.role }
    public var subrole: String? { element.ax(kAXSubroleAttribute) }
    public var isStandard: Bool { subrole == kAXStandardWindowSubrole as String }
    public var isMinimized: Bool { element.ax(kAXMinimizedAttribute) ?? false }
    public var isFullScreen: Bool { element.ax("AXFullScreen") ?? false }
    public var app: NSRunningApplication? { NSRunningApplication(processIdentifier: pid) }
    public var appName: String { app?.localizedName ?? "" }
    public var bundleIdentifier: String? { app?.bundleIdentifier }

    public var isResizable: Bool {
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &settable)
        return settable.boolValue
    }

    /// CoreGraphics window number (private `_AXUIElementGetWindow`).
    public var windowID: CGWindowID? {
        guard let fn = AXPrivate.getWindow else { return nil }
        var id: CGWindowID = 0
        return fn(element, &id) == .success ? id : nil
    }

    public var position: CGPoint? {
        guard let v: AXValue = element.ax(kAXPositionAttribute) else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v, .cgPoint, &p) ? p : nil
    }

    public var size: CGSize? {
        guard let v: AXValue = element.ax(kAXSizeAttribute) else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v, .cgSize, &s) ? s : nil
    }

    public var frame: CGRect? {
        guard let p = position, let s = size else { return nil }
        return CGRect(origin: p, size: s)
    }

    // MARK: Actions

    @discardableResult
    public func setPosition(_ p: CGPoint) -> Bool {
        var point = p
        guard let v = AXValueCreate(.cgPoint, &point) else { return false }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, v) == .success
    }

    @discardableResult
    public func setSize(_ s: CGSize) -> Bool {
        var size = s
        guard let v = AXValueCreate(.cgSize, &size) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, v) == .success
    }

    /// Size → position → size, which survives apps that clamp size against the old position.
    public func setFrame(_ r: CGRect) {
        let enhanced = app.map { AXUIElementCreateApplication($0.processIdentifier) }
        let wasEnhanced: Bool = enhanced?.ax("AXEnhancedUserInterface") ?? false
        if wasEnhanced, let enhanced { AXUIElementSetAttributeValue(enhanced, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
        setSize(r.size)
        setPosition(r.origin)
        setSize(r.size)
        if wasEnhanced, let enhanced { AXUIElementSetAttributeValue(enhanced, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) }
    }

    /// Brings the window to the front and activates its app.
    public func focus() {
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        app?.activate()
    }

    public func raise() { AXUIElementPerformAction(element, kAXRaiseAction as CFString) }

    public func minimize(_ on: Bool = true) {
        AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, on ? kCFBooleanTrue : kCFBooleanFalse)
    }

    public func close() {
        if let button: AXUIElement = element.ax(kAXCloseButtonAttribute) {
            AXUIElementPerformAction(button, kAXPressAction as CFString)
        }
    }

    public static func == (a: WindowRef, b: WindowRef) -> Bool { CFEqual(a.element, b.element) }
    public func hash(into h: inout Hasher) { h.combine(CFHash(element)) }
}

/// Info about an on-screen window from the window server (no Accessibility needed).
public struct WindowInfo: Hashable, Sendable {
    public let id: CGWindowID
    public let pid: pid_t
    public let ownerName: String
    public let title: String
    /// Global top-left coordinates.
    public let frame: CGRect
    public let layer: Int
    public let isOnScreen: Bool

    /// Normal-level windows, front to back.
    public static func onScreen(includeOwn: Bool = false) -> [WindowInfo] {
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                    as? [[String: Any]]) ?? []
        let own = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { d -> WindowInfo? in
            guard let id = d[kCGWindowNumber as String] as? CGWindowID,
                  let pid = d[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = d[kCGWindowLayer as String] as? Int,
                  let boundsDict = d[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { return nil }
            if !includeOwn && pid == own { return nil }
            return WindowInfo(id: id, pid: pid, ownerName: d[kCGWindowOwnerName as String] as? String ?? "",
                              title: d[kCGWindowName as String] as? String ?? "", frame: bounds, layer: layer,
                              isOnScreen: d[kCGWindowIsOnscreen as String] as? Bool ?? true)
        }
        .filter { $0.layer == 0 && $0.frame.width > 40 && $0.frame.height > 40 }
    }
}

// MARK: - AX helpers

enum AXPrivate {
    typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    static let getWindow: GetWindowFn? = {
        guard let handle = dlopen(nil, RTLD_NOW), let sym = dlsym(handle, "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(sym, to: GetWindowFn.self)
    }()
}

extension AXUIElement {
    /// Typed attribute read: `let title: String? = element.ax(kAXTitleAttribute)`.
    public func ax<T>(_ attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &value) == .success, let value else { return nil }
        if T.self == AXUIElement.self || T.self == AXValue.self { return (value as! T) }
        return value as? T
    }

    public var role: String? { ax(kAXRoleAttribute) }

    public func set(_ attribute: String, _ value: CFTypeRef) {
        AXUIElementSetAttributeValue(self, attribute as CFString, value)
    }

    public func perform(_ action: String) {
        AXUIElementPerformAction(self, action as CFString)
    }

    public var children: [AXUIElement] { ax(kAXChildrenAttribute) ?? [] }
}

/// Watches AX notifications for one app (window moved, resized, created, destroyed, focus).
///
///     let watcher = AXWatcher(pid: pid) { notification, element in … }
///     watcher?.add(kAXMovedNotification, on: window.element)
public final class AXWatcher {
    public typealias Callback = (String, AXUIElement) -> Void
    private var observer: AXObserver?
    private let callback: Callback
    private let app: AXUIElement
    private var registered: [(String, AXUIElement)] = []

    public init?(pid: pid_t, callback: @escaping Callback) {
        self.callback = callback
        self.app = AXUIElementCreateApplication(pid)
        var obs: AXObserver?
        let status = AXObserverCreate(pid, { _, element, notification, refcon in
            guard let refcon else { return }
            let me = Unmanaged<AXWatcher>.fromOpaque(refcon).takeUnretainedValue()
            me.callback(notification as String, element)
        }, &obs)
        guard status == .success, let obs else { return nil }
        observer = obs
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
    }

    /// Observe `notification` on `element` (defaults to the application element).
    public func add(_ notification: String, on element: AXUIElement? = nil) {
        guard let observer else { return }
        let target = element ?? app
        AXObserverAddNotification(observer, target, notification as CFString, Unmanaged.passUnretained(self).toOpaque())
        registered.append((notification, target))
    }

    public func invalidate() {
        guard let observer else { return }
        for (n, e) in registered { AXObserverRemoveNotification(observer, e, n as CFString) }
        registered.removeAll()
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        self.observer = nil
    }

    deinit { invalidate() }
}
