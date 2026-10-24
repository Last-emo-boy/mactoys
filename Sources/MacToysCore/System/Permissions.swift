import AppKit
import ApplicationServices
import AVFoundation
import CoreLocation
import IOKit.hid
import Observation

public enum Permission: String, CaseIterable, Codable, Sendable, Identifiable {
    case accessibility
    case inputMonitoring
    case screenRecording
    case automation
    case fullDiskAccess
    case microphone
    case location

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .accessibility: "Accessibility"
        case .inputMonitoring: "Input Monitoring"
        case .screenRecording: "Screen Recording"
        case .automation: "Automation"
        case .fullDiskAccess: "Full Disk Access"
        case .microphone: "Microphone"
        case .location: "Location"
        }
    }

    public var reason: String {
        switch self {
        case .accessibility: "Move windows, listen for shortcuts, remap keys"
        case .inputMonitoring: "Watch keys for Quick Accent and mouse utilities"
        case .screenRecording: "Color Picker, Screen Ruler, OCR, ZoomIt, mirrors"
        case .automation: "Read the Finder selection, switch appearance"
        case .fullDiskAccess: "Optional · let File Locksmith see protected files"
        case .microphone: "ZoomIt recording audio and snip dictation"
        case .location: "Light Switch sunrise and sunset times"
        }
    }

    var settingsAnchor: String {
        switch self {
        case .accessibility: "Privacy_Accessibility"
        case .inputMonitoring: "Privacy_ListenEvent"
        case .screenRecording: "Privacy_ScreenCapture"
        case .automation: "Privacy_Automation"
        case .fullDiskAccess: "Privacy_AllFiles"
        case .microphone: "Privacy_Microphone"
        case .location: "Privacy_LocationServices"
        }
    }

    /// Optional permissions don't produce warnings on the dashboard.
    public var isOptional: Bool { self == .fullDiskAccess }
}

/// Live permission state, refreshed every couple of seconds while anything observes it.
@MainActor
@Observable
public final class PermissionCenter {
    public static let shared = PermissionCenter()

    public private(set) var granted: Set<Permission> = []
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var listeners: [(Set<Permission>) -> Void] = []
    @ObservationIgnored private let locationManager = CLLocationManager()

    private init() { refresh() }

    public func isGranted(_ p: Permission) -> Bool { granted.contains(p) }

    public func missing(_ list: [Permission]) -> [Permission] { list.filter { !granted.contains($0) } }

    /// Called whenever the set of granted permissions changes.
    public func onChange(_ listener: @escaping (Set<Permission>) -> Void) { listeners.append(listener) }

    public func startMonitoring() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { PermissionCenter.shared.refresh() }
        }
    }

    public func refresh() {
        var now: Set<Permission> = []
        if AXIsProcessTrusted() { now.insert(.accessibility) }
        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted { now.insert(.inputMonitoring) }
        if CGPreflightScreenCaptureAccess() { now.insert(.screenRecording) }
        if Self.automationGranted(bundleID: "com.apple.finder") { now.insert(.automation) }
        if Self.fullDiskAccessGranted() { now.insert(.fullDiskAccess) }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { now.insert(.microphone) }
        let loc = locationManager.authorizationStatus
        if loc == .authorizedAlways || loc == .authorized { now.insert(.location) }
        if now != granted {
            granted = now
            for l in listeners { l(now) }
        }
    }

    /// Triggers the system prompt where one exists, otherwise opens System Settings.
    public func request(_ p: Permission) {
        switch p {
        case .accessibility:
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            if !AXIsProcessTrustedWithOptions(opts) { openSettings(p) }
        case .inputMonitoring:
            if !IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) { openSettings(p) }
        case .screenRecording:
            if !CGRequestScreenCaptureAccess() { openSettings(p) }
        case .automation:
            Task.detached { _ = Self.automationGranted(bundleID: "com.apple.finder", ask: true) }
        case .microphone:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        case .location:
            locationManager.requestWhenInUseAuthorization()
        case .fullDiskAccess:
            openSettings(p)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.refresh() }
    }

    public func openSettings(_ p: Permission) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(p.settingsAnchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Whether we may send Apple Events to `bundleID`. With `ask`, shows the consent prompt.
    nonisolated public static func automationGranted(bundleID: String, ask: Bool = false) -> Bool {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let desc = target.aeDesc else { return false }
        let status = AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, ask)
        return status == noErr
    }

    nonisolated static func fullDiskAccessGranted() -> Bool {
        let probe = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.apple.stocks")
        return (try? FileManager.default.contentsOfDirectory(atPath: probe.path)) != nil
    }
}
