import AppKit
import CoreGraphics
import MacToysCore

/// Resolution, software brightness, sync, arrangement, color, picture in picture and virtual displays.
extension PowerDisplayModule {
    // MARK: - Lifecycle

    /// Undoes everything these features changed (module stop and quit).
    func stopDisplayFeatures() {
        if let effect = confirmation.revert() { perform(effect) }
        confirmationTimer?.invalidate()
        confirmationTimer = nil
        confirmationPresenter.dismiss()
        syncTimer?.invalidate()
        syncTimer = nil
        lastSourceReading = nil
        stateSave?.cancel()
        saveState()
        for work in pendingMirrors { work.cancel() }
        pendingMirrors.removeAll()
        for w in Array(pipWindows.values) { w.close() }
        pipWindows.removeAll()
        store.pipOpen.removeAll()
        software.restoreAll()
        if settings.value.gammaDimmed { settings.value.gammaDimmed = false }
        for m in store.monitors { m.softDim = 0; m.boost = 0 }
        for h in virtualHandles.values { h.remove() }
        virtualHandles.removeAll()
        store.connectedVirtual.removeAll()
    }

    /// After a scan: drop state of displays that left, re-apply software brightness (display ids
    /// can change on reconnect; the system resets color tables on reconfiguration and wake).
    func displaysChanged() {
        let online = Set(store.monitors.map(\.snapshot.displayID))
        software.displaysChanged(online: online)
        for m in store.monitors { applySoftware(m) }
        if let pending = confirmation.pending, !online.contains(pending.displayID) {
            confirmation.displayRemoved(pending.displayID)
            updateConfirmationUI()
        }
        for (id, w) in pipWindows where !store.monitors.contains(where: { $0.id == id && $0.snapshot.displayID == w.displayID }) {
            w.close()
        }
        confirmationPresenter.layout()
        updateSync()
    }

    /// Reacts to settings that change how displays are driven (only when one of them changed:
    /// other settings change on every slider move).
    func displaySettingsChanged() {
        let s = settings.value
        let key = DisplayFeatureSettings(s)
        guard key != appliedFeatureSettings else { return }
        let modesChanged = key.hideLowResolutionModes != appliedFeatureSettings?.hideLowResolutionModes
        appliedFeatureSettings = key
        for m in store.monitors {
            let t = track(for: m)
            if t.dimShare == 0 && m.softDim > 0 { m.softDim = 0 }
            if t.boostShare == 0 && m.boost > 0 { m.boost = 0 }
            applySoftware(m)
        }
        for w in pipWindows.values { w.update(options: s.pip) }
        if modesChanged { for m in store.monitors { refreshModes(m) } }
        updateSync()
    }

    /// Re-reads arrangement, modes and color profiles (cheap CoreGraphics calls, main thread).
    func refreshDisplayFacts() {
        for m in store.monitors {
            let facts = DisplayFacts.read(m.snapshot.displayID)
            if m.facts != facts { m.facts = facts }
            refreshModes(m)
            let current = ColorProfiles.current(m.snapshot.displayID)
            if m.colorProfile != current { m.colorProfile = current }
            let factory = ColorProfiles.factory(m.snapshot.displayID)
            if m.factoryProfile != factory { m.factoryProfile = factory }
        }
    }

    func monitor(id: String) -> MonitorState? { store.monitors.first { $0.id == id } }

    /// A monitor named by number (`list`) or stable id, as URLs and the CLI pass them.
    func monitor(param: String?) -> MonitorState? {
        guard let p = param?.trimmingCharacters(in: .whitespaces), !p.isEmpty else { return nil }
        if let n = Int(p) { return store.monitors.first { $0.snapshot.number == n } }
        return monitor(id: p)
    }

    // MARK: - Software brightness

    /// The combined slider for a monitor. Displays without a hardware control always get software
    /// dimming; with one, dimming below its minimum follows the setting.
    func track(for m: MonitorState) -> BrightnessTrack {
        let s = settings.value
        let hardware = m.supports(.brightness)
        return BrightnessTrack(hasHardware: hardware, dimming: !hardware || s.softwareDimming,
                               boost: s.extraBrightness && m.facts.supportsExtraBrightness)
    }

