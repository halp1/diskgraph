import AppKit

/// DiskGraph runs unsandboxed so it can measure anything the user points it at, which
/// means it needs Full Disk Access to see `~/Library`, other users' folders and most of
/// the system volume.
///
/// macOS offers no API to query the grant, so this probes a directory that is readable
/// only with it.
public enum FullDiskAccess {
    private static let promptedKey = "FullDiskAccessPrompted"

    /// A TCC-protected path that never requires a consent dialog to *attempt* — the read
    /// simply fails without the grant.
    private static let probePath = ("~/Library/Application Support/com.apple.TCC" as NSString)
        .expandingTildeInPath

    public static var isGranted: Bool {
        // opendir succeeds only when the grant is in place.
        guard let handle = opendir(probePath) else { return false }
        closedir(handle)
        return true
    }

    public static func shouldPrompt() -> Bool {
        !isGranted && !UserDefaults.standard.bool(forKey: promptedKey)
    }

    public static func presentPrompt(completion: @escaping () -> Void) {
        UserDefaults.standard.set(true, forKey: promptedKey)

        let alert = NSAlert()
        alert.messageText = "Grant Full Disk Access to see everything"
        alert.informativeText = """
            Without it, DiskGraph cannot read folders such as ~/Library, so parts of the \
            graph will be missing and totals will be too small.

            Open Privacy & Security ▸ Full Disk Access, then add and enable DiskGraph.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Privacy Settings")
        alert.addButton(withTitle: Strings.buttonContinue)

        if alert.runModal() == .alertFirstButtonReturn {
            openSettings()
        }
        completion()
    }

    public static func openSettings() {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }
}
