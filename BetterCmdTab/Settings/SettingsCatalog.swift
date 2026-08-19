import AppKit
import BetterSettings

// Central declaration of the settings window: the ordered tabs (with their
// macOS-style gradient icon badges), the searchable catalog, and the factory
// that builds each tab's content controller. Consumed by
// `SettingsWindowPresenter` to drive `BetterSettings.SettingsWindowController`.

/// Tab identifiers shared between the catalog and the content controllers.
/// Nothing persists a tab id (the window always opens on the first tab unless
/// a caller passes one), so these are free to change with the layout.
enum SettingsTabID {
    static let general = "general"
    static let profiles = "profiles"
    static let shortcuts = "shortcuts"
    static let switcher = "switcher"
    static let controls = "controls"
    static let tabs = "tabs"
    static let apps = "apps"
    static let appearance = "appearance"
    static let privacy = "privacy"
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
    static let recovery = "general.recovery"
    // Profiles
    static let switching = "profiles.switching"
    // Shortcuts — every global hotkey that isn't a switcher trigger.
    static let directActivation = "shortcuts.directActivation"
    static let windowArrange = "shortcuts.arrange"
    static let windowAll = "shortcuts.all"
    static let swipe = "shortcuts.swipe"
    // Switcher — what the panel lists.
    static let contents = "switcher.contents"
    static let timing = "switcher.timing"
    // Controls — how you drive the panel.
    static let keyboard = "controls.keyboard"
    static let letterJump = "controls.letterJump"
    static let search = "controls.search"
    static let mouse = "controls.mouse"
    static let hoverActions = "controls.hoverActions"
    // Tabs
    static let nativeTabs = "tabs.native"
    static let browserTabs = "tabs.browser"
    // Apps
    static let appRules = "apps.rules"
    static let pinned = "apps.pinned"
    // Appearance
    static let appearanceLayout = "appearance.layoutSection"
    static let appearanceLabels = "appearance.labels"
    static let appearancePanel = "appearance.panel"
    // Privacy
    static let permissions = "privacy.permissions"
    static let screenSharing = "privacy.screenSharing"
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
    static let fullDiskAccess = "privacy.fullDiskAccess"
    static let restoreShortcuts = "privacy.restoreShortcuts"
    static let updateInterval = "general.updateInterval"
    static let beta = "general.beta"
    static let exportSettings = "general.exportSettings"
    static let importSettings = "general.importSettings"
    static let configFile = "general.configFile"
    // Profiles
    static let scopedSwitch = "shortcuts.scopedSwitch"
    static let panelKeys = "shortcuts.panelKeys"
    // Shortcuts
    static let directActivation = "general.directActivation"
    static let windowMgmt = "shortcuts.windowMgmt"
    static let cycleTileWidths = "shortcuts.cycleTileWidths"
    static let hideAllWindows = "shortcuts.hideAllWindows"
    static let showAllWindows = "shortcuts.showAllWindows"
    static let keepAppsVisible = "shortcuts.keepAppsVisible"
    static let swipe = "experimental.swipe"
    static let swipeMode = "experimental.swipeMode"
    static let reverseSwipe = "experimental.reverseSwipe"
    static let switchOnRelease = "experimental.switchOnRelease"
    static let sensitivity = "experimental.sensitivity"
    // Switcher
    static let showMinimized = "switcher.showMinimized"
    static let showHidden = "switcher.showHidden"
    static let sinkHiddenApps = "switcher.sinkHiddenApps"
    static let sinkMinimizedWindows = "switcher.sinkMinimizedWindows"
    static let showWindowless = "switcher.showWindowless"
    static let applicationsOnly = "switcher.applicationsOnly"
    static let showBadges = "switcher.showBadges"
    static let spaceScope = "switcher.spaceScope"
    static let instantSpace = "switcher.instantSpace"
    static let sortOrder = "switcher.sortOrder"
    static let showRecentlyClosed = "switcher.showRecentlyClosed"
    static let recentlyClosedLimit = "switcher.recentlyClosedLimit"
    static let windowDrill = "switcher.windowDrill"
    static let quickSwitchDelay = "appearance.quickSwitchDelay"
    static let titleRefreshInterval = "switcher.titleRefreshInterval"
    // Controls
    static let letterHints = "switcher.letterHints"
    static let letterChainTimeout = "switcher.letterChainTimeout"
    static let fuzzy = "switcher.fuzzy"
    static let rankResults = "switcher.rankResults"
    static let launcher = "switcher.launcher"
    static let searchMode = "switcher.searchMode"
    static let shiftTapBack = "switcher.shiftTapBack"
    static let backtickReverse = "switcher.backtickReverse"
    static let stayOpen = "switcher.stayOpen"
    static let stayOpenQuickTap = "switcher.stayOpenQuickTap"
    static let vimNavigation = "switcher.vimNavigation"
    static let scroll = "switcher.scroll"
    static let scrollReverse = "switcher.scrollReverse"
    static let clickDismiss = "switcher.clickDismiss"
    static let selectOnHover = "controls.selectOnHover"
    static let selectOnClick = "controls.selectOnClick"
    static let hoverActions = "switcher.hoverActions"
    // Tabs
    static let tabDrill = "switcher.tabDrill"
    static let expandTabs = "switcher.expandTabs"
    static let expandBrowserTabs = "switcher.expandBrowserTabs"
    static let browserTabLimit = "switcher.browserTabLimit"
    static let browserIconOnTabs = "switcher.browserIconOnTabs"
    static let browserTabMRU = "switcher.browserTabMRU"
    static let browserTabPreviews = "appearance.browserTabPreviews"
    static let searchExpandsBrowserTabs = "switcher.searchExpandsBrowserTabs"
    // Apps
    static let exceptions = "switcher.exceptions"
    static let pinnedApps = "switcher.pinnedApps"
    // Appearance
    static let displayMonitor = "switcher.displayMonitor"
    static let layout = "appearance.layout"
    static let size = "appearance.size"
    static let gridColumns = "appearance.gridColumns"
    static let selectionColor = "appearance.selectionColor"
    static let gridSingleRow = "appearance.gridSingleRow"
    static let listMaxWidth = "appearance.listMaxWidth"
    static let windowTitle = "appearance.windowTitle"
    static let titleAlignment = "appearance.titleAlignment"
    static let titleTruncation = "appearance.titleTruncation"
    static let textSize = "appearance.textSize"
    static let fontFace = "appearance.fontFace"
    static let boldSelected = "appearance.boldSelected"
    static let applicationNames = "switcher.applicationNames"
    static let windowStatusIcons = "switcher.windowStatusIcons"
    static let theme = "appearance.theme"
    static let opacity = "appearance.opacity"
    static let cornerRadius = "appearance.cornerRadius"
    static let animations = "appearance.animations"
    static let livePreviews = "appearance.livePreviews"
    static let preview = "appearance.preview"
    // Privacy
    static let tabPermissions = "switcher.tabPermissions"
}

