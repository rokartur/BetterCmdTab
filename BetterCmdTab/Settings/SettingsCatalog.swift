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
    static let switcherShortcuts = "switcherShortcuts"
    static let contents = "contents"
    static let tabs = "tabs"
    static let apps = "apps"
    static let appearance = "appearance"
    static let keyboard = "keyboard"
    static let mouse = "mouse"
    static let trackpad = "trackpad"
    static let windowShortcuts = "windowShortcuts"
    static let general = "general"
    static let privacy = "privacy"
    static let about = "about"
    #if DEBUG
    static let debug = "debug"
    #endif
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
    // Switcher Shortcuts
    static let switching = "switcherShortcuts.switching"
    // Window Shortcuts — every global hotkey that does not open the switcher.
    static let directActivation = "windowShortcuts.directActivation"
    static let directActivationCycle = "windowShortcuts.directActivationCycle"
    static let windowArrange = "windowShortcuts.arrange"
    static let windowAll = "windowShortcuts.all"
    // Trackpad
    static let swipe = "trackpad.swipe"
    // Contents — what the panel lists.
    static let contents = "contents.contents"
    static let windowShelf = "contents.windowShelf"
    static let handoff = "contents.handoff"
    static let timing = "contents.timing"
    // Keyboard
    static let keyboard = "keyboard.keyboard"
    static let letterJump = "keyboard.letterJump"
    static let oneHandHints = "keyboard.oneHandHints"
    static let inputLanguage = "keyboard.inputLanguage"
    static let search = "keyboard.search"
    // Mouse
    static let mouse = "mouse.mouse"
    static let mouseRelease = "mouse.mouseRelease"
    static let hoverActions = "mouse.hoverActions"
    // Tabs
    static let nativeTabs = "tabs.native"
    static let browserTabs = "tabs.browser"
    // Apps
    static let appRules = "apps.rules"
    static let pinned = "apps.pinned"
    // Appearance
    static let appearancePlacement = "appearance.placement"
    static let appearanceLayout = "appearance.layoutSection"
    static let appearanceLabels = "appearance.labels"
    static let appearancePanel = "appearance.panel"
    static let appearanceFade = "appearance.fade"
    // Privacy
    static let permissions = "privacy.permissions"
    static let screenSharing = "privacy.screenSharing"
    // About
    static let about = "about.info"
}

