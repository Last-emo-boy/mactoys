import Foundation

extension ClipItem {
    /// Builds an item in another module (the synthesized memberwise initializer is internal),
    /// e.g. to put a transformed result on the pasteboard with `ClipboardHistory.shared.restore(_:)`.
    public init(kind: Kind, text: String?, html: String? = nil, rtf: Data? = nil, image: Data? = nil, files: [URL] = []) {
        self.kind = kind
        self.text = text
        self.html = html
        self.rtf = rtf
        self.image = image
        self.files = files
    }
}
