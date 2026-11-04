import Foundation
import MacToysCore
import Testing
@testable import QuickSwitches

@Suite(.serialized) struct QuickSwitchesTests {
    /// A throwaway preferences domain, removed after each test.
    final class ScratchDomain {
        let name = "com.w33d.mactoys.tests.switches.\(UUID().uuidString)"

        func bool(_ key: String, default value: Bool) -> DefaultsBool {
            DefaultsBool(domain: name, key: key, defaultValue: value)
        }

        func setRaw(_ key: String, _ value: CFPropertyList?) {
            CFPreferencesSetAppValue(key as CFString, value, name as CFString)
            CFPreferencesAppSynchronize(name as CFString)
        }

        deinit {
            let id = name as CFString
            if let keys = CFPreferencesCopyKeyList(id, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] {
                for k in keys { CFPreferencesSetAppValue(k as CFString, nil, id) }
            }
            CFPreferencesAppSynchronize(id)
            let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/\(name).plist")
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: Defaults

    @Test func missingKeysReadAsTheirDefault() {
        let d = ScratchDomain()
        #expect(d.bool("CreateDesktop", default: true).read() == true)
        #expect(d.bool("AppleShowAllFiles", default: false).read() == false)
    }

    @Test func writingAndReadingBack() {
        let d = ScratchDomain()
        let pref = d.bool("autohide", default: false)
        #expect(pref.write(true))
        #expect(pref.read() == true)
        #expect(pref.write(false))
        #expect(pref.read() == false)
        #expect(pref.remove())
        #expect(pref.read() == false)
        let other = d.bool("other", default: true)
        #expect(other.write(false))
        #expect(other.read() == false)
        #expect(other.remove())
        #expect(other.read() == true)
    }

    @Test func valuesWrittenByDefaultsInOtherForms() {
        let d = ScratchDomain()
        let pref = d.bool("AppleShowAllFiles", default: false)
        d.setRaw("AppleShowAllFiles", "YES" as CFString)
        #expect(pref.read() == true)
        d.setRaw("AppleShowAllFiles", 0 as CFNumber)
        #expect(pref.read() == false)
        d.setRaw("AppleShowAllFiles", "true" as CFString)
        #expect(pref.read() == true)
        d.setRaw("AppleShowAllFiles", "maybe" as CFString)
        #expect(pref.read() == false) // unreadable: the default
        #expect(DefaultsBool.bool(1 as CFNumber) == true)
        #expect(DefaultsBool.bool(kCFBooleanFalse) == false)
        #expect(DefaultsBool.bool("NO" as CFString) == false)
    }

    @Test func switchStateMapsToThePreference() {
        let d = ScratchDomain()
        // Hide Desktop Icons is on when Finder's CreateDesktop is false.
        let hide = DefaultsSwitch(pref: d.bool("CreateDesktop", default: true), onValue: false)
        #expect(!hide.isOn)
        #expect(hide.value(forOn: true) == false)
        #expect(hide.set(on: true))
        #expect(hide.isOn)
        #expect(hide.pref.read() == false)
        #expect(hide.set(on: false))
        #expect(!hide.isOn)
        let show = DefaultsSwitch(pref: d.bool("AppleShowAllFiles", default: false), onValue: true)
        #expect(!show.isOn)
        #expect(show.set(on: true))
        #expect(show.isOn)
    }

    @Test func builtInSwitchesUseTheSystemKeys() {
        #expect(DefaultsSwitch.hideDesktopIcons.pref == DefaultsBool(domain: "com.apple.finder", key: "CreateDesktop", defaultValue: true))
        #expect(DefaultsSwitch.hideDesktopIcons.onValue == false)
        #expect(DefaultsSwitch.showHiddenFiles.pref.key == "AppleShowAllFiles")
        #expect(DefaultsSwitch.autohideDock.pref.domain == "com.apple.dock")
        #expect(DefaultsSwitch.autohideMenuBar.pref.domain == nil)
    }

    // MARK: Settings and URL actions

    @Test func enabledAndShortcutsPerSwitch() throws {
        var s = SwitchesSettings()
        #expect(s.isEnabled(.hideDesktopIcons))
        #expect(!s.isEnabled(.lowPowerMode))
        #expect(s.shortcut(.darkMode) == nil)
        s.enabled[SwitchKind.lowPowerMode.rawValue] = true
        s.enabled[SwitchKind.hideDesktopIcons.rawValue] = false
        s.shortcuts[SwitchKind.darkMode.rawValue] = Shortcut(2, [.control, .option, .command])
        let back = try JSONDecoder().decode(SwitchesSettings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
        #expect(back.isEnabled(.lowPowerMode) && !back.isEnabled(.hideDesktopIcons))
        #expect(back.shortcut(.darkMode)?.keyCode == 2)
    }

    @Test func everySwitchHasAURLAction() {
        #expect(QuickSwitchesModule.actionNames.count == SwitchKind.allCases.count)
        #expect(Set(QuickSwitchesModule.actionNames.values).count == SwitchKind.allCases.count)
        for kind in SwitchKind.allCases {
            let name = QuickSwitchesModule.actionNames[kind]!
            #expect(QuickSwitchesModule.kind(forAction: name) == kind)
            #expect(QuickSwitchesModule.kind(forAction: kind.rawValue) == kind)
        }
        #expect(QuickSwitchesModule.kind(forAction: "nope") == nil)
    }

    @Test func togglesAndActions() {
        #expect(SwitchKind.hideDesktopIcons.isToggle)
        #expect(SwitchKind.bluetooth.isToggle)
        #expect(!SwitchKind.emptyTrash.isToggle)
        #expect(!SwitchKind.cleanKeyboard.isToggle)
        let defaults = SwitchKind.allCases.filter(\.enabledByDefault)
        #expect(defaults.allSatisfy { $0.isToggle })
    }

    // MARK: Bluetooth

    @Test func deviceKinds() {
        #expect(BluetoothKind.classify(name: "Maya’s AirPods Pro", major: 0x04, minor: 0x06) == .airpodsPro)
        #expect(BluetoothKind.classify(name: "AirPods Max", major: 0x04, minor: 0x06) == .airpodsMax)
        #expect(BluetoothKind.classify(name: "Jonas’s AirPods", major: 0x04, minor: 0x01) == .airpods)
        #expect(BluetoothKind.classify(name: "WH-1000XM5", major: 0x04, minor: 0x06) == .headphones)
        #expect(BluetoothKind.classify(name: "Kitchen", major: 0x04, minor: 0x05) == .speaker)
        #expect(BluetoothKind.classify(name: "Magic Keyboard", major: 0x05, minor: 0x10) == .keyboard)
        #expect(BluetoothKind.classify(name: "MX Master 3S", major: 0x05, minor: 0x20) == .mouse)
        #expect(BluetoothKind.classify(name: "Magic Trackpad", major: 0x05, minor: 0x20) == .trackpad)
        #expect(BluetoothKind.classify(name: "Xbox Wireless Controller", major: 0x05, minor: 0x02) == .gameController)
        #expect(BluetoothKind.classify(name: "Maya’s iPhone", major: 0x02, minor: 0x03) == .phone)
        #expect(BluetoothKind.classify(name: "UE BOOM 3", major: 0x1F, minor: 0) == .speaker)
        #expect(BluetoothKind.classify(name: "Thing", major: 0x1F, minor: 0) == .other)
        #expect(BluetoothKind.headphones.isAudio && !BluetoothKind.keyboard.isAudio)
    }

    @Test func deviceListOrderAndPinning() {
        let keyboard = BluetoothDeviceInfo(id: "aa", name: "Magic Keyboard", connected: true, kind: .keyboard)
        let pods = BluetoothDeviceInfo(id: "bb", name: "AirPods Pro", connected: false, kind: .airpodsPro)
        let speaker = BluetoothDeviceInfo(id: "cc", name: "Kitchen Speaker", connected: false, kind: .speaker)
        let mouse = BluetoothDeviceInfo(id: "dd", name: "MX Master", connected: false, kind: .mouse)
        let list = [mouse, speaker, keyboard, pods]
        #expect(BluetoothDeviceInfo.sorted(list).map(\.id) == ["aa", "bb", "cc", "dd"])
        // Nothing pinned yet: every audio device.
        #expect(BluetoothDeviceInfo.shown(list, pinned: nil).map(\.id) == ["bb", "cc"])
        // Pinned: in the user's order; forgotten devices drop out.
        #expect(BluetoothDeviceInfo.shown(list, pinned: ["dd", "zz", "bb"]).map(\.id) == ["dd", "bb"])
        #expect(BluetoothDeviceInfo.shown(list, pinned: []).isEmpty)
    }

    // MARK: Clean keyboard

    @Test func countdown() {
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        let s = CleanKeyboardSession(start: start, duration: 30)
        #expect(s.secondsLeft(at: start) == 30)
        #expect(s.secondsLeft(at: start.addingTimeInterval(0.2)) == 30)
        #expect(s.secondsLeft(at: start.addingTimeInterval(1)) == 29)
        #expect(s.secondsLeft(at: start.addingTimeInterval(29.5)) == 1)
        #expect(s.secondsLeft(at: start.addingTimeInterval(31)) == 0)
        #expect(!s.isOver(at: start.addingTimeInterval(29.9)))
        #expect(s.isOver(at: start.addingTimeInterval(30)))
        #expect(s.progress(at: start.addingTimeInterval(15)) == 0.5)
        #expect(s.progress(at: start.addingTimeInterval(-5)) == 0)
        #expect(s.progress(at: start.addingTimeInterval(45)) == 1)
        #expect(CleanKeyboardSession(start: start, duration: 0).duration == 1)
    }

    /// Presses esc at each offset (seconds after the start); returns whether each press stopped the session.
    private func escapes(_ s: inout CleanKeyboardSession, _ offsets: [TimeInterval]) -> [Bool] {
        offsets.map { s.registerEscape(at: s.start.addingTimeInterval($0)) }
    }

    @Test func threeEscapesStopEarly() {
        var s = CleanKeyboardSession(start: Date(timeIntervalSinceReferenceDate: 1000), duration: 30)
        #expect(escapes(&s, [1, 1.4]) == [false, false])
        #expect(s.escapeCount == 2)
        #expect(escapes(&s, [1.8]) == [true])
    }

    @Test func slowOrInterruptedEscapesDontCount() {
        var s = CleanKeyboardSession(start: Date(timeIntervalSinceReferenceDate: 1000), duration: 30)
        // The first press is older than the window by the third one.
        #expect(escapes(&s, [1, 2, 3.5]) == [false, false, false])
        #expect(s.escapeCount == 2)
        s.registerOtherKey()
        #expect(s.escapeCount == 0)
        #expect(escapes(&s, [4, 4.2, 4.4]) == [false, false, true])
    }

    @Test func countdownClock() {
        #expect(CleanKeyboardSession.clock(27, locale: Locale(identifier: "en_US")) == "0:27")
        #expect(CleanKeyboardSession.clock(90, locale: Locale(identifier: "en_US")) == "1:30")
    }

    // MARK: Microphone and Focus

    @Test func microphoneMuteRules() {
        #expect(MicrophoneMute.isMuted(volume: 0))
        #expect(MicrophoneMute.isMuted(volume: 0.005))
        #expect(!MicrophoneMute.isMuted(volume: 0.4))
        #expect(!MicrophoneMute.isMuted(volume: nil))
        #expect(MicrophoneMute.restoreLevel(remembered: 0.62) == 0.62)
        #expect(MicrophoneMute.restoreLevel(remembered: nil) == MicrophoneMute.fallbackLevel)
        #expect(MicrophoneMute.restoreLevel(remembered: 0) == MicrophoneMute.fallbackLevel)
        #expect(MicrophoneMute.restoreLevel(remembered: 1.4) == 1)
    }

    @Test func focusShortcuts() {
        #expect(FocusShortcuts.parseList("Work Focus\nDo Not Disturb On\n\n  Do Not Disturb Off \nDo Not Disturb On\n")
                == ["Do Not Disturb Off", "Do Not Disturb On", "Work Focus"])
        #expect(FocusShortcuts.shortcut(toTurnOn: true, onShortcut: "DND On", offShortcut: "DND Off") == "DND On")
        #expect(FocusShortcuts.shortcut(toTurnOn: false, onShortcut: "DND On", offShortcut: "DND Off") == "DND Off")
        #expect(FocusShortcuts.shortcut(toTurnOn: false, onShortcut: "Toggle DND", offShortcut: nil) == "Toggle DND")
        #expect(FocusShortcuts.shortcut(toTurnOn: true, onShortcut: nil, offShortcut: "DND Off") == nil)
        let on = Data(#"{"data":[{"storeAssertionRecords":[{"assertionDetails":{"assertionDetailsModeIdentifier":"com.apple.donotdisturb.mode.default"}}]}]}"#.utf8)
        let off = Data(#"{"data":[{}]}"#.utf8)
        #expect(FocusShortcuts.parseAssertions(on) == true)
        #expect(FocusShortcuts.parseAssertions(off) == false)
        #expect(FocusShortcuts.parseAssertions(Data("nope".utf8)) == nil)
    }
}
