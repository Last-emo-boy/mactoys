import AppKit
import AudioToolbox
import CoreAudio
import Darwin
import Foundation
import MacToysCore

/// Small typed wrappers around `AudioObjectGetPropertyData` and friends. Safe to call from any thread.
enum HAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    /// UIDs of App Volume's own (private) aggregate devices start with this; they're never listed.
    static let aggregatePrefix = "com.w33d.mactoys.appvolume."

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func has(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                    _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Bool {
        var a = address(selector, scope)
        return AudioObjectHasProperty(object, &a)
    }

    static func isSettable(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                           _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Bool {
        var a = address(selector, scope)
        guard AudioObjectHasProperty(object, &a) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(object, &a, &settable) == noErr && settable.boolValue
    }

    /// A fixed-size value (UInt32, Float32, Float64, AudioStreamBasicDescription…).
    static func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, as _: T.Type = T.self,
                       initial: T) -> T? {
        var a = address(selector, scope)
        guard AudioObjectHasProperty(object, &a) else { return nil }
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &a, 0, nil, &size, $0) }
        return status == noErr ? value : nil
    }

    static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        get(object, selector, scope, initial: UInt32(0))
    }

    static func float32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Float32? {
        get(object, selector, scope, initial: Float32(0))
    }

    static func float64(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Float64? {
        get(object, selector, scope, initial: Float64(0))
    }

    static func array<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, of _: T.Type,
                         zero: T) -> [T] {
        var a = address(selector, scope)
        var size: UInt32 = 0
        guard AudioObjectHasProperty(object, &a), AudioObjectGetPropertyDataSize(object, &a, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var out = [T](repeating: zero, count: Int(size) / MemoryLayout<T>.stride)
        let status = out.withUnsafeMutableBytes { AudioObjectGetPropertyData(object, &a, 0, nil, &size, $0.baseAddress!) }
        guard status == noErr else { return [] }
        return Array(out.prefix(Int(size) / MemoryLayout<T>.stride))
    }

    static func objects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        array(object, selector, scope, of: AudioObjectID.self, zero: 0)
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> String? {
        var a = address(selector, scope)
        guard AudioObjectHasProperty(object, &a) else { return nil }
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &a, 0, nil, &size, $0) }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    @discardableResult
    static func set<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ value: T) -> OSStatus {
        var a = address(selector, scope)
        var v = value
        return withUnsafeMutablePointer(to: &v) {
            AudioObjectSetPropertyData(object, &a, 0, nil, UInt32(MemoryLayout<T>.size), $0)
        }
    }

    /// Channels per stream buffer, from `kAudioDevicePropertyStreamConfiguration`.
    static func bufferChannels(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope) -> [Int] {
        var a = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &a, 0, nil, &size, raw) == noErr else { return [] }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.map { Int($0.mNumberChannels) }
    }

    static func deviceID(uid: String) -> AudioObjectID? {
        devices().first { string($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    static func devices() -> [AudioObjectID] { objects(system, kAudioHardwarePropertyDevices) }

    /// The device's stereo pair, 1-based (default 1 and 2).
    static func preferredStereo(_ device: AudioObjectID) -> (Int, Int) {
        let pair = array(device, kAudioDevicePropertyPreferredChannelsForStereo, kAudioObjectPropertyScopeOutput,
                         of: UInt32.self, zero: 0)
        guard pair.count == 2, pair[0] > 0, pair[1] > 0 else { return (1, 2) }
        return (Int(pair[0]), Int(pair[1]))
    }

    static func dataSourceName(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope) -> String? {
        guard var source = uint32(device, kAudioDevicePropertyDataSource, scope) else { return nil }
        var name: Unmanaged<CFString>?
        var a = address(kAudioDevicePropertyDataSourceNameForIDCFString, scope)
        let status = withUnsafeMutablePointer(to: &source) { input in
            withUnsafeMutablePointer(to: &name) { output in
                var translation = AudioValueTranslation(mInputData: input, mInputDataSize: UInt32(MemoryLayout<UInt32>.size),
                                                        mOutputData: output,
                                                        mOutputDataSize: UInt32(MemoryLayout<Unmanaged<CFString>?>.size))
                var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
                return AudioObjectGetPropertyData(device, &a, 0, nil, &size, &translation)
            }
        }
        guard status == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }

    static func deviceInfo(_ id: AudioObjectID) -> AudioDeviceInfo? {
        guard let uid = string(id, kAudioDevicePropertyDeviceUID), !uid.hasPrefix(aggregatePrefix),
              uint32(id, kAudioDevicePropertyIsHidden) != 1 else { return nil }
        let outputs = bufferChannels(id, kAudioObjectPropertyScopeOutput).reduce(0, +)
        let inputs = bufferChannels(id, kAudioObjectPropertyScopeInput).reduce(0, +)
        guard outputs > 0 || inputs > 0 else { return nil }
        return AudioDeviceInfo(id: id, uid: uid, name: string(id, kAudioObjectPropertyName) ?? uid,
                               outputChannels: outputs, inputChannels: inputs,
                               sampleRate: float64(id, kAudioDevicePropertyNominalSampleRate) ?? 48_000,
                               transport: uint32(id, kAudioDevicePropertyTransportType) ?? 0,
                               dataSource: outputs > 0 ? dataSourceName(id, kAudioObjectPropertyScopeOutput) : nil)
    }
}

/// Reads processes and devices into an `AudioWorld`, watches them for changes, and sets the
/// system's default devices, volumes and mutes.
@MainActor
final class AudioSystem {
    private struct Listener {
        var object: AudioObjectID
        var address: AudioObjectPropertyAddress
        var block: AudioObjectPropertyListenerBlock
    }

    /// `true` for changes that need a new snapshot; `false` for volume and mute only.
    var onChange: ((_ structural: Bool) -> Void)?
    private var systemListeners: [Listener] = []
    private var processListeners: [AudioObjectID: [Listener]] = [:]
    private var deviceListeners: [AudioObjectID: [Listener]] = [:]
    private var owners: [AudioObjectID: (pid: pid_t, identity: AppIdentity)] = [:]
    private let ownPID = getpid()
    private let log = Log.for("appvolume")
    private(set) var isListening = false

    // MARK: Snapshot

    func snapshot() -> AudioWorld {
        var world = AudioWorld()
        world.devices = HAL.devices().compactMap(HAL.deviceInfo)
        let byID = Dictionary(world.devices.map { ($0.id, $0.uid) }, uniquingKeysWith: { a, _ in a })
        if let id = HAL.get(HAL.system, kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID(0)) { world.defaultOutputUID = byID[id] }
        if let id = HAL.get(HAL.system, kAudioHardwarePropertyDefaultInputDevice, initial: AudioObjectID(0)) { world.defaultInputUID = byID[id] }

        let running = NSWorkspace.shared.runningApplications.compactMap { app -> RunningAppInfo? in
            guard let id = app.bundleIdentifier else { return nil }
            return RunningAppInfo(bundleID: id, name: app.localizedName ?? id, bundlePath: app.bundleURL?.path)
        }
        var seen = Set<AudioObjectID>()
        for object in HAL.objects(HAL.system, kAudioHardwarePropertyProcessObjectList) {
            guard let pid = HAL.get(object, kAudioProcessPropertyPID, initial: pid_t(0)), pid > 0, pid != ownPID else { continue }
            seen.insert(object)
            let bundleID = HAL.string(object, kAudioProcessPropertyBundleID) ?? ""
            let identity: AppIdentity
            if let cached = owners[object], cached.pid == pid {
                identity = cached.identity
            } else {
                identity = Self.resolveOwner(pid: pid, bundleID: bundleID, running: running)
                owners[object] = (pid, identity)
            }
            guard identity.key != Paths.bundleIdentifier else { continue }
            let devices = HAL.objects(object, kAudioProcessPropertyDevices, kAudioObjectPropertyScopeOutput).compactMap { byID[$0] }
            world.processes.append(AudioProcessInfo(
                objectID: object, pid: pid, bundleID: bundleID,
                isRunningOutput: (HAL.uint32(object, kAudioProcessPropertyIsRunningOutput) ?? 0) != 0,
                outputDeviceUIDs: devices, owner: identity))
        }
        owners = owners.filter { seen.contains($0.key) }
        if isListening { syncObjectListeners(processes: seen, devices: Set(world.devices.map(\.id))) }
        return world
    }

    private static func resolveOwner(pid: pid_t, bundleID: String, running: [RunningAppInfo]) -> AppIdentity {
        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let path = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 ? String(cString: pathBuffer) : nil
        var nameBuffer = [CChar](repeating: 0, count: 256)
        let name = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count)) > 0 ? String(cString: nameBuffer) : ""
        let process = OwnerResolver.Process(bundleID: bundleID, executablePath: path,
                                            displayName: NSRunningApplication(processIdentifier: pid)?.localizedName,
                                            processName: name)
        return OwnerResolver.identity(of: process, running: running) { appPath in
            guard let id = Bundle(path: appPath)?.bundleIdentifier else { return nil }
            let display = FileManager.default.displayName(atPath: appPath)
            return (id, display.hasSuffix(".app") ? String(display.dropLast(4)) : display)
        }
    }

    // MARK: Listening

    func startListening() {
        guard !isListening else { return }
        isListening = true
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice,
                         kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyProcessObjectList] {
            if let l = listen(HAL.system, HAL.address(selector), structural: true) { systemListeners.append(l) }
        }
    }

    func stopListening() {
        guard isListening else { return }
        isListening = false
        for l in systemListeners { remove(l) }
        for l in processListeners.values.flatMap({ $0 }) { remove(l) }
        for l in deviceListeners.values.flatMap({ $0 }) { remove(l) }
        systemListeners.removeAll()
        processListeners.removeAll()
        deviceListeners.removeAll()
        owners.removeAll()
    }

    private func syncObjectListeners(processes: Set<AudioObjectID>, devices: Set<AudioObjectID>) {
        for (object, list) in processListeners where !processes.contains(object) {
            list.forEach(remove)
            processListeners[object] = nil
        }
        for object in processes where processListeners[object] == nil {
            processListeners[object] = [
                listen(object, HAL.address(kAudioProcessPropertyIsRunningOutput), structural: true),
                listen(object, HAL.address(kAudioProcessPropertyDevices, kAudioObjectPropertyScopeOutput), structural: true),
            ].compactMap { $0 }
        }
        for (object, list) in deviceListeners where !devices.contains(object) {
            list.forEach(remove)
            deviceListeners[object] = nil
        }
        for object in devices where deviceListeners[object] == nil {
            var list: [Listener?] = [
                listen(object, HAL.address(kAudioDevicePropertyNominalSampleRate), structural: true),
                listen(object, HAL.address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput), structural: true),
                listen(object, HAL.address(kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeOutput), structural: true),
            ]
            for scope in [kAudioObjectPropertyScopeOutput, kAudioObjectPropertyScopeInput] {
                list.append(listen(object, HAL.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope), structural: false))
                list.append(listen(object, HAL.address(kAudioDevicePropertyMute, scope), structural: false))
            }
            list.append(listen(object, HAL.address(kAudioHardwareServiceDeviceProperty_VirtualMainBalance,
                                                   kAudioObjectPropertyScopeOutput), structural: false))
            deviceListeners[object] = list.compactMap { $0 }
        }
    }

    private func listen(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, structural: Bool) -> Listener? {
        var a = address
        guard AudioObjectHasProperty(object, &a) else { return nil }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.onChange?(structural) }
        }
        let status = AudioObjectAddPropertyListenerBlock(object, &a, DispatchQueue.main, block)
        guard status == noErr else {
            log.error("listener \(address.mSelector) on \(object) failed: \(status)")
            return nil
        }
        return Listener(object: object, address: address, block: block)
    }

    private func remove(_ l: Listener) {
        var a = l.address
        // Fails harmlessly for objects that are already gone.
        AudioObjectRemovePropertyListenerBlock(l.object, &a, DispatchQueue.main, l.block)
    }

    // MARK: Device control

    func volume(_ device: AudioObjectID, input: Bool = false) -> Float? {
        HAL.float32(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope(input))
    }

    func canSetVolume(_ device: AudioObjectID, input: Bool = false) -> Bool {
        HAL.isSettable(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope(input))
    }

    func setVolume(_ value: Float, on device: AudioObjectID, input: Bool = false) {
        let status = HAL.set(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope(input), min(max(value, 0), 1))
        if status != noErr { log.error("set volume failed: \(status)") }
    }

    func isMuted(_ device: AudioObjectID, input: Bool = false) -> Bool? {
        HAL.uint32(device, kAudioDevicePropertyMute, scope(input)).map { $0 != 0 }
    }

    func canMute(_ device: AudioObjectID, input: Bool = false) -> Bool {
        HAL.isSettable(device, kAudioDevicePropertyMute, scope(input))
    }

    func setMuted(_ muted: Bool, on device: AudioObjectID, input: Bool = false) {
        HAL.set(device, kAudioDevicePropertyMute, scope(input), UInt32(muted ? 1 : 0))
    }

    func balance(_ device: AudioObjectID) -> Float? {
        guard HAL.isSettable(device, kAudioHardwareServiceDeviceProperty_VirtualMainBalance, kAudioObjectPropertyScopeOutput) else { return nil }
        return HAL.float32(device, kAudioHardwareServiceDeviceProperty_VirtualMainBalance, kAudioObjectPropertyScopeOutput)
    }

    func setBalance(_ value: Float, on device: AudioObjectID) {
        HAL.set(device, kAudioHardwareServiceDeviceProperty_VirtualMainBalance, kAudioObjectPropertyScopeOutput, min(max(value, 0), 1))
    }

    /// Standard rates the device offers.
    func sampleRates(_ device: AudioObjectID) -> [Double] {
        let ranges = HAL.array(device, kAudioDevicePropertyAvailableNominalSampleRates, of: AudioValueRange.self,
                               zero: AudioValueRange(mMinimum: 0, mMaximum: 0))
        let standard: [Double] = [8_000, 11_025, 16_000, 22_050, 32_000, 44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]
        return standard.filter { r in ranges.contains { r >= $0.mMinimum && r <= $0.mMaximum } }
    }

    func setSampleRate(_ rate: Double, on device: AudioObjectID) {
        let status = HAL.set(device, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, Float64(rate))
        if status != noErr { log.error("set sample rate failed: \(status)") }
    }

    func setDefault(_ device: AudioObjectID, input: Bool) {
        let selector = input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice
        let status = HAL.set(HAL.system, selector, kAudioObjectPropertyScopeGlobal, device)
        if status != noErr { log.error("set default device failed: \(status)") }
    }

    private func scope(_ input: Bool) -> AudioObjectPropertyScope {
        input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
    }
}