/// Search-item identifiers. A row registers itself under the matching id so a
/// search result scrolls straight to (and flashes) that exact control.
enum SearchID {
    // General, Privacy
    static let launchAtLogin = "general.launchAtLogin"
    static let hideMenuBar = "general.hideMenuBar"
    static let switchApps = "switcherShortcuts.switchApps"
    static let switchWindows = "switcherShortcuts.switchWindows"
    static let haptic = "general.haptic"
    static let sound = "general.sound"
    static let hideFromScreenSharing = "privacy.hideFromScreenSharing"
    static let accessibility = "privacy.accessibility"
    static let fullDiskAccess = "privacy.fullDiskAccess"
    static let restoreShortcuts = "general.restoreShortcuts"
    static let updateInterval = "general.updateInterval"
    static let beta = "general.beta"
    static let exportSettings = "general.exportSettings"
    static let importSettings = "general.importSettings"
    static let configFile = "general.configFile"
    // Switcher Shortcuts
    static let scopedSwitch = "switcherShortcuts.scopedSwitch"
    static let panelKeys = "switcherShortcuts.panelKeys"
    // Window Shortcuts, Trackpad
    static let directActivation = "windowShortcuts.directActivation"
    static let directActivationCyclesWindows = "windowShortcuts.directActivationCyclesWindows"
    static let windowMgmt = "windowShortcuts.windowMgmt"
    static let cycleTileWidths = "windowShortcuts.cycleTileWidths"
    static let hideAllWindows = "windowShortcuts.hideAllWindows"
    static let showAllWindows = "windowShortcuts.showAllWindows"
    static let keepAppsVisible = "windowShortcuts.keepAppsVisible"
    static let swipe = "trackpad.swipe"
    static let swipeFingers = "trackpad.swipeFingers"
    static let swipeMode = "trackpad.swipeMode"
    static let reverseSwipe = "trackpad.reverseSwipe"
    static let switchOnRelease = "trackpad.switchOnRelease"
    static let sensitivity = "trackpad.sensitivity"
    // Contents
    static let showMinimized = "contents.showMinimized"
    static let showHidden = "contents.showHidden"
    static let sinkHiddenApps = "contents.sinkHiddenApps"
    static let sinkMinimizedWindows = "contents.sinkMinimizedWindows"
    static let showWindowless = "contents.showWindowless"
    static let applicationsOnly = "contents.applicationsOnly"
    static let showBadges = "contents.showBadges"
    static let spaceScope = "contents.spaceScope"
    static let instantSpace = "contents.instantSpace"
    static let sortOrder = "contents.sortOrder"
    static let initialSelection = "contents.initialSelection"
    static let showRecentlyClosed = "contents.showRecentlyClosed"
    static let recentlyClosedLimit = "contents.recentlyClosedLimit"
    static let windowDrill = "contents.windowDrill"
    static let windowShelf = "contents.windowShelf"
    static let windowShelfSingleWindow = "contents.windowShelfSingleWindow"
    static let handoffPlacement = "contents.handoffPlacement"
    static let quickSwitchDelay = "contents.quickSwitchDelay"
    static let titleRefreshInterval = "contents.titleRefreshInterval"
    // Keyboard, Mouse
    static let letterHints = "keyboard.letterHints"
    static let quickJumpMappings = "keyboard.quickJumpMappings"
    static let letterChainTimeout = "keyboard.letterChainTimeout"
    static let oneHandHints = "keyboard.oneHandHints"
    static let fuzzy = "keyboard.fuzzy"
    static let rankResults = "keyboard.rankResults"
    static let launcher = "keyboard.launcher"
    static let searchMode = "keyboard.searchMode"
    static let shiftTapBack = "keyboard.shiftTapBack"
    static let backtickReverse = "keyboard.backtickReverse"
    static let stayOpen = "keyboard.stayOpen"
    static let stayOpenQuickTap = "keyboard.stayOpenQuickTap"
    static let englishKeyboard = "keyboard.englishKeyboard"
    static let vimNavigation = "keyboard.vimNavigation"
    static let scroll = "mouse.scroll"
    static let scrollReverse = "mouse.scrollReverse"
    static let clickDismiss = "mouse.clickDismiss"
    static let selectOnHover = "mouse.selectOnHover"
    static let selectOnClick = "mouse.selectOnClick"
    static let clickOnMouseUp = "mouse.clickOnMouseUp"
    static let hoverActions = "mouse.hoverActions"
    // Tabs
    static let tabDrill = "tabs.tabDrill"
    static let expandTabs = "tabs.expandTabs"
    static let expandBrowserTabs = "tabs.expandBrowserTabs"
    static let browserTabLimit = "tabs.browserTabLimit"
    static let browserIconOnTabs = "tabs.browserIconOnTabs"
    static let browserTabMRU = "tabs.browserTabMRU"
    static let browserTabPreviews = "tabs.browserTabPreviews"
    static let searchExpandsBrowserTabs = "tabs.searchExpandsBrowserTabs"
    // Apps
    static let exceptions = "apps.exceptions"
    static let pinnedApps = "apps.pinnedApps"
    // Appearance
    static let displayMonitor = "appearance.displayMonitor"
    static let movePointerAcrossDisplays = "appearance.movePointerAcrossDisplays"
    static let verticalPosition = "appearance.verticalPosition"
    static let topOffset = "appearance.topOffset"
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
    static let applicationNames = "appearance.applicationNames"
    static let windowStatusIcons = "appearance.windowStatusIcons"
    static let theme = "appearance.theme"
    static let opacity = "appearance.opacity"
    static let cornerRadius = "appearance.cornerRadius"
    static let animations = "appearance.animations"
    static let fadeIn = "appearance.fadeIn"
    static let fadeOut = "appearance.fadeOut"
    static let livePreviews = "appearance.livePreviews"
    static let preview = "appearance.preview"
    // Privacy
    static let tabPermissions = "privacy.tabPermissions"
}

