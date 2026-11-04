import Foundation
import IOBluetooth
import MacToysCore

/// What kind of device a paired Bluetooth device is, for its icon and for "audio devices first".
enum BluetoothKind: String, Sendable, Equatable {
    case airpods, airpodsPro, airpodsMax, headphones, speaker, keyboard, mouse, trackpad, gameController, phone, computer, other

    var symbol: String {
        switch self {
        case .airpods: "airpods"
        case .airpodsPro: "airpods.pro"
        case .airpodsMax: "airpods.max"
        case .headphones: "headphones"
        case .speaker: "hifispeaker.fill"
        case .keyboard: "keyboard"
        case .mouse: "computermouse"
        case .trackpad: "rectangle.and.hand.point.up.left"
        case .gameController: "gamecontroller"
        case .phone: "iphone"
        case .computer: "laptopcomputer"
        case .other: "dot.radiowaves.left.and.right"
        }
    }

    var isAudio: Bool { [.airpods, .airpodsPro, .airpodsMax, .headphones, .speaker].contains(self) }

    /// From the device name and its Bluetooth Class of Device (major and minor class).
    static func classify(name: String, major: UInt32, minor: UInt32) -> BluetoothKind {
        let n = name.lowercased()
        if n.contains("airpods max") { return .airpodsMax }
        if n.contains("airpods pro") { return .airpodsPro }
        if n.contains("airpods") { return .airpods }
        if n.contains("trackpad") { return .trackpad }
        switch major {
        case 0x04: // audio/video
            switch minor {
            case 0x05, 0x0A: return .speaker          // loudspeaker, hi-fi audio
            default: return .headphones                // headset, hands-free, headphones…
            }
        case 0x05: // peripheral
            if minor & 0x10 != 0 { return .keyboard }
            if minor & 0x20 != 0 { return .mouse }
            if minor & 0x0F == 0x01 || minor & 0x0F == 0x02 { return .gameController } // joystick, gamepad
            return n.contains("keyboard") ? .keyboard : n.contains("mouse") ? .mouse : .other
        case 0x02: return .phone
        case 0x01: return .computer
        default:
            if n.contains("keyboard") { return .keyboard }
            if n.contains("mouse") { return .mouse }
            if n.contains("speaker") || n.contains("boom") || n.contains("soundlink") { return .speaker }
            if n.contains("buds") || n.contains("headphone") || n.contains("beats") { return .headphones }
            return .other
        }
    }
}

/// A paired device as the switches show it.
struct BluetoothDeviceInfo: Hashable, Identifiable, Sendable {
    /// The device address, "a4-83-e7-12-34-56".
    let id: String
    let name: String
    let connected: Bool
    let kind: BluetoothKind

    /// Connected first, then audio devices, then by name.
    static func sorted(_ list: [BluetoothDeviceInfo]) -> [BluetoothDeviceInfo] {
        list.sorted { a, b in
            if a.connected != b.connected { return a.connected }
            if a.kind.isAudio != b.kind.isAudio { return a.kind.isAudio }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// The devices shown as switches: the pinned ones, or every audio device when nothing is pinned yet.
    static func shown(_ list: [BluetoothDeviceInfo], pinned: [String]?) -> [BluetoothDeviceInfo] {
        guard let pinned else { return sorted(list.filter(\.kind.isAudio)) }
        return pinned.compactMap { id in list.first { $0.id == id } }
    }
}

/// Paired devices through IOBluetooth. macOS stops apps that touch Bluetooth without a usage
/// description, so everything here checks for `NSBluetoothAlwaysUsageDescription` first.
@MainActor
final class BluetoothDevices: NSObject {
    static var isAvailable: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription") != nil
    }

    private var pending: [String: (Bool) -> Void] = [:]

    func paired() -> [BluetoothDeviceInfo] {
        guard Self.isAvailable, let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else { return [] }
        return BluetoothDeviceInfo.sorted(devices.compactMap { d in
            guard let address = d.addressString else { return nil }
            let name = d.name ?? d.nameOrAddress ?? address
            return BluetoothDeviceInfo(id: address, name: name, connected: d.isConnected(),
                                       kind: BluetoothKind.classify(name: name, major: d.deviceClassMajor, minor: d.deviceClassMinor))
        })
    }

    func isConnected(_ address: String) -> Bool {
        guard Self.isAvailable, let d = IOBluetoothDevice(addressString: address) else { return false }
        return d.isConnected()
    }

    /// Connects or disconnects; `completion` gets whether it worked.
    func setConnected(_ on: Bool, address: String, completion: @escaping (Bool) -> Void) {
        guard Self.isAvailable, let d = IOBluetoothDevice(addressString: address) else { completion(false); return }
        if on {
            pending[address] = completion
            let status = d.openConnection(self)
            if status != kIOReturnSuccess {
                pending[address] = nil
                completion(false)
            }
        } else {
            completion(d.closeConnection() == kIOReturnSuccess)
        }
    }

    /// IOBluetooth's asynchronous `openConnection:` callback.
    @objc nonisolated func connectionComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        let address = device?.addressString ?? ""
        MainActor.assumeIsolated {
            let completion = pending.removeValue(forKey: address)
            completion?(status == kIOReturnSuccess)
        }
    }
}
