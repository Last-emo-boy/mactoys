import Carbon.HIToolbox
import CoreGraphics
import Foundation
import MacToysCore

/// Where the mirror drops from.
enum MirrorPlacement: String, Codable, CaseIterable, Sendable {
    /// Under the menu bar icon (or under the camera when the icon is hidden).
    case underIcon
    /// Centered at the top of the screen with the camera: the notch on a MacBook.
    case underCamera

    var title: String {
        switch self {
        case .underIcon: String(localized: "Under the menu bar icon", comment: "Camera Mirror: where the mirror opens")
        case .underCamera: String(localized: "Under the camera", comment: "Camera Mirror: where the mirror opens (top center of the screen)")
        }
    }
}

/// The outline of the floating window.
enum MirrorShape: String, Codable, CaseIterable, Sendable {
    case circle, rounded, rectangle

    var title: String {
        switch self {
        case .circle: String(localized: "Circle", comment: "Camera Mirror window shape")
        case .rounded: String(localized: "Rounded", comment: "Camera Mirror window shape: rounded rectangle")
        case .rectangle: String(localized: "Rectangle", comment: "Camera Mirror window shape")
        }
    }

    var symbol: String {
        switch self {
        case .circle: "circle"
        case .rounded: "rectangle.roundedtop"
        case .rectangle: "rectangle"
        }
    }
}

/// The proportions of a rounded or rectangular floating window (a circle is always 1:1).
enum MirrorAspect: String, Codable, CaseIterable, Sendable {
    case fourThree, sixteenNine, square, portrait

    /// Width divided by height.
    var ratio: CGFloat {
        switch self {
        case .fourThree: 4.0 / 3.0
        case .sixteenNine: 16.0 / 9.0
        case .square: 1
        case .portrait: 3.0 / 4.0
        }
    }

    /// "4:3" — a ratio, the same in every language.
    var label: String {
        switch self {
        case .fourThree: "4:3"
        case .sixteenNine: "16:9"
        case .square: "1:1"
        case .portrait: "3:4"
        }
    }
}

/// Where photos are saved.
enum PhotoFolder: String, Codable, CaseIterable, Sendable {
    case desktop, pictures

    var title: String {
        switch self {
        case .desktop: String(localized: "Desktop", comment: "Folder name")
        case .pictures: String(localized: "Pictures", comment: "Folder name")
        }
    }

    var url: URL {
        let dir: FileManager.SearchPathDirectory = self == .desktop ? .desktopDirectory : .picturesDirectory
        return FileManager.default.urls(for: dir, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }
}

/// A window frame in Cocoa screen coordinates.
struct StoredFrame: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(_ r: CGRect) {
        x = r.minX
        y = r.minY
        width = r.width
        height = r.height
    }

    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

struct MirrorSettings: Codable, Equatable {
    var showMenuBarIcon = true
    @NullCodable var activation: Shortcut? = Shortcut(kVK_ANSI_I, [.control, .option])
    var placement: MirrorPlacement = .underIcon
    /// On a Mac with a notch, clicking the notch opens the mirror under the camera.
    var openFromNotch = true
    /// `AVCaptureDevice.uniqueID`; nil follows the camera macOS prefers.
    var cameraID: String?
    var mirrored = true
    /// Static framing: zoom (1…3) around a center in the camera picture (0…1, top-left origin).
    var zoom: Double = 1
    var centerX: Double = 0.5
    var centerY: Double = 0.45
    var showGrid = false
    var lightCheck = true
    var shape: MirrorShape = .rounded
    var aspect: MirrorAspect = .fourThree
    var opacity: Double = 1
    var floatOnTop = true
    var floatingFrame: StoredFrame?
    var photoFolder: PhotoFolder = .desktop
    /// Save photos as the mirror shows them (flipped) instead of as others see you.
    var photoMirrored = false
    var shutterSound = true

    var framing: MirrorFraming {
        MirrorFraming(zoom: zoom, center: CGPoint(x: centerX, y: centerY))
    }

    mutating func setFraming(_ f: MirrorFraming) {
        zoom = (Double(f.zoom) * 100).rounded() / 100
        centerX = (Double(f.center.x) * 1000).rounded() / 1000
        centerY = (Double(f.center.y) * 1000).rounded() / 1000
    }
}
