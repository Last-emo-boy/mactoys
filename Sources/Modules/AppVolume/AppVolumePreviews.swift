import CoreAudio
import Foundation
import MacToysCore
import SwiftUI

/// Sample data for `MacToys --snapshot … --only appvolume`.
@MainActor
enum AppVolumePreviews {
    static var scenes: [PreviewScene] {
        [PreviewScene("flyout", size: CGSize(width: 420, height: 580)) { AnyView(scene()) },
         PreviewScene("equalizer", size: CGSize(width: 420, height: 860)) { AnyView(scene(expanded: music.key)) },
         PreviewScene("devices", size: CGSize(width: 420, height: 830)) { AnyView(scene(outputOpen: true, inputOpen: true)) },
         PreviewScene("permission", size: CGSize(width: 420, height: 720)) { AnyView(scene(capture: .silent)) },
         PreviewScene("empty", size: CGSize(width: 420, height: 420)) { AnyView(scene(empty: true)) }]
    }

    static let music = AppIdentity(key: "com.apple.Music", name: "Music")
    static let safari = AppIdentity(key: "com.apple.Safari", name: "Safari")
    static let zoom = AppIdentity(key: "us.zoom.xos", name: "Zoom")
    static let podcasts = AppIdentity(key: "com.apple.podcasts", name: "Podcasts")

    static func scene(expanded: String? = nil, outputOpen: Bool = false, inputOpen: Bool = false,
                      capture: TapController.Capture = .granted, empty: Bool = false) -> some View {
        let module = sampleModule(capture: capture, empty: empty)
        return AppVolumeFlyout(module: module, maxHeight: 2000, expanded: expanded, outputOpen: outputOpen, inputOpen: inputOpen)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 20)
    }

    static func sampleModule(capture: TapController.Capture = .granted, empty: Bool = false) -> AppVolumeModule {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mactoys-preview-\(UUID().uuidString)")
        let module = AppVolumeModule(store: SettingsStore(directory: dir), preview: true)
        let speakers = AudioDeviceInfo(id: 1, uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers", outputChannels: 2,
                                       transport: kAudioDeviceTransportTypeBuiltIn)
        let airpods = AudioDeviceInfo(id: 2, uid: "AirPods-Pro", name: "AirPods Pro", outputChannels: 2, inputChannels: 1,
                                      transport: kAudioDeviceTransportTypeBluetooth)
        let display = AudioDeviceInfo(id: 3, uid: "Studio-Display", name: "Studio Display Speakers", outputChannels: 2,
                                      transport: kAudioDeviceTransportTypeUSB)
        let mic = AudioDeviceInfo(id: 4, uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", inputChannels: 1,
                                  transport: kAudioDeviceTransportTypeBuiltIn)
        let displayMic = AudioDeviceInfo(id: 5, uid: "Studio-Display-Mic", name: "Studio Display Microphone", inputChannels: 1,
                                         transport: kAudioDeviceTransportTypeUSB)
        let store = module.store
        store.world = AudioWorld(devices: [speakers, airpods, display, mic, displayMic], defaultOutputUID: speakers.uid,
                                 defaultInputUID: mic.uid)
        store.output = DeviceControls(volume: 0.62, canSetVolume: true, muted: false, canMute: true, balance: 0.5,
                                      sampleRates: [44_100, 48_000, 88_200, 96_000])
        store.input = DeviceControls(volume: 0.74, canSetVolume: true, muted: false, canMute: true)
        store.capture = capture
        store.hasScanned = true
        guard !empty else { return module }

        module.settings.update { s in
            s.pinnedApps = [podcasts.key]
            s.apps[music.key] = AppAudioSettings(name: music.name,
                                                 eq: EQSettings(isOn: true, preset: "rock", gains: EQPreset.named("rock")?.gains(count: 10) ?? []))
            s.apps[safari.key] = AppAudioSettings(name: safari.name, volume: 0.65)
            s.apps[zoom.key] = AppAudioSettings(name: zoom.name, volume: 1.3, outputUID: airpods.uid, outputName: airpods.name,
                                                eq: EQSettings(isOn: true, preset: "voice", gains: EQPreset.named("voice")?.gains(count: 10) ?? []))
            s.apps[podcasts.key] = AppAudioSettings(name: podcasts.name, volume: 0.8, muted: true)
        }
        store.rows = [AppRow(identity: podcasts, state: .quiet), AppRow(identity: music, state: .playing),
                      AppRow(identity: safari, state: .playing), AppRow(identity: zoom, state: .playing)]
        store.processing = capture == .granted ? [music.key, safari.key, zoom.key] : []
        module.levels.levels = [music.key: StereoLevel(left: 0.82, right: 0.77),
                                safari.key: StereoLevel(left: 0.55, right: 0.58),
                                zoom.key: StereoLevel(left: 0.66, right: 0.47)]
        return module
    }
}