@MainActor
enum SettingsCatalog {

    /// Shown at the top of Contents, Keyboard, Mouse and Appearance: those panes
    /// hold the switcher's global defaults and nothing else says so (#74). Only
    /// some rows have a matching `ShortcutOverride` field, hence "many".
    /// The subtitle carries only the override pointer — the title already says
    /// what the scope is, and a row subtitle that wraps to a second line gets
    /// its tail clipped by BetterSettings' height measurement.
    static let globalDefaultNoteTitle = String(localized: "Defaults for every shortcut")
    static let globalDefaultNoteSubtitle = String(localized: "Many of these can be overridden per shortcut under Switcher Shortcuts.")

    static func title(of tabID: String) -> String {
        tabs.first { $0.id == tabID }!.title
    }

    static func makeConfiguration() -> SettingsConfiguration {
        SettingsConfiguration(
            tabs: tabs,
            searchItems: searchItems,
            contentProvider: { tab, _ in
                switch tab.id {
                case SettingsTabID.switcherShortcuts: return ProfilesSettingsViewController()
                case SettingsTabID.contents:          return SwitcherPanesViewController(pane: .contents)
                case SettingsTabID.tabs:              return SwitcherPanesViewController(pane: .tabs)
                case SettingsTabID.apps:              return AppsSettingsViewController()
                case SettingsTabID.appearance:        return AppearanceSettingsViewController()
                case SettingsTabID.keyboard:          return SwitcherPanesViewController(pane: .keyboard)
                case SettingsTabID.mouse:             return SwitcherPanesViewController(pane: .mouse)
                case SettingsTabID.trackpad:          return TrackpadSettingsViewController()
                case SettingsTabID.windowShortcuts:   return ShortcutsSettingsViewController()
                case SettingsTabID.general:           return GeneralSettingsViewController()
                case SettingsTabID.privacy:           return PrivacySettingsViewController()
                #if DEBUG
                case SettingsTabID.debug:             return DebugSettingsViewController()
                #endif
                default:                              return AboutSettingsViewController()
                }
            },
            searchPlaceholder: String(localized: "Search"),
            noResultsText: String(localized: "No matching settings"),
            showDetailsLabel: String(localized: "Show Details"),
            showDetailsDefaultsKey: "BetterCmdTab.showSettingsDetails",
            // Keep the active tab + 1 previous live and drop to active-only when
            // the settings window loses key. Inactive tab trees are freed and
            // rebuilt lazily on revisit, minimizing RAM for this secondary window.
            tabUnloadPolicy: .balanced
        )
    }

    // MARK: - Tabs

    #if DEBUG
    static let tabs = productTabs + [
        SettingsTab(
            id: SettingsTabID.debug, title: "Debug", icon: "ladybug.fill",
            iconStyle: style(0x898A8F, 0x67686E, scale: 0.9),
            group: systemGroup
        ),
    ]
    #else
    static let tabs = productTabs
    #endif

    private static let switcherGroup = String(localized: "Switcher")
    private static let inputGroup = String(localized: "Input")
    private static let windowsGroup = String(localized: "Windows")
    private static let systemGroup = String(localized: "settings.group.system", defaultValue: "System")

