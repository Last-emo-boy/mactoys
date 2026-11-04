import AppKit
import MacToysCore
import SwiftUI

/// Sample data and scenes for `MacToys --snapshot … --only clipboard`.
@MainActor
enum ClipboardPreviews {
    static func scenes(settings: ClipboardSettings) -> [PreviewScene] {
        var s = settings
        s.style = .panel
        s.showPreview = true
        s.returnAction = .paste
        let panelSettings = s
        var barSettings = s
        barSettings.style = .bar
        return [
            PreviewScene("panel", size: CGSize(width: 960, height: 660), wallpaper: false) {
                let model = makeModel(settings: panelSettings)
                model.selection = 3
                return panelScene(model)
            },
            PreviewScene("bar", size: CGSize(width: 1440, height: 420), wallpaper: false) {
                let model = makeModel(settings: barSettings)
                model.selection = 1
                return desktop(
                    VStack {
                        Spacer()
                        PasteBarView(model: model).frame(width: 1400, height: PanelLayout.barHeight)
                            .shadow(color: .black.opacity(0.3), radius: 24, y: 10)
                            .padding(.bottom, 14)
                    }
                )
            },
            PreviewScene("pinboards", size: CGSize(width: 960, height: 660), wallpaper: false) {
                let model = makeModel(settings: panelSettings)
                if let board = model.library.pinboards.first { model.source = .pinboard(board.id) }
                model.selection = 1
                return panelScene(model)
            },
            PreviewScene("search", size: CGSize(width: 960, height: 660), wallpaper: false) {
                let model = makeModel(settings: panelSettings)
                model.query = "review"
                return panelScene(model)
            },
            PreviewScene("actions", size: CGSize(width: 960, height: 660), wallpaper: false) {
                let model = makeModel(settings: panelSettings)
                model.selection = 1
                model.mode = .actions
                model.actionSelection = 3
                return panelScene(model)
            },
            PreviewScene("merge", size: CGSize(width: 960, height: 660), wallpaper: false) {
                let model = makeModel(settings: panelSettings)
                model.select(0)
                model.select(4, toggle: true)
                model.select(7, toggle: true)
                model.stackCount = 0
                return panelScene(model)
            },
            PreviewScene("rename", size: CGSize(width: 960, height: 660), wallpaper: false) {
                let model = makeModel(settings: panelSettings)
                model.selection = 1
                if let clip = model.selectedRow?.clip { model.mode = .renaming(clip.id, "Cart total") }
                return panelScene(model)
            },
            PreviewScene("snippet-editor", size: CGSize(width: 600, height: 720), wallpaper: false) {
                let snippet = sampleSnippets[2]
                return AnyView(
                    SnippetEditorView(snippet: snippet, isNew: false, onDelete: {})
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(nsColor: .windowBackgroundColor)))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .shadow(color: .black.opacity(0.18), radius: 20, y: 8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(nsColor: .underPageBackgroundColor))
                        .ignoresSafeArea()
                )
            },
            PreviewScene("stack", size: CGSize(width: 560, height: 420), wallpaper: false) {
                let now = Date()
                let items = [
                    clip(.text, "Ada Lovelace", app: ("Contacts", "com.apple.AddressBook"), ago: 50, now: now),
                    clip(.text, "ada@example.com", app: ("Contacts", "com.apple.AddressBook"), ago: 40, now: now),
                    clip(.text, "+44 20 7946 0958", app: ("Contacts", "com.apple.AddressBook"), ago: 30, now: now),
                    clip(.text, "12 Analytical Row, London", app: ("Maps", "com.apple.Maps"), ago: 20, now: now),
                ]
                let controller = PasteStackController.preview(items)
                let height = PasteStackHUD.height(rows: items.count, warning: false, more: false)
                return desktop(
                    VStack {
                        HStack {
                            Spacer()
                            PasteStackHUD(controller: controller).frame(width: PasteStackController.hudWidth, height: height)
                        }
                        Spacer()
                    }
                    .padding(.top, 34)
                    .padding(.trailing, 20)
                )
            },
            PreviewScene("empty", size: CGSize(width: 960, height: 660), wallpaper: false) {
                let model = ClipboardPanelModel(history: SampleHistory([]), library: ClipLibrary(file: nil), settings: panelSettings)
                return panelScene(model)
            },
        ]
    }

    private static func panelScene(_ model: ClipboardPanelModel) -> AnyView {
        desktop(
            ClipboardPanelView(model: model)
                .frame(width: PanelLayout.panelSize.width, height: PanelLayout.panelSize.height)
                .shadow(color: .black.opacity(0.35), radius: 30, y: 14)
                .padding(.top, 24)
        )
    }

    /// The scene on a desktop: wallpaper and menu bar from edge to edge (under the snapshot window's title bar).
    private static func desktop(_ content: some View) -> AnyView {
        AnyView(
            ZStack(alignment: .top) {
                LinearGradient(colors: [Color(red: 0.09, green: 0.13, blue: 0.36), Color(red: 0.24, green: 0.17, blue: 0.56),
                                        Color(red: 0.6, green: 0.25, blue: 0.53), Color(red: 0.88, green: 0.54, blue: 0.42)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
                menuBar
            }
            .ignoresSafeArea()
        )
    }

    /// A strip that reads as the menu bar, so scenes sit on a desktop.
    private static var menuBar: some View {
        Rectangle().fill(.black.opacity(0.18)).frame(height: 24)
            .overlay(alignment: .leading) {
                Image(systemName: "apple.logo").font(.system(size: 13)).foregroundStyle(.white.opacity(0.9)).padding(.leading, 18)
            }
    }

    static func makeModel(settings: ClipboardSettings) -> ClipboardPanelModel {
        let now = Date()
        let history = SampleHistory(sampleHistory(now: now))
        let library = ClipLibrary(file: nil, initial: LibraryData(pinboards: samplePinboards(now: now), snippets: sampleSnippets))
        return ClipboardPanelModel(history: history, library: library, settings: settings)
    }

    // MARK: Sample data

    private static func clip(_ kind: ClipItem.Kind, _ text: String?, app: (String, String), ago: TimeInterval, now: Date,
                             image: Data? = nil, rtf: Data? = nil, files: [URL] = [], name: String? = nil, pinned: Bool = false) -> ClipItem {
        var item = ClipItem(kind: kind, text: text, rtf: rtf, image: image, files: files)
        item.date = now.addingTimeInterval(-ago)
        item.sourceApp = app.0
        item.sourceBundleID = app.1
        item.name = name
        item.pinned = pinned
        return item
    }

    private static let safari = ("Safari", "com.apple.Safari")
    private static let xcode = ("Xcode", "com.apple.dt.Xcode")
    private static let mail = ("Mail", "com.apple.mail")
    private static let notes = ("Notes", "com.apple.Notes")
    private static let terminal = ("Terminal", "com.apple.Terminal")
    private static let finder = ("Finder", "com.apple.finder")
    private static let freeform = ("Freeform", "com.apple.freeform")
    private static let preview = ("Preview", "com.apple.Preview")
    private static let messages = ("Messages", "com.apple.MobileSMS")

    static func sampleHistory(now: Date) -> [ClipItem] {
        [
            clip(.text, "https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:)", app: safari, ago: 35, now: now),
            clip(.text, "let total = cart.items.reduce(0) { $0 + $1.price * Double($1.quantity) }\nreceipt.totalLabel.text = total.formatted(.currency(code: \"EUR\"))",
                 app: xcode, ago: 4 * 60, now: now),
            clip(.text, "#FF5F4A", app: freeform, ago: 9 * 60, now: now),
            clip(.image, nil, app: preview, ago: 14 * 60, now: now, image: sampleImage()),
            clip(.text, "Hi Ada,\n\nThe launch review moved to Thursday at 14:00 — I’ll share the deck and the release notes afterwards.\n\nThanks,\nGrace",
                 app: mail, ago: 31 * 60, now: now),
            clip(.files, "/Users/ada/Documents/Invoices/Invoice-2026-114.pdf", app: finder, ago: 58 * 60, now: now,
                 files: [URL(fileURLWithPath: "/Users/ada/Documents/Invoices/Invoice-2026-114.pdf")]),
            clip(.richText, "Launch checklist\nRecord the product film\nTranslate release notes\nTag v1.4 and publish", app: notes,
                 ago: 2 * 3600, now: now, rtf: sampleRTF()),
            clip(.text, "ssh deploy@build.example.net -p 2222", app: terminal, ago: 2 * 86_400, now: now, pinned: true),
            clip(.text, "Room B · 4th floor, left after the lifts", app: messages, ago: 26 * 3600, now: now),
            clip(.text, "https://github.com/mactoys/mactoys/pull/214", app: safari, ago: 5 * 3600, now: now),
            clip(.text, "lantern-orbit-42", app: notes, ago: 6 * 86_400, now: now, name: "Guest Wi-Fi password", pinned: true),
            clip(.text, "rgb(10, 132, 255)", app: freeform, ago: 3 * 86_400, now: now),
        ].sorted { $0.date > $1.date }
    }

    static func samplePinboards(now: Date) -> [Pinboard] {
        [
            Pinboard(name: "Launch", tint: .indigo, items: [
                clip(.text, "https://mactoys.app/releases/1.4", app: safari, ago: 3600, now: now, name: "Release page"),
                clip(.text, "MacToys 1.4 brings a clipboard manager, pinboards and a paste stack to every Mac — free.",
                     app: notes, ago: 2 * 3600, now: now, name: "Tagline"),
                clip(.text, "#5E5CE6", app: freeform, ago: 3 * 3600, now: now, name: "Brand indigo"),
                clip(.image, nil, app: preview, ago: 4 * 3600, now: now, image: sampleImage(), name: "Hero artwork"),
                clip(.text, "git tag -s v1.4.0 -m \"MacToys 1.4\" && git push origin v1.4.0", app: terminal, ago: 5 * 3600, now: now),
            ]),
            Pinboard(name: "Design", tint: .pink, items: [
                clip(.text, "#FF5F4A", app: freeform, ago: 7200, now: now),
                clip(.text, "hsl(211, 100%, 52%)", app: freeform, ago: 9000, now: now),
            ]),
            Pinboard(name: "Support replies", tint: .green, items: [
                clip(.text, "Thanks for the report! Could you send the log from Settings › General › Export diagnostics?",
                     app: mail, ago: 86_400, now: now),
            ]),
        ]
    }

    static let sampleSnippets: [Snippet] = [
        Snippet(name: "Email signature", abbreviation: "sig", text: "Best,\nAda Lovelace\nMacToys · ada@example.com"),
        Snippet(name: "Today’s date", abbreviation: "dd", text: "{date:yyyy-MM-dd}"),
        Snippet(name: "Bug report", abbreviation: ";bug",
                text: "**Steps**\n1. {cursor}\n\n**Expected**\n\n**Actual**\n\nmacOS 26.1 · reported {datetime}"),
        Snippet(name: "Code review reply", abbreviation: "lgtm", text: "Thanks for the review! I’ve addressed the comments in {clipboard}."),
        Snippet(name: "Quote the clipboard", abbreviation: "qq", text: "> {clipboard}"),
    ]

    /// A small sunset landscape, drawn once.
    private static let cachedImage: Data? = {
        let size = CGSize(width: 1280, height: 800)
        let image = NSImage(size: size, flipped: false) { rect in
            NSGradient(colors: [NSColor(srgbRed: 0.98, green: 0.62, blue: 0.38, alpha: 1),
                                NSColor(srgbRed: 0.85, green: 0.38, blue: 0.55, alpha: 1),
                                NSColor(srgbRed: 0.27, green: 0.22, blue: 0.55, alpha: 1)])?.draw(in: rect, angle: 90)
            NSColor(srgbRed: 1, green: 0.86, blue: 0.6, alpha: 0.95).setFill()
            NSBezierPath(ovalIn: CGRect(x: 760, y: 330, width: 190, height: 190)).fill()
            func ridge(_ points: [CGPoint], _ color: NSColor) {
                let path = NSBezierPath()
                path.move(to: CGPoint(x: 0, y: 0))
                for p in points { path.line(to: p) }
                path.line(to: CGPoint(x: rect.width, y: 0))
                path.close()
                color.setFill()
                path.fill()
            }
            ridge([CGPoint(x: 0, y: 360), CGPoint(x: 220, y: 470), CGPoint(x: 430, y: 330), CGPoint(x: 650, y: 450),
                   CGPoint(x: 900, y: 300), CGPoint(x: 1120, y: 420), CGPoint(x: 1280, y: 350)],
                  NSColor(srgbRed: 0.36, green: 0.22, blue: 0.48, alpha: 1))
            ridge([CGPoint(x: 0, y: 220), CGPoint(x: 300, y: 300), CGPoint(x: 560, y: 190), CGPoint(x: 820, y: 280),
                   CGPoint(x: 1080, y: 170), CGPoint(x: 1280, y: 240)],
                  NSColor(srgbRed: 0.18, green: 0.14, blue: 0.34, alpha: 1))
            return true
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }()

    static func sampleImage() -> Data? { cachedImage }

    private static func sampleRTF() -> Data? {
        let text = NSMutableAttributedString()
        text.append(NSAttributedString(string: "Launch checklist\n", attributes: [
            .font: NSFont.systemFont(ofSize: 18, weight: .bold), .foregroundColor: NSColor.black,
        ]))
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.black]
        let done: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.gray,
                                                   .strikethroughStyle: NSUnderlineStyle.single.rawValue]
        text.append(NSAttributedString(string: "✓ Record the product film\n", attributes: done))
        text.append(NSAttributedString(string: "○ Translate release notes\n", attributes: body))
        text.append(NSAttributedString(string: "○ Tag ", attributes: body))
        text.append(NSAttributedString(string: "v1.4", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .medium),
                                                                   .foregroundColor: NSColor.systemIndigo]))
        text.append(NSAttributedString(string: " and publish", attributes: body))
        return text.rtf(from: NSRange(location: 0, length: text.length), documentAttributes: [:])
    }
}
