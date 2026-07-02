import AppKit
import BetterSettings

// Central declaration of the settings window: the ordered tabs (with their
// macOS-style gradient icon badges), the searchable catalog, and the factory
// that builds each tab's content controller. Consumed by
// `SettingsWindowPresenter` to drive `BetterSettings.SettingsWindowController`.

/// Tab identifiers shared between the catalog and the content controllers.
enum SettingsTabID {
    static let general = "general"
    static let shortcuts = "shortcuts"
    static let windows = "windows"
    static let switcher = "switcher"
    static let apps = "apps"
    static let appearance = "appearance"
    static let privacy = "privacy"
    static let experimental = "experimental"
    static let about = "about"
}

/// Section-anchor identifiers. A content controller registers each section
/// under one of these so search/section navigation can scroll to it.
enum SettingsAnchor {
    // General
    static let startup = "general.startup"
    static let feedback = "general.feedback"
    static let updates = "general.updates"
    static let backup = "general.backup"
    // Profiles (shortcuts tab)
    static let switching = "shortcuts.switching"
    static let scopedSwitch = "shortcuts.scopedSwitch"
    static let panelKeys = "shortcuts.panelKeys"
    // Windows
    static let windowArrange = "windows.arrange"
    static let windowAll = "windows.all"
    // Privacy
    static let screenSharing = "privacy.screenSharing"
    static let permissions = "privacy.permissions"
    static let recovery = "privacy.recovery"
    // Behavior (switcher tab)
    static let display = "switcher.display"
    static let contents = "switcher.contents"
    static let tabs = "switcher.tabs"
    static let search = "switcher.search"
    static let navigation = "switcher.navigation"
    static let actions = "switcher.actions"
    // Apps
    static let appRules = "apps.rules"
    static let directActivation = "apps.directActivation"
    static let pinned = "apps.pinned"
    // Appearance
    static let appearance = "appearance.switcher"
    // Experimental
    static let experimental = "experimental.features"
    // About
    static let about = "about.info"
}

/// Search-item identifiers. A row registers itself under the matching id so a
/// search result scrolls straight to (and flashes) that exact control.
enum SearchID {
    // General
    static let launchAtLogin = "general.launchAtLogin"
    static let hideMenuBar = "general.hideMenuBar"
    static let switchApps = "general.switchApps"
    static let switchWindows = "general.switchWindows"
    static let haptic = "general.haptic"
    static let sound = "general.sound"
    static let hideFromScreenSharing = "general.hideFromScreenSharing"
    static let accessibility = "general.accessibility"
    static let restoreShortcuts = "privacy.restoreShortcuts"
    static let updateInterval = "general.updateInterval"
    static let beta = "general.beta"
    static let directActivation = "general.directActivation"
    static let scopedSwitch = "shortcuts.scopedSwitch"
    static let panelKeys = "shortcuts.panelKeys"
    static let windowMgmt = "shortcuts.windowMgmt"
    static let exportSettings = "general.exportSettings"
    static let importSettings = "general.importSettings"
    // Switcher
    static let showMinimized = "switcher.showMinimized"
    static let showHidden = "switcher.showHidden"
    static let showWindowless = "switcher.showWindowless"
    static let applicationsOnly = "switcher.applicationsOnly"
    static let showBadges = "switcher.showBadges"
    static let spaceScope = "switcher.spaceScope"
    static let sortOrder = "switcher.sortOrder"
    static let showRecentlyClosed = "switcher.showRecentlyClosed"
    static let recentlyClosedLimit = "switcher.recentlyClosedLimit"
    static let tabDrill = "switcher.tabDrill"
    static let expandTabs = "switcher.expandTabs"
    static let expandBrowserTabs = "switcher.expandBrowserTabs"
    static let tabPermissions = "switcher.tabPermissions"
    static let letterHints = "switcher.letterHints"
    static let applicationNames = "switcher.applicationNames"
    static let fuzzy = "switcher.fuzzy"
    static let launcher = "switcher.launcher"
    static let searchMode = "switcher.searchMode"
    static let letterChainTimeout = "switcher.letterChainTimeout"
    static let shiftTapBack = "switcher.shiftTapBack"
    static let scroll = "switcher.scroll"
    static let scrollReverse = "switcher.scrollReverse"
    static let clickDismiss = "switcher.clickDismiss"
    static let stayOpen = "switcher.stayOpen"
    static let vimNavigation = "switcher.vimNavigation"
    static let hoverActions = "switcher.hoverActions"
    static let displayMonitor = "switcher.displayMonitor"
    static let exceptions = "switcher.exceptions"
    static let pinnedApps = "switcher.pinnedApps"
    // Appearance
    static let layout = "appearance.layout"
    static let size = "appearance.size"
    static let gridColumns = "appearance.gridColumns"
    static let accent = "appearance.accent"
    static let quickSwitchDelay = "appearance.quickSwitchDelay"
    static let windowTitle = "appearance.windowTitle"
    static let titleAlignment = "appearance.titleAlignment"
    static let boldSelected = "appearance.boldSelected"
    static let opacity = "appearance.opacity"
    static let cornerRadius = "appearance.cornerRadius"
    // Experimental
    static let swipe = "experimental.swipe"
    static let swipeMode = "experimental.swipeMode"
    static let reverseSwipe = "experimental.reverseSwipe"
    static let switchOnRelease = "experimental.switchOnRelease"
    static let sensitivity = "experimental.sensitivity"
    static let instantSpace = "experimental.instantSpace"
    static let browserTabMRU = "experimental.browserTabMRU"
}