    /// Sidebar order; each group's tabs must stay adjacent, the package starts
    /// a new header whenever `group` changes.
    private static let productTabs: [SettingsTab] = [
        // Palette + icon style mirror BetterAudio: muted macOS System Settings
        // gradient badges with white SF Symbols; white badge for About.
        SettingsTab(
            id: SettingsTabID.general, title: String(localized: "General"), icon: "gear",
            iconStyle: style(0x898A8F, 0x67686E, scale: 1.0)
        ),
        SettingsTab(
            id: SettingsTabID.appearance, title: String(localized: "Appearance"), icon: "paintbrush.fill",
            iconStyle: style(0xFF6991, 0xD41E5A, scale: 0.9),
            group: switcherGroup
        ),
        SettingsTab(
            id: SettingsTabID.contents, title: String(localized: "Contents"), icon: "rectangle.stack.fill",
            iconStyle: style(0xB272FF, 0x6228FF, scale: 0.95),
            group: switcherGroup
        ),
        SettingsTab(
            id: SettingsTabID.apps, title: String(localized: "Apps"), icon: "square.grid.2x2.fill",
            iconStyle: style(0x4ED98F, 0x12A85B, scale: 0.9),
            group: switcherGroup
        ),
        SettingsTab(
            id: SettingsTabID.tabs, title: String(localized: "Tabs"), icon: "rectangle.split.3x1.fill",
            iconStyle: style(0xFFA846, 0xFF6F00, scale: 0.9),
            group: switcherGroup
        ),
        // Each switcher shortcut is a profile with its own trigger, per-shortcut
        // option overrides and in-panel keys.
        SettingsTab(
            id: SettingsTabID.switcherShortcuts, title: String(localized: "Switcher Shortcuts"), icon: "slider.horizontal.3",
            iconStyle: style(0x40BCFF, 0x0060FF, scale: 0.9),
            group: switcherGroup
        ),
        SettingsTab(
            id: SettingsTabID.keyboard, title: String(localized: "Keyboard"), icon: "keyboard.fill",
            iconStyle: style(0x4ADEDE, 0x00A0A8, scale: 0.8),
            group: inputGroup
        ),
        SettingsTab(
            id: SettingsTabID.mouse, title: String(localized: "Mouse"), icon: "computermouse.fill",
            iconStyle: style(0x4ADEDE, 0x00A0A8, scale: 0.85),
            group: inputGroup
        ),
        SettingsTab(
            id: SettingsTabID.trackpad, title: String(localized: "Trackpad"), icon: "rectangle.and.hand.point.up.left.fill",
            iconStyle: style(0x4ADEDE, 0x00A0A8, scale: 0.8),
            group: inputGroup
        ),
        SettingsTab(
            id: SettingsTabID.windowShortcuts, title: String(localized: "Window Shortcuts"), icon: "command",
            iconStyle: style(0x5AC8FA, 0x0A84C4, scale: 0.9),
            group: windowsGroup
        ),
        SettingsTab(
            id: SettingsTabID.privacy, title: String(localized: "Privacy"), icon: "lock.fill",
            iconStyle: style(0xFF5E62, 0xFF0016, scale: 0.9),
            group: systemGroup
        ),
        SettingsTab(
            id: SettingsTabID.about, title: String(localized: "About"), icon: "info.circle.fill",
            iconStyle: style(0xFFFFFF, 0xECECF0, scale: 1.0, symbol: 0x1C1C1E),
            group: systemGroup
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

        // Switcher Shortcuts
        item(SearchID.switchApps, .switcherShortcuts, SettingsAnchor.switching, String(localized: "Switcher Shortcuts"), String(localized: "Switcher shortcuts"),
             String(localized: "Switch apps"), ["shortcut", "hotkey", "cmd tab", "command tab", "trigger"]),
        item(SearchID.switchWindows, .switcherShortcuts, SettingsAnchor.switching, String(localized: "Switcher Shortcuts"), String(localized: "Switcher shortcuts"),
             String(localized: "Switch windows"), ["shortcut", "hotkey", "window cycle"]),
        item(SearchID.scopedSwitch, .switcherShortcuts, SettingsAnchor.switching, String(localized: "Switcher Shortcuts"), String(localized: "Switcher shortcuts"),
             String(localized: "Scoped shortcuts"), ["scope", "scoped", "all windows", "current app", "minimized", "this space", "filtered switcher"]),
        item(SearchID.panelKeys, .switcherShortcuts, SettingsAnchor.switching, String(localized: "Switcher Shortcuts"), String(localized: "In-panel keys"),
             String(localized: "Action keys while switching"),
             ["panel keys", "rebind", "close", "minimize", "hide", "quit", "wmhq", "in-panel", "search key", "slash", "tab drill", "peek tabs", "backslash", "arrows", "navigation", "move selection"]),

        // Window Shortcuts · Direct activation
        item(SearchID.directActivation, .windowShortcuts, SettingsAnchor.directActivation, String(localized: "Window Shortcuts"), String(localized: "Direct activation"),
             String(localized: "Jump straight to an app"),
             ["direct activation", "hotkey", "shortcut", "activate", "focus app", "jump to app"]),
        item(SearchID.directActivationCyclesWindows, .windowShortcuts, SettingsAnchor.directActivationCycle, String(localized: "Window Shortcuts"), String(localized: "Repeat presses"),
             String(localized: "Cycle app windows"), ["cycle", "windows", "next window", "press again", "repeat", "direct activation"]),
        // Window Shortcuts · Arrange window
        item(SearchID.windowMgmt, .windowShortcuts, SettingsAnchor.windowArrange, String(localized: "Window Shortcuts"), String(localized: "Arrange window"),
             String(localized: "Arrange the focused window"),
             ["window management", "tile", "maximize", "center", "snap", "halves", "arrange", "rebind", "highlighted"]),
        item(SearchID.cycleTileWidths, .windowShortcuts, SettingsAnchor.windowArrange, String(localized: "Window Shortcuts"), String(localized: "Arrange window"),
             String(localized: "Cycle tile widths"), ["tile", "cycle", "width", "halves", "thirds", "two thirds", "resize"]),
        // Window Shortcuts · All windows
        item(SearchID.hideAllWindows, .windowShortcuts, SettingsAnchor.windowAll, String(localized: "Window Shortcuts"), String(localized: "All windows"),
             String(localized: "Hide all windows"), ["hide all", "desktop", "show desktop", "clear screen", "minimize all"]),
        item(SearchID.showAllWindows, .windowShortcuts, SettingsAnchor.windowAll, String(localized: "Window Shortcuts"), String(localized: "All windows"),
             String(localized: "Show all windows"), ["show all", "unhide", "restore", "bring back"]),
        item(SearchID.keepAppsVisible, .windowShortcuts, SettingsAnchor.windowAll, String(localized: "Window Shortcuts"), String(localized: "All windows"),
             String(localized: "Keep apps visible"), ["exclude", "exception", "keep visible", "hide all", "finder"]),
        // Trackpad · Trackpad swipe
        item(SearchID.swipe, .trackpad, SettingsAnchor.swipe, String(localized: "Trackpad"), String(localized: "Trackpad swipe"),
             String(localized: "Swipe gesture"), ["swipe", "trackpad", "gesture", "three finger", "four finger", "experimental"]),
        item(SearchID.swipeFingers, .trackpad, SettingsAnchor.swipe, String(localized: "Trackpad"), String(localized: "Trackpad swipe"),
             String(localized: "Fingers"), ["fingers", "three finger", "four finger", "drag"]),
        item(SearchID.swipeMode, .trackpad, SettingsAnchor.swipe, String(localized: "Trackpad"), String(localized: "Trackpad swipe"),
             String(localized: "Swipe action"), ["swipe", "spaces", "switch spaces", "open switcher", "gesture action"]),
        item(SearchID.reverseSwipe, .trackpad, SettingsAnchor.swipe, String(localized: "Trackpad"), String(localized: "Trackpad swipe"),
             String(localized: "Reverse swipe direction"), ["swipe", "reverse", "invert"]),
        item(SearchID.switchOnRelease, .trackpad, SettingsAnchor.swipe, String(localized: "Trackpad"), String(localized: "Trackpad swipe"),
             String(localized: "Switch on release"), ["release", "commit", "lift"]),
        item(SearchID.sensitivity, .trackpad, SettingsAnchor.swipe, String(localized: "Trackpad"), String(localized: "Trackpad swipe"),
             String(localized: "Swipe sensitivity"), ["sensitivity", "swipe", "distance"]),

        // Contents · Contents
        item(SearchID.showMinimized, .contents, SettingsAnchor.contents, String(localized: "Contents"), String(localized: "Contents"),
             String(localized: "Show minimized windows"), ["minimized", "minimize"]),
        item(SearchID.showHidden, .contents, SettingsAnchor.contents, String(localized: "Contents"), String(localized: "Contents"),
             String(localized: "Show hidden apps"), ["hidden", "hide"]),
        item(SearchID.sinkHiddenApps, .contents, SettingsAnchor.contents, String(localized: "Contents"), String(localized: "Contents"),
             String(localized: "Move hidden apps to the bottom"), ["hidden", "hide", "sort", "bottom", "position", "order"]),
        item(SearchID.sinkMinimizedWindows, .contents, SettingsAnchor.contents, String(localized: "Contents"), String(localized: "Contents"),
             String(localized: "Move minimized windows to the bottom"),
             ["minimized", "minimize", "sort", "bottom", "position", "order"]),
        item(SearchID.showWindowless, .contents, SettingsAnchor.contents, String(localized: "Contents"), String(localized: "Contents"),
             String(localized: "Show apps without windows"), ["windowless", "no windows", "background apps"]),
        item(SearchID.applicationsOnly, .contents, SettingsAnchor.contents, String(localized: "Contents"), String(localized: "Contents"),
             String(localized: "Applications only"),
             ["applications only", "apps only", "one per app", "per app", "command tab", "classic", "group windows"]),
        item(SearchID.windowDrill, .contents, SettingsAnchor.contents, String(localized: "Contents"), String(localized: "Contents"),
             String(localized: "Peek windows with ↓"),
             ["windows", "window", "drill", "peek", "down arrow", "applications only", "app windows", "expose"]),
        item(SearchID.windowShelf, .contents, SettingsAnchor.windowShelf, String(localized: "Contents"), String(localized: "Window shelf"),
             String(localized: "Show windows under the switcher"),
             ["windows", "shelf", "hyperswitch", "previews", "grid", "list", "applications only", "app windows", "group by app"]),
        item(SearchID.windowShelfSingleWindow, .contents, SettingsAnchor.windowShelf, String(localized: "Contents"), String(localized: "Window shelf"),
             String(localized: "Show for a single window"),
             ["windows", "shelf", "single window", "one window"]),
        item(SearchID.handoffPlacement, .contents, SettingsAnchor.handoff, String(localized: "Contents"), String(localized: "Handoff"),
             String(localized: "Show Handoff from other devices"),
             ["handoff", "continuity", "iphone", "ipad", "mac", "other device", "safari"]),
        item(SearchID.showBadges, .contents, SettingsAnchor.contents, String(localized: "Contents"), String(localized: "Contents"),
             String(localized: "Show unread badges"), ["badge", "unread", "dock badge", "count"]),
        item(SearchID.spaceScope, .contents, SettingsAnchor.contents, String(localized: "Contents"), String(localized: "Contents"),
             String(localized: "Show windows from"), ["space", "current space", "visible spaces", "desktop", "display", "monitor", "filter"]),
        item(SearchID.instantSpace, .contents, SettingsAnchor.contents, String(localized: "Contents"), String(localized: "Contents"),
             String(localized: "Switch Spaces without animation"), ["spaces", "space", "animation", "instant", "full screen"]),
        item(SearchID.sortOrder, .contents, SettingsAnchor.contents, String(localized: "Contents"), String(localized: "Contents"),
             String(localized: "Sort order"), ["sort", "order", "mru", "most recent", "alphabetical", "launch order", "windows", "window recency"]),
        item(SearchID.initialSelection, .contents, SettingsAnchor.contents, String(localized: "Contents"), String(localized: "Contents"),
             String(localized: "First ⌘Tab selects"), ["initial selection", "first", "middle", "center", "next app", "start", "selects"]),
        item(SearchID.showRecentlyClosed, .contents, SettingsAnchor.contents, String(localized: "Contents"), String(localized: "Contents"),
             String(localized: "Show recently closed apps"), ["recently closed", "reopen", "recent"]),
        item(SearchID.recentlyClosedLimit, .contents, SettingsAnchor.contents, String(localized: "Contents"), String(localized: "Contents"),
             String(localized: "Recently closed to show"), ["recently closed", "limit", "count"]),
        // Contents · Timing
        item(SearchID.quickSwitchDelay, .contents, SettingsAnchor.timing, String(localized: "Contents"), String(localized: "Timing"),
             String(localized: "Quick-switch delay"), ["delay", "reveal", "hold", "quick switch"]),
        item(SearchID.titleRefreshInterval, .contents, SettingsAnchor.timing, String(localized: "Contents"), String(localized: "Timing"),
             String(localized: "Title refresh delay"), ["title", "refresh", "update", "interval", "window title", "live titles", "debounce"]),

        // Keyboard · Keyboard
        item(SearchID.stayOpen, .keyboard, SettingsAnchor.keyboard, String(localized: "Keyboard"), String(localized: "Keyboard"),
             String(localized: "Stay open after releasing the modifier"), ["stay open", "sticky", "release", "modifier", "keep open", "hold"]),
        item(SearchID.stayOpenQuickTap, .keyboard, SettingsAnchor.keyboard, String(localized: "Keyboard"), String(localized: "Keyboard"),
             String(localized: "Also stay open after a quick tap"), ["quick tap", "mouse", "mouse button", "gesture", "stay open", "sticky", "tap"]),
        item(SearchID.shiftTapBack, .keyboard, SettingsAnchor.keyboard, String(localized: "Keyboard"), String(localized: "Keyboard"),
             String(localized: "Tap Shift to step backwards"), ["shift", "backwards", "back", "reverse", "tap shift", "cmd shift tab", "windows"]),
        item(SearchID.backtickReverse, .keyboard, SettingsAnchor.keyboard, String(localized: "Keyboard"), String(localized: "Keyboard"),
             String(localized: "Use window-switch shortcut to step backwards"), ["backtick", "tilde", "cmd backtick", "command backtick", "window shortcut", "reverse", "backwards", "native"]),
        item(SearchID.englishKeyboard, .keyboard, SettingsAnchor.inputLanguage, String(localized: "Keyboard"), String(localized: "Input language"),
             String(localized: "Always use English keyboard mapping"),
             ["english", "US", "keyboard", "language", "layout", "hebrew", "search"]),
        item(SearchID.vimNavigation, .keyboard, SettingsAnchor.keyboard, String(localized: "Keyboard"), String(localized: "Keyboard"),
             String(localized: "Vim keys (h j k l)"), ["vim", "hjkl", "h j k l", "keyboard", "arrows", "navigation"]),
        // Keyboard · Letter jump
        item(SearchID.letterHints, .keyboard, SettingsAnchor.letterJump, String(localized: "Keyboard"), String(localized: "Letter jump"),
             String(localized: "Letter hints"), ["letter hints", "jump", "vim", "quick jump"]),
        item(SearchID.quickJumpMappings, .keyboard, SettingsAnchor.letterJump, String(localized: "Keyboard"), String(localized: "Letter jump"),
             String(localized: "Custom app mappings"), ["letter", "mapping", "custom", "quick jump", "app", "skip", "exclude", "no letter", "hint"]),
        item(SearchID.letterChainTimeout, .keyboard, SettingsAnchor.letterJump, String(localized: "Keyboard"), String(localized: "Letter jump"),
             String(localized: "Letter chain timeout"), ["letter", "chain", "timeout", "reset", "jump", "delay", "prefix", "sequence", "expire"]),
        item(SearchID.oneHandHints, .keyboard, SettingsAnchor.oneHandHints, String(localized: "Keyboard"), String(localized: "One-hand letter jump"),
             String(localized: "Hints on the ⌘ side"), ["one hand", "single hand", "left", "right", "command", "trackpad", "letter", "hint", "jump"]),
        // Keyboard · Search
        item(SearchID.fuzzy, .keyboard, SettingsAnchor.search, String(localized: "Keyboard"), String(localized: "Search"),
             String(localized: "Type-to-filter search"), ["search", "filter", "fuzzy", "type"]),
        item(SearchID.rankResults, .keyboard, SettingsAnchor.search, String(localized: "Keyboard"), String(localized: "Search"),
             String(localized: "Rank search"), ["fuzzy", "search", "ranking", "rank", "best match", "sort results", "relevance"]),
        item(SearchID.launcher, .keyboard, SettingsAnchor.search, String(localized: "Keyboard"), String(localized: "Search"),
             String(localized: "Launch apps from search"), ["launcher", "launch", "open app"]),
        item(SearchID.searchMode, .keyboard, SettingsAnchor.search, String(localized: "Keyboard"), String(localized: "Search"),
             String(localized: "When searching"), ["search mode", "hold", "stay open", "dismiss"]),
        // Mouse · Mouse
        item(SearchID.scroll, .mouse, SettingsAnchor.mouse, String(localized: "Mouse"), String(localized: "Mouse"),
             String(localized: "Switch with mouse scroll"), ["scroll", "wheel", "mouse"]),
        item(SearchID.scrollReverse, .mouse, SettingsAnchor.mouse, String(localized: "Mouse"), String(localized: "Mouse"),
             String(localized: "Reverse scroll direction"), ["scroll", "reverse", "invert"]),
        item(SearchID.clickDismiss, .mouse, SettingsAnchor.mouse, String(localized: "Mouse"), String(localized: "Mouse"),
             String(localized: "Click outside to dismiss"), ["click", "outside", "dismiss", "cancel", "spotlight"]),
        item(SearchID.selectOnHover, .mouse, SettingsAnchor.mouse, String(localized: "Mouse"), String(localized: "Mouse"),
             String(localized: "Select window on hover"), ["hover", "pointer", "mouse", "selection", "highlight"]),
        item(SearchID.selectOnClick, .mouse, SettingsAnchor.mouse, String(localized: "Mouse"), String(localized: "Mouse"),
             String(localized: "Select window on click"), ["click", "mouse", "pick", "selection"]),
        item(SearchID.clickOnMouseUp, .mouse, SettingsAnchor.mouseRelease, String(localized: "Mouse"), String(localized: "Mouse release"),
             String(localized: "Click on mouse release"), ["click", "mouse", "release", "mouse up", "drag", "menu", "cancel"]),
        // Mouse · Hover actions
        item(SearchID.hoverActions, .mouse, SettingsAnchor.hoverActions, String(localized: "Mouse"), String(localized: "Hover actions"),
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
        item(SearchID.displayMonitor, .appearance, SettingsAnchor.appearancePlacement, String(localized: "Appearance"), String(localized: "Placement"),
             String(localized: "Show switcher on"), ["display", "monitor", "screen", "multi monitor", "cursor", "main display", "active app", "active space"]),
        item(SearchID.movePointerAcrossDisplays, .appearance, SettingsAnchor.appearancePlacement, String(localized: "Appearance"), String(localized: "Placement"),
             String(localized: "Move pointer to the window's display"), ["pointer", "cursor", "mouse", "follow", "display", "monitor", "multi monitor"]),
        item(SearchID.verticalPosition, .appearance, SettingsAnchor.appearancePlacement, String(localized: "Appearance"), String(localized: "Placement"),
             String(localized: "Vertical position"), ["position", "vertical", "top", "center", "higher", "align", "placement"]),
        item(SearchID.topOffset, .appearance, SettingsAnchor.appearancePlacement, String(localized: "Appearance"), String(localized: "Placement"),
             String(localized: "Distance from top"), ["top", "offset", "margin", "padding", "gap", "percent", "higher", "lower"]),
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
        item(SearchID.fadeIn, .appearance, SettingsAnchor.appearanceFade, String(localized: "Appearance"), String(localized: "Fade"),
             String(localized: "Fade in"), ["fade", "fading", "animation", "dissolve", "open", "appear", "duration"]),
        item(SearchID.fadeOut, .appearance, SettingsAnchor.appearanceFade, String(localized: "Appearance"), String(localized: "Fade"),
             String(localized: "Fade out"), ["fade", "fading", "animation", "dissolve", "close", "disappear", "duration"]),

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
        case switcherShortcuts, contents, tabs, apps, appearance, keyboard, mouse, trackpad, windowShortcuts, general, privacy

        var id: String {
            switch self {
            case .switcherShortcuts: return SettingsTabID.switcherShortcuts
            case .contents: return SettingsTabID.contents
            case .tabs: return SettingsTabID.tabs
            case .apps: return SettingsTabID.apps
            case .appearance: return SettingsTabID.appearance
            case .keyboard: return SettingsTabID.keyboard
            case .mouse: return SettingsTabID.mouse
            case .trackpad: return SettingsTabID.trackpad
            case .windowShortcuts: return SettingsTabID.windowShortcuts
            case .general: return SettingsTabID.general
            case .privacy: return SettingsTabID.privacy
            }
        }
    }
}