@MainActor
enum SettingsCatalog {

    /// Shown at the top of Switcher, Controls and Appearance: those three panes
    /// hold the switcher's global defaults and nothing else says so (#74). Only
    /// some rows have a matching `ShortcutOverride` field, hence "many".
    /// The subtitle carries only the override pointer — the title already says
    /// what the scope is, and a row subtitle that wraps to a second line gets
    /// its tail clipped by BetterSettings' height measurement.
    static let globalDefaultNoteTitle = String(localized: "Defaults for every shortcut")
    static let globalDefaultNoteSubtitle = String(localized: "Many of these can be overridden per shortcut under Profiles.")

    static func makeConfiguration() -> SettingsConfiguration {
        SettingsConfiguration(
            tabs: tabs,
            searchItems: searchItems,
            contentProvider: { tab, _ in
                switch tab.id {
                case SettingsTabID.general:    return GeneralSettingsViewController()
                case SettingsTabID.profiles:   return ProfilesSettingsViewController()
                case SettingsTabID.shortcuts:  return ShortcutsSettingsViewController()
                case SettingsTabID.switcher:   return SwitcherPanesViewController(pane: .switcher)
                case SettingsTabID.controls:   return SwitcherPanesViewController(pane: .controls)
                case SettingsTabID.tabs:       return SwitcherPanesViewController(pane: .tabs)
                case SettingsTabID.apps:       return AppsSettingsViewController()
                case SettingsTabID.appearance: return AppearanceSettingsViewController()
                case SettingsTabID.privacy:    return PrivacySettingsViewController()
                default:                       return AboutSettingsViewController()
                }
            },
            searchPlaceholder: String(localized: "Search"),
            showDetailsDefaultsKey: "BetterCmdTab.showSettingsDetails",
            // Keep the active tab + 1 previous live and drop to active-only when
            // the settings window loses key. Inactive tab trees are freed and
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
        // per-shortcut option overrides and in-panel keys.
        SettingsTab(
            id: SettingsTabID.profiles, title: String(localized: "Profiles"), icon: "slider.horizontal.3",
            iconStyle: style(0x40BCFF, 0x0060FF, scale: 0.9)
        ),
        // Shortcuts — every global hotkey that does not open the switcher:
        // direct activation, window arranging, hide/show all, trackpad swipe.
        SettingsTab(
            id: SettingsTabID.shortcuts, title: String(localized: "Shortcuts"), icon: "command",
            iconStyle: style(0x5AC8FA, 0x0A84C4, scale: 0.9)
        ),
        // Switcher — what the panel lists, and the two timing knobs.
        SettingsTab(
            id: SettingsTabID.switcher, title: String(localized: "Switcher"), icon: "rectangle.stack.fill",
            iconStyle: style(0xB272FF, 0x6228FF, scale: 0.95)
        ),
        // Controls — how you drive the open panel: keys, letter jump, search,
        // mouse, hover actions.
        SettingsTab(
            id: SettingsTabID.controls, title: String(localized: "Controls"), icon: "hand.tap.fill",
            iconStyle: style(0x4ADEDE, 0x00A0A8, scale: 0.85)
        ),
        // Tabs — native window tabs and browser tabs, including their previews.
        SettingsTab(
            id: SettingsTabID.tabs, title: String(localized: "Tabs"), icon: "rectangle.split.3x1.fill",
            iconStyle: style(0xFFA846, 0xFF6F00, scale: 0.9)
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
             String(localized: "Sound on switch"), ["sound", "click", "audio", "system sound", "custom sound", "audio file"]),
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
        item(SearchID.configFile, .general, SettingsAnchor.backup, String(localized: "General"), String(localized: "Backup"),
             String(localized: "Configuration file"), ["config", "config file", "dotfiles", "json", "xdg", "sync", "config.json"]),
        // General · Recovery
        item(SearchID.restoreShortcuts, .general, SettingsAnchor.recovery, String(localized: "General"), String(localized: "Recovery"),
             String(localized: "Restore macOS keyboard shortcuts"), ["restore", "recover", "command tab", "cmd tab", "native", "symbolic hotkey", "stuck", "reset shortcuts"]),

        // Profiles · Switcher shortcuts
        item(SearchID.switchApps, .profiles, SettingsAnchor.switching, String(localized: "Profiles"), String(localized: "Switcher shortcuts"),
             String(localized: "Switch apps"), ["shortcut", "hotkey", "cmd tab", "command tab", "trigger"]),
        item(SearchID.switchWindows, .profiles, SettingsAnchor.switching, String(localized: "Profiles"), String(localized: "Switcher shortcuts"),
             String(localized: "Switch windows"), ["shortcut", "hotkey", "window cycle"]),
        item(SearchID.scopedSwitch, .profiles, SettingsAnchor.switching, String(localized: "Profiles"), String(localized: "Switcher shortcuts"),
             String(localized: "Scoped shortcuts"), ["scope", "scoped", "all windows", "current app", "minimized", "this space", "filtered switcher"]),
        item(SearchID.panelKeys, .profiles, SettingsAnchor.switching, String(localized: "Profiles"), String(localized: "In-panel keys"),
             String(localized: "Action keys while switching"),
             ["panel keys", "rebind", "close", "minimize", "hide", "quit", "wmhq", "in-panel", "search key", "slash", "tab drill", "peek tabs", "backslash"]),

        // Shortcuts · Direct activation
        item(SearchID.directActivation, .shortcuts, SettingsAnchor.directActivation, String(localized: "Shortcuts"), String(localized: "Direct activation"),
             String(localized: "Jump straight to an app"),
             ["direct activation", "hotkey", "shortcut", "activate", "focus app", "jump to app"]),
        // Shortcuts · Arrange window
        item(SearchID.windowMgmt, .shortcuts, SettingsAnchor.windowArrange, String(localized: "Shortcuts"), String(localized: "Arrange window"),
             String(localized: "Arrange the focused window"),
             ["window management", "tile", "maximize", "center", "snap", "halves", "arrange", "rebind", "highlighted"]),
        item(SearchID.cycleTileWidths, .shortcuts, SettingsAnchor.windowArrange, String(localized: "Shortcuts"), String(localized: "Arrange window"),
             String(localized: "Cycle tile widths"), ["tile", "cycle", "width", "halves", "thirds", "two thirds", "resize"]),
        // Shortcuts · All windows
        item(SearchID.hideAllWindows, .shortcuts, SettingsAnchor.windowAll, String(localized: "Shortcuts"), String(localized: "All windows"),
             String(localized: "Hide all windows"), ["hide all", "desktop", "show desktop", "clear screen", "minimize all"]),
        item(SearchID.showAllWindows, .shortcuts, SettingsAnchor.windowAll, String(localized: "Shortcuts"), String(localized: "All windows"),
             String(localized: "Show all windows"), ["show all", "unhide", "restore", "bring back"]),
        item(SearchID.keepAppsVisible, .shortcuts, SettingsAnchor.windowAll, String(localized: "Shortcuts"), String(localized: "All windows"),
             String(localized: "Keep apps visible"), ["exclude", "exception", "keep visible", "hide all", "finder"]),
        // Shortcuts · Trackpad swipe
        item(SearchID.swipe, .shortcuts, SettingsAnchor.swipe, String(localized: "Shortcuts"), String(localized: "Trackpad swipe"),
             String(localized: "Three-finger swipe"), ["swipe", "trackpad", "gesture", "three finger", "experimental"]),
        item(SearchID.swipeMode, .shortcuts, SettingsAnchor.swipe, String(localized: "Shortcuts"), String(localized: "Trackpad swipe"),
             String(localized: "Swipe action"), ["swipe", "spaces", "switch spaces", "open switcher", "gesture action"]),
        item(SearchID.reverseSwipe, .shortcuts, SettingsAnchor.swipe, String(localized: "Shortcuts"), String(localized: "Trackpad swipe"),
             String(localized: "Reverse swipe direction"), ["swipe", "reverse", "invert"]),
        item(SearchID.switchOnRelease, .shortcuts, SettingsAnchor.swipe, String(localized: "Shortcuts"), String(localized: "Trackpad swipe"),
             String(localized: "Switch on release"), ["release", "commit", "lift"]),
        item(SearchID.sensitivity, .shortcuts, SettingsAnchor.swipe, String(localized: "Shortcuts"), String(localized: "Trackpad swipe"),
             String(localized: "Swipe sensitivity"), ["sensitivity", "swipe", "distance"]),

        // Switcher · Contents
        item(SearchID.showMinimized, .switcher, SettingsAnchor.contents, String(localized: "Switcher"), String(localized: "Contents"),
             String(localized: "Show minimized windows"), ["minimized", "minimize"]),
        item(SearchID.showHidden, .switcher, SettingsAnchor.contents, String(localized: "Switcher"), String(localized: "Contents"),
             String(localized: "Show hidden apps"), ["hidden", "hide"]),
        item(SearchID.sinkHiddenApps, .switcher, SettingsAnchor.contents, String(localized: "Switcher"), String(localized: "Contents"),
             String(localized: "Move hidden apps to the bottom"), ["hidden", "hide", "sort", "bottom", "position", "order"]),
        item(SearchID.sinkMinimizedWindows, .switcher, SettingsAnchor.contents, String(localized: "Switcher"), String(localized: "Contents"),
             String(localized: "Move minimized windows to the bottom"),
             ["minimized", "minimize", "sort", "bottom", "position", "order"]),
        item(SearchID.showWindowless, .switcher, SettingsAnchor.contents, String(localized: "Switcher"), String(localized: "Contents"),
             String(localized: "Show apps without windows"), ["windowless", "no windows", "background apps"]),
        item(SearchID.applicationsOnly, .switcher, SettingsAnchor.contents, String(localized: "Switcher"), String(localized: "Contents"),
             String(localized: "Applications only"),
             ["applications only", "apps only", "one per app", "per app", "command tab", "classic", "group windows"]),
        item(SearchID.windowDrill, .switcher, SettingsAnchor.contents, String(localized: "Switcher"), String(localized: "Contents"),
             String(localized: "Peek windows with ↓"),
             ["windows", "window", "drill", "peek", "down arrow", "applications only", "app windows", "expose"]),
        item(SearchID.showBadges, .switcher, SettingsAnchor.contents, String(localized: "Switcher"), String(localized: "Contents"),
             String(localized: "Show unread badges"), ["badge", "unread", "dock badge", "count"]),
        item(SearchID.spaceScope, .switcher, SettingsAnchor.contents, String(localized: "Switcher"), String(localized: "Contents"),
             String(localized: "Show windows from"), ["space", "current space", "visible spaces", "desktop", "display", "monitor", "filter"]),
        item(SearchID.instantSpace, .switcher, SettingsAnchor.contents, String(localized: "Switcher"), String(localized: "Contents"),
             String(localized: "Switch Spaces without animation"), ["spaces", "space", "animation", "instant", "full screen"]),
        item(SearchID.sortOrder, .switcher, SettingsAnchor.contents, String(localized: "Switcher"), String(localized: "Contents"),
             String(localized: "Sort order"), ["sort", "order", "mru", "most recent", "alphabetical", "launch order", "windows", "window recency"]),
        item(SearchID.showRecentlyClosed, .switcher, SettingsAnchor.contents, String(localized: "Switcher"), String(localized: "Contents"),
             String(localized: "Show recently closed apps"), ["recently closed", "reopen", "recent"]),
        item(SearchID.recentlyClosedLimit, .switcher, SettingsAnchor.contents, String(localized: "Switcher"), String(localized: "Contents"),
             String(localized: "Recently closed to show"), ["recently closed", "limit", "count"]),
        // Switcher · Timing
        item(SearchID.quickSwitchDelay, .switcher, SettingsAnchor.timing, String(localized: "Switcher"), String(localized: "Timing"),
             String(localized: "Quick-switch delay"), ["delay", "reveal", "hold", "quick switch"]),
        item(SearchID.titleRefreshInterval, .switcher, SettingsAnchor.timing, String(localized: "Switcher"), String(localized: "Timing"),
             String(localized: "Title refresh delay"), ["title", "refresh", "update", "interval", "window title", "live titles", "debounce"]),

        // Controls · Keyboard
        item(SearchID.stayOpen, .controls, SettingsAnchor.keyboard, String(localized: "Controls"), String(localized: "Keyboard"),
             String(localized: "Stay open after releasing the modifier"), ["stay open", "sticky", "release", "modifier", "keep open", "hold"]),
        item(SearchID.stayOpenQuickTap, .controls, SettingsAnchor.keyboard, String(localized: "Controls"), String(localized: "Keyboard"),
             String(localized: "Also stay open after a quick tap"), ["quick tap", "mouse", "mouse button", "gesture", "stay open", "sticky", "tap"]),
        item(SearchID.shiftTapBack, .controls, SettingsAnchor.keyboard, String(localized: "Controls"), String(localized: "Keyboard"),
             String(localized: "Tap Shift to step backwards"), ["shift", "backwards", "back", "reverse", "tap shift", "cmd shift tab", "windows"]),
        item(SearchID.backtickReverse, .controls, SettingsAnchor.keyboard, String(localized: "Controls"), String(localized: "Keyboard"),
             String(localized: "Use window-switch shortcut to step backwards"), ["backtick", "tilde", "cmd backtick", "command backtick", "window shortcut", "reverse", "backwards", "native"]),
        item(SearchID.vimNavigation, .controls, SettingsAnchor.keyboard, String(localized: "Controls"), String(localized: "Keyboard"),
             String(localized: "Vim keys (h j k l)"), ["vim", "hjkl", "h j k l", "keyboard", "arrows", "navigation"]),
        // Controls · Letter jump
        item(SearchID.letterHints, .controls, SettingsAnchor.letterJump, String(localized: "Controls"), String(localized: "Letter jump"),
             String(localized: "Letter hints"), ["letter hints", "jump", "vim", "quick jump"]),
        item(SearchID.letterChainTimeout, .controls, SettingsAnchor.letterJump, String(localized: "Controls"), String(localized: "Letter jump"),
             String(localized: "Letter chain timeout"), ["letter", "chain", "timeout", "reset", "jump", "delay", "prefix", "sequence", "expire"]),
        // Controls · Search
        item(SearchID.fuzzy, .controls, SettingsAnchor.search, String(localized: "Controls"), String(localized: "Search"),
             String(localized: "Type-to-filter search"), ["search", "filter", "fuzzy", "type"]),
        item(SearchID.rankResults, .controls, SettingsAnchor.search, String(localized: "Controls"), String(localized: "Search"),
             String(localized: "Rank search"), ["fuzzy", "search", "ranking", "rank", "best match", "sort results", "relevance"]),
        item(SearchID.launcher, .controls, SettingsAnchor.search, String(localized: "Controls"), String(localized: "Search"),
             String(localized: "Launch apps from search"), ["launcher", "launch", "open app"]),
        item(SearchID.searchMode, .controls, SettingsAnchor.search, String(localized: "Controls"), String(localized: "Search"),
             String(localized: "When searching"), ["search mode", "hold", "stay open", "dismiss"]),
        // Controls · Mouse
        item(SearchID.scroll, .controls, SettingsAnchor.mouse, String(localized: "Controls"), String(localized: "Mouse"),
             String(localized: "Switch with mouse scroll"), ["scroll", "wheel", "mouse"]),
        item(SearchID.scrollReverse, .controls, SettingsAnchor.mouse, String(localized: "Controls"), String(localized: "Mouse"),
             String(localized: "Reverse scroll direction"), ["scroll", "reverse", "invert"]),
        item(SearchID.clickDismiss, .controls, SettingsAnchor.mouse, String(localized: "Controls"), String(localized: "Mouse"),
             String(localized: "Click outside to dismiss"), ["click", "outside", "dismiss", "cancel", "spotlight"]),
        item(SearchID.selectOnHover, .controls, SettingsAnchor.mouse, String(localized: "Controls"), String(localized: "Mouse"),
             String(localized: "Select window on hover"), ["hover", "pointer", "mouse", "selection", "highlight"]),
        item(SearchID.selectOnClick, .controls, SettingsAnchor.mouse, String(localized: "Controls"), String(localized: "Mouse"),
             String(localized: "Select window on click"), ["click", "mouse", "pick", "selection"]),
        // Controls · Hover actions
        item(SearchID.hoverActions, .controls, SettingsAnchor.hoverActions, String(localized: "Controls"), String(localized: "Hover actions"),
             String(localized: "Action buttons on hover"), ["hover", "buttons", "close", "minimize", "maximize", "zoom", "hide", "quit", "force quit", "actions"]),

        // Tabs · Native tabs
        item(SearchID.tabDrill, .tabs, SettingsAnchor.nativeTabs, String(localized: "Tabs"), String(localized: "Native tabs"),
             String(localized: "Peek tabs"), ["tabs", "tab", "drill", "peek", "backslash", "finder tabs", "browser tabs", "safari", "chrome"]),
        item(SearchID.expandTabs, .tabs, SettingsAnchor.nativeTabs, String(localized: "Tabs"), String(localized: "Native tabs"),
             String(localized: "Show tabs as separate entries"), ["tabs", "tab", "expand", "separate", "rows", "per tab", "finder", "terminal", "native tabs"]),
        // Tabs · Browser tabs
        item(SearchID.expandBrowserTabs, .tabs, SettingsAnchor.browserTabs, String(localized: "Tabs"), String(localized: "Browser tabs"),
             String(localized: "Show browser tabs as separate entries"), ["tabs", "tab", "browser", "expand", "separate", "rows", "per tab", "safari", "chrome", "arc", "brave", "edge"]),
        item(SearchID.browserTabLimit, .tabs, SettingsAnchor.browserTabs, String(localized: "Tabs"), String(localized: "Browser tabs"),
             String(localized: "Browser tabs to show"), ["tabs", "tab", "browser", "limit", "cap", "max", "count", "recent", "clutter"]),
        item(SearchID.browserIconOnTabs, .tabs, SettingsAnchor.browserTabs, String(localized: "Tabs"), String(localized: "Browser tabs"),
             String(localized: "Show browser icon on tab entries"), ["tabs", "tab", "browser", "icon", "badge", "favicon", "source", "safari", "chrome", "arc", "brave", "edge"]),
        item(SearchID.browserTabMRU, .tabs, SettingsAnchor.browserTabs, String(localized: "Tabs"), String(localized: "Browser tabs"),
             String(localized: "Track browser tabs in recency"), ["browser", "tab", "tabs", "recent", "mru", "safari", "chrome"]),
        item(SearchID.browserTabPreviews, .tabs, SettingsAnchor.browserTabs, String(localized: "Tabs"), String(localized: "Browser tabs"),
             String(localized: "Browser tab previews"), ["browser", "tab", "preview", "previews", "thumbnail", "safari", "chrome"]),
        item(SearchID.searchExpandsBrowserTabs, .tabs, SettingsAnchor.browserTabs, String(localized: "Tabs"), String(localized: "Browser tabs"),
             String(localized: "Search browser tabs"), ["search", "browser", "tabs", "tab", "fuzzy", "find tab", "safari", "chrome"]),

        // Apps · App rules
        item(SearchID.exceptions, .apps, SettingsAnchor.appRules, String(localized: "Apps"), String(localized: "App rules"),
             String(localized: "App rules"), ["app rules", "exceptions", "excluded", "exclude", "hide app", "blacklist", "ignore shortcuts", "per-app", "fullscreen", "cmd tab"]),
        // Apps · Pinned
        item(SearchID.pinnedApps, .apps, SettingsAnchor.pinned, String(localized: "Apps"), String(localized: "Pinned"),
             String(localized: "Pinned apps"), ["pinned", "pin", "favorite", "always show"]),

        // Appearance · Layout
        item(SearchID.displayMonitor, .appearance, SettingsAnchor.appearanceLayout, String(localized: "Appearance"), String(localized: "Layout"),
             String(localized: "Show switcher on"), ["display", "monitor", "screen", "multi monitor", "cursor", "main display", "active app", "active space"]),
        item(SearchID.layout, .appearance, SettingsAnchor.appearanceLayout, String(localized: "Appearance"), String(localized: "Layout"),
             String(localized: "Layout"), ["layout", "grid", "list", "preview"]),
        item(SearchID.size, .appearance, SettingsAnchor.appearanceLayout, String(localized: "Appearance"), String(localized: "Layout"),
             String(localized: "Size"), ["size", "panel size", "scale", "percent", "compact", "small", "large"]),
        item(SearchID.listMaxWidth, .appearance, SettingsAnchor.appearanceLayout, String(localized: "Appearance"), String(localized: "Layout"),
             String(localized: "Maximum list width"), ["list", "width", "max width", "narrow", "wide", "ultrawide", "percent", "cap"]),
        item(SearchID.gridColumns, .appearance, SettingsAnchor.appearanceLayout, String(localized: "Appearance"), String(localized: "Layout"),
             String(localized: "Grid columns"), ["grid", "columns"]),
        item(SearchID.gridSingleRow, .appearance, SettingsAnchor.appearanceLayout, String(localized: "Appearance"), String(localized: "Layout"),
             String(localized: "Single row"), ["grid", "single row", "one row", "rows", "wrap", "shrink"]),
        // Appearance · Labels
        item(SearchID.textSize, .appearance, SettingsAnchor.appearanceLabels, String(localized: "Appearance"), String(localized: "Labels"),
             String(localized: "Text size"), ["text size", "font size", "smaller", "larger", "text", "scale"]),
        item(SearchID.fontFace, .appearance, SettingsAnchor.appearanceLabels, String(localized: "Appearance"), String(localized: "Labels"),
             String(localized: "Font"), ["font", "typeface", "face", "monospaced", "fixed width", "mono", "rounded", "serif"]),
        item(SearchID.windowTitle, .appearance, SettingsAnchor.appearanceLabels, String(localized: "Appearance"), String(localized: "Labels"),
             String(localized: "Show window title"), ["window title", "title", "label", "name"]),
        item(SearchID.titleAlignment, .appearance, SettingsAnchor.appearanceLabels, String(localized: "Appearance"), String(localized: "Labels"),
             String(localized: "Title alignment"), ["title", "alignment", "align", "left", "center", "centre", "right", "position"]),
        item(SearchID.titleTruncation, .appearance, SettingsAnchor.appearanceLabels, String(localized: "Appearance"), String(localized: "Labels"),
             String(localized: "Ellipsis position"), ["ellipsis", "truncate", "truncation", "beginning", "middle", "end", "long title", "shorten", "title"]),
        item(SearchID.boldSelected, .appearance, SettingsAnchor.appearanceLabels, String(localized: "Appearance"), String(localized: "Labels"),
             String(localized: "Bold selected title"), ["bold", "selected", "title", "weight", "highlight", "label"]),
        item(SearchID.applicationNames, .appearance, SettingsAnchor.appearanceLabels, String(localized: "Appearance"), String(localized: "Labels"),
             String(localized: "Show application names"),
             ["application names", "app name", "app names", "name", "label", "icon only", "hide name"]),
        item(SearchID.windowStatusIcons, .appearance, SettingsAnchor.appearanceLabels, String(localized: "Appearance"), String(localized: "Labels"),
             String(localized: "Show status icons"),
             ["status icons", "status", "icons", "glyph", "minimized", "hidden", "full-screen", "no window", "dashed square"]),
        // Appearance · Panel
        item(SearchID.theme, .appearance, SettingsAnchor.appearancePanel, String(localized: "Appearance"), String(localized: "Panel"),
             String(localized: "Appearance"), ["theme", "appearance", "light", "dark", "system", "color scheme"]),
        item(SearchID.selectionColor, .appearance, SettingsAnchor.appearancePanel, String(localized: "Appearance"), String(localized: "Panel"),
             String(localized: "Selection color"), ["selection", "color", "colour", "accent", "highlight", "border", "tint", "selected"]),
        item(SearchID.opacity, .appearance, SettingsAnchor.appearancePanel, String(localized: "Appearance"), String(localized: "Panel"),
             String(localized: "Panel opacity"), ["opacity", "transparency", "alpha", "translucent"]),
        item(SearchID.cornerRadius, .appearance, SettingsAnchor.appearancePanel, String(localized: "Appearance"), String(localized: "Panel"),
             String(localized: "Corner radius"), ["corner", "radius", "rounded", "rounding"]),
        item(SearchID.animations, .appearance, SettingsAnchor.appearancePanel, String(localized: "Appearance"), String(localized: "Panel"),
             String(localized: "Animations"), ["animation", "animations", "motion", "slide", "resize", "instant", "static"]),
        item(SearchID.livePreviews, .appearance, SettingsAnchor.appearancePanel, String(localized: "Appearance"), String(localized: "Panel"),
             String(localized: "Live window previews"), ["live", "preview", "previews", "thumbnail", "thumbnails", "refresh", "video"]),
        item(SearchID.preview, .appearance, SettingsAnchor.appearancePanel, String(localized: "Appearance"), String(localized: "Panel"),
             String(localized: "Preview"), ["preview", "sample", "test", "live"]),

        // Privacy · Permissions
        item(SearchID.accessibility, .privacy, SettingsAnchor.permissions, String(localized: "Privacy"), String(localized: "Permissions"),
             String(localized: "Accessibility access"), ["accessibility", "permission", "grant", "trusted"]),
        item(SearchID.fullDiskAccess, .privacy, SettingsAnchor.permissions, String(localized: "Privacy"), String(localized: "Permissions"),
             String(localized: "Full Disk Access"), ["full", "disk", "access", "fda", "permission", "safari", "favicon", "favicons"]),
        item(SearchID.tabPermissions, .privacy, SettingsAnchor.permissions, String(localized: "Privacy"), String(localized: "Permissions"),
             String(localized: "Browser tab access"), ["tabs", "apple events", "automation", "permission", "browser", "consent"]),
        // Privacy · Screen sharing
        item(SearchID.hideFromScreenSharing, .privacy, SettingsAnchor.screenSharing, String(localized: "Privacy"), String(localized: "Screen sharing"),
             String(localized: "Don't look at my windows"), ["privacy", "screen sharing", "screen recording", "hide", "zoom", "meet", "teams", "screencapture"]),
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
        case general, profiles, shortcuts, switcher, controls, tabs, apps, appearance, privacy

        var id: String {
            switch self {
            case .general: return SettingsTabID.general
            case .profiles: return SettingsTabID.profiles
            case .shortcuts: return SettingsTabID.shortcuts
            case .switcher: return SettingsTabID.switcher
            case .controls: return SettingsTabID.controls
            case .tabs: return SettingsTabID.tabs
            case .apps: return SettingsTabID.apps
            case .appearance: return SettingsTabID.appearance
            case .privacy: return SettingsTabID.privacy
            }
        }
    }
}