@MainActor
enum SettingsCatalog {

    static func makeConfiguration() -> SettingsConfiguration {
        SettingsConfiguration(
            tabs: tabs,
            searchItems: searchItems,
            contentProvider: { tab, _ in
                switch tab.id {
                case SettingsTabID.general:      return GeneralSettingsViewController()
                case SettingsTabID.shortcuts:    return ShortcutsSettingsViewController()
                case SettingsTabID.windows:      return WindowsSettingsViewController()
                case SettingsTabID.switcher:     return SwitcherSettingsViewController()
                case SettingsTabID.apps:         return AppsSettingsViewController()
                case SettingsTabID.appearance:   return AppearanceSettingsViewController()
                case SettingsTabID.privacy:      return PrivacySettingsViewController()
                case SettingsTabID.experimental: return ExperimentalSettingsViewController()
                default:                         return AboutSettingsViewController()
                }
            },
            searchPlaceholder: String(localized: "Search"),
            showDetailsDefaultsKey: "BetterCmdTab.showSettingsDetails",
            // 9 tabs: keep the active tab + 1 previous live and drop to active-only
            // when the settings window loses key. Inactive tab trees are freed and
            // rebuilt lazily on revisit, minimizing RAM for this secondary window.
            tabUnloadPolicy: .balanced
        )
    }

    // MARK: - Tabs

