import Foundation

/// App version/build/name read from the main bundle. Previously lived in the
/// updater's `UpdaterLogging.swift`; relocated here when the updater moved to
/// the BetterUpdater Swift package.
enum AppInfo {
    static let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    static let appBuildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    static let displayName = (Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String)
        ?? (Bundle.main.infoDictionary?["CFBundleName"] as? String)
        ?? "BetterCmdTab"
}
