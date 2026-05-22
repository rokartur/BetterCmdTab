import AppKit
import ApplicationServices

struct SwitcherRow {
    let app: NSRunningApplication
    let window: AXUIElement?
    let windowTitle: String
    let isMinimized: Bool
    let isFullscreen: Bool
    let isPlaceholder: Bool

    init(
        app: NSRunningApplication,
        window: AXUIElement?,
        windowTitle: String,
        isMinimized: Bool,
        isFullscreen: Bool = false,
        isPlaceholder: Bool = false
    ) {
        self.app = app
        self.window = window
        self.windowTitle = windowTitle
        self.isMinimized = isMinimized
        self.isFullscreen = isFullscreen
        self.isPlaceholder = isPlaceholder
    }

    var pid: pid_t { app.processIdentifier }
    var appName: String { app.localizedName ?? "" }
    var icon: NSImage? { app.icon }
    var displayTitle: String {
        if isPlaceholder { return appName }
        if window == nil { return appName }
        return windowTitle.isEmpty ? appName : windowTitle
    }
    var bundleIdentifier: String? { app.bundleIdentifier }
}