    func brightnessPosition(_ m: MonitorState) -> Double { track(for: m).position(m.components) }

    /// The flyout slider moved.
    func setBrightnessPosition(_ position: Double, on m: MonitorState) {
        apply(track(for: m).components(at: position), to: m, byUser: true)
    }

    func stepBrightness(_ m: MonitorState, by delta: Double) {
        let t = track(for: m)
        if m.supports(.brightness) {
            let level = BrightnessLevel.level(m.components) + delta
            apply(BrightnessLevel.components(level, dimming: t.dimShare > 0, boost: t.boostShare > 0), to: m, byUser: true)
        } else {
            // Software only: dimming 0…1 plus extra brightness, in percent steps.
            var c = m.components
            if c.boost > 0 || (delta > 0 && c.dim == 0) {
                c.boost = t.boostShare > 0 ? max(0, min(1, c.boost + delta / 100)) : 0
            } else {
                c.dim = max(0, min(1, c.dim - delta / 100))
            }
            apply(c, to: m, byUser: true)
        }
    }

    /// Sets hardware brightness, software dimming and extra brightness of one monitor.
    func apply(_ c: BrightnessComponents, to m: MonitorState, byUser: Bool) {
        if m.supports(.brightness), abs((m.percent[.brightness] ?? -1) - c.hardware) >= 0.5 {
            set(.brightness, percent: c.hardware, on: m)
        }
        if m.softDim != c.dim || m.boost != c.boost {
            m.softDim = c.dim
            m.boost = c.boost
            applySoftware(m)
            scheduleStateSave()
        }
        guard byUser, isSyncing, let source = syncSourceMonitor else { return }
        if m.id == source.id {
            followSource()
        } else if syncFollowers.contains(where: { $0.id == m.id }) {
            syncOffsets[m.id] = BrightnessSync.offset(follower: BrightnessLevel.level(m.components),
                                                      source: BrightnessLevel.level(source.components))
            scheduleStateSave()
        }
    }

    func applySoftware(_ m: MonitorState) {
        let s = settings.value
        software.apply(m.snapshot.displayID,
                       dimFactor: SoftwareFactor.dim(m.softDim, maxDim: s.maxSoftwareDim),
                       boostFactor: SoftwareFactor.boost(m.boost, maxBoost: s.maxExtraBrightness),
                       method: s.dimMethod, gammaCapacity: m.facts.gammaCapacity)
        let dimmed = software.isGammaActive
        if s.gammaDimmed != dimmed { settings.value.gammaDimmed = dimmed }
    }

    /// Turns extra brightness on (after explaining what it does) or off.
    func setExtraBrightness(_ on: Bool) {
        if on && !settings.value.extraBrightness {
            guard confirm(String(localized: "Turn on extra brightness?"),
                          String(localized: "On XDR displays the brightness slider continues past 100 % into the HDR headroom. Sustained high brightness uses more power and warms the display; macOS may lower it again to protect the panel. Very bright parts of HDR videos and photos can lose detail while it's on."),
                          button: String(localized: "Turn On")) else { return }
        }
        settings.value.extraBrightness = on
    }

    /// Software dimming for the command line and URLs: 0 (off) … 100 (darkest allowed).
    func setSoftwareDim(percent: Double, on m: MonitorState) {
        var c = m.components
        c.dim = max(0, min(1, percent / 100))
        c.boost = 0
        if c.dim > 0, m.supports(.brightness) { c.hardware = 0 }
        apply(c, to: m, byUser: true)
    }

    /// The unified level of the linked group (see `BrightnessLevel`).
    var linkedLevel: Double {
        let values = linkedMonitors.map { BrightnessLevel.level($0.components) }
        return values.isEmpty ? 0 : (values.reduce(0, +) / Double(values.count)).rounded()
    }

