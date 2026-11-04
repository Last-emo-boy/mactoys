import AppKit
import Quartz

/// The floating shelf window: borderless, above other apps, on every Space; takes the keyboard
/// when clicked without activating MacToys, so the app you are working in stays in front.
final class ShelfPanel: NSPanel {
    weak var controller: ShelfWindowController?

    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isMovable = true
        isMovableByWindowBackground = false
        animationBehavior = .none
        tabbingMode = .disallowed
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// A text field (renaming) has the keyboard: leave keys to it.
    var isEditingText: Bool { firstResponder is NSText }

    override func keyDown(with event: NSEvent) {
        if isEditingText || controller?.handleKeyDown(event) != true { super.keyDown(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if !isEditingText, controller?.handleKeyEquivalent(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        controller?.escape()
    }

    // MARK: Quick Look (the panel looks for a controller along the responder chain)

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        controller?.hasQuickLookItems ?? false
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        controller?.beginQuickLook(panel)
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        controller?.endQuickLook(panel)
    }
}

/// The panel's content view: receives drops and tracks the pointer for the hover controls.
final class ShelfContainerView: NSView {
    weak var controller: ShelfWindowController?

    override init(frame: CGRect) {
        super.init(frame: frame)
        var types = ShelfPasteboardReader.acceptedTypes
        types += NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        registerForDraggedTypes(types)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { controller?.setHovering(true) }
    override func mouseExited(with event: NSEvent) { controller?.setHovering(false) }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        controller?.dragUpdated(sender) ?? []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        controller?.dragUpdated(sender) ?? []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        controller?.dragEnded()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        controller?.performDrop(sender) ?? false
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        controller?.dragEnded()
    }
}
