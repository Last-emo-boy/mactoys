import FinderSync
import MacToysCore
import SwiftUI

/// Settings section showing whether the MacToys Finder extension (context menus) is on.
struct FinderExtensionSection: View {
    @State private var enabled = FIFinderSyncController.isExtensionEnabled

    var body: some View {
        Section("Finder extension") {
            LabeledContent {
                Button("Extension Settings…") { FIFinderSyncController.showExtensionManagementInterface() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: enabled ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(enabled ? .green : .orange)
                        .font(.system(size: 16))
                    RowLabel(enabled ? "The MacToys Finder extension is on" : "The MacToys Finder extension is off",
                             subtitle: "It adds the MacToys submenu (PowerRename, Image Resizer, File Locksmith, Peek) "
                                 + "and New+ to Finder’s context menu. Turn it on under File Providers & Finder Extensions.")
                }
            }
        }
        .task {
            while !Task.isCancelled {
                enabled = FIFinderSyncController.isExtensionEnabled
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}
