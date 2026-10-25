import AppKit
import MacToysCore
import SwiftUI

/// Sample area used by the snapshot scenes: the chart card of the mock dashboard.
private let sampleCrop = CGRect(x: 358, y: 86, width: 312, height: 188)
private let dashboardSize = CGSize(width: 700, height: 460)

/// Snapshot scene: the selection overlay dragged over a window.
struct CropSelectionPreview: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            MockDashboard()
                .frame(width: dashboardSize.width, height: dashboardSize.height)
                .offset(x: 100, y: 60)
            SelectionPreviewView(selection: sampleCrop)
                .frame(width: dashboardSize.width, height: dashboardSize.height)
                .offset(x: 100, y: 60)
        }
    }
}

/// Snapshot scene: a resized live thumbnail and an interactive crop floating over other windows.
struct CropWindowPreview: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            MockDashboard()
                .frame(width: dashboardSize.width, height: dashboardSize.height)
                .opacity(0.92)
                .offset(x: 40, y: 40)
            CropChrome(showClose: true) {
                CroppedDashboard(crop: sampleCrop).scaleEffect(1.3, anchor: .topLeading)
                    .frame(width: sampleCrop.width * 1.3, height: sampleCrop.height * 1.3, alignment: .topLeading)
            }
            .offset(x: 470, y: 250)
            CropChrome(showClose: false) {
                CroppedDashboard(crop: CGRect(x: 22, y: 86, width: 332, height: 124))
            }
            .offset(x: 70, y: 360)
        }
    }
}

/// Snapshot scene: a screenshot crop with its toolbar showing.
struct ScreenshotCropPreview: View {
    var body: some View {
        ScreenshotCropView(image: sampleImage(), alwaysShowToolbar: true)
            .frame(width: sampleCrop.width * 1.4, height: sampleCrop.height * 1.4)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 22, y: 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @MainActor private func sampleImage() -> NSImage {
        let renderer = ImageRenderer(content: CroppedDashboard(crop: sampleCrop).environment(\.colorScheme, .light))
        renderer.scale = 2
        return renderer.nsImage ?? NSImage(size: sampleCrop.size)
    }
}

/// Draws the real selection view with a fixed selection.
private struct SelectionPreviewView: NSViewRepresentable {
    let selection: CGRect

    func makeNSView(context: Context) -> CropSelectionView {
        let v = CropSelectionView(frame: CGRect(origin: .zero, size: dashboardSize), mode: .thumbnail)
        v.selection = selection
        return v
    }

    func updateNSView(_ view: CropSelectionView, context: Context) { view.selection = selection }
}

/// Window chrome of a crop window: rounded, shadowed, close button on hover.
private struct CropChrome<Content: View>: View {
    let showClose: Bool
    @ViewBuilder let content: Content

    var body: some View {
        content
            .overlay(alignment: .topLeading) {
                if showClose {
                    Circle().fill(Color(red: 1, green: 0.37, blue: 0.34)).frame(width: 12, height: 12)
                        .overlay(Image(systemName: "xmark").font(.system(size: 7, weight: .heavy)).foregroundStyle(.black.opacity(0.55)))
                        .padding(9)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.18)))
            .shadow(color: .black.opacity(0.35), radius: 22, y: 10)
    }
}

/// The part of the mock dashboard inside `crop`.
private struct CroppedDashboard: View {
    let crop: CGRect

    var body: some View {
        MockDashboard()
            .frame(width: dashboardSize.width, height: dashboardSize.height)
            .offset(x: -crop.minX, y: -crop.minY)
            .frame(width: crop.width, height: crop.height, alignment: .topLeading)
            .clipped()
            .environment(\.colorScheme, .light)
    }
}

/// An analytics window drawn in code.
struct MockDashboard: View {
    private let bars: [CGFloat] = [0.42, 0.55, 0.38, 0.7, 0.62, 0.84, 0.76, 0.9, 0.68, 0.95]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18),
                         Color(red: 0.16, green: 0.79, blue: 0.25)], id: \.self) { Circle().fill($0).frame(width: 12, height: 12) }
                Spacer()
                Text(verbatim: "Analytics — Q4").font(.system(size: 13, weight: .semibold)).foregroundStyle(.black.opacity(0.7))
                Spacer()
                Color.clear.frame(width: 50)
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(Color(white: 0.955))
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 12) {
                    stat("Active users", "48,210", "+12.4%", .green)
                    stat("Revenue", "$1.92M", "+8.1%", .green)
                    stat("Churn", "2.3%", "−0.4%", .orange)
                }
                .frame(width: 320)
                VStack(alignment: .leading, spacing: 10) {
                    Text(verbatim: "Weekly signups").font(.system(size: 13, weight: .semibold)).foregroundStyle(.black.opacity(0.8))
                    HStack(alignment: .bottom, spacing: 9) {
                        ForEach(Array(bars.enumerated()), id: \.offset) { i, v in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(i == bars.count - 1 ? Color(nsColor: Tint.teal.nsColor) : Color(nsColor: Tint.blue.nsColor).opacity(0.75))
                                .frame(width: 18, height: 110 * v)
                        }
                    }
                    .frame(height: 112, alignment: .bottom)
                }
                .padding(14)
                .frame(width: 300, height: 176, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.black.opacity(0.08)))
            }
            .padding(.horizontal, 28)
            .padding(.top, 52)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(0..<5, id: \.self) { i in
                    HStack {
                        Capsule().fill(Color.black.opacity(0.12)).frame(width: CGFloat(140 + (i * 53) % 120), height: 7)
                        Spacer()
                        Capsule().fill(Color.black.opacity(0.08)).frame(width: 60, height: 7)
                    }
                }
            }
            .padding(28)
            Spacer(minLength: 0)
        }
        .background(Color(white: 0.985))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 20, y: 10)
        .environment(\.colorScheme, .light)
    }

    private func stat(_ title: String, _ value: String, _ delta: String, _ color: Color) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: title).font(.system(size: 11.5)).foregroundStyle(.black.opacity(0.5))
                Text(verbatim: value).font(.system(size: 19, weight: .bold)).foregroundStyle(.black.opacity(0.85))
            }
            Spacer()
            Text(verbatim: delta).font(.system(size: 12, weight: .semibold)).foregroundStyle(color)
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.black.opacity(0.08)))
    }
}
