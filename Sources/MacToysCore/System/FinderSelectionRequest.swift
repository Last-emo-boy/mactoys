import Foundation

extension FinderSelection {
    /// The Finder selection for a shortcut or quick action. When MacToys may not control Finder yet,
    /// shows a HUD, asks for Automation and returns nil.
    @MainActor
    public static func selectionRequestingPermission() -> [URL]? {
        if !PermissionCenter.shared.isGranted(.automation),
           !PermissionCenter.automationGranted(bundleID: "com.apple.finder") {
            HUD.show("Automation permission needed to read the Finder selection", symbol: "exclamationmark.shield")
            PermissionCenter.shared.request(.automation)
            return nil
        }
        return selectedURLs()
    }
}
