import AppKit
import MacToysCore
import SwiftUI
import UniformTypeIdentifiers

/// A floating window with a frozen capture of the cropped area: copy (⌘C), save (⌘S), drag out.
/// Dragging the image moves the window.
@MainActor
final class ScreenshotCropWindow: NSPanel, NSWindowDelegate {
    let image: NSImage
    var onClosed: ((ScreenshotCropWindow) -> Void)?
    private let sourceName: String
    private let log = Log.for("cropandlock")

    /// - Parameter rect: where the area was on screen (global top-left coordinates).
    init(image cgImage: CGImage, pointSize: CGSize, at rect: CGRect, sourceName: String, allSpaces: Bool) {
        image = NSImage(cgImage: cgImage, size: pointSize)
        self.sourceName = sourceName
        let visible = ScreenGeometry.screen(forAX: rect)?.axVisibleFrame ?? rect
        let content = CropGeometry.keep(CGRect(origin: rect.origin, size: pointSize), inside: visible)
        super.init(contentRect: ScreenGeometry.toCocoa(content), styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        title = CropMode.screenshot.windowTitle(of: sourceName)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        backgroundColor = .black
        collectionBehavior = allSpaces ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.moveToActiveSpace, .fullScreenAuxiliary]
        contentAspectRatio = pointSize
        contentMinSize = CropGeometry.minimumContentSize(for: pointSize)
        delegate = self
        contentView = NSHostingView(rootView: ScreenshotCropView(
            image: image,
            onCopy: { [weak self] in self?.copyImage() },
            onSave: { [weak self] in self?.saveImage() },
            dragFile: { [weak self] in self?.temporaryFile() }))
    }

    override var canBecomeKey: Bool { true }

    func show() { orderFrontRegardless() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods == .command, let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        switch key {
        case "c": copyImage()
        case "s": saveImage()
        case "w": close()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    @objc func copy(_ sender: Any?) { copyImage() }

    private func copyImage() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
    }

    private func saveImage() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = Self.fileName()
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        panel.canCreateDirectories = true
        NSApp.activate()
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { self?.write(to: url) }
        }
    }

    private func write(to url: URL) {
        guard let data = pngData else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            log.error("Saving crop failed: \(error.localizedDescription, privacy: .public)")
            HUD.show("Couldn't save the screenshot", symbol: "exclamationmark.triangle")
        }
    }

    /// A PNG in the temporary folder, for dragging the crop into other apps.
    private func temporaryFile() -> URL? {
        guard let data = pngData else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(Self.fileName())
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            log.error("Writing drag file failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private var pngData: Data? {
        image.cgImage(forProposedRect: nil, context: nil, hints: nil)?.pngData
    }

    private static func fileName() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Crop \(f.string(from: Date())).png"
    }

    func windowWillClose(_ notification: Notification) { onClosed?(self) }
}

/// Screenshot crop content: the image, plus a glass toolbar while the pointer is over it.
struct ScreenshotCropView: View {
    let image: NSImage
    var onCopy: () -> Void = {}
    var onSave: () -> Void = {}
    var dragFile: () -> URL? = { nil }
    var alwaysShowToolbar = false
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .gesture(WindowDragGesture())
            if hovering || alwaysShowToolbar {
                HStack(spacing: 2) {
                    toolButton(copied ? "checkmark" : "doc.on.doc",
                               copied ? Text("Copied", comment: "Screenshot crop toolbar: the image was copied")
                                      : Text("Copy", comment: "Screenshot crop toolbar: copy the image")) {
                        onCopy()
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                    }
                    toolButton("square.and.arrow.down", Text("Save…"), action: onSave)
                    Label {
                        Text("Drag", comment: "Screenshot crop toolbar: drag the image into another app")
                    } icon: {
                        Image(systemName: "hand.draw")
                    }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .contentShape(Capsule())
                        .help("Drag the image into another app")
                        .onDrag {
                            guard let url = dragFile(), let provider = NSItemProvider(contentsOf: url) else { return NSItemProvider() }
                            return provider
                        }
                }
                .padding(4)
                // A dark base keeps the glass legible over light screenshots.
                .background(Capsule().fill(Color.black.opacity(0.5)))
                .glassEffect(.regular, in: .capsule)
                .environment(\.colorScheme, .dark)
                .padding(10)
                .transition(.opacity)
            }
        }
        .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { hovering = inside } }
    }

    private func toolButton(_ symbol: String, _ title: Text, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label { title } icon: { Image(systemName: symbol) }
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }
}

/// The ring drawn around the cropped area while the original window is in front (interactive mode).
struct CropOutlineView: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .strokeBorder(Tint.teal.color, style: StrokeStyle(lineWidth: 2, dash: [7, 4]))
            .padding(1)
    }
}
