import MacToysCore
import SwiftUI

/// Offscreen stand-in for the Awake `NSMenu` (menus can't be rendered offscreen), drawn from
/// the same `AwakeMenu.entries` the real menu uses.
struct AwakeMenuPreview: View {
    let entries: [AwakeMenuEntry]
    let highlighted: Int?
    let mode: AwakeMode

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            HStack(spacing: 14) {
                Image(nsImage: AwakeIcon.image(for: mode)).renderingMode(.template)
                Image(systemName: "wifi")
                Text("Sat 24 Oct 22:41")
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            menu
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }

    private var menu: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                switch entry {
                case .header(let title):
                    Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 12).padding(.top, 2).padding(.bottom, 3)
                case .separator:
                    Divider().padding(.horizontal, 10).padding(.vertical, 5)
                case let .item(title, checked, badge, action):
                    let hot = index == highlighted
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                            .opacity(checked ? 1 : 0).frame(width: 12)
                        Text(title)
                        Spacer(minLength: 16)
                        if let badge { Text(badge).foregroundStyle(hot ? .white.opacity(0.85) : .secondary) }
                        if action == .settings { Text("⌘ ,").foregroundStyle(hot ? .white.opacity(0.85) : .secondary) }
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(hot ? .white : .primary)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(RoundedRectangle(cornerRadius: 5).fill(hot ? Color.accentColor : .clear))
                    .padding(.horizontal, 5)
                }
            }
        }
        .padding(.vertical, 6)
        .frame(width: 290)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.black.opacity(0.12)))
        .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
        .environment(\.colorScheme, .light)
    }
}
