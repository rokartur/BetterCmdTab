import AppKit
import ApplicationServices

/// Identifies one tab within a browser window for an inline browser-tab row.
/// `index` is the tab's 0-based position; `parentTitle` is the parent window's
/// AX title, used to resolve the AppleScript `window N` on commit without a
/// raise (matching `BrowserTabs.tabTitles`/`activateTab`'s name-match path).
struct BrowserTabRef {
    let index: Int
    let parentTitle: String
}

struct SwitcherRow {
    /// What a row stands for. Most rows are a running app/window; search mode
    /// can also surface not-yet-running apps (`.launchable`) so they can be
    /// launched straight from the switcher.
    enum Subject {
        case running(NSRunningApplication)
        case launchable(InstalledApp)
        case recentlyClosed(RecentEntry)
    }

    let subject: Subject
    let window: AXUIElement?
    /// WindowServer id of `window`, propagated from `WindowInfo`. 0 for rows with
    /// no window (placeholder / launchable / recently-closed). Lets MRU sorting
    /// avoid re-resolving the id via `_AXUIElementGetWindow` on every reorder.
    let cgWindowID: CGWindowID
    let windowTitle: String
    let isMinimized: Bool
    let isFullscreen: Bool
    let isPlaceholder: Bool
    /// Set on the windowless row we synthesize the instant an app's last window
    /// is closed. The app's final resting state isn't known yet — it may stay
    /// windowless or hide itself (Electron apps do the latter) — so the view
    /// suppresses the "no window" glyph until the next cache refresh resolves
    /// it, avoiding a no-window→hidden flash. `isHidden` is read live, so if the
    /// app hides before then the row already shows the hidden glyph.
    let suppressNoWindowGlyph: Bool
    /// In-content `AXTabs` of this row's window (rare; most apps don't expose
    /// it). Drives the AX `\` drill backend for apps that do.
    let tabs: [AXUIElement]
    /// Native macOS window-tab siblings, when this row is the collapsed front
    /// tab of a group (Finder/Terminal/TextEdit/…). Each is a real NSWindow;
    /// the `\` peek lists them and committing one raises that window (selecting
    /// the tab). Empty for ordinary windows and in "expand tabs as windows" mode
    /// (each tab is then its own row).
    let tabWindows: [TabWindowRef]
    /// Non-nil when this row stands for a single browser tab (Safari/Chromium)
    /// surfaced inline among windows — the "expand browser tabs as windows"
    /// mode. `window`/`cgWindowID` point at the *parent* browser window;
    /// `browserTab.index` is the tab's 0-based position and `browserTab.parentTitle`
    /// is the parent window's AX title, used to resolve the AppleScript window on
    /// commit without a raise. Browser tabs aren't separate NSWindows, so there's
    /// no per-tab AX element — activation goes through `BrowserTabs.activateTab`.
    let browserTab: BrowserTabRef?
    /// True when this row is a background tab of a native window-tab group kept
    /// as its own row ("expand tabs as windows"). A tabbed-away window belongs
    /// to no Space — the same signature as an Electron phantom helper — so the
    /// phantom-window filter exempts these rows instead of dropping them.
    let isTabSibling: Bool

    init(
        app: NSRunningApplication,
        window: AXUIElement?,
        windowTitle: String,
        isMinimized: Bool,
        isFullscreen: Bool = false,
        isPlaceholder: Bool = false,
        suppressNoWindowGlyph: Bool = false,
        tabs: [AXUIElement] = [],
        tabWindows: [TabWindowRef] = [],
        cgWindowID: CGWindowID = 0,
        browserTab: BrowserTabRef? = nil,
        isTabSibling: Bool = false
    ) {
        self.subject = .running(app)
        self.window = window
        self.cgWindowID = cgWindowID
        self.windowTitle = windowTitle
        self.isMinimized = isMinimized
        self.isFullscreen = isFullscreen
        self.isPlaceholder = isPlaceholder
        self.suppressNoWindowGlyph = suppressNoWindowGlyph
        self.tabs = tabs
        self.tabWindows = tabWindows
        self.browserTab = browserTab
        self.isTabSibling = isTabSibling
    }

