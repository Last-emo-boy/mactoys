import MacToysCore
import SwiftUI

/// Snapshot scene: an active app window with two pinned windows mirrored above it — one with the
/// default accent ring, one with a custom square orange border.
struct AlwaysOnTopPreview: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            MockWindow(title: "Mail — Inbox", rows: 11, sidebar: true)
                .frame(width: 640, height: 450)
                .offset(x: 60, y: 46)
            pinned(MockWindow(title: "Notes — Release checklist", rows: 8, accent: .yellow),
                   frame: CGRect(x: 548, y: 150, width: 352, height: 300),
                   color: Color(nsColor: .controlAccentColor), border: 4, rounded: true)
            pinned(MockPlayer(),
                   frame: CGRect(x: 96, y: 420, width: 320, height: 118),
                   color: Color(nsColor: Tint.orange.nsColor), border: 6, rounded: false)
        }
        .environment(\.colorScheme, .light)
    }

    private func pinned<V: View>(_ content: V, frame: CGRect, color: Color, border: CGFloat, rounded: Bool) -> some View {
        let radii = PinGeometry.radii(rounded: rounded, border: border)
        return content
            .frame(width: frame.width, height: frame.height)
            .clipShape(RoundedRectangle(cornerRadius: radii.inner, style: .continuous))
            .padding(border)
            .overlay(RoundedRectangle(cornerRadius: radii.outer, style: .continuous).strokeBorder(color, lineWidth: border))
            .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
            .offset(x: frame.minX - border, y: frame.minY - border)
    }
}

/// A plain app window drawn in code (toolbar, optional sidebar, text lines).
struct MockWindow: View {
    let title: String
    let rows: Int
    var sidebar = false
    var accent: Color = .blue

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                HStack(spacing: 7) {
                    ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18),
                             Color(red: 0.16, green: 0.79, blue: 0.25)], id: \.self) { Circle().fill($0).frame(width: 12, height: 12) }
                    Spacer()
                }
                Text(verbatim: title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.black.opacity(0.7))
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(Color(white: 0.955))
            HStack(spacing: 0) {
                if sidebar {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(0..<6, id: \.self) { i in
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 3).fill(i == 0 ? accent : Color.black.opacity(0.18)).frame(width: 12, height: 12)
                                Capsule().fill(Color.black.opacity(0.14)).frame(width: CGFloat(54 + (i * 13) % 30), height: 7)
                            }
                        }
                        Spacer()
                    }
                    .padding(14)
                    .frame(width: 150)
                    .frame(maxHeight: .infinity)
                    .background(Color(white: 0.93))
                }
                VStack(alignment: .leading, spacing: 11) {
                    Capsule().fill(Color.black.opacity(0.22)).frame(width: 150, height: 10)
                    ForEach(0..<rows, id: \.self) { i in
                        HStack(spacing: 8) {
                            if !sidebar {
                                RoundedRectangle(cornerRadius: 3).strokeBorder(accent, lineWidth: 1.5).frame(width: 12, height: 12)
                            }
                            Capsule().fill(Color.black.opacity(0.1))
                                .frame(width: CGFloat(120 + (i * 47) % 170), height: 7)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 20, y: 10)
    }
}

/// A compact media player window.
private struct MockPlayer: View {
    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.98, green: 0.36, blue: 0.45), Color(red: 0.55, green: 0.2, blue: 0.85)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 78, height: 78)
                .overlay(Image(systemName: "music.note").font(.system(size: 28, weight: .semibold)).foregroundStyle(.white))
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: "Midnight City").font(.system(size: 14, weight: .semibold)).foregroundStyle(.black.opacity(0.85))
                Text(verbatim: "M83 · Hurry Up, We're Dreaming").font(.system(size: 11.5)).foregroundStyle(.black.opacity(0.5))
                HStack(spacing: 16) {
                    Image(systemName: "backward.fill")
                    Image(systemName: "pause.fill").font(.system(size: 18))
                    Image(systemName: "forward.fill")
                }
                .foregroundStyle(.black.opacity(0.7))
                .padding(.top, 2)
                Capsule().fill(Color.black.opacity(0.1)).frame(height: 4)
                    .overlay(alignment: .leading) { Capsule().fill(Color.black.opacity(0.45)).frame(width: 80, height: 4) }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Color(white: 0.97))
    }
}
