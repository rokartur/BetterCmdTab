import AppKit

/// App icons that exist only on the Dock tile, set through `NSApp.applicationIconImage` or an
/// `NSDockTilePlugIn`, which `NSRunningApplication.icon` never reports. A Finder custom icon
/// needs no entry here: `NSRunningApplication.icon` already returns it.
@MainActor
enum DockTileIcon {
    private static let cmuxBundleID = "com.cmuxterm.app"
    /// cmux posts this after its `appIconMode` default changes (cmux `AppIconDockTilePlugin.swift`).
    private static let cmuxIconDidChange = Notification.Name("com.cmuxterm.appIconDidChange")
    private static let rexBundleID = "com.superlogical.rex"
    private static let calendarBundleID = "com.apple.iCal"

    /// The icon the Dock shows for `bundleIdentifier`, or nil when it is the bundle icon.
    static func image(bundleIdentifier: String?, bundleURL: URL? = nil) -> NSImage? {
        switch bundleIdentifier {
        case cmuxBundleID: cmuxIcon(bundleURL: bundleURL)
        case rexBundleID: rexIcon(bundleURL: bundleURL)
        case calendarBundleID: calendarIcon(on: Date())
        default: nil
        }
    }

    /// Drops cached icons when cmux's icon mode, the system appearance or the day changes. Rex
    /// posts no change notification, so its tile updates when Rex relaunches.
    static func observeChanges() {
        let center = DistributedNotificationCenter.default()
        for name in [cmuxIconDidChange, Notification.Name("AppleInterfaceThemeChangedNotification")] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    IconCache.evict(bundleIdentifier: cmuxBundleID)
                    IconCache.evict(bundleIdentifier: calendarBundleID)
                }
            }
        }
        NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { IconCache.evict(bundleIdentifier: calendarBundleID) }
        }
    }

    private static func cmuxIcon(bundleURL: URL?) -> NSImage? {
        guard let url = bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: cmuxBundleID)
        else { return nil }
        CFPreferencesAppSynchronize(cmuxBundleID as CFString)
        let mode = CFPreferencesCopyAppValue("appIconMode" as CFString, cmuxBundleID as CFString) as? String
        let dark = switch mode {
        case "dark": true
        case "light": false
        default: isDarkAppearance()
        }
        return Bundle(url: url)?.image(forResource: dark ? "AppIconDark" : "AppIconLight")
    }

    private static func rexIcon(bundleURL: URL?) -> NSImage? {
        guard let url = bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: rexBundleID)
        else { return nil }
        CFPreferencesAppSynchronize(rexBundleID as CFString)
        // Rex sets `applicationIconImage` from asset "<Mode>AppIcon" ("shell" -> ShellAppIcon);
        // a mode without such an asset is the bundle icon.
        guard let mode = CFPreferencesCopyAppValue("Workspace.appIcon" as CFString, rexBundleID as CFString) as? String,
              let art = Bundle(url: url)?.image(forResource: mode.capitalized + "AppIcon")
        else { return nil }
        // The asset is full-bleed; shrink it to the 824/1024 macOS icon grid so it matches other tiles.
        return NSImage(size: art.size, flipped: false) { rect in
            art.draw(in: iconBody(in: rect))
            return true
        }
    }

    /// Calendar's Dock plugin draws the weekday and day of month; the bundle icon is a fixed grid.
    /// Proportions measured from the macOS 26 Dock tile.
    private static func calendarIcon(on date: Date) -> NSImage {
        let dark = isDarkAppearance()
        let weekday = date.formatted(.dateTime.weekday(.abbreviated))
        let day = date.formatted(.dateTime.day())
        return NSImage(size: NSSize(width: 512, height: 512), flipped: false) { rect in
            let body = iconBody(in: rect)
            let edge = body.width
            let tile = NSBezierPath(roundedRect: body, xRadius: edge * 0.225, yRadius: edge * 0.225)
            let fill = dark
                ? NSGradient(starting: NSColor(white: 0.17, alpha: 1), ending: NSColor(white: 0.08, alpha: 1))
                : NSGradient(starting: .white, ending: NSColor(white: 0.9, alpha: 1))
            fill?.draw(in: tile, angle: -90)
            NSColor(white: 1, alpha: dark ? 0.15 : 0.6).setStroke()
            tile.lineWidth = edge * 0.01
            tile.stroke()
            drawCentered(weekday, font: .systemFont(ofSize: edge * 0.2, weight: .medium),
                         color: .systemRed, center: NSPoint(x: body.midX, y: body.maxY - edge * 0.22))
            drawCentered(day, font: .systemFont(ofSize: edge * 0.64, weight: .regular),
                         color: dark ? .white : .black, center: NSPoint(x: body.midX, y: body.maxY - edge * 0.59))
            return true
        }
    }

    private static func drawCentered(_ text: String, font: NSFont, color: NSColor, center: NSPoint) {
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let size = string.size()
        // Center on the cap height, not the line box, so digits sit where the Dock puts them.
        let baseline = center.y - font.capHeight / 2
        string.draw(at: NSPoint(x: center.x - size.width / 2, y: baseline + font.descender))
    }

    private static func iconBody(in rect: NSRect) -> NSRect {
        rect.insetBy(dx: rect.width * 100 / 1024, dy: rect.height * 100 / 1024)
    }

    private static func isDarkAppearance() -> Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}