    /// Map one enumerated window to its switcher row, carrying its native
    /// window-tab siblings (if any) for the `\` peek. Expansion to one row per
    /// tab is decided upstream in `WindowEnumerator` (it emits one `WindowInfo`
    /// per tab in that mode), so this is always 1:1.
    static func from(app: NSRunningApplication, window w: WindowInfo) -> SwitcherRow {
        SwitcherRow(
            app: app,
            window: w.ref,
            windowTitle: w.title,
            isMinimized: w.isMinimized,
            isFullscreen: w.isFullscreen,
            tabs: w.tabs,
            tabWindows: w.tabWindows,
            cgWindowID: w.cgWindowID,
            isTabSibling: w.isTabSibling
        )
    }

    /// A not-yet-running app surfaced in search so it can be launched.
    init(launchable: InstalledApp) {
        self.subject = .launchable(launchable)
        self.window = nil
        self.cgWindowID = 0
        self.windowTitle = ""
        self.isMinimized = false
        self.isFullscreen = false
        self.isPlaceholder = false
        self.suppressNoWindowGlyph = false
        self.tabs = []
        self.tabWindows = []
        self.browserTab = nil
        self.isTabSibling = false
    }

    /// A recently closed window/app surfaced in search so it can be reopened.
    init(recentlyClosed entry: RecentEntry) {
        self.subject = .recentlyClosed(entry)
        self.window = nil
        self.cgWindowID = 0
        self.windowTitle = entry.title
        self.isMinimized = false
        self.isFullscreen = false
        self.isPlaceholder = false
        self.suppressNoWindowGlyph = false
        self.tabs = []
        self.tabWindows = []
        self.browserTab = nil
        self.isTabSibling = false
    }

    /// A copy of this row with an updated window title, used for in-place title
    /// refresh while the panel is open. No-op for non-window (launchable/recent)
    /// subjects since they carry no live window title.
    func withWindowTitle(_ newTitle: String) -> SwitcherRow {
        guard case .running(let app) = subject else { return self }
        return SwitcherRow(
            app: app,
            window: window,
            windowTitle: newTitle,
            isMinimized: isMinimized,
            isFullscreen: isFullscreen,
            isPlaceholder: isPlaceholder,
            suppressNoWindowGlyph: suppressNoWindowGlyph,
            tabs: tabs,
            tabWindows: tabWindows,
            cgWindowID: cgWindowID,
            browserTab: browserTab,
            isTabSibling: isTabSibling
        )
    }

    /// Expand this collapsed browser-window row into one row per tab. Each output
    /// row shows a tab's title and carries its 0-based index plus this window's
    /// title (`parentTitle`) so commit can resolve the AppleScript window without
    /// a raise. Fewer than 2 titles, a non-running subject, or no window → just
    /// this row (nothing to expand). Pure — no AX messaging.
    func browserTabRows(tabTitles: [String]) -> [SwitcherRow] {
        guard case .running(let app) = subject, window != nil, tabTitles.count > 1 else { return [self] }
        let parentTitle = windowTitle
        return tabTitles.enumerated().map { i, title in
            SwitcherRow(
                app: app,
                window: window,
                windowTitle: title,
                isMinimized: isMinimized,
                isFullscreen: isFullscreen,
                cgWindowID: cgWindowID,
                browserTab: BrowserTabRef(index: i, parentTitle: parentTitle)
            )
        }
    }

    /// Collapse a browser-tab row back to its parent-window row — the inverse of
    /// `browserTabRows`, reconstructing the window row from the tab's stored
    /// `parentTitle`. Returns `self` for non-tab rows. Lets the controller
    /// re-derive a fresh collapsed source for re-expansion straight from the
    /// displayed rows, rather than keeping a parallel array that can drift.
    func collapsedFromBrowserTab() -> SwitcherRow {
        guard let bt = browserTab, case .running(let app) = subject else { return self }
        return SwitcherRow(
            app: app,
            window: window,
            windowTitle: bt.parentTitle,
            isMinimized: isMinimized,
            isFullscreen: isFullscreen,
            cgWindowID: cgWindowID,
            browserTab: nil
        )
    }

    /// True when this row has a tab group worth peeking with `\` — either native
    /// window-tab siblings or an in-content `AXTabs` group.
    var hasTabs: Bool { tabWindows.count > 1 || tabs.count > 1 }

    /// The backing running application, or `nil` for a launchable/recent row.
    var app: NSRunningApplication? {
        if case .running(let app) = subject { return app }
        return nil
    }

