import AppKit
import BetterSettings

// Central declaration of the settings window: the ordered tabs (with their
// macOS-style gradient icon badges), the searchable catalog, and the factory
// that builds each tab's content controller. Consumed by
// `SettingsWindowPresenter` to drive `BetterSettings.SettingsWindowController`.

/// Tab identifiers shared between the catalog and the content controllers.
enum SettingsTabID {
    static let general = "general"
    static let switcher = "switcher"
    static let appearance = "appearance"
    static let experimental = "experimental"
    static let about = "about"
}

/// Section-anchor identifiers. A content controller registers each section
/// under one of these so search/section navigation can scroll to it.
enum SettingsAnchor {
    // General
    static let startup = "general.startup"
    static let shortcuts = "general.shortcuts"
    static let feedback = "general.feedback"
    static let permissions = "general.permissions"
    static let updates = "general.updates"
    // Switcher
    static let contents = "switcher.contents"
    static let search = "switcher.search"
    static let navigation = "switcher.navigation"
    static let apps = "switcher.apps"
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
    static let accessibility = "general.accessibility"
    static let updateInterval = "general.updateInterval"
    static let beta = "general.beta"
    // Switcher
    static let showMinimized = "switcher.showMinimized"
    static let showHidden = "switcher.showHidden"
    static let showWindowless = "switcher.showWindowless"
    static let showBadges = "switcher.showBadges"
    static let showRecentlyClosed = "switcher.showRecentlyClosed"
    static let recentlyClosedLimit = "switcher.recentlyClosedLimit"
    static let letterHints = "switcher.letterHints"
    static let fuzzy = "switcher.fuzzy"
    static let launcher = "switcher.launcher"
    static let searchMode = "switcher.searchMode"
    static let scroll = "switcher.scroll"
    static let scrollReverse = "switcher.scrollReverse"
    static let excludedApps = "switcher.excludedApps"
    static let pinnedApps = "switcher.pinnedApps"
    // Appearance
    static let layout = "appearance.layout"
    static let size = "appearance.size"
    static let gridColumns = "appearance.gridColumns"
    static let accent = "appearance.accent"
    static let quickSwitchDelay = "appearance.quickSwitchDelay"
    // Experimental
    static let swipe = "experimental.swipe"
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
                case SettingsTabID.switcher:     return SwitcherSettingsViewController()
                case SettingsTabID.appearance:   return AppearanceSettingsViewController()
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
        SettingsTab(
            id: SettingsTabID.general, title: "General", icon: "gearshape.fill",
            iconStyle: style(0x8E8E93, 0x5E5E63, scale: 0.85)
        ),
        // ⌘ glyph — the app *is* a Command-Tab switcher.
        SettingsTab(
            id: SettingsTabID.switcher, title: "Switcher", icon: "command",
            iconStyle: style(0x0A84FF, 0x0A56D6, scale: 0.82, mode: .monochrome)
        ),
        SettingsTab(
            id: SettingsTabID.appearance, title: "Appearance", icon: "paintbrush.fill",
            iconStyle: style(0xFF6CAB, 0xD81E7B, scale: 0.74)
        ),
        SettingsTab(
            id: SettingsTabID.experimental, title: "Experimental", icon: "flask.fill",
            iconStyle: style(0xFFC24B, 0xFF8A00, scale: 0.74)
        ),
        SettingsTab(
            id: SettingsTabID.about, title: "About", icon: "info.circle.fill",
            iconStyle: style(0x6E6CF0, 0x3F3AD6, scale: 0.72)
        ),
    ]

    private static func style(
        _ start: UInt32,
        _ end: UInt32,
        scale: CGFloat,
        mode: SettingsTabIconStyle.SymbolColorMode = .hierarchical
    ) -> SettingsTabIconStyle {
        SettingsTabIconStyle(
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
        // General · Shortcuts
        item(SearchID.switchApps, .general, SettingsAnchor.shortcuts, "General", "Shortcuts",
             "Switch apps", ["shortcut", "hotkey", "cmd tab", "command tab", "trigger"]),
        item(SearchID.switchWindows, .general, SettingsAnchor.shortcuts, "General", "Shortcuts",
             "Switch windows", ["shortcut", "hotkey", "window cycle"]),
        // General · Feedback
        item(SearchID.haptic, .general, SettingsAnchor.feedback, "General", "Feedback",
             "Haptic feedback on switch", ["haptic", "vibration", "force touch", "trackpad"]),
        item(SearchID.sound, .general, SettingsAnchor.feedback, "General", "Feedback",
             "Sound on switch", ["sound", "click", "audio"]),
        // General · Permissions
        item(SearchID.accessibility, .general, SettingsAnchor.permissions, "General", "Permissions",
             "Accessibility access", ["accessibility", "permission", "grant", "trusted"]),
        // General · Updates
        item(SearchID.updateInterval, .general, SettingsAnchor.updates, "General", "Updates",
             "Check for updates", ["update", "upgrade", "interval", "cadence"]),
        item(SearchID.beta, .general, SettingsAnchor.updates, "General", "Updates",
             "Include beta releases", ["beta", "prerelease", "pre-release", "channel"]),

        // Switcher · Contents
        item(SearchID.showMinimized, .switcher, SettingsAnchor.contents, "Switcher", "Contents",
             "Show minimized windows", ["minimized", "minimize"]),
        item(SearchID.showHidden, .switcher, SettingsAnchor.contents, "Switcher", "Contents",
             "Show hidden apps", ["hidden", "hide"]),
        item(SearchID.showWindowless, .switcher, SettingsAnchor.contents, "Switcher", "Contents",
             "Show apps without windows", ["windowless", "no windows", "background apps"]),
        item(SearchID.showBadges, .switcher, SettingsAnchor.contents, "Switcher", "Contents",
             "Show unread badges", ["badge", "unread", "dock badge", "count"]),
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
        // Switcher · Apps
        item(SearchID.excludedApps, .switcher, SettingsAnchor.apps, "Switcher", "Apps",
             "Excluded apps", ["excluded", "exclude", "hide app", "blacklist"]),
        item(SearchID.pinnedApps, .switcher, SettingsAnchor.apps, "Switcher", "Apps",
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

        // Experimental
        item(SearchID.swipe, .experimental, SettingsAnchor.experimental, "Experimental", "Experimental",
             "Open with three-finger swipe", ["swipe", "trackpad", "gesture", "three finger"]),
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
        case general, switcher, appearance, experimental

        var id: String {
            switch self {
            case .general: return SettingsTabID.general
            case .switcher: return SettingsTabID.switcher
            case .appearance: return SettingsTabID.appearance
            case .experimental: return SettingsTabID.experimental
            }
        }
    }
}