    /// The All displays slider spans dimming and extra brightness when any linked display has them.
    var linkedTrack: BrightnessTrack {
        let tracks = linkedMonitors.map(track(for:))
        return BrightnessTrack(hasHardware: true, dimming: tracks.contains { $0.dimShare > 0 },
                               boost: tracks.contains { $0.boostShare > 0 })
    }

    func setLinkedLevel(_ level: Double) {
        for m in linkedMonitors {
            let t = track(for: m)
            apply(BrightnessLevel.components(level, dimming: t.dimShare > 0, boost: t.boostShare > 0), to: m, byUser: false)
        }
    }

    var linkedPosition: Double {
        let t = linkedTrack
        return t.position(BrightnessLevel.components(linkedLevel, dimming: t.dimShare > 0, boost: t.boostShare > 0))
    }

    func setLinkedPosition(_ p: Double) { setLinkedLevel(BrightnessLevel.level(linkedTrack.components(at: p))) }

    /// "Brightness 40 %", "Dimmed 30 %", "Extra brightness 50 %".
    func showBrightnessHUD(_ m: MonitorState) {
        let c = m.components
        let pct = { (v: Double) in v.formatted(.percent.precision(.fractionLength(0))) }
        if c.dim > 0 {
            HUD.show("Dimmed \(pct(c.dim))", symbol: "moon.fill", duration: 0.9)
        } else if c.boost > 0 {
            HUD.show("Extra brightness \(pct(c.boost))", symbol: "sun.max.trianglebadge.exclamationmark.fill", duration: 0.9)
        } else {
            HUD.show("Brightness \(pct(c.hardware / 100))", symbol: "sun.max.fill", duration: 0.9)
        }
    }