    var isLaunchable: Bool {
        if case .launchable = subject { return true }
        return false
    }

    var isRecentlyClosed: Bool {
        if case .recentlyClosed = subject { return true }
        return false
    }

    var recentEntry: RecentEntry? {
        if case .recentlyClosed(let entry) = subject { return entry }
        return nil
    }

    /// `nil` for launchable rows (no process yet).
    var pid: pid_t? { app?.processIdentifier }

    var appName: String {
        switch subject {
        case .running(let app): return app.localizedName ?? ""
        case .launchable(let installed): return installed.name
        case .recentlyClosed(let entry): return entry.appName
        }
    }

    var icon: NSImage? {
        switch subject {
        case .running(let app): return app.icon
        case .launchable(let installed): return installed.icon
        case .recentlyClosed(let entry):
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.bundleID) else { return nil }
            return NSWorkspace.shared.icon(forFile: url.path)
        }
    }

    var bundleIdentifier: String? {
        switch subject {
        case .running(let app): return app.bundleIdentifier
        case .launchable(let installed): return installed.bundleID
        case .recentlyClosed(let entry): return entry.bundleID
        }
    }

    /// Whether the backing app is hidden. Always false for non-running rows.
    var isHidden: Bool { app?.isHidden ?? false }

    /// System UI agents that host permission/consent windows. Their process
    /// name and icon are cryptic, so these rows are presented with the window
    /// title and the System Settings icon instead.
    ///
    /// `UserNotificationCenter` is the big one — it hosts the bulk of TCC
    /// prompts (camera, microphone, screen recording, files & folders,
    /// automation, contacts, …), so covering it handles "other" permission
    /// windows beyond the accessibility alert. The rest cover the cases that
    /// have their own host process.
    static let systemDialogHosts: Set<String> = [
        "com.apple.UserNotificationCenter",
        "com.apple.accessibility.universalAccessAuthWarn", // "control this computer" accessibility alert
        "com.apple.SecurityAgent",                          // password / authorization prompts
        "com.apple.coreservices.uiagent",                   // quarantine / "downloaded app" consent
        "com.apple.CoreServicesUIAgent",                    // older id variant, kept defensively
    ]

    var isSystemDialog: Bool {
        guard let bundleID = bundleIdentifier else { return false }
        return Self.systemDialogHosts.contains(bundleID)
    }

    var displayTitle: String {
        if isPlaceholder { return appName }
        if case .recentlyClosed(let entry) = subject {
            return entry.title.isEmpty ? appName : entry.title
        }
        if window == nil { return appName }
        return windowTitle.isEmpty ? appName : windowTitle
    }

    /// The window-title portion only — falls back to `appName` when the window title
    /// is empty (e.g. PWAs whose AX title is blank). Used by the "Show application
    /// names" = off path. Windowless rows and placeholders still return "".
    var windowTitleText: String {
        if isPlaceholder { return "" }
        // Mirror `displayTitle`'s fallback: a recently-closed entry with a blank
        // title (e.g. an app-level reopen recorded on ⌘Q) keeps the app name so the
        // Previews layout — which renders this verbatim with no "Reopen" fallback —
        // never shows a fully blank tile.
        if case .recentlyClosed(let entry) = subject {
            return entry.title.isEmpty ? appName : entry.title
        }
        if window == nil { return "" }
        return windowTitle.isEmpty ? appName : windowTitle
    }

    /// Text for the dedicated app-name slot (List right column, Grid name-under-
    /// icon). Empty when the user hid application names. The single source of this
    /// rule so the layouts can't drift; dialog rows handle their own label inline.
    func appNameSlot(showAppNames: Bool) -> String {
        showAppNames ? appName : ""
    }

    /// Text for the primary title slot: the full `displayTitle` when app names are
    /// shown, or the window-title-only `windowTitleText` when hidden (so hiding
    /// names never re-surfaces the app name as a title). Shared by List and Previews.
    func titleSlot(showAppNames: Bool) -> String {
        showAppNames ? displayTitle : windowTitleText
    }
}

/// Cached System Settings app icon, used for system permission/dialog rows.
@MainActor
enum SystemSettingsIcon {
    static let image: NSImage? = {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: "gearshape.fill", accessibilityDescription: "System Settings")
    }()
}
