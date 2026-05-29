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
    // Shortcuts
    static let switching = "shortcuts.switching"
    static let directActivation = "shortcuts.directActivation"
    static let scopedSwitch = "shortcuts.scopedSwitch"
    static let panelKeys = "shortcuts.panelKeys"
    // Privacy
    static let screenSharing = "privacy.screenSharing"
    static let permissions = "privacy.permissions"
    // Switcher
    static let contents = "switcher.contents"
    static let search = "switcher.search"
    static let navigation = "switcher.navigation"
    static let actions = "switcher.actions"
    // Apps
    static let appRules = "apps.rules"
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
    static let updateInterval = "general.updateInterval"
    static let beta = "general.beta"
    static let directActivation = "general.directActivation"
    static let scopedSwitch = "shortcuts.scopedSwitch"
    static let panelKeys = "shortcuts.panelKeys"
    static let exportSettings = "general.exportSettings"
    static let importSettings = "general.importSettings"
    // Switcher
    static let showMinimized = "switcher.showMinimized"
    static let showHidden = "switcher.showHidden"
    static let showWindowless = "switcher.showWindowless"
    static let showBadges = "switcher.showBadges"
    static let currentSpaceOnly = "switcher.currentSpaceOnly"
    static let sortOrder = "switcher.sortOrder"
    static let showRecentlyClosed = "switcher.showRecentlyClosed"
    static let recentlyClosedLimit = "switcher.recentlyClosedLimit"
    static let letterHints = "switcher.letterHints"
    static let fuzzy = "switcher.fuzzy"
    static let launcher = "switcher.launcher"
    static let searchMode = "switcher.searchMode"
    static let scroll = "switcher.scroll"
    static let scrollReverse = "switcher.scrollReverse"
    static let clickDismiss = "switcher.clickDismiss"
    static let hoverActions = "switcher.hoverActions"
    static let exceptions = "switcher.exceptions"
    static let pinnedApps = "switcher.pinnedApps"
    // Appearance
    static let layout = "appearance.layout"
    static let size = "appearance.size"
    static let gridColumns = "appearance.gridColumns"
    static let accent = "appearance.accent"
    static let quickSwitchDelay = "appearance.quickSwitchDelay"
    static let windowTitle = "appearance.windowTitle"
    static let opacity = "appearance.opacity"
    static let cornerRadius = "appearance.cornerRadius"
    // Experimental
    static let swipe = "experimental.swipe"
    static let swipeMode = "experimental.swipeMode"
    static let reverseSwipe = "experimental.reverseSwipe"
    static let switchOnRelease = "experimental.switchOnRelease"
    static let sensitivity = "experimental.sensitivity"
    static let instantSpace = "experimental.instantSpace"
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
                case SettingsTabID.switcher:     return SwitcherSettingsViewController()
                case SettingsTabID.apps:         return AppsSettingsViewController()
                case SettingsTabID.appearance:   return AppearanceSettingsViewController()
                case SettingsTabID.privacy:      return PrivacySettingsViewController()
                case SettingsTabID.experimental: return ExperimentalSettingsViewController()
                default:                         return AboutSettingsViewController()
                }
            },
            searchPlaceholder: "Search",
            showDetailsDefaultsKey: "BetterCmdTab.showSettingsDetails"
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
        // ⌘ glyph — the Shortcuts tab is where you bind the Command-Tab triggers.
        SettingsTab(
            id: SettingsTabID.shortcuts, title: String(localized: "Shortcuts"), icon: "command",
            iconStyle: style(0x40BCFF, 0x0060FF, scale: 0.9)
        ),
        // Stacked windows — the switcher cycles through your open windows/apps.
        SettingsTab(
            id: SettingsTabID.switcher, title: String(localized: "Switcher"), icon: "rectangle.stack.fill",
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
        item(SearchID.launchAtLogin, .general, SettingsAnchor.startup, "General", "Startup",
             "Launch at login", ["startup", "boot", "open at login", "autostart"]),
        item(SearchID.hideMenuBar, .general, SettingsAnchor.startup, "General", "Startup",
             "Hide menu bar icon", ["menu bar", "status item", "hide icon"]),
        // General · Feedback
        item(SearchID.haptic, .general, SettingsAnchor.feedback, "General", "Feedback",
             "Haptic feedback on switch", ["haptic", "vibration", "force touch", "trackpad"]),
        item(SearchID.sound, .general, SettingsAnchor.feedback, "General", "Feedback",
             "Sound on switch", ["sound", "click", "audio"]),
        // General · Updates
        item(SearchID.updateInterval, .general, SettingsAnchor.updates, "General", "Updates",
             "Check for updates", ["update", "upgrade", "interval", "cadence"]),
        item(SearchID.beta, .general, SettingsAnchor.updates, "General", "Updates",
             "Include beta releases", ["beta", "prerelease", "pre-release", "channel"]),
        // General · Backup
        item(SearchID.exportSettings, .general, SettingsAnchor.backup, "General", "Backup",
             "Export settings", ["export", "backup", "save settings", "share settings"]),
        item(SearchID.importSettings, .general, SettingsAnchor.backup, "General", "Backup",
             "Import settings", ["import", "restore", "load settings"]),

        // Shortcuts · Switching
        item(SearchID.switchApps, .shortcuts, SettingsAnchor.switching, "Shortcuts", "Switching",
             "Switch apps", ["shortcut", "hotkey", "cmd tab", "command tab", "trigger"]),
        item(SearchID.switchWindows, .shortcuts, SettingsAnchor.switching, "Shortcuts", "Switching",
             "Switch windows", ["shortcut", "hotkey", "window cycle"]),
        // Shortcuts · Direct activation
        item(SearchID.directActivation, .shortcuts, SettingsAnchor.directActivation, "Shortcuts", "Direct activation",
             "Direct activation hotkeys", ["direct", "hotkey", "shortcut", "activate", "focus app", "jump to app"]),
        item(SearchID.scopedSwitch, .shortcuts, SettingsAnchor.scopedSwitch, "Shortcuts", "Scoped shortcuts",
             "Scoped shortcuts", ["scope", "scoped", "all windows", "current app", "minimized", "this space", "filtered switcher"]),
        item(SearchID.panelKeys, .shortcuts, SettingsAnchor.panelKeys, "Shortcuts", "In-panel keys",
             "Action keys while switching", ["panel keys", "rebind", "close", "minimize", "hide", "quit", "wmhq", "in-panel"]),

        // Privacy · Screen sharing
        item(SearchID.hideFromScreenSharing, .privacy, SettingsAnchor.screenSharing, "Privacy", "Screen sharing",
             "Don't look at my windows", ["privacy", "screen sharing", "screen recording", "hide", "zoom", "meet", "teams", "screencapture"]),
        // Privacy · Permissions
        item(SearchID.accessibility, .privacy, SettingsAnchor.permissions, "Privacy", "Permissions",
             "Accessibility access", ["accessibility", "permission", "grant", "trusted"]),

        // Switcher · Contents
        item(SearchID.showMinimized, .switcher, SettingsAnchor.contents, "Switcher", "Contents",
             "Show minimized windows", ["minimized", "minimize"]),
        item(SearchID.showHidden, .switcher, SettingsAnchor.contents, "Switcher", "Contents",
             "Show hidden apps", ["hidden", "hide"]),
        item(SearchID.showWindowless, .switcher, SettingsAnchor.contents, "Switcher", "Contents",
             "Show apps without windows", ["windowless", "no windows", "background apps"]),
        item(SearchID.showBadges, .switcher, SettingsAnchor.contents, "Switcher", "Contents",
             "Show unread badges", ["badge", "unread", "dock badge", "count"]),
        item(SearchID.currentSpaceOnly, .switcher, SettingsAnchor.contents, "Switcher", "Contents",
             "Only current Space", ["space", "current space", "desktop", "filter"]),
        item(SearchID.sortOrder, .switcher, SettingsAnchor.contents, "Switcher", "Contents",
             "Sort order", ["sort", "order", "mru", "most recent", "alphabetical", "launch order"]),
        item(SearchID.showRecentlyClosed, .switcher, SettingsAnchor.contents, "Switcher", "Contents",
             "Show recently closed apps", ["recently closed", "reopen", "recent"]),
        item(SearchID.recentlyClosedLimit, .switcher, SettingsAnchor.contents, "Switcher", "Contents",
             "Recently closed to show", ["recently closed", "limit", "count"]),
        // Switcher · Search
        item(SearchID.letterHints, .switcher, SettingsAnchor.search, "Switcher", "Search",
             "Letter hints", ["letter hints", "jump", "vim"]),
        item(SearchID.fuzzy, .switcher, SettingsAnchor.search, "Switcher", "Search",
             "Type-to-filter search", ["search", "filter", "fuzzy", "type"]),
        item(SearchID.launcher, .switcher, SettingsAnchor.search, "Switcher", "Search",
             "Launch apps from search", ["launcher", "launch", "open app"]),
        item(SearchID.searchMode, .switcher, SettingsAnchor.search, "Switcher", "Search",
             "When searching", ["search mode", "hold", "stay open", "dismiss"]),
        // Switcher · Navigation
        item(SearchID.scroll, .switcher, SettingsAnchor.navigation, "Switcher", "Navigation",
             "Switch with mouse scroll", ["scroll", "wheel", "mouse"]),
        item(SearchID.scrollReverse, .switcher, SettingsAnchor.navigation, "Switcher", "Navigation",
             "Reverse scroll direction", ["scroll", "reverse", "invert"]),
        item(SearchID.clickDismiss, .switcher, SettingsAnchor.navigation, "Switcher", "Navigation",
             "Click outside to dismiss", ["click", "outside", "dismiss", "cancel", "spotlight"]),
        // Switcher · Actions
        item(SearchID.hoverActions, .switcher, SettingsAnchor.actions, "Switcher", "Hover actions",
             "Action buttons on hover", ["hover", "buttons", "close", "minimize", "maximize", "hide", "quit", "actions"]),
        // Apps · App rules
        item(SearchID.exceptions, .apps, SettingsAnchor.appRules, "Apps", "App rules",
             "App rules", ["app rules", "exceptions", "excluded", "exclude", "hide app", "blacklist", "ignore shortcuts", "per-app", "fullscreen", "cmd tab"]),
        // Apps · Pinned
        item(SearchID.pinnedApps, .apps, SettingsAnchor.pinned, "Apps", "Pinned",
             "Pinned apps", ["pinned", "pin", "favorite", "always show"]),

        // Appearance
        item(SearchID.layout, .appearance, SettingsAnchor.appearance, "Appearance", "Switcher",
             "Layout", ["layout", "grid", "list", "preview"]),
        item(SearchID.size, .appearance, SettingsAnchor.appearance, "Appearance", "Switcher",
             "Size", ["size", "panel size", "small", "large"]),
        item(SearchID.gridColumns, .appearance, SettingsAnchor.appearance, "Appearance", "Switcher",
             "Grid columns", ["grid", "columns"]),
        item(SearchID.accent, .appearance, SettingsAnchor.appearance, "Appearance", "Switcher",
             "Accent color", ["accent", "color", "highlight", "tint"]),
        item(SearchID.quickSwitchDelay, .appearance, SettingsAnchor.appearance, "Appearance", "Switcher",
             "Quick-switch delay", ["delay", "reveal", "hold", "quick switch"]),
        item(SearchID.windowTitle, .appearance, SettingsAnchor.appearance, "Appearance", "Switcher",
             "Show window title", ["window title", "title", "label", "name"]),
        item(SearchID.opacity, .appearance, SettingsAnchor.appearance, "Appearance", "Switcher",
             "Panel opacity", ["opacity", "transparency", "alpha", "translucent"]),
        item(SearchID.cornerRadius, .appearance, SettingsAnchor.appearance, "Appearance", "Switcher",
             "Corner radius", ["corner", "radius", "rounded", "rounding"]),

        // Experimental
        item(SearchID.swipe, .experimental, SettingsAnchor.experimental, "Experimental", "Experimental",
             "Three-finger swipe", ["swipe", "trackpad", "gesture", "three finger"]),
        item(SearchID.swipeMode, .experimental, SettingsAnchor.experimental, "Experimental", "Experimental",
             "Swipe action", ["swipe", "spaces", "switch spaces", "open switcher", "gesture action"]),
        item(SearchID.reverseSwipe, .experimental, SettingsAnchor.experimental, "Experimental", "Experimental",
             "Reverse swipe direction", ["swipe", "reverse", "invert"]),
        item(SearchID.switchOnRelease, .experimental, SettingsAnchor.experimental, "Experimental", "Experimental",
             "Switch on release", ["release", "commit", "lift"]),
        item(SearchID.sensitivity, .experimental, SettingsAnchor.experimental, "Experimental", "Experimental",
             "Swipe sensitivity", ["sensitivity", "swipe", "distance"]),
        item(SearchID.instantSpace, .experimental, SettingsAnchor.experimental, "Experimental", "Experimental",
             "Switch Spaces without animation", ["spaces", "space", "animation", "instant", "full screen"]),
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
        case general, shortcuts, switcher, apps, appearance, privacy, experimental

        var id: String {
            switch self {
            case .general: return SettingsTabID.general
            case .shortcuts: return SettingsTabID.shortcuts
            case .switcher: return SettingsTabID.switcher
            case .apps: return SettingsTabID.apps
            case .appearance: return SettingsTabID.appearance
            case .privacy: return SettingsTabID.privacy
            case .experimental: return SettingsTabID.experimental
            }
        }
    }
}
