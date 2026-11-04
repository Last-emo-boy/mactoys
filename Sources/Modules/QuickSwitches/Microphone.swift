import CoreAudio
import Foundation
import MacToysCore

/// The default input device's volume through Core Audio (no permission needed: it changes the
/// device's level, it doesn't record).
enum Microphone {
    struct Device: Equatable {
        let id: AudioDeviceID
        let name: String
    }

    static func defaultInput() -> Device? {
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        return Device(id: id, name: name(of: id) ?? String(localized: "Microphone"))
    }

    private static func name(of id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }

    /// Elements that carry the input volume: the main element, or channels 1 and 2 on devices without one.
    private static func volumeElements(_ id: AudioDeviceID) -> [AudioObjectPropertyElement] {
        var main = address(kAudioObjectPropertyElementMain)
        if AudioObjectHasProperty(id, &main) { return [kAudioObjectPropertyElementMain] }
        return [1, 2].filter { var a = address($0); return AudioObjectHasProperty(id, &a) }
    }

    private static func address(_ element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeInput, mElement: element)
    }

    /// The input volume 0…1, or nil when the device has no volume control.
    static func volume(_ device: Device) -> Double? {
        let elements = volumeElements(device.id)
        guard !elements.isEmpty else { return nil }
        var total: Float32 = 0
        for e in elements {
            var a = address(e)
            var v: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            guard AudioObjectGetPropertyData(device.id, &a, 0, nil, &size, &v) == noErr else { return nil }
            total += v
        }
        return Double(total / Float32(elements.count))
    }

    /// Sets the input volume; false when the device doesn't allow it.
    @discardableResult
    static func setVolume(_ volume: Double, on device: Device) -> Bool {
        let elements = volumeElements(device.id)
        guard !elements.isEmpty else { return false }
        var ok = true
        for e in elements {
            var a = address(e)
            var settable: DarwinBoolean = false
            guard AudioObjectIsPropertySettable(device.id, &a, &settable) == noErr, settable.boolValue else { return false }
            var v = Float32(max(0, min(1, volume)))
            ok = ok && AudioObjectSetPropertyData(device.id, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr
        }
        return ok
    }
}

/// Mute state rules: what "muted" means and which level comes back.
enum MicrophoneMute {
    /// Below this the input is effectively silent.
    static let silent = 0.01
    /// Used when there is no remembered level (or it was zero).
    static let fallbackLevel = 0.75

    static func isMuted(volume: Double?) -> Bool {
        guard let volume else { return false }
        return volume < silent
    }

    /// The level to restore when unmuting.
    static func restoreLevel(remembered: Double?) -> Double {
        guard let remembered, remembered >= silent else { return fallbackLevel }
        return min(1, remembered)
    }
}
