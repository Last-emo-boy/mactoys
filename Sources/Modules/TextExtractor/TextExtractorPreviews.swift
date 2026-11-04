import AppKit
import MacToysCore
import SwiftUI

/// Offscreen scenes for `MacToys --snapshot … --only textextractor`, with realistic sample captures.
@MainActor
enum TextExtractorPreviews {
    static func scenes(for module: TextExtractorModule) -> [PreviewScene] {
        [
            PreviewScene("selection", size: CGSize(width: 1100, height: 640), wallpaper: false) {
                let model = SelectionModel(mode: .paragraphs, language: "en-US")
                model.begin(at: CGPoint(x: 236, y: 152))
                model.update(to: CGPoint(x: 676, y: 318), moving: false)
                model.add = true
                return AnyView(TextExtractorOverlay(model: model, background: SampleScreen(),
                                                    languages: [("en-US", "English (United States)")]))
            },
            PreviewScene("card", size: CGSize(width: 1100, height: 800), wallpaper: false) {
                let card = model(recents: true)
                card.capture = releaseNotes
                card.canJoin = true
                card.showRecent = true
                return AnyView(onDesk(card))
            },
            PreviewScene("qrcode", size: CGSize(width: 560, height: 420)) {
                let card = model(recents: false)
                card.capture = Capture(text: "Scan for the slides", mode: .lines, source: .screen, language: "en",
                                       barcodes: [Barcode(symbology: "QR", payload: "https://conf.northwind.dev/talks/2026/live-text?ref=qr")],
                                       barcodeFirst: true)
                return AnyView(framed(card))
            },
            PreviewScene("wifi", size: CGSize(width: 560, height: 440)) {
                let card = model(recents: false)
                card.capture = Capture(text: "", mode: .lines, source: .file("Guest Wi-Fi.png"), language: nil,
                                       barcodes: [Barcode(symbology: "QR", payload: "WIFI:T:WPA;S:Lumen Café Guest;P:espresso-2026;;")],
                                       barcodeFirst: true)
                return AnyView(framed(card))
            },
            PreviewScene("translation", size: CGSize(width: 560, height: 520)) {
                let card = model(recents: false)
                card.capture = Capture(text: "本日の営業は午後8時までです。\nまたのご来店をお待ちしております。", mode: .lines, source: .screen,
                                       language: "ja")
                card.canJoin = true
                card.target = Locale.Language(identifier: "en")
                card.translation = .done("We’re open until 8 p.m. today.\nWe look forward to seeing you again.")
                return AnyView(framed(card))
            },
            PreviewScene("download", size: CGSize(width: 560, height: 480)) {
                let card = model(recents: false)
                card.capture = Capture(text: "Der Zug nach München fährt heute von Gleis 14 ab.", mode: .paragraphs, source: .screen,
                                       language: "de")
                card.target = Locale.Language(identifier: "ko")
                card.translation = .needsDownload
                return AnyView(framed(card))
            },
            PreviewScene("added", size: CGSize(width: 560, height: 420)) {
                let card = model(recents: false)
                card.capture = Capture(text: "Order #48213 · Shipped 3 November", mode: .lines, source: .screen, language: "en")
                card.addedCount = 3
                return AnyView(framed(card))
            },
            PreviewScene("file", size: CGSize(width: 560, height: 300)) {
                let card = model(recents: false)
                card.phase = .working(String(localized: "Reading “\("Invoice-2026-10.pdf")”…", comment: "Card title while reading a file; %@ is its name"),
                                      detail: String(localized: "Page \(2) of \(5)", comment: "Progress while reading a PDF"))
                return AnyView(framed(card))
            },
            PreviewScene("empty", size: CGSize(width: 560, height: 300)) {
                let card = model(recents: false)
                card.phase = .empty(String(localized: "No text found"))
                return AnyView(framed(card))
            },
            PreviewScene("drop", size: CGSize(width: 560, height: 380)) {
                let card = model(recents: false)
                card.capture = releaseNotes
                card.canJoin = true
                card.dropTargeted = true
                return AnyView(framed(card))
            },
        ]
    }

    static let releaseNotes = Capture(
        text: "Release notes 0.102\n\nMouse Button Lock and CursorHide join the mouse utilities family. Quick Accent gains Belarusian and Pitjantjatjara sets.",
        mode: .paragraphs, source: .screen, language: "en")

    /// A card model with sample recent captures.
    static func model(recents: Bool) -> CardModel {
        let history = CaptureHistory(file: nil)
        if recents {
            let now = Date()
            let samples = [
                Capture(date: now.addingTimeInterval(-4 * 3600), text: "ssh deploy@build-07.northwind.dev -p 2222", mode: .lines,
                        source: .screen, language: "en"),
                Capture(date: now.addingTimeInterval(-50 * 60), text: "", mode: .lines, source: .screen,
                        barcodes: [Barcode(symbology: "QR", payload: "https://conf.northwind.dev/talks/2026/live-text")], barcodeFirst: true),
                Capture(date: now.addingTimeInterval(-26 * 60), text: "Invoice INV-2026-1043 · Total due € 1,284.50", mode: .lines,
                        source: .file("Invoice-2026-10.pdf"), language: "en"),
                Capture(date: now.addingTimeInterval(-9 * 60), text: "会议改到周四下午两点，地点不变。", mode: .lines, source: .clipboard,
                        language: "zh-Hans"),
            ]
            for c in samples { history.add(c) }
        }
        let card = CardModel(history: history)
        card.target = Locale.Language(identifier: "en")
        return card
    }

    static func framed(_ card: CardModel) -> some View {
        ResultCard(model: card)
            .fixedSize(horizontal: false, vertical: true)
            .shadow(color: .black.opacity(0.3), radius: 24, y: 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The card under its selection on a document, as it appears after a capture.
    static func onDesk(_ card: CardModel) -> some View {
        ZStack(alignment: .topLeading) {
            SampleScreen()
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Tint.mint.color, lineWidth: 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Tint.mint.color.opacity(0.08)))
                .frame(width: 452, height: 186)
                .offset(x: 236, y: 152)
            ResultCard(model: card)
                .fixedSize(horizontal: false, vertical: true)
                .shadow(color: .black.opacity(0.3), radius: 24, y: 12)
                .offset(x: 236, y: 350)
        }
    }
}

/// A desktop with a document, standing in for the frozen screen in previews.
struct SampleScreen: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(red: 0.09, green: 0.13, blue: 0.36), Color(red: 0.42, green: 0.22, blue: 0.55),
                                    Color(red: 0.88, green: 0.54, blue: 0.42)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: "Release notes 0.102").font(.system(size: 26, weight: .bold))
                Text(verbatim: "Mouse Button Lock and CursorHide join\nthe mouse utilities family.").font(.system(size: 15))
                Text(verbatim: "Quick Accent gains Belarusian and Pitjantjatjara sets.").font(.system(size: 15)).padding(.top, 30)
            }
            .foregroundStyle(.white)
            .padding(.leading, 250)
            .padding(.top, 170)
        }
    }
}