    static let tabs: [SettingsTab] = [
        // Palette + icon style mirror BetterAudio: muted macOS System Settings
        // gradient badges (gray, blue, purple, pink, red, orange; white badge for
        // About) with white SF Symbols.
        SettingsTab(
            id: SettingsTabID.general, title: String(localized: "General"), icon: "gear",
            iconStyle: style(0x898A8F, 0x67686E, scale: 1.0)
        ),
        // Profiles — each switcher shortcut is a profile with its own trigger +
        // per-shortcut options, plus direct-activation and in-panel keys.
        SettingsTab(
            id: SettingsTabID.shortcuts, title: String(localized: "Profiles"), icon: "command",
            iconStyle: style(0x40BCFF, 0x0060FF, scale: 0.9)
        ),
        // Window management — tile / maximize / center + hide-all hotkeys.
        SettingsTab(
            id: SettingsTabID.windows, title: String(localized: "Windows"), icon: "macwindow.on.rectangle",
            iconStyle: style(0x5AC8FA, 0x0A84C4, scale: 0.85)
        ),
        // Stacked windows — the switcher cycles through your open windows/apps.
        SettingsTab(
            id: SettingsTabID.switcher, title: String(localized: "Behavior"), icon: "rectangle.stack.fill",
            iconStyle: style(0xB272FF, 0x6228FF, scale: 0.95)
        ),
        // Per-app rules (hide / ⌘Tab) and pinned apps.
        SettingsTab(
            id: SettingsTabID.apps, title: String(localized: "Apps"), icon: "square.grid.2x2.fill",
            iconStyle: style(0x4ED98F, 0x12A85B, scale: 0.9)
        ),
        SettingsTab(
            id: SettingsTabID.appearance, title: String(localized: "Appearance"), icon: "paintbrush.fill",
            iconStyle: style(0xFF6991, 0xD41E5A, scale: 0.9)
        ),
        SettingsTab(
            id: SettingsTabID.privacy, title: String(localized: "Privacy"), icon: "lock.fill",
            iconStyle: style(0xFF5E62, 0xFF0016, scale: 0.9)
        ),
        SettingsTab(
            id: SettingsTabID.experimental, title: String(localized: "Experimental"), icon: "flask.fill",
            iconStyle: style(0xFFA846, 0xFF6F00, scale: 0.9)
        ),
        SettingsTab(
            id: SettingsTabID.about, title: String(localized: "About"), icon: "info.circle.fill",
            iconStyle: style(0xFFFFFF, 0xECECF0, scale: 1.0, symbol: 0x1C1C1E)
        ),
    ]

    private static func style(
        _ start: UInt32,
        _ end: UInt32,
        scale: CGFloat,
        symbol: UInt32? = nil,
        mode: SettingsTabIconStyle.SymbolColorMode = .hierarchical
    ) -> SettingsTabIconStyle {
        SettingsTabIconStyle(
            symbolColor: symbol.map { SettingsColor(hex: $0) } ?? .white,
            gradientStart: SettingsColor(hex: start),
            gradientEnd: SettingsColor(hex: end),
            symbolScale: scale,
            symbolColorMode: mode
        )
    }

    // MARK: - Search catalog

