import FinderSync
import MacToysCore
import SwiftUI

/// Settings section showing whether the MacToys Finder extension (context menus) is on.
struct FinderExtensionSection: View {
    /// nil until the first check finishes. `FIFinderSyncController.isExtensionEnabled` waits on the
    /// extension service and can block for seconds, so it never runs on the main thread.
    @State private var enabled: Bool?

    var body: some View {
        Section("Finder extension") {
            LabeledContent {
                Button("Extension Settings…") { FIFinderSyncController.showExtensionManagementInterface() }
            } label: {
                HStack(spacing: 10) {
                    Group {
                        if let enabled {
                            Image(systemName: enabled ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                .foregroundStyle(enabled ? .green : .orange)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .font(.system(size: 16))
                    .frame(width: 18)
                    RowLabel(title: enabled == false ? Text("The MacToys Finder extension is off")
                                : Text("The MacToys Finder extension is on"),
                             subtitle: Text("It adds the MacToys submenu (PowerRename, Image Resizer, File Locksmith, Peek) and New+ to Finder’s context menu. Turn it on under File Providers & Finder Extensions.",
                                            comment: "“File Providers & Finder Extensions” is the System Settings pane: use its name in macOS"))
                }
            }
        }
        .task {
            while !Task.isCancelled {
                enabled = await Task.detached(priority: .utility) { FIFinderSyncController.isExtensionEnabled }.value
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}
