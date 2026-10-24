import MacToysCore
import Observation
import SwiftUI

/// Drag state on one screen's overlay. Points are in the overlay's own space (top-left origin).
@MainActor
@Observable
final class SelectionModel {
    private(set) var anchor: CGPoint?
    private(set) var current: CGPoint?
    private var last: CGPoint?
    var mode: TextExtractorSettings.Mode
    var language: String?

    init(mode: TextExtractorSettings.Mode, language: String?) {
        self.mode = mode
        self.language = language
    }

    var rect: CGRect? {
        guard let anchor, let current else { return nil }
        return CGRect(x: min(anchor.x, current.x), y: min(anchor.y, current.y),
                      width: abs(anchor.x - current.x), height: abs(anchor.y - current.y))
    }

    var isDragging: Bool { anchor != nil }

    func begin(at p: CGPoint) {
        anchor = p
        current = p
        last = p
    }

    /// Resizes from the anchor, or with Shift held moves the whole selection.
    func update(to p: CGPoint, moving: Bool) {
        if anchor == nil { begin(at: p) }
        if moving, let last, let a = anchor, let c = current {
            let d = CGPoint(x: p.x - last.x, y: p.y - last.y)
            anchor = CGPoint(x: a.x + d.x, y: a.y + d.y)
            current = CGPoint(x: c.x + d.x, y: c.y + d.y)
        } else {
            current = p
        }
        last = p
    }

    func reset() {
        anchor = nil
        current = nil
        last = nil
    }
}

/// The frozen screen, dimmed except for the selection, with the hint bar (design 06).
struct TextExtractorOverlay<Background: View>: View {
    @Bindable var model: SelectionModel
    let background: Background
    var languages: [(code: String, name: String)] = TextRecognizer.languages
    var onFinish: (_ rect: CGRect?, _ click: CGPoint?) -> Void = { _, _ in }
    var onSettingsChange: (TextExtractorSettings.Mode, String?) -> Void = { _, _ in }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                background
                    .frame(width: geo.size.width, height: geo.size.height)
                DimShape(hole: model.rect)
                    .fill(Color.black.opacity(0.48), style: FillStyle(eoFill: true))
                if let rect = model.rect, rect.width > 1 || rect.height > 1 {
                    Rectangle()
                        .strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        .allowsHitTesting(false)
                }
                hintBar
                    .fixedSize()
                    .position(hintPosition(in: geo.size))
            }
            .contentShape(Rectangle())
            .gesture(drag)
            .onContinuousHover { _ in NSCursor.crosshair.set() }
        }
        .ignoresSafeArea()
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if !model.isDragging { model.begin(at: value.startLocation) }
                model.update(to: value.location, moving: NSEvent.modifierFlags.contains(.shift))
                NSCursor.crosshair.set()
            }
            .onEnded { value in
                if let rect = model.rect, rect.width >= 4 || rect.height >= 4 {
                    onFinish(rect, nil)
                } else {
                    model.reset()
                    onFinish(nil, value.location)
                }
            }
    }

    /// Below the selection (above it when there's no room); centered near the top before a drag.
    private func hintPosition(in size: CGSize) -> CGPoint {
        let barSize = CGSize(width: 400, height: 38)
        guard let rect = model.rect, rect.width > 1 else {
            return CGPoint(x: size.width / 2, y: 64)
        }
        var y = rect.maxY + 12 + barSize.height / 2
        if y + barSize.height / 2 > size.height - 8 { y = rect.minY - 12 - barSize.height / 2 }
        if y - barSize.height / 2 < 8 { y = rect.maxY - 12 - barSize.height / 2 }
        let x = min(max(rect.minX + barSize.width / 2, barSize.width / 2 + 8), size.width - barSize.width / 2 - 8)
        return CGPoint(x: x, y: y)
    }

    private var hintBar: some View {
        HStack(spacing: 8) {
            Text(model.isDragging ? "Release to copy" : "Drag over text · click a word")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.leading, 4)
            Menu {
                Button("Automatic") { setLanguage(nil) }
                Divider()
                ForEach(languages, id: \.code) { lang in
                    Button(lang.name) { setLanguage(lang.code) }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(TextRecognizer.shortName(for: model.language))
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.08)))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            HStack(spacing: 2) {
                ForEach(TextExtractorSettings.Mode.allCases, id: \.self) { mode in
                    Button { setMode(mode) } label: {
                        Text(mode.title)
                            .font(.system(size: 11.5, weight: model.mode == mode ? .semibold : .regular))
                            .foregroundStyle(.white.opacity(model.mode == mode ? 1 : 0.7))
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                            .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(model.mode == mode ? 0.2 : 0)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(red: 0.11, green: 0.11, blue: 0.13).opacity(0.7))
        .glassEffect(.regular, in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.14)))
        .environment(\.colorScheme, .dark)
    }

    private func setMode(_ mode: TextExtractorSettings.Mode) {
        model.mode = mode
        onSettingsChange(mode, model.language)
    }

    private func setLanguage(_ code: String?) {
        model.language = code
        onSettingsChange(model.mode, code)
    }
}

/// The whole overlay minus the selection (filled even-odd).
struct DimShape: Shape {
    var hole: CGRect?

    func path(in rect: CGRect) -> Path {
        var p = Path(rect)
        if let hole, hole.width > 1 || hole.height > 1 { p.addRect(hole) }
        return p
    }
}
