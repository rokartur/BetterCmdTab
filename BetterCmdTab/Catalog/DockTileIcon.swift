import AppKit

/// App icons that exist only on the Dock tile, set through `NSApp.applicationIconImage` or an
/// `NSDockTilePlugIn`, which `NSRunningApplication.icon` never reports. A Finder custom icon
/// needs no entry here: `NSRunningApplication.icon` already returns it.
@MainActor
enum DockTileIcon {
    private static let cmuxBundleID = "com.cmuxterm.app"
    /// cmux posts this after its `appIconMode` default changes (cmux `AppIconDockTilePlugin.swift`).
    private static let cmuxIconDidChange = Notification.Name("com.cmuxterm.appIconDidChange")

    /// The icon the Dock shows for `bundleIdentifier`, or nil when it is the bundle icon.
    static func image(bundleIdentifier: String?, bundleURL: URL? = nil) -> NSImage? {
        guard bundleIdentifier == cmuxBundleID,
              let url = bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: cmuxBundleID)
        else { return nil }
        CFPreferencesAppSynchronize(cmuxBundleID as CFString)
        let mode = CFPreferencesCopyAppValue("appIconMode" as CFString, cmuxBundleID as CFString) as? String
        let dark = switch mode {
        case "dark": true
        case "light": false
        default: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
        return Bundle(url: url)?.image(forResource: dark ? "AppIconDark" : "AppIconLight")
    }

    /// Drops cached cmux icons when its icon mode or the system appearance changes.
    static func observeChanges() {
        let center = DistributedNotificationCenter.default()
        for name in [cmuxIconDidChange, Notification.Name("AppleInterfaceThemeChangedNotification")] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { IconCache.evict(bundleIdentifier: cmuxBundleID) }
            }
        }
    }
}