    func scheduleStateSave() {
        stateSave?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.saveState() } }
        stateSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// Writes software dimming and sync offsets to the monitor prefs (debounced: sliders move fast).
    func saveState() {
        stateSave = nil
        let monitors = store.monitors.map { ($0.id, $0.softDim) }
        let offsets = syncOffsets
        settings.update { s in
            for (id, dim) in monitors {
                var p = s.prefs(id)
                p.lastSoftDim = dim > 0 ? dim : nil
                if let o = offsets[id] { p.syncOffset = o }
                if s.monitors[id] != p { s.monitors[id] = p }
            }
        }
    }

    // MARK: - Sync

    var isSyncing: Bool { settings.value.syncSource != nil && !isLinked && syncSourceMonitor != nil }

    var syncSourceMonitor: MonitorState? {
        settings.value.syncSource.flatMap { id in brightnessMonitors.first { $0.id == id } }
    }

    var syncFollowers: [MonitorState] {
        guard let source = syncSourceMonitor else { return [] }
        return brightnessMonitors.filter { $0.id != source.id && !settings.value.prefs($0.id).excludeFromLinkedBrightness }
    }

    /// Turns following on (keeping every display's current distance to the source) or off.
    func setSyncSource(_ id: String?) {
        settings.update { s in
            s.syncSource = id
            if id != nil { s.linkedBrightness = false }
        }
        syncOffsets.removeAll()
        if let source = syncSourceMonitor {
            let base = BrightnessLevel.level(source.components)
            for f in syncFollowers { syncOffsets[f.id] = BrightnessLevel.level(f.components) - base }
            scheduleStateSave()
        }
        updateSync()
    }

    /// Starts or stops polling the source (DisplayServices displays change brightness on their
    /// own: keys, ambient light). DDC sources only change through MacToys.
    func updateSync() {
        let polls = isSyncing && [.builtIn, .appleNative].contains(syncSourceMonitor?.snapshot.kind)
        if polls && syncTimer == nil {
            if syncOffsets.isEmpty {
                for f in syncFollowers { syncOffsets[f.id] = settings.value.prefs(f.id).syncOffset ?? 0 }
            }
            syncTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pollSyncSource() }
            }
        } else if !polls, let t = syncTimer {
            t.invalidate()
            syncTimer = nil
            lastSourceReading = nil
        }
    }

    private func pollSyncSource() {
        guard let source = syncSourceMonitor, let b = DisplayServices.brightness(source.snapshot.displayID) else { return }
        let percent = Double(b) * 100
        guard BrightnessSync.moved(from: lastSourceReading, to: percent) else { return }
        let first = lastSourceReading == nil
        lastSourceReading = percent
        guard pending["\(source.id)|\(DisplayFeature.brightness.rawValue)"] == nil else { return }
        source.percent[.brightness] = percent.rounded()
        if !first { followSource() }
    }

    func followSource() {
        guard let source = syncSourceMonitor else { return }
        let level = BrightnessLevel.level(source.components)
        for f in syncFollowers {
            let t = track(for: f)
            let offset = syncOffsets[f.id] ?? settings.value.prefs(f.id).syncOffset ?? 0
            let target = BrightnessSync.follow(source: level, offset: offset,
                                               range: BrightnessSync.range(dimming: t.dimShare > 0, boost: t.boostShare > 0))
            apply(BrightnessLevel.components(target, dimming: t.dimShare > 0, boost: t.boostShare > 0), to: f, byUser: false)
        }
    }

    // MARK: - Resolution

    func refreshModes(_ m: MonitorState) {
        let catalog = DisplayModeReader.catalog(m.snapshot.displayID, favorites: settings.value.prefs(m.id).favoriteModes,
                                                hideLowResolutionDuplicates: settings.value.hideLowResolutionModes)
        if m.modes != catalog { m.modes = catalog }
    }

    /// Switches a display's mode; with confirmation on, it switches back unless kept in 15 s.
    func switchMode(_ mode: DisplayModeInfo, on m: MonitorState) {
        let id = m.snapshot.displayID
        guard let previous = DisplayModeReader.current(id), previous != mode else { return }
        if Services.autoTilingManagesDisplay?(id) == true {
            log.info("resolution change on a display Auto Tiling arranges; it re-tiles after the change")
        }
        guard DisplayModeReader.apply(mode, to: id) else {
            HUD.show("Couldn't switch the resolution", symbol: "exclamationmark.triangle.fill")
            return
        }
        log.info("mode \(mode.width)x\(mode.height)@\(mode.refreshRate) on \(m.id, privacy: .public)")
        refreshModes(m)
        guard settings.value.confirmModeChanges else { return }
        if let effect = confirmation.begin(display: id, previous: previous, applied: mode, now: Date()) { perform(effect) }
        updateConfirmationUI()
    }

    func switchRefresh(_ rate: Double, on m: MonitorState) {
        guard let mode = m.modes?.mode(refresh: rate) else { return }
        switchMode(mode, on: m)
    }

    func toggleFavorite(_ key: ResolutionKey, on m: MonitorState) {
        settings.update { s in
            var p = s.prefs(m.id)
            if let i = p.favoriteModes.firstIndex(of: key.string) { p.favoriteModes.remove(at: i) } else { p.favoriteModes.append(key.string) }
            s.monitors[m.id] = p
        }
        refreshModes(m)
    }

    func keepMode() {
        if let effect = confirmation.keep() { perform(effect) }
        updateConfirmationUI()
    }

    func revertMode() {
        if let effect = confirmation.revert() { perform(effect) }
        updateConfirmationUI()
    }

    private func perform(_ effect: ModeConfirmation.Effect) {
        switch effect {
        case .kept:
            break
        case .revert(let id, let mode):
            if DisplayModeReader.apply(mode, to: id) {
                HUD.show("Previous resolution restored", symbol: "arrow.uturn.backward")
            } else {
                log.error("couldn't restore the previous mode on \(id)")
            }
            if let m = store.monitors.first(where: { $0.snapshot.displayID == id }) { refreshModes(m) }
        }
    }

    /// Shows, updates or hides the prompt and its timer to match `confirmation`.
    func updateConfirmationUI() {
        guard let p = confirmation.pending else {
            confirmationTimer?.invalidate()
            confirmationTimer = nil
            confirmationPresenter.dismiss()
            return
        }
        let m = store.monitors.first { $0.snapshot.displayID == p.displayID }
        let info = ModeConfirmationInfo(displayID: p.displayID, displayName: m?.name ?? String(localized: "Display"),
                                        modeTitle: Self.modeTitle(p.applied, builtIn: m?.snapshot.kind == .builtIn,
                                                                  rates: m?.modes?.refreshRates ?? []),
                                        deadline: p.deadline)
        confirmationPresenter.show(info, keep: { [weak self] in self?.keepMode() },
                                   revert: { [weak self] in self?.revertMode() })
        guard confirmationTimer == nil else { return }
        confirmationTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let effect = self.confirmation.tick(now: Date()) {
                    self.perform(effect)
                    self.updateConfirmationUI()
                }
            }
        }
    }

    /// "2560 × 1440 · HiDPI · 60 Hz".
    static func modeTitle(_ mode: DisplayModeInfo, builtIn: Bool, rates: [Double]) -> String {
        var parts = [mode.resolution.title]
        if mode.isHiDPI { parts.append("HiDPI") }
        if mode.refreshRate > 0 {
            parts.append(RefreshFormat.title(mode.refreshRate,
                                             proMotion: RefreshFormat.isProMotion(mode.refreshRate, builtIn: builtIn, rates: rates)))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Arrangement

    func makeMain(_ m: MonitorState) {
        guard !m.facts.isMain else { return }
        if !DisplayArranger.makeMain(m.snapshot.displayID) {
            HUD.show("Couldn't change the main display", symbol: "exclamationmark.triangle.fill")
        }
        refreshDisplayFacts()
    }

    /// Makes `m` show what `source` shows; nil stops mirroring.
    func mirror(_ m: MonitorState, of source: MonitorState?) {
        if !DisplayArranger.mirror(m.snapshot.displayID, of: source?.snapshot.displayID) {
            HUD.show("Couldn't change mirroring", symbol: "exclamationmark.triangle.fill")
        }
        refreshDisplayFacts()
    }

    func mirrorSources(for m: MonitorState) -> [MonitorState] {
        let ids = store.monitors.map(\.snapshot.displayID)
        let mirrorOf = Dictionary(store.monitors.compactMap { s in s.facts.mirrorOf.map { (s.snapshot.displayID, $0) } },
                                  uniquingKeysWith: { a, _ in a })
        let allowed = Set(Arrangement.mirrorSources(for: m.snapshot.displayID, displays: ids, mirrorOf: mirrorOf))
        return store.monitors.filter { allowed.contains($0.snapshot.displayID) }
    }

    // MARK: - Color

    func loadColorProfiles() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let list = ColorProfiles.installed()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.store.colorProfiles = list }
            }
        }
    }

    /// Profiles for a monitor's menu: its own first.
    func colorProfiles(for m: MonitorState) -> [ColorProfile] {
        var list = store.colorProfiles
        for url in [m.factoryProfile, m.colorProfile].compactMap({ $0 }) where !list.contains(where: { $0.url == url }) {
            list.append(ColorProfile(url: url, name: url.deletingPathExtension().lastPathComponent))
        }
        return ColorProfiles.ordered(list, factory: m.factoryProfile)
    }

    func profileName(_ url: URL?) -> String? {
        guard let url else { return nil }
        return store.colorProfiles.first { $0.url.standardizedFileURL == url.standardizedFileURL }?.name
            ?? url.deletingPathExtension().lastPathComponent
    }

    func setColorProfile(_ url: URL?, on m: MonitorState) {
        let target = url == m.factoryProfile ? nil : url
        if !ColorProfiles.set(target, for: m.snapshot.displayID) {
            HUD.show("Couldn't change the color profile", symbol: "exclamationmark.triangle.fill")
        }
        m.colorProfile = ColorProfiles.current(m.snapshot.displayID)
    }

    /// ColorSync switched a profile (here, in System Settings, or after a reconnect).
    func colorSyncChanged() {
        software.tablesChanged()
        for m in store.monitors { m.colorProfile = ColorProfiles.current(m.snapshot.displayID) }
        loadColorProfiles()
    }

    func toggleNightShift() {
        guard NightShift.isAvailable else { return }
        let on = !(NightShift.isOn ?? false)
        NightShift.set(on)
        store.nightShiftOn = NightShift.isOn ?? on
    }

    // MARK: - Picture in picture

    func togglePiP(_ m: MonitorState) {
        if let w = pipWindows[m.id] { w.close(); return }
        guard CGPreflightScreenCaptureAccess() else {
            HUD.show("Screen Recording permission needed", symbol: "exclamationmark.shield")
            PermissionCenter.shared.request(.screenRecording)
            return
        }
        let w = PiPWindow(displayID: m.snapshot.displayID, monitorID: m.id, name: m.name, options: settings.value.pip)
        w.onClosed = { [weak self] w in
            guard let self, self.pipWindows[w.monitorID] === w else { return }
            self.pipWindows[w.monitorID] = nil
            self.store.pipOpen.remove(w.monitorID)
        }
        pipWindows[m.id] = w
        store.pipOpen.insert(m.id)
        closeFlyout()
        w.start()
    }

    // MARK: - Virtual displays

    var virtualDisplaysAvailable: Bool { VirtualDisplayAPI.isAvailable }

    func connectVirtualDisplays() {
        for c in settings.value.virtualDisplays where c.enabled { connect(c) }
    }

    func connect(_ config: VirtualDisplayConfig) {
        guard virtualHandles[config.id] == nil else { return }
        guard let handle = VirtualDisplayAPI.create(config) else {
            HUD.show("Couldn't create the virtual display", symbol: "exclamationmark.triangle.fill")
            return
        }
        virtualHandles[config.id] = handle
        store.connectedVirtual.insert(config.id)
        if let target = config.mirroredBy { scheduleMirror(target, onto: handle.displayID) }
    }

    /// Mirrors a physical monitor onto a new virtual display once macOS has set it up.
    private func scheduleMirror(_ monitorID: String, onto display: CGDirectDisplayID) {
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isVirtualRunning(display),
                      let physical = self.monitor(id: monitorID)?.snapshot.displayID, physical != display else { return }
                if !DisplayArranger.mirror(physical, of: display) {
                    self.log.error("couldn't mirror \(monitorID, privacy: .public) onto the virtual display")
                }
            }
        }
        pendingMirrors.append(work)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func isVirtualRunning(_ display: CGDirectDisplayID) -> Bool {
        virtualHandles.values.contains { $0.displayID == display }
    }

    func disconnect(_ id: UUID) {
        virtualHandles.removeValue(forKey: id)?.remove()
        store.connectedVirtual.remove(id)
    }

    func setVirtualDisplay(_ id: UUID, connected: Bool) {
        settings.update { s in
            if let i = s.virtualDisplays.firstIndex(where: { $0.id == id }) { s.virtualDisplays[i].enabled = connected }
        }
        guard let config = settings.value.virtualDisplays.first(where: { $0.id == id }) else { return }
        if connected { connect(config) } else { disconnect(id) }
    }

    @discardableResult
    func addVirtualDisplay(width: Int, height: Int, hiDPI: Bool = true) -> VirtualDisplayConfig {
        let n = settings.value.virtualDisplays.count + 1
        let config = VirtualDisplayConfig(name: String(localized: "Virtual Display \(n)", comment: "Default name; the placeholder is a number"),
                                          width: width, height: height, hiDPI: hiDPI)
        settings.value.virtualDisplays.append(config)
        connect(config)
        return config
    }

    /// Saves an edited configuration; a connected display is recreated with it.
    func updateVirtualDisplay(_ config: VirtualDisplayConfig) {
        guard let i = settings.value.virtualDisplays.firstIndex(where: { $0.id == config.id }) else { return }
        let old = settings.value.virtualDisplays[i]
        guard old != config else { return }
        settings.value.virtualDisplays[i] = config
        if virtualHandles[config.id] != nil {
            disconnect(config.id)
            if config.enabled { connect(config) }
        } else if config.enabled && !old.enabled {
            connect(config)
        }
    }

    func removeVirtualDisplay(_ id: UUID) {
        disconnect(id)
        settings.value.virtualDisplays.removeAll { $0.id == id }
    }

    // MARK: - URL actions

    /// The display actions of `handle(_:)`; nil for actions this part doesn't know.
    func handleDisplayCommand(_ command: AppCommand) -> Bool? {
        let p = command.parameters
        switch command.action {
        case "set-mode", "mode":
            guard running, let m = monitor(param: p["monitor"]), let catalog = m.modes else { return false }
            var request = ModeRequest.parse(p["mode"] ?? p["resolution"] ?? "") ?? ModeRequest()
            if let id = p["mode-id"].flatMap({ Int32($0) }) { request.modeID = id }
            if let hz = p["refresh"].flatMap(Double.init) { request.refresh = hz }
            if let h = p["hidpi"] { request.hiDPI = ["1", "true", "yes", "on"].contains(h.lowercased()) }
            guard let mode = catalog.match(request) else { return false }
            switchMode(mode, on: m)
        case "dim":
            guard running else { return false }
            let level = max(0, min(100, Double(p["level"] ?? "0") ?? 0))
            let targets = p["monitor"] == "all" || p["monitor"] == nil ? store.monitors : monitor(param: p["monitor"]).map { [$0] } ?? []
            guard !targets.isEmpty else { return false }
            for m in targets { setSoftwareDim(percent: level, on: m) }
        case "pip":
            guard running, let m = monitor(param: p["monitor"]) else { return false }
            let close = ["1", "true", "yes"].contains((p["close"] ?? "").lowercased())
            if close { pipWindows[m.id]?.close() } else if pipWindows[m.id] == nil { togglePiP(m) }
        case "set-main", "main":
            guard running, let m = monitor(param: p["monitor"]) else { return false }
            makeMain(m)
        case "mirror":
            guard running, let m = monitor(param: p["monitor"]), let source = monitor(param: p["of"]) else { return false }
            mirror(m, of: source)
        case "unmirror":
            guard running, let m = monitor(param: p["monitor"]) else { return false }
            mirror(m, of: nil)
        case "night-shift", "nightshift":
            guard NightShift.isAvailable else { return false }
            if let on = p["on"] { NightShift.set(["1", "true", "yes", "on"].contains(on.lowercased())) } else { toggleNightShift() }
            store.nightShiftOn = NightShift.isOn
        case "virtual-display":
            guard running, let name = p["name"] ?? p["id"],
                  let config = settings.value.virtualDisplays.first(where: { $0.name == name || $0.id.uuidString == name }) else { return false }
            let on = p["on"].map { ["1", "true", "yes", "on"].contains($0.lowercased()) } ?? (virtualHandles[config.id] == nil)
            setVirtualDisplay(config.id, connected: on)
        default:
            return nil
        }
        return true
    }
}

/// The settings `displaySettingsChanged` reacts to.
struct DisplayFeatureSettings: Equatable {
    var softwareDimming: Bool
    var dimMethod: DimMethod
    var maxSoftwareDim: Double
    var extraBrightness: Bool
    var maxExtraBrightness: Double
    var hideLowResolutionModes: Bool
    var pip: PiPOptions
    var syncSource: String?
    var linked: Bool

    init(_ s: PowerDisplaySettings) {
        softwareDimming = s.softwareDimming
        dimMethod = s.dimMethod
        maxSoftwareDim = s.maxSoftwareDim
        extraBrightness = s.extraBrightness
        maxExtraBrightness = s.maxExtraBrightness
        hideLowResolutionModes = s.hideLowResolutionModes
        pip = s.pip
        syncSource = s.syncSource
        linked = s.linkedBrightness
    }
}
