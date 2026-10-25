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
                    RowLabel(title: enabled ? Text("The MacToys Finder extension is on") : Text("The MacToys Finder extension is off"),
                             subtitle: Text("It adds the MacToys submenu (PowerRename, Image Resizer, File Locksmith, Peek) and New+ to Finder’s context menu. Turn it on under File Providers & Finder Extensions.",
                                            comment: "“File Providers & Finder Extensions” is the System Settings pane: use its name in macOS"))
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
