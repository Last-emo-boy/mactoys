import AppKit
import CoreGraphics
import MacToysCore
import Metal
import QuartzCore

/// Applies software dimming (color tables or overlays) and extra brightness (EDR overlays) to
/// displays, and puts everything back. Color tables changed by a process are reset by the window
/// server when it exits, so a crash never leaves a display dimmed; `stop` restores them earlier.
@MainActor
final class SoftwareBrightnessController {
    private var gamma = GammaBookkeeping()
    private var overlays: [CGDirectDisplayID: BrightnessOverlay] = [:]
    /// Displays whose color table refused a change: they dim with an overlay.
    private var gammaRefused: Set<CGDirectDisplayID> = []
    private let log = Log.for("powerdisplay")

    var isGammaActive: Bool { gamma.isActive }

    /// Sets one display's software state: `dimFactor` ≤ 1 (1 = none), `boostFactor` ≥ 1 (1 = none).
    func apply(_ id: CGDirectDisplayID, dimFactor: Double, boostFactor: Double, method: DimMethod, gammaCapacity: Int) {
        var useGamma = method.usesGamma(gammaSupported: gammaCapacity > 1 && !gammaRefused.contains(id))
        perform(gamma.set(useGamma ? dimFactor : 1, for: id) { Self.readTable(id) })
        if gammaRefused.contains(id) { useGamma = false }
        let overlayFactor = boostFactor > 1.001 ? boostFactor : (useGamma ? 1 : dimFactor)
        if abs(overlayFactor - 1) < 0.001 {
            overlays.removeValue(forKey: id)?.close()
        } else if let overlay = overlays[id] ?? BrightnessOverlay(displayID: id) {
            overlays[id] = overlay
            overlay.set(factor: overlayFactor)
        }
    }

    /// Color tables were reset by the system (profile change, wake, reconfiguration): dim again.
    func tablesChanged() {
        perform(gamma.tablesChanged { Self.readTable($0) })
    }

    /// Re-places overlays after the arrangement changed; drops displays that are gone.
    func displaysChanged(online: Set<CGDirectDisplayID>) {
        gamma.retain(online: online)
        gammaRefused.formIntersection(online)
        for (id, overlay) in overlays where !online.contains(id) {
            overlay.close()
            overlays.removeValue(forKey: id)
        }
        for overlay in overlays.values { overlay.reposition() }
    }

    /// Removes every change (module stop, quit).
    func restoreAll() {
        perform(gamma.restoreAll())
        for overlay in overlays.values { overlay.close() }
        overlays.removeAll()
    }

    private func perform(_ actions: [GammaBookkeeping.Action]) {
        for action in actions {
            switch action {
            case .apply(let id, let table):
                let e = CGSetDisplayTransferByTable(id, UInt32(table.count), table.red, table.green, table.blue)
                if e != .success { refused(id, e) }
            case .formula(let id, let f):
                let v = CGGammaValue(f)
                let e = CGSetDisplayTransferByFormula(id, 0, v, 1, 0, v, 1, 0, v, 1)
                if e != .success { refused(id, e) }
            case .restore(let id, let table):
                CGSetDisplayTransferByTable(id, UInt32(table.count), table.red, table.green, table.blue)
            case .restoreSystem:
                CGDisplayRestoreColorSyncSettings()
            }
        }
    }

    private func refused(_ id: CGDirectDisplayID, _ error: CGError) {
        log.notice("color table refused on \(id) (\(error.rawValue)); dimming with an overlay")
        gammaRefused.insert(id)
        perform(gamma.set(1, for: id) { nil })
    }

    static func readTable(_ id: CGDirectDisplayID) -> GammaTable? {
        let capacity = CGDisplayGammaTableCapacity(id)
        guard capacity > 1 else { return nil }
        var r = [CGGammaValue](repeating: 0, count: Int(capacity)), g = r, b = r
        var count: UInt32 = 0
        guard CGGetDisplayTransferByTable(id, capacity, &r, &g, &b, &count) == .success, count > 1 else { return nil }
        let n = Int(count)
        return GammaTable(red: Array(r.prefix(n)), green: Array(g.prefix(n)), blue: Array(b.prefix(n)))
    }
}

/// A click-through window over one display that multiplies what is under it: below 1 it darkens
/// (overlay dimming); above 1 it renders EDR content in multiply mode, which makes macOS raise the
/// panel's brightness into its HDR headroom and brightens everything beneath by the factor.
/// It is left out of screen capture and dies with the process.
@MainActor
final class BrightnessOverlay {
    let displayID: CGDirectDisplayID
    private let window: NSWindow
    private let root = CALayer()
    private var metal: (layer: CAMetalLayer, queue: MTLCommandQueue)?
    private var timer: Timer?
    private(set) var factor: Double = 1
    /// Renders per second while boosting: macOS drops EDR headroom once content stops updating.
    static let boostFPS = 5.0

    init?(displayID: CGDirectDisplayID) {
        guard let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) else { return nil }
        self.displayID = displayID
        window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.canHide = false
        window.animationBehavior = .none
        window.sharingType = .none
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let view = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.layer = root   // before wantsLayer: a layer-hosting view
        view.wantsLayer = true
        root.frame = view.bounds
        window.contentView = view
        window.setFrame(screen.frame, display: false)
    }

    func set(factor newFactor: Double) {
        factor = newFactor
        if newFactor > 1 {
            root.backgroundColor = nil
            startBoost()
            render()
        } else {
            stopBoost()
            root.backgroundColor = NSColor.black.withAlphaComponent(max(0, min(1, 1 - newFactor))).cgColor
        }
        window.orderFrontRegardless()
    }

    func reposition() {
        guard let screen else { close(); return }
        window.setFrame(screen.frame, display: false)
        metal?.layer.frame = root.bounds
        if factor > 1 { render() }
    }

    func close() {
        stopBoost()
        window.orderOut(nil)
        window.close()
    }

    private var screen: NSScreen? { NSScreen.screens.first { $0.displayID == displayID } }

    private func startBoost() {
        if metal == nil, let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() {
            let layer = CAMetalLayer()
            layer.device = device
            layer.pixelFormat = .rgba16Float
            layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
            layer.wantsExtendedDynamicRangeContent = true
            layer.framebufferOnly = true
            layer.isOpaque = false
            // A flat color: a tiny drawable stretched over the screen is enough.
            layer.drawableSize = CGSize(width: 4, height: 4)
            layer.compositingFilter = "multiply"
            layer.frame = root.bounds
            layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            root.addSublayer(layer)
            metal = (layer, queue)
        }
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1 / Self.boostFPS, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        }
    }

    private func stopBoost() {
        timer?.invalidate()
        timer = nil
        metal?.layer.removeFromSuperlayer()
        metal = nil
    }

    private func render() {
        guard factor > 1, let (layer, queue) = metal, let drawable = layer.nextDrawable() else { return }
        let potential = Double(screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1)
        let current = Double(screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1)
        let k = SoftwareFactor.boostToRender(target: factor, potential: potential, current: current)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: k, green: k, blue: k, alpha: 1)
        guard let buffer = queue.makeCommandBuffer(), let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }
}