    static let searchItems: [SettingsSearchItem] = [
        // General · Startup
        item(SearchID.launchAtLogin, .general, SettingsAnchor.startup, String(localized: "General"), String(localized: "Startup"),
             String(localized: "Launch at login"), ["startup", "boot", "open at login", "autostart"]),
        item(SearchID.hideMenuBar, .general, SettingsAnchor.startup, String(localized: "General"), String(localized: "Startup"),
             String(localized: "Hide menu bar icon"), ["menu bar", "status item", "hide icon"]),
        // General · Feedback
        item(SearchID.haptic, .general, SettingsAnchor.feedback, String(localized: "General"), String(localized: "Feedback"),
             String(localized: "Haptic feedback on switch"), ["haptic", "vibration", "force touch", "trackpad"]),
        item(SearchID.sound, .general, SettingsAnchor.feedback, String(localized: "General"), String(localized: "Feedback"),
             String(localized: "Sound on switch"), ["sound", "click", "audio"]),
        // General · Updates
        item(SearchID.updateInterval, .general, SettingsAnchor.updates, String(localized: "General"), String(localized: "Updates"),
             String(localized: "Check for updates"), ["update", "upgrade", "interval", "cadence"]),
        item(SearchID.beta, .general, SettingsAnchor.updates, String(localized: "General"), String(localized: "Updates"),
             String(localized: "Include beta releases"), ["beta", "prerelease", "pre-release", "channel"]),
        // General · Backup
        item(SearchID.exportSettings, .general, SettingsAnchor.backup, String(localized: "General"), String(localized: "Backup"),
             String(localized: "Export settings"), ["export", "backup", "save settings", "share settings"]),
        item(SearchID.importSettings, .general, SettingsAnchor.backup, String(localized: "General"), String(localized: "Backup"),
             String(localized: "Import settings"), ["import", "restore", "load settings"]),

        // Shortcuts · Switching
        item(SearchID.switchApps, .shortcuts, SettingsAnchor.switching, String(localized: "Profiles"), String(localized: "Switcher shortcuts"),
             String(localized: "Switch apps"), ["shortcut", "hotkey", "cmd tab", "command tab", "trigger"]),
        item(SearchID.switchWindows, .shortcuts, SettingsAnchor.switching, String(localized: "Profiles"), String(localized: "Switcher shortcuts"),
             String(localized: "Switch windows"), ["shortcut", "hotkey", "window cycle"]),
        // Apps · Direct activation
        item(SearchID.directActivation, .apps, SettingsAnchor.directActivation, String(localized: "Apps"), String(localized: "Direct activation"),
             String(localized: "Direct activation hotkeys"), ["direct", "hotkey", "shortcut", "activate", "focus app", "jump to app"]),
        item(SearchID.scopedSwitch, .shortcuts, SettingsAnchor.switching, String(localized: "Profiles"), String(localized: "Switcher shortcuts"),
             String(localized: "Scoped shortcuts"), ["scope", "scoped", "all windows", "current app", "minimized", "this space", "filtered switcher"]),
        item(SearchID.panelKeys, .shortcuts, SettingsAnchor.switching, String(localized: "Profiles"), String(localized: "In-panel keys"),
             String(localized: "Action keys while switching"), ["panel keys", "rebind", "close", "minimize", "hide", "quit", "wmhq", "in-panel"]),
        item(SearchID.windowMgmt, .windows, SettingsAnchor.windowArrange, String(localized: "Windows"), String(localized: "Arrange window"),
             String(localized: "Arrange the highlighted window"), ["window management", "tile", "maximize", "center", "snap", "halves", "arrange", "rebind"]),

        // Privacy · Screen sharing
        item(SearchID.hideFromScreenSharing, .privacy, SettingsAnchor.screenSharing, String(localized: "Privacy"), String(localized: "Screen sharing"),
             String(localized: "Don't look at my windows"), ["privacy", "screen sharing", "screen recording", "hide", "zoom", "meet", "teams", "screencapture"]),
        // Privacy · Permissions
        item(SearchID.accessibility, .privacy, SettingsAnchor.permissions, String(localized: "Privacy"), String(localized: "Permissions"),
             String(localized: "Accessibility access"), ["accessibility", "permission", "grant", "trusted"]),
        // Privacy · Recovery
        item(SearchID.restoreShortcuts, .privacy, SettingsAnchor.recovery, String(localized: "Privacy"), String(localized: "Recovery"),
             String(localized: "Restore macOS keyboard shortcuts"), ["restore", "recover", "command tab", "cmd tab", "native", "symbolic hotkey", "stuck", "reset shortcuts"]),

        // Switcher · Display
        item(SearchID.displayMonitor, .switcher, SettingsAnchor.display, String(localized: "Behavior"), String(localized: "Display"),
             String(localized: "Show switcher on"), ["display", "monitor", "screen", "multi monitor", "cursor", "main display", "active space"]),
        // Switcher · Tabs
        item(SearchID.tabDrill, .switcher, SettingsAnchor.tabs, String(localized: "Behavior"), String(localized: "Tabs"),
             String(localized: "Peek tabs with \\"), ["tabs", "tab", "drill", "peek", "backslash", "finder tabs", "browser tabs", "safari", "chrome"]),
        item(SearchID.expandTabs, .switcher, SettingsAnchor.tabs, String(localized: "Behavior"), String(localized: "Tabs"),
             String(localized: "Show tabs as separate entries"), ["tabs", "tab", "expand", "separate", "rows", "per tab", "finder", "terminal", "native tabs"]),
        item(SearchID.expandBrowserTabs, .switcher, SettingsAnchor.tabs, String(localized: "Behavior"), String(localized: "Tabs"),
             String(localized: "Show browser tabs as separate entries"), ["tabs", "tab", "browser", "expand", "separate", "rows", "per tab", "safari", "chrome", "arc", "brave", "edge"]),
        item(SearchID.tabPermissions, .switcher, SettingsAnchor.tabs, String(localized: "Behavior"), String(localized: "Tabs"),
             String(localized: "Browser tab access"), ["tabs", "apple events", "automation", "permission", "browser", "consent"]),
        // Switcher · Search
        item(SearchID.letterHints, .switcher, SettingsAnchor.search, String(localized: "Behavior"), String(localized: "Search"),
             String(localized: "Letter hints"), ["letter hints", "jump", "vim"]),
        item(SearchID.letterChainTimeout, .switcher, SettingsAnchor.search, String(localized: "Behavior"), String(localized: "Search"),
             String(localized: "Letter chain timeout"), ["letter", "chain", "timeout", "reset", "jump", "delay", "prefix", "sequence", "expire"]),
        item(SearchID.fuzzy, .switcher, SettingsAnchor.search, String(localized: "Behavior"), String(localized: "Search"),
             String(localized: "Type-to-filter search"), ["search", "filter", "fuzzy", "type"]),
        item(SearchID.launcher, .switcher, SettingsAnchor.search, String(localized: "Behavior"), String(localized: "Search"),
             String(localized: "Launch apps from search"), ["launcher", "launch", "open app"]),
        item(SearchID.searchMode, .switcher, SettingsAnchor.search, String(localized: "Behavior"), String(localized: "Search"),
             String(localized: "When searching"), ["search mode", "hold", "stay open", "dismiss"]),
        // Switcher · Navigation
        item(SearchID.stayOpen, .switcher, SettingsAnchor.navigation, String(localized: "Behavior"), String(localized: "Navigation"),
             String(localized: "Stay open after releasing the modifier"), ["stay open", "sticky", "release", "modifier", "keep open", "hold"]),
        item(SearchID.shiftTapBack, .switcher, SettingsAnchor.navigation, String(localized: "Behavior"), String(localized: "Navigation"),
             String(localized: "Tap Shift to step backwards"), ["shift", "backwards", "back", "reverse", "tap shift", "cmd shift tab", "windows"]),
        item(SearchID.scroll, .switcher, SettingsAnchor.navigation, String(localized: "Behavior"), String(localized: "Navigation"),
             String(localized: "Switch with mouse scroll"), ["scroll", "wheel", "mouse"]),
        item(SearchID.scrollReverse, .switcher, SettingsAnchor.navigation, String(localized: "Behavior"), String(localized: "Navigation"),
             String(localized: "Reverse scroll direction"), ["scroll", "reverse", "invert"]),
        item(SearchID.clickDismiss, .switcher, SettingsAnchor.navigation, String(localized: "Behavior"), String(localized: "Navigation"),
             String(localized: "Click outside to dismiss"), ["click", "outside", "dismiss", "cancel", "spotlight"]),
        item(SearchID.vimNavigation, .switcher, SettingsAnchor.navigation, String(localized: "Behavior"), String(localized: "Navigation"),
             String(localized: "Vim keys (h j k l)"), ["vim", "hjkl", "h j k l", "keyboard", "arrows", "navigation"]),
        // Switcher · Actions
        item(SearchID.hoverActions, .switcher, SettingsAnchor.actions, String(localized: "Behavior"), String(localized: "Hover actions"),
             String(localized: "Action buttons on hover"), ["hover", "buttons", "close", "minimize", "maximize", "hide", "quit", "actions"]),
        // Apps · App rules
        item(SearchID.exceptions, .apps, SettingsAnchor.appRules, String(localized: "Apps"), String(localized: "App rules"),
             String(localized: "App rules"), ["app rules", "exceptions", "excluded", "exclude", "hide app", "blacklist", "ignore shortcuts", "per-app", "fullscreen", "cmd tab"]),
        // Apps · Pinned
        item(SearchID.pinnedApps, .apps, SettingsAnchor.pinned, String(localized: "Apps"), String(localized: "Pinned"),
             String(localized: "Pinned apps"), ["pinned", "pin", "favorite", "always show"]),

        // Appearance
        item(SearchID.layout, .appearance, SettingsAnchor.appearance, String(localized: "Appearance"), String(localized: "Switcher"),
             String(localized: "Layout"), ["layout", "grid", "list", "preview"]),
        item(SearchID.size, .appearance, SettingsAnchor.appearance, String(localized: "Appearance"), String(localized: "Switcher"),
             String(localized: "Size"), ["size", "panel size", "small", "large"]),
        item(SearchID.gridColumns, .appearance, SettingsAnchor.appearance, String(localized: "Appearance"), String(localized: "Switcher"),
             String(localized: "Grid columns"), ["grid", "columns"]),
        item(SearchID.accent, .appearance, SettingsAnchor.appearance, String(localized: "Appearance"), String(localized: "Switcher"),
             String(localized: "Accent color"), ["accent", "color", "highlight", "tint"]),
        item(SearchID.quickSwitchDelay, .appearance, SettingsAnchor.appearance, String(localized: "Appearance"), String(localized: "Switcher"),
             String(localized: "Quick-switch delay"), ["delay", "reveal", "hold", "quick switch"]),
        item(SearchID.windowTitle, .appearance, SettingsAnchor.appearance, String(localized: "Appearance"), String(localized: "Switcher"),
             String(localized: "Show window title"), ["window title", "title", "label", "name"]),
        item(SearchID.titleAlignment, .appearance, SettingsAnchor.appearance, String(localized: "Appearance"), String(localized: "Switcher"),
             String(localized: "Title alignment"), ["title", "alignment", "align", "left", "center", "centre", "right", "position", "ellipsis"]),
        item(SearchID.boldSelected, .appearance, SettingsAnchor.appearance, String(localized: "Appearance"), String(localized: "Switcher"),
             String(localized: "Bold selected title"), ["bold", "selected", "title", "weight", "highlight", "label"]),
        item(SearchID.applicationNames, .appearance, SettingsAnchor.appearance, String(localized: "Appearance"), String(localized: "Switcher"),
             String(localized: "Show application names"),
             ["application names", "app name", "app names", "name", "label", "icon only", "hide name"]),
        item(SearchID.opacity, .appearance, SettingsAnchor.appearance, String(localized: "Appearance"), String(localized: "Switcher"),
             String(localized: "Panel opacity"), ["opacity", "transparency", "alpha", "translucent"]),
        item(SearchID.cornerRadius, .appearance, SettingsAnchor.appearance, String(localized: "Appearance"), String(localized: "Switcher"),
             String(localized: "Corner radius"), ["corner", "radius", "rounded", "rounding"]),

        // Behavior · Contents
        item(SearchID.showMinimized, .switcher, SettingsAnchor.contents, String(localized: "Behavior"), String(localized: "Contents"),
             String(localized: "Show minimized windows"), ["minimized", "minimize"]),
        item(SearchID.showHidden, .switcher, SettingsAnchor.contents, String(localized: "Behavior"), String(localized: "Contents"),
             String(localized: "Show hidden apps"), ["hidden", "hide"]),
        item(SearchID.showWindowless, .switcher, SettingsAnchor.contents, String(localized: "Behavior"), String(localized: "Contents"),
             String(localized: "Show apps without windows"), ["windowless", "no windows", "background apps"]),
        item(SearchID.applicationsOnly, .switcher, SettingsAnchor.contents, String(localized: "Behavior"), String(localized: "Contents"),
             String(localized: "Applications only"),
             ["applications only", "apps only", "one per app", "per app", "command tab", "classic", "group windows"]),
        item(SearchID.showBadges, .switcher, SettingsAnchor.contents, String(localized: "Behavior"), String(localized: "Contents"),
             String(localized: "Show unread badges"), ["badge", "unread", "dock badge", "count"]),
        item(SearchID.spaceScope, .switcher, SettingsAnchor.contents, String(localized: "Behavior"), String(localized: "Contents"),
             String(localized: "Show windows from"), ["space", "current space", "visible spaces", "desktop", "display", "monitor", "filter"]),
        item(SearchID.sortOrder, .switcher, SettingsAnchor.contents, String(localized: "Behavior"), String(localized: "Contents"),
             String(localized: "Sort order"), ["sort", "order", "mru", "most recent", "alphabetical", "launch order", "windows", "window recency"]),
        item(SearchID.showRecentlyClosed, .switcher, SettingsAnchor.contents, String(localized: "Behavior"), String(localized: "Contents"),
             String(localized: "Show recently closed apps"), ["recently closed", "reopen", "recent"]),
        item(SearchID.recentlyClosedLimit, .switcher, SettingsAnchor.contents, String(localized: "Behavior"), String(localized: "Contents"),
             String(localized: "Recently closed to show"), ["recently closed", "limit", "count"]),

        // Experimental
        item(SearchID.swipe, .experimental, SettingsAnchor.experimental, String(localized: "Experimental"), String(localized: "Experimental"),
             String(localized: "Three-finger swipe"), ["swipe", "trackpad", "gesture", "three finger"]),
        item(SearchID.swipeMode, .experimental, SettingsAnchor.experimental, String(localized: "Experimental"), String(localized: "Experimental"),
             String(localized: "Swipe action"), ["swipe", "spaces", "switch spaces", "open switcher", "gesture action"]),
        item(SearchID.reverseSwipe, .experimental, SettingsAnchor.experimental, String(localized: "Experimental"), String(localized: "Experimental"),
             String(localized: "Reverse swipe direction"), ["swipe", "reverse", "invert"]),
        item(SearchID.switchOnRelease, .experimental, SettingsAnchor.experimental, String(localized: "Experimental"), String(localized: "Experimental"),
             String(localized: "Switch on release"), ["release", "commit", "lift"]),
        item(SearchID.sensitivity, .experimental, SettingsAnchor.experimental, String(localized: "Experimental"), String(localized: "Experimental"),
             String(localized: "Swipe sensitivity"), ["sensitivity", "swipe", "distance"]),
        item(SearchID.instantSpace, .experimental, SettingsAnchor.experimental, String(localized: "Experimental"), String(localized: "Experimental"),
             String(localized: "Switch Spaces without animation"), ["spaces", "space", "animation", "instant", "full screen"]),
        item(SearchID.browserTabMRU, .experimental, SettingsAnchor.experimental, String(localized: "Experimental"), String(localized: "Experimental"),
             String(localized: "Track browser tabs in recency"), ["browser", "tab", "tabs", "recent", "mru", "safari", "chrome"]),
    ]

    private static func item(
        _ id: String,
        _ tab: TabRef,
        _ anchor: String,
        _ tabTitle: String,
        _ sectionTitle: String,
        _ title: String,
        _ keywords: [String]
    ) -> SettingsSearchItem {
        SettingsSearchItem(
            id: id,
            tabID: tab.id,
            sectionAnchor: anchor,
            title: title,
            tabTitle: tabTitle,
            sectionTitle: sectionTitle,
            keywords: keywords
        )
    }

    private enum TabRef {
        case general, shortcuts, windows, switcher, apps, appearance, privacy, experimental

        var id: String {
            switch self {
            case .general: return SettingsTabID.general
            case .shortcuts: return SettingsTabID.shortcuts
            case .windows: return SettingsTabID.windows
            case .switcher: return SettingsTabID.switcher
            case .apps: return SettingsTabID.apps
            case .appearance: return SettingsTabID.appearance
            case .privacy: return SettingsTabID.privacy
            case .experimental: return SettingsTabID.experimental
            }
        }
    }
}
