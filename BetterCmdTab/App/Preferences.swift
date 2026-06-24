import AppKit
import Combine
import Foundation

enum SwitcherLayoutMode: String, CaseIterable {
    case list
    case gridView = "iconDock"
    case windowPreview

    var displayName: String {
        switch self {
        case .list: return String(localized: "List")
        case .gridView: return String(localized: "Grid View")
        case .windowPreview: return String(localized: "Previews")
        }
    }

    /// True for the 2-D tile layouts (grid + previews), which share the same
    /// spatial up/down/left/right navigation, as opposed to the linear list.
    var isGridLike: Bool {
        switch self {
        case .gridView, .windowPreview: return true
        case .list: return false
        }
    }
}

/// Which display the switcher panel opens on (#22).
enum SwitcherDisplayMode: String, CaseIterable {
    /// Screen under the mouse pointer. Default — matches pre-#22 behavior.
    case mouseCursor
    /// Screen of the window focused when ⌘Tab fired.
    case activeWindow
    /// "Main display" from System Settings → Displays (the origin-zero screen).
    case mainDisplay

    var displayName: String {
        switch self {
        case .mouseCursor:  return String(localized: "Monitor with the cursor")
        case .activeWindow: return String(localized: "Monitor with the active window")
        case .mainDisplay:  return String(localized: "Main display")
        }
    }
}

/// What keeps the switcher open once fuzzy-search has been activated with `/`.
enum SearchDismissMode: String, CaseIterable {
    /// Keep holding the switcher modifier (⌘); releasing it commits the
    /// selection. Matches the non-search behavior. (Default.)
    case holdModifier
    /// After `/`, the switcher stays open even when ⌘ is released, until the
    /// user picks a row with Return or the mouse.
    case stayOpen

    var displayName: String {
        switch self {
        case .holdModifier: return String(localized: "Hold ⌘")
        case .stayOpen: return String(localized: "Stay open until I choose")
        }
    }
}

/// Accent color used for the selection highlight and the type-to-jump letter
/// prefix. `.system` follows the user's macOS accent (`controlAccentColor`);
/// every other case is a fixed color.
enum SwitcherAccent: String, CaseIterable {
    case system
    case blue
    case purple
    case pink
    case red
    case orange
    case yellow
    case green
    case graphite
    /// User-supplied color; the actual value lives in `Preferences.customAccentHex`.
    /// Resolve via `Preferences.shared.resolvedAccent`, not `resolved`, so the hex
    /// is read on the main actor.
    case custom

    var displayName: String {
        switch self {
        case .system: return String(localized: "System")
        case .blue: return String(localized: "Blue")
        case .purple: return String(localized: "Purple")
        case .pink: return String(localized: "Pink")
        case .red: return String(localized: "Red")
        case .orange: return String(localized: "Orange")
        case .yellow: return String(localized: "Yellow")
        case .green: return String(localized: "Green")
        case .graphite: return String(localized: "Graphite")
        case .custom: return String(localized: "Custom…")
        }
    }

    /// Fixed color, or `nil` when the choice tracks the system accent or is custom.
    var color: NSColor? {
        switch self {
        case .system, .custom: return nil
        case .blue: return .systemBlue
        case .purple: return .systemPurple
        case .pink: return .systemPink
        case .red: return .systemRed
        case .orange: return .systemOrange
        case .yellow: return .systemYellow
        case .green: return .systemGreen
        case .graphite: return .systemGray
        }
    }

    /// The concrete color to draw with right now. Resolving `.system` lazily
    /// keeps it appearance-reactive (light/dark) like the rest of AppKit. For
    /// `.custom` this falls back to the system accent — use
    /// `Preferences.shared.resolvedAccent` to honor the stored hex.
    var resolved: NSColor { color ?? .controlAccentColor }
}

/// Background material for the switcher panel (the blur behind the rows). Maps to
/// an `NSVisualEffectView.Material`; the macOS 26 glass backdrop ignores it.
enum BackdropMaterial: String, CaseIterable {
    case hud
    case sidebar
    case menu
    case popover
    case fullScreen
    case underWindow

    var displayName: String {
        switch self {
        case .hud: return String(localized: "HUD (default)")
        case .sidebar: return String(localized: "Sidebar")
        case .menu: return String(localized: "Menu")
        case .popover: return String(localized: "Popover")
        case .fullScreen: return String(localized: "Full Screen")
        case .underWindow: return String(localized: "Under Window")
        }
    }

    var material: NSVisualEffectView.Material {
        switch self {
        case .hud: return .hudWindow
        case .sidebar: return .sidebar
        case .menu: return .menu
        case .popover: return .popover
        case .fullScreen: return .fullScreenUI
        case .underWindow: return .underWindowBackground
        }
    }
}

/// Order the switcher lists apps/windows in. `.mru` is the default (most
/// recently used first, the classic ⌘Tab behavior); the others give a stable
/// ordering that doesn't reshuffle as you switch. Read off the main actor by
/// `CatalogFilter`, so the raw value is stored in the shared UserDefaults key.
enum SwitcherSortOrder: String, CaseIterable {
    /// Most-recently-used first, with the usual status buckets. Default.
    case mru
    /// Flat cross-app window recency — each window ordered by when it was last
    /// focused, regardless of app, so windows of different apps interleave.
    /// Sorted in `SwitcherController` from `WindowMRUTracker`'s global order.
    case mruWindows
    /// Apps A→Z by name; an app's windows stay grouped together.
    case alphabetical
    /// By launch order — oldest running process first.
    case launchOrder

    var displayName: String {
        switch self {
        case .mru: return String(localized: "Most recent")
        case .mruWindows: return String(localized: "Most recent (windows)")
        case .alphabetical: return String(localized: "Alphabetical")
        case .launchOrder: return String(localized: "Launch order")
        }
    }
}

/// The subset of windows a scoped custom shortcut opens the switcher onto.
/// Each user-defined scoped shortcut (Shortcuts settings) carries one of these;
/// triggering it opens the switcher already filtered to that subset instead of
/// the full app list. Raw values are persisted, so don't rename cases.
enum SwitchScope: String, CaseIterable {
    /// Every open window of every app, flat (one row per window), across Spaces.
    case allAppsAllSpaces
    /// Every app's windows, but only those on the Space you're viewing.
    case allAppsCurrentSpace
    /// Just the windows of the app that was frontmost when you triggered it.
    case currentAppWindows
    /// Only minimized windows, from every app.
    case minimizedOnly

    var displayName: String {
        switch self {
        case .allAppsAllSpaces: return String(localized: "All windows")
        case .allAppsCurrentSpace: return String(localized: "Windows on this Space")
        case .currentAppWindows: return String(localized: "Current app's windows")
        case .minimizedOnly: return String(localized: "Minimized windows")
        }
    }
}

extension NSColor {
    /// Parses `#RRGGBB` / `RRGGBB` (and the 8-digit `#RRGGBBAA` form). Returns
    /// `nil` for malformed input so callers can fall back to a default.
    convenience init?(hexString: String) {
        var hex = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6 || hex.count == 8,
              let value = UInt64(hex, radix: 16) else { return nil }
        let r, g, b, a: CGFloat
        if hex.count == 8 {
            r = CGFloat((value >> 24) & 0xFF) / 255
            g = CGFloat((value >> 16) & 0xFF) / 255
            b = CGFloat((value >> 8) & 0xFF) / 255
            a = CGFloat(value & 0xFF) / 255
        } else {
            r = CGFloat((value >> 16) & 0xFF) / 255
            g = CGFloat((value >> 8) & 0xFF) / 255
            b = CGFloat(value & 0xFF) / 255
            a = 1
        }
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }

    /// `#RRGGBB` string in the sRGB space; nil if the color can't be converted.
    var hexString: String? {
        guard let rgb = usingColorSpace(.sRGB) else { return nil }
        let r = Int(round(rgb.redComponent * 255))
        let g = Int(round(rgb.greenComponent * 255))
        let b = Int(round(rgb.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

/// What a three-finger horizontal trackpad swipe does (when the experimental
/// swipe trigger is enabled).
enum SwipeMode: String, CaseIterable {
    /// Open the switcher and scrub through apps (the original behavior).
    case openSwitcher
    /// Switch to the Space on the left/right, one per swipe step.
    case switchSpaces
    /// Flip to the previously-used app — one swipe acts like a quick ⌘Tab
    /// tap-and-release. Repeated swipes bounce between the two most recent apps.
    case quickSwitch

    var displayName: String {
        switch self {
        case .openSwitcher: return String(localized: "Open switcher")
        case .switchSpaces: return String(localized: "Switch Spaces")
        case .quickSwitch: return String(localized: "Quick switch (last 2 apps)")
        }
    }
}

/// Overall size multiplier applied to the switcher panel (icons, text, spacing).
enum PanelSize: String, CaseIterable {
    case small
    case standard
    case large

    // Scale remap (2026-05-28): old Small was too tight; the new Small is
    // what used to be Default, Medium is what used to be Large, and Large is
    // a genuinely big tile. Raw values stay the same so persisted prefs
    // still parse — users transparently shift up one notch on first launch.
    var scale: CGFloat {
        switch self {
        case .small: return 1.0
        case .standard: return 1.2
        case .large: return 1.5
        }
    }

    var displayName: String {
        switch self {
        case .small: return String(localized: "Small")
        case .standard: return String(localized: "Medium")
        case .large: return String(localized: "Large")
        }
    }
}

/// Per-app override for whether the app's windows appear in the switcher.
/// Lives on an `AppException`; an app with no exception uses the global
/// Contents toggles unchanged.
enum HideWindowsMode: String, CaseIterable, Sendable {
    /// The exception adds no hiding — the global Contents toggles still apply.
    /// (Default for a freshly added exception.)
    case dontHide
    /// Always hide this app from the switcher entirely (the old "Excluded apps").
    case always
    /// Hide this app only while it has no open windows (suppress its windowless
    /// row) regardless of the global "show apps without windows" toggle.
    case whenNoWindows

    var displayName: String {
        switch self {
        case .dontHide: return String(localized: "Don't hide")
        case .always: return String(localized: "Always")
        case .whenNoWindows: return String(localized: "When no open windows")
        }
    }
}

/// Per-app override for whether the switcher trigger (⌘Tab / ⌘`) is suppressed
/// while this app is frontmost, letting the chord pass straight through to the
/// app (e.g. a VM / remote-desktop window that wants its own ⌘Tab).
enum IgnoreShortcutsMode: String, CaseIterable, Sendable {
    /// The switcher trigger always works. (Default.)
    case never
    /// Pass the trigger chord through whenever this app is frontmost.
    case always
    /// Pass the trigger chord through only when this app is frontmost and its
    /// focused window is full screen.
    case whenFullscreen

    var displayName: String {
        switch self {
        case .never: return String(localized: "Never")
        case .always: return String(localized: "Always")
        case .whenFullscreen: return String(localized: "When fullscreen")
        }
    }
}

/// A per-app entry in the switcher's Exceptions list, identified by bundle ID.
/// Carries the hide-windows and ignore-shortcuts overrides shown in the
/// Exceptions editor. Persisted as a `[String: String]` dictionary so both the
/// main-actor `Preferences` and the off-main `CatalogFilter` can read it.
struct AppException: Equatable, Sendable {
    var bundleID: String
    var hide: HideWindowsMode
    var ignore: IgnoreShortcutsMode

    init(bundleID: String, hide: HideWindowsMode = .dontHide, ignore: IgnoreShortcutsMode = .never) {
        self.bundleID = bundleID
        self.hide = hide
        self.ignore = ignore
    }

    /// Plist-friendly representation for UserDefaults.
    var dictionary: [String: String] {
        ["bundleID": bundleID, "hide": hide.rawValue, "ignore": ignore.rawValue]
    }

    /// Parse one stored dictionary. Missing/unknown modes fall back to the
    /// neutral default so a half-written entry never silently drops the app.
    init?(dictionary: [String: String]) {
        guard let bid = dictionary["bundleID"], !bid.isEmpty else { return nil }
        self.bundleID = bid
        self.hide = dictionary["hide"].flatMap(HideWindowsMode.init) ?? .dontHide
        self.ignore = dictionary["ignore"].flatMap(IgnoreShortcutsMode.init) ?? .never
    }
}

@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    // Trigger keys are stored by the BetterShortcuts package
    // (see BetterShortcuts.Name.switchApps / .switchWindows), not here.

    /// Seeded as a first-run App rule (show only with open windows).
    static let finderBundleID = "com.apple.finder"

    static let defaultRevealDelayMs = 100
    static let revealDelayRange: ClosedRange<Int> = 40...500

    /// How long a partial letter-jump prefix survives before it expires and the
    /// switcher returns to its pre-typing order. Default 1000ms.
    static let defaultLetterChainTimeoutMs = 1000
    static let letterChainTimeoutRange: ClosedRange<Int> = 200...3000

    static let defaultSwipeSensitivity = 5
    static let swipeSensitivityRange: ClosedRange<Int> = 1...10

    static let panelOpacityRange: ClosedRange<Int> = 30...100
    /// `0` means "automatic" (track the size-derived metric); above that the
    /// user pins an explicit radius in points.
    static let panelCornerRadiusRange: ClosedRange<Int> = 0...40

    /// Grid layout column cap. `0` = automatic (width-driven); above that the
    /// user pins an explicit count. Bounded so a hand-edited/corrupted import
    /// can't land a negative or absurd value in the live pref.
    static let gridMaxColumnsRange: ClosedRange<Int> = 0...12
    /// Upper bound on recently-closed entries surfaced in search. `0` disables.
    static let recentlyClosedLimitRange: ClosedRange<Int> = 0...50

    /// Number of direct-activation hotkey slots. Each slot binds a recorded
    /// shortcut (stored by BetterShortcuts) to a target app bundle ID.
    static let directActivationSlotCount = 9

    /// Number of scoped-switch shortcut slots. Each slot binds a recorded
    /// shortcut to a `SwitchScope` — triggering it opens the switcher already
    /// filtered to that subset (all windows / current Space / current app /
    /// minimized).
    static let scopedShortcutSlotCount = 3

    // Internal (not private): `CatalogFilter` reads the catalog-related keys
    // directly from `UserDefaults` off the main actor, so the key strings must
    // be shared rather than duplicated.
    enum Keys {
        static let switcherLayoutMode = "Switcher.layoutMode"
        static let sortOrder = "Switcher.sortOrder"
        static let revealDelayMs = "Switcher.revealDelayMs"
        static let letterChainTimeoutMs = "Switcher.letterChainTimeoutMs"
        static let panelSize = "Switcher.panelSize"
        static let gridMaxColumns = "Switcher.gridMaxColumns"
        static let appExceptions = "Switcher.appExceptions"
        /// Pre-Exceptions key: a plain bundle-ID array of always-hidden apps.
        /// Read once at launch and folded into `appExceptions` (hide = .always).
        static let legacyExcludedBundleIDs = "Switcher.excludedBundleIDs"
        static let pinnedBundleIDs = "Switcher.pinnedBundleIDs"
        /// Bundle IDs the "Hide all windows" shortcut leaves visible.
        static let hideAllExcludedBundleIDs = "Switcher.hideAllExcludedBundleIDs"
        static let showMinimizedWindows = "Switcher.showMinimizedWindows"
        static let showHiddenApps = "Switcher.showHiddenApps"
        static let showWindowlessApps = "Switcher.showWindowlessApps"
        static let applicationsOnly = "Switcher.applicationsOnly"
        static let fuzzySearchEnabled = "Switcher.fuzzySearchEnabled"
        static let letterHintsEnabled = "Switcher.letterHintsEnabled"
        static let searchDismissMode = "Switcher.searchDismissMode"
        static let searchIncludesLaunchableApps = "Switcher.searchIncludesLaunchableApps"
        static let showRecentlyClosed = "Switcher.showRecentlyClosed"
        static let recentlyClosedLimit = "Switcher.recentlyClosedLimit"
        static let hapticOnCommit = "Switcher.hapticOnCommit"
        static let soundOnCommit = "Switcher.soundOnCommit"
        static let accentChoice = "Switcher.accentChoice"
        static let hideMenuBarIcon = "Switcher.hideMenuBarIcon"
        static let experimentalSwipeTrigger = "Switcher.experimentalSwipeTrigger"
        static let swipeMode = "Switcher.swipeMode"
        static let swipeReverseDirection = "Switcher.swipeReverseDirection"
        static let swipeCommitOnRelease = "Switcher.swipeCommitOnRelease"
        static let swipeSensitivity = "Switcher.swipeSensitivity"
        static let scrollToSwitch = "Switcher.scrollToSwitch"
        static let scrollReverseDirection = "Switcher.scrollReverseDirection"
        static let clickOutsideToDismiss = "Switcher.clickOutsideToDismiss"
        static let cycleTileWidths = "Switcher.cycleTileWidths"
        static let experimentalInstantSpaceSwitch = "Switcher.experimentalInstantSpaceSwitch"
        /// `\` tab drill-in (peek the highlighted window's tabs in a strip).
        /// Graduated out of the Experimental tab in 26.x and flipped to default
        /// ON (intentional — the `\` peek is now the standard way to reach tabs).
        /// The pre-graduation key `Switcher.experimentalTabDrillIn` defaulted OFF
        /// and is deliberately not migrated: everyone, including users who never
        /// touched the old toggle, gets the peek on by default now.
        static let tabDrillEnabled = "Switcher.tabDrillEnabled"
        /// Expand native-system-tab windows (Finder, Terminal, TextEdit, …) into
        /// one switcher row per tab instead of a single collapsed window row.
        /// Default off — the collapsed row + `\` peek is the default.
        static let expandTabsAsWindows = "Switcher.expandTabsAsWindows"
        /// Expand a browser window (Safari/Chromium) into one switcher row per
        /// tab, surfaced inline among the other windows. Default off — the
        /// collapsed row + `\` peek is the default. Browser tabs aren't separate
        /// NSWindows, so the rows are built from an async Apple Events tab scan.
        static let expandBrowserTabsAsWindows = "Switcher.expandBrowserTabsAsWindows"
        static let showUnreadBadges = "Switcher.showUnreadBadges"
        /// Pre-graduation key (badges used to live behind the Experimental tab);
        /// read once at launch to carry a user's earlier choice over to the new key.
        static let legacyUnreadBadges = "Switcher.experimentalUnreadBadges"
        static let showWindowTitleLabel = "Switcher.showWindowTitleLabel"
        static let showApplicationNames = "Switcher.showApplicationNames"
        static let panelOpacity = "Switcher.panelOpacity"
        static let panelCornerRadius = "Switcher.panelCornerRadius"
        static let customAccentHex = "Switcher.customAccentHex"
        static let backdropMaterial = "Switcher.backdropMaterial"
        static let currentSpaceOnly = "Switcher.currentSpaceOnly"
        static let directActivationBindings = "Switcher.directActivationBindings"
        static let scopedShortcutScopes = "Switcher.scopedShortcutScopes"
        static let mouseHoverSelectionEnabled = "Switcher.mouseHoverSelectionEnabled"
        static let mouseClickSelectionEnabled = "Switcher.mouseClickSelectionEnabled"
        static let hoverActionsEnabled = "Switcher.hoverActionsEnabled"
        static let hoverShowClose = "Switcher.hoverShowClose"
        static let hoverShowMinimize = "Switcher.hoverShowMinimize"
        static let hoverShowMaximize = "Switcher.hoverShowMaximize"
        static let hoverShowHide = "Switcher.hoverShowHide"
        static let hoverShowQuit = "Switcher.hoverShowQuit"
        static let hoverShowForceQuit = "Switcher.hoverShowForceQuit"
        static let hideFromScreenSharing = "Switcher.hideFromScreenSharing"
        static let vimNavigationEnabled = "Switcher.vimNavigationEnabled"
        static let switcherDisplayMode = "Switcher.displayMode"
    }

    @Published var switcherLayoutMode: SwitcherLayoutMode {
        didSet {
            guard oldValue != switcherLayoutMode else { return }
            UserDefaults.standard.set(switcherLayoutMode.rawValue, forKey: Keys.switcherLayoutMode)
        }
    }

    /// Which monitor the switcher panel appears on (#22). Default `.mouseCursor`
    /// preserves the pre-#22 behavior for existing users.
    @Published var switcherDisplayMode: SwitcherDisplayMode {
        didSet {
            guard oldValue != switcherDisplayMode else { return }
            UserDefaults.standard.set(switcherDisplayMode.rawValue, forKey: Keys.switcherDisplayMode)
        }
    }

    /// Order apps/windows appear in the switcher (most-recent / alphabetical /
    /// launch order). Read off-main by `CatalogFilter`, so the key is shared.
    @Published var sortOrder: SwitcherSortOrder {
        didSet {
            guard oldValue != sortOrder else { return }
            UserDefaults.standard.set(sortOrder.rawValue, forKey: Keys.sortOrder)
        }
    }

    @Published var revealDelayMs: Int {
        didSet {
            let clamped = Self.clampDelay(revealDelayMs)
            if clamped != revealDelayMs {
                revealDelayMs = clamped
                return
            }
            guard oldValue != revealDelayMs else { return }
            UserDefaults.standard.set(revealDelayMs, forKey: Keys.revealDelayMs)
        }
    }

    /// How long a typed letter-jump prefix stays active before it expires. On
    /// expiry the switcher drops the prefix, clears the highlight, and restores
    /// the order rows had before typing. Read live so a change applies to the
    /// next keystroke without restart.
    @Published var letterChainTimeoutMs: Int {
        didSet {
            let clamped = Self.clampLetterChainTimeout(letterChainTimeoutMs)
            if clamped != letterChainTimeoutMs {
                letterChainTimeoutMs = clamped
                return
            }
            guard oldValue != letterChainTimeoutMs else { return }
            UserDefaults.standard.set(letterChainTimeoutMs, forKey: Keys.letterChainTimeoutMs)
        }
    }

    @Published var panelSize: PanelSize {
        didSet {
            guard oldValue != panelSize else { return }
            UserDefaults.standard.set(panelSize.rawValue, forKey: Keys.panelSize)
        }
    }

    /// Maximum columns in Grid layout. `0` = automatic (width-driven).
    @Published var gridMaxColumns: Int {
        didSet {
            let clamped = Self.clampGridColumns(gridMaxColumns)
            if clamped != gridMaxColumns {
                gridMaxColumns = clamped
                return
            }
            guard oldValue != gridMaxColumns else { return }
            UserDefaults.standard.set(gridMaxColumns, forKey: Keys.gridMaxColumns)
        }
    }

    /// Per-app overrides shown in the Exceptions editor (hide-windows +
    /// ignore-shortcuts). Order is the editor's list order.
    @Published var appExceptions: [AppException] {
        didSet {
            guard oldValue != appExceptions else { return }
            UserDefaults.standard.set(appExceptions.map(\.dictionary), forKey: Keys.appExceptions)
        }
    }

    /// The ignore-shortcuts mode for `bundleID`, or `.never` when the app has no
    /// exception. Used to decide whether to let the trigger chord pass through.
    func ignoreMode(for bundleID: String) -> IgnoreShortcutsMode {
        appExceptions.first { $0.bundleID == bundleID }?.ignore ?? .never
    }

    /// Bundle identifiers forced to the front of the switcher. Order is the
    /// pin order (first pinned shows first), independent of MRU.
    @Published var pinnedBundleIDs: [String] {
        didSet {
            guard oldValue != pinnedBundleIDs else { return }
            UserDefaults.standard.set(pinnedBundleIDs, forKey: Keys.pinnedBundleIDs)
        }
    }

    /// Bundle identifiers the "Hide all windows" shortcut skips, so chosen apps
    /// stay visible while everything else is hidden. Empty by default (hide-all
    /// covers every app, Finder included — add Finder here to keep it visible as
    /// the desktop owner; see `Activator.hideAllApps`).
    @Published var hideAllExcludedBundleIDs: [String] {
        didSet {
            guard oldValue != hideAllExcludedBundleIDs else { return }
            UserDefaults.standard.set(hideAllExcludedBundleIDs, forKey: Keys.hideAllExcludedBundleIDs)
        }
    }

    /// Include minimized windows in the switcher. Default `true` (matches the
    /// long-standing behavior of listing them, just sorted lower).
    @Published var showMinimizedWindows: Bool {
        didSet {
            guard oldValue != showMinimizedWindows else { return }
            UserDefaults.standard.set(showMinimizedWindows, forKey: Keys.showMinimizedWindows)
        }
    }

    /// Include hidden apps (Cmd+H) in the switcher. Default `true`.
    @Published var showHiddenApps: Bool {
        didSet {
            guard oldValue != showHiddenApps else { return }
            UserDefaults.standard.set(showHiddenApps, forKey: Keys.showHiddenApps)
        }
    }

    /// Include running apps that have no open windows. Default `true`.
    @Published var showWindowlessApps: Bool {
        didSet {
            guard oldValue != showWindowlessApps else { return }
            UserDefaults.standard.set(showWindowlessApps, forKey: Keys.showWindowlessApps)
        }
    }

    /// Collapse the switcher to one row per application instead of one row per
    /// window — classic macOS ⌘Tab. The representative row is the app's frontmost
    /// window (so selecting it activates the app); native/browser tab expansion is
    /// suppressed while on. Default `false` (per-window). Read directly off
    /// `UserDefaults` by `CatalogFilter` on the catalog thread, so the key string
    /// is the contract.
    @Published var applicationsOnly: Bool {
        didSet {
            guard oldValue != applicationsOnly else { return }
            UserDefaults.standard.set(applicationsOnly, forKey: Keys.applicationsOnly)
        }
    }

    /// Enable the type-to-filter fuzzy search mode (entered with `/`).
    @Published var fuzzySearchEnabled: Bool {
        didSet {
            guard oldValue != fuzzySearchEnabled else { return }
            UserDefaults.standard.set(fuzzySearchEnabled, forKey: Keys.fuzzySearchEnabled)
        }
    }

    /// Show per-window letter hints and let a typed letter jump to and select
    /// that window. Default on. When off, the hint letters are hidden and typing
    /// a letter does nothing (so letters stay free for type-to-filter search).
    @Published var letterHintsEnabled: Bool {
        didSet {
            guard oldValue != letterHintsEnabled else { return }
            UserDefaults.standard.set(letterHintsEnabled, forKey: Keys.letterHintsEnabled)
        }
    }

    /// Whether activating search detaches the switcher from the held modifier.
    @Published var searchDismissMode: SearchDismissMode {
        didSet {
            guard oldValue != searchDismissMode else { return }
            UserDefaults.standard.set(searchDismissMode.rawValue, forKey: Keys.searchDismissMode)
        }
    }

    /// While searching, also offer matching apps that aren't running yet so they
    /// can be launched straight from the switcher. Default on.
    @Published var searchIncludesLaunchableApps: Bool {
        didSet {
            guard oldValue != searchIncludesLaunchableApps else { return }
            UserDefaults.standard.set(searchIncludesLaunchableApps, forKey: Keys.searchIncludesLaunchableApps)
        }
    }

    /// Show recently closed windows/apps in the switcher (at the end of the
    /// list, and matched while searching) so they can be reopened. Default off
    /// so it doesn't change the default switcher list until opted into.
    @Published var showRecentlyClosed: Bool {
        didSet {
            guard oldValue != showRecentlyClosed else { return }
            UserDefaults.standard.set(showRecentlyClosed, forKey: Keys.showRecentlyClosed)
        }
    }

    /// How many recently closed entries to surface in search at most. Default 5.
    @Published var recentlyClosedLimit: Int {
        didSet {
            let clamped = Self.clampRecentlyClosedLimit(recentlyClosedLimit)
            if clamped != recentlyClosedLimit {
                recentlyClosedLimit = clamped
                return
            }
            guard oldValue != recentlyClosedLimit else { return }
            UserDefaults.standard.set(recentlyClosedLimit, forKey: Keys.recentlyClosedLimit)
        }
    }

    /// Fire a trackpad haptic tap when a selection is committed. Only Force
    /// Touch trackpads produce a sensation; elsewhere it's a no-op. Default off.
    @Published var hapticOnCommit: Bool {
        didSet {
            guard oldValue != hapticOnCommit else { return }
            UserDefaults.standard.set(hapticOnCommit, forKey: Keys.hapticOnCommit)
        }
    }

    /// Play a subtle click sound when a selection is committed. Default off.
    @Published var soundOnCommit: Bool {
        didSet {
            guard oldValue != soundOnCommit else { return }
            UserDefaults.standard.set(soundOnCommit, forKey: Keys.soundOnCommit)
        }
    }

    /// Accent color for the selection highlight and letter-jump prefix.
    @Published var accentChoice: SwitcherAccent {
        didSet {
            guard oldValue != accentChoice else { return }
            UserDefaults.standard.set(accentChoice.rawValue, forKey: Keys.accentChoice)
        }
    }

    /// Hide the menu bar (status) icon. With it hidden there's no in-menu way
    /// to reach Settings, so `AppDelegate` reopens this window when the app is
    /// launched again (e.g. from Spotlight). Default off.
    @Published var hideMenuBarIcon: Bool {
        didSet {
            guard oldValue != hideMenuBarIcon else { return }
            UserDefaults.standard.set(hideMenuBarIcon, forKey: Keys.hideMenuBarIcon)
        }
    }

    /// Experimental: open the switcher with a horizontal three-finger trackpad
    /// swipe. Relies on global swipe events the system may also consume, so it's
    /// best-effort and off by default. [[experimental-features]]
    @Published var experimentalSwipeTrigger: Bool {
        didSet {
            guard oldValue != experimentalSwipeTrigger else { return }
            UserDefaults.standard.set(experimentalSwipeTrigger, forKey: Keys.experimentalSwipeTrigger)
        }
    }

    /// What the three-finger swipe does: open the switcher (default) or switch
    /// Spaces left/right. Only meaningful while `experimentalSwipeTrigger` is on.
    @Published var swipeMode: SwipeMode {
        didSet {
            guard oldValue != swipeMode else { return }
            UserDefaults.standard.set(swipeMode.rawValue, forKey: Keys.swipeMode)
        }
    }

    /// When false (default), sliding fingers right moves the selection right;
    /// when true the axis is flipped. Only affects the three-finger swipe.
    @Published var swipeReverseDirection: Bool {
        didSet {
            guard oldValue != swipeReverseDirection else { return }
            UserDefaults.standard.set(swipeReverseDirection, forKey: Keys.swipeReverseDirection)
        }
    }

    /// When true, lifting all fingers off the trackpad commits the three-finger
    /// swipe's current selection. When false (default), the switcher stays open
    /// so you commit with a click or Return.
    @Published var swipeCommitOnRelease: Bool {
        didSet {
            guard oldValue != swipeCommitOnRelease else { return }
            UserDefaults.standard.set(swipeCommitOnRelease, forKey: Keys.swipeCommitOnRelease)
        }
    }

    /// Step the open switcher's selection with a mouse scroll wheel. Off for
    /// trackpads — a continuous (precise) scroll is ignored, so trackpad users
    /// keep the three-finger swipe and two-finger scrolling stays free. Only
    /// acts while the switcher is already showing; never opens it from idle.
    @Published var scrollToSwitch: Bool {
        didSet {
            guard oldValue != scrollToSwitch else { return }
            UserDefaults.standard.set(scrollToSwitch, forKey: Keys.scrollToSwitch)
        }
    }

    /// When false (default), scrolling down advances the selection forward; when
    /// true the axis is flipped. Only affects mouse scroll-to-switch.
    @Published var scrollReverseDirection: Bool {
        didSet {
            guard oldValue != scrollReverseDirection else { return }
            UserDefaults.standard.set(scrollReverseDirection, forKey: Keys.scrollReverseDirection)
        }
    }

    /// Dismiss the switcher when the user clicks outside the panel, leaving the
    /// currently focused window untouched — like a macOS context menu or
    /// Spotlight. The click is swallowed so it doesn't also activate whatever
    /// was under the pointer. Default on.
    @Published var clickOutsideToDismiss: Bool {
        didSet {
            guard oldValue != clickOutsideToDismiss else { return }
            UserDefaults.standard.set(clickOutsideToDismiss, forKey: Keys.clickOutsideToDismiss)
        }
    }

    /// Treat the vim motion keys h/j/k/l as navigation while the switcher is
    /// open: h/l step horizontally (grid columns or list columns), j/k step
    /// vertically. Mirrors the bare arrow keys exactly — no modifier, opt-in
    /// because h overlaps the default "hide app" panel binding and j/k overlap
    /// letter-jump. Default off; ignored while search mode is active so a
    /// typed query can still contain those letters.
    @Published var vimNavigationEnabled: Bool {
        didSet {
            guard oldValue != vimNavigationEnabled else { return }
            UserDefaults.standard.set(vimNavigationEnabled, forKey: Keys.vimNavigationEnabled)
        }
    }

    /// Move the switcher selection to the row under the pointer. Default on.
    /// Off keeps the keyboard selection put so the mouse can't change the
    /// highlighted row by accident (issue #47). Hover-action buttons still
    /// appear under the pointer when `hoverActionsEnabled` is on.
    @Published var mouseHoverSelectionEnabled: Bool {
        didSet {
            guard oldValue != mouseHoverSelectionEnabled else { return }
            UserDefaults.standard.set(mouseHoverSelectionEnabled, forKey: Keys.mouseHoverSelectionEnabled)
        }
    }

    /// Commit the switcher selection when a row is clicked. Default on. Off
    /// ignores clicks inside the panel so the mouse can't pick a window by
    /// accident (issue #47); the tab strip and hover-action buttons still work,
    /// and click-outside-to-dismiss is unaffected.
    @Published var mouseClickSelectionEnabled: Bool {
        didSet {
            guard oldValue != mouseClickSelectionEnabled else { return }
            UserDefaults.standard.set(mouseClickSelectionEnabled, forKey: Keys.mouseClickSelectionEnabled)
        }
    }

    /// When on, repeatedly pressing the tile-left / tile-right window-management
    /// shortcut cycles the window through half → two-thirds → one-third width on
    /// that side instead of always snapping to half. Default off.
    @Published var cycleTileWidths: Bool {
        didSet {
            guard oldValue != cycleTileWidths else { return }
            UserDefaults.standard.set(cycleTileWidths, forKey: Keys.cycleTileWidths)
        }
    }

    /// How far fingers must slide to advance one app in the three-finger swipe,
    /// as a 1–10 level. Higher = more sensitive (shorter slide per app).
    @Published var swipeSensitivity: Int {
        didSet {
            let clamped = Self.clampSwipeSensitivity(swipeSensitivity)
            if clamped != swipeSensitivity {
                swipeSensitivity = clamped
                return
            }
            guard oldValue != swipeSensitivity else { return }
            UserDefaults.standard.set(swipeSensitivity, forKey: Keys.swipeSensitivity)
        }
    }

    /// When true, committing to an app on another Space or in full screen jumps
    /// there instantly with no slide animation (private SkyLight Space APIs).
    /// Off by default — fragile, undocumented APIs.
    @Published var experimentalInstantSpaceSwitch: Bool {
        didSet {
            guard oldValue != experimentalInstantSpaceSwitch else { return }
            UserDefaults.standard.set(experimentalInstantSpaceSwitch, forKey: Keys.experimentalInstantSpaceSwitch)
        }
    }

    /// Tab drill-in: pressing `\` on a row whose window has a tab group reveals
    /// a horizontal tab strip beneath the switcher so a specific tab can be
    /// picked. Native AX `AXTabs` for Finder/Terminal/…; AppleScript for
    /// Safari/Chromium. Default on (graduated out of Experimental).
    @Published var tabDrillEnabled: Bool {
        didSet {
            guard oldValue != tabDrillEnabled else { return }
            UserDefaults.standard.set(tabDrillEnabled, forKey: Keys.tabDrillEnabled)
        }
    }

    /// Show each native-system-tab window's tabs as their own switcher rows
    /// (one entry per tab) instead of a single collapsed window row. Applies to
    /// apps that expose AppKit `AXTabs` (Finder, Terminal, TextEdit, Ghostty,
    /// …); browsers keep a single row and the `\` peek. Default off. Read
    /// off-main by `WindowEnumerator`, so the key is shared.
    @Published var expandTabsAsWindows: Bool {
        didSet {
            guard oldValue != expandTabsAsWindows else { return }
            UserDefaults.standard.set(expandTabsAsWindows, forKey: Keys.expandTabsAsWindows)
        }
    }

    /// Show each browser window's tabs (Safari, Chrome, Arc, Brave, Edge, …) as
    /// their own switcher rows, inline among the other windows, instead of one
    /// collapsed window row. Browser tabs aren't separate NSWindows — the rows
    /// are filled in by an off-main Apple Events scan after the panel opens.
    /// Default off; the collapsed row + `\` peek stays the default.
    @Published var expandBrowserTabsAsWindows: Bool {
        didSet {
            guard oldValue != expandBrowserTabsAsWindows else { return }
            UserDefaults.standard.set(expandBrowserTabsAsWindows, forKey: Keys.expandBrowserTabsAsWindows)
        }
    }

    /// Show app unread-badge counts (e.g. Mail's unread mail) on switcher rows,
    /// read from the Dock via the Accessibility API. On by default.
    @Published var showUnreadBadges: Bool {
        didSet {
            guard oldValue != showUnreadBadges else { return }
            UserDefaults.standard.set(showUnreadBadges, forKey: Keys.showUnreadBadges)
        }
    }

    /// Show the per-window title label under the icon in Grid and Previews
    /// layouts. Default on. (No effect on the List layout, which always shows it.)
    @Published var showWindowTitleLabel: Bool {
        didSet {
            guard oldValue != showWindowTitleLabel else { return }
            UserDefaults.standard.set(showWindowTitleLabel, forKey: Keys.showWindowTitleLabel)
        }
    }

    /// Show the application name in every switcher layout (List right column,
    /// Grid name-under-icon, and any app-name fallback in Previews). Default on.
    /// Off = strict icon-only.
    @Published var showApplicationNames: Bool {
        didSet {
            guard oldValue != showApplicationNames else { return }
            UserDefaults.standard.set(showApplicationNames, forKey: Keys.showApplicationNames)
        }
    }

    /// Panel opacity as a 30–100 percentage. Default 100 (fully opaque).
    @Published var panelOpacity: Int {
        didSet {
            let clamped = Self.clampOpacity(panelOpacity)
            if clamped != panelOpacity { panelOpacity = clamped; return }
            guard oldValue != panelOpacity else { return }
            UserDefaults.standard.set(panelOpacity, forKey: Keys.panelOpacity)
        }
    }

    /// Explicit panel corner radius in points; `0` = automatic (size-derived).
    @Published var panelCornerRadius: Int {
        didSet {
            let clamped = Self.clampCornerRadius(panelCornerRadius)
            if clamped != panelCornerRadius { panelCornerRadius = clamped; return }
            guard oldValue != panelCornerRadius else { return }
            UserDefaults.standard.set(panelCornerRadius, forKey: Keys.panelCornerRadius)
        }
    }

    /// `#RRGGBB` used when `accentChoice == .custom`. `nil` until the user picks one.
    @Published var customAccentHex: String? {
        didSet {
            guard oldValue != customAccentHex else { return }
            UserDefaults.standard.set(customAccentHex, forKey: Keys.customAccentHex)
        }
    }

    /// Background blur material for the panel (NSVisualEffectView fallback path).
    @Published var backdropMaterial: BackdropMaterial {
        didSet {
            guard oldValue != backdropMaterial else { return }
            UserDefaults.standard.set(backdropMaterial.rawValue, forKey: Keys.backdropMaterial)
        }
    }

    /// Show only windows that live on the currently active Space. Default off.
    /// Reads window Space membership via the same private APIs as instant Space
    /// switching; degrades to showing everything when those are unavailable.
    @Published var currentSpaceOnly: Bool {
        didSet {
            guard oldValue != currentSpaceOnly else { return }
            UserDefaults.standard.set(currentSpaceOnly, forKey: Keys.currentSpaceOnly)
        }
    }

    /// Target app bundle IDs for the direct-activation hotkey slots. Index maps
    /// to the slot number (0 = slot 1). An empty string means the slot is unset.
    /// Always normalized to `directActivationSlotCount` entries.
    @Published var directActivationBindings: [String] {
        didSet {
            let normalized = Self.normalizeBindings(directActivationBindings)
            if normalized != directActivationBindings { directActivationBindings = normalized; return }
            guard oldValue != directActivationBindings else { return }
            UserDefaults.standard.set(directActivationBindings, forKey: Keys.directActivationBindings)
        }
    }

    /// Scope for each scoped-switch shortcut slot, as `SwitchScope` raw values.
    /// Index maps to the slot number. Always normalized to
    /// `scopedShortcutSlotCount` entries; an unset slot defaults to `.allAppsAllSpaces`.
    /// The slot is only *live* when the user has recorded a shortcut for it
    /// (BetterShortcuts stores that separately); the scope just says what the
    /// shortcut shows.
    @Published var scopedShortcutScopes: [SwitchScope] {
        didSet {
            let normalized = Self.normalizeScopes(scopedShortcutScopes)
            if normalized != scopedShortcutScopes { scopedShortcutScopes = normalized; return }
            guard oldValue != scopedShortcutScopes else { return }
            UserDefaults.standard.set(scopedShortcutScopes.map(\.rawValue), forKey: Keys.scopedShortcutScopes)
        }
    }

    // In-panel action keys (#5) and window-management chords (#7) are
    // BetterShortcuts names now (`BetterShortcuts.Name.panelActionKeys` /
    // `.windowMgmt`); the package owns their recording + persistence.

    /// Master switch for the hover action buttons shown on each switcher row.
    /// Default off. Per-button visibility lives in `hoverShow*`.
    @Published var hoverActionsEnabled: Bool {
        didSet {
            guard oldValue != hoverActionsEnabled else { return }
            UserDefaults.standard.set(hoverActionsEnabled, forKey: Keys.hoverActionsEnabled)
        }
    }

    @Published var hoverShowClose: Bool {
        didSet {
            guard oldValue != hoverShowClose else { return }
            UserDefaults.standard.set(hoverShowClose, forKey: Keys.hoverShowClose)
        }
    }

    @Published var hoverShowMinimize: Bool {
        didSet {
            guard oldValue != hoverShowMinimize else { return }
            UserDefaults.standard.set(hoverShowMinimize, forKey: Keys.hoverShowMinimize)
        }
    }

    @Published var hoverShowMaximize: Bool {
        didSet {
            guard oldValue != hoverShowMaximize else { return }
            UserDefaults.standard.set(hoverShowMaximize, forKey: Keys.hoverShowMaximize)
        }
    }

    @Published var hoverShowHide: Bool {
        didSet {
            guard oldValue != hoverShowHide else { return }
            UserDefaults.standard.set(hoverShowHide, forKey: Keys.hoverShowHide)
        }
    }

    @Published var hoverShowQuit: Bool {
        didSet {
            guard oldValue != hoverShowQuit else { return }
            UserDefaults.standard.set(hoverShowQuit, forKey: Keys.hoverShowQuit)
        }
    }

    /// Force-quit button visibility — defaults off so the bar stays uncluttered;
    /// ⌘+⌥+Q is always available regardless of this toggle.
    @Published var hoverShowForceQuit: Bool {
        didSet {
            guard oldValue != hoverShowForceQuit else { return }
            UserDefaults.standard.set(hoverShowForceQuit, forKey: Keys.hoverShowForceQuit)
        }
    }

    /// Number of hover-action dots the bar will show, or 0 when the feature is
    /// off. The List layout reserves a column this wide when app names are hidden
    /// so the bar doesn't overlap the window title.
    var enabledHoverActionCount: Int {
        guard hoverActionsEnabled else { return 0 }
        var n = 0
        if hoverShowClose { n += 1 }
        if hoverShowMinimize { n += 1 }
        if hoverShowMaximize { n += 1 }
        if hoverShowHide { n += 1 }
        if hoverShowQuit { n += 1 }
        if hoverShowForceQuit { n += 1 }
        return n
    }

    /// Hide the switcher panel from screen recording / sharing capture
    /// (Zoom, Meet, Teams, QuickTime, ScreenCaptureKit). Default off.
    /// Requires macOS 14.6+ for `NSWindowSharingType.none` to be honored by
    /// modern capture APIs; on older systems the toggle is a no-op.
    @Published var hideFromScreenSharing: Bool {
        didSet {
            guard oldValue != hideFromScreenSharing else { return }
            UserDefaults.standard.set(hideFromScreenSharing, forKey: Keys.hideFromScreenSharing)
        }
    }

    /// Concrete accent color honoring the `.custom` choice (reads `customAccentHex`).
    var resolvedAccent: NSColor {
        if accentChoice == .custom, let hex = customAccentHex, let color = NSColor(hexString: hex) {
            return color
        }
        return accentChoice.resolved
    }

    static func clampDelay(_ value: Int) -> Int {
        min(revealDelayRange.upperBound, max(revealDelayRange.lowerBound, value))
    }

    static func clampLetterChainTimeout(_ value: Int) -> Int {
        min(letterChainTimeoutRange.upperBound, max(letterChainTimeoutRange.lowerBound, value))
    }

    static func clampSwipeSensitivity(_ value: Int) -> Int {
        min(swipeSensitivityRange.upperBound, max(swipeSensitivityRange.lowerBound, value))
    }

    static func clampOpacity(_ value: Int) -> Int {
        min(panelOpacityRange.upperBound, max(panelOpacityRange.lowerBound, value))
    }

    static func clampCornerRadius(_ value: Int) -> Int {
        min(panelCornerRadiusRange.upperBound, max(panelCornerRadiusRange.lowerBound, value))
    }

    static func clampGridColumns(_ value: Int) -> Int {
        min(gridMaxColumnsRange.upperBound, max(gridMaxColumnsRange.lowerBound, value))
    }

    static func clampRecentlyClosedLimit(_ value: Int) -> Int {
        min(recentlyClosedLimitRange.upperBound, max(recentlyClosedLimitRange.lowerBound, value))
    }

    /// Pads/truncates to exactly `directActivationSlotCount` entries.
    static func normalizeBindings(_ value: [String]) -> [String] {
        var out = Array(value.prefix(directActivationSlotCount))
        while out.count < directActivationSlotCount { out.append("") }
        return out
    }

    /// Pads/truncates to exactly `scopedShortcutSlotCount` entries, filling
    /// missing slots with the neutral `.allAppsAllSpaces` default.
    static func normalizeScopes(_ value: [SwitchScope]) -> [SwitchScope] {
        var out = Array(value.prefix(scopedShortcutSlotCount))
        while out.count < scopedShortcutSlotCount { out.append(.allAppsAllSpaces) }
        return out
    }

    /// Parse the stored `[String]` raw values into `[SwitchScope]`, normalized.
    static func loadScopes(_ raw: [String]?) -> [SwitchScope] {
        normalizeScopes((raw ?? []).map { SwitchScope(rawValue: $0) ?? .allAppsAllSpaces })
    }


    private init() {
        let defaults = UserDefaults.standard

        let layoutRaw = defaults.string(forKey: Keys.switcherLayoutMode)
        self.switcherLayoutMode = layoutRaw.flatMap(SwitcherLayoutMode.init(rawValue:)) ?? .gridView
        self.switcherDisplayMode = defaults.string(forKey: Keys.switcherDisplayMode)
            .flatMap(SwitcherDisplayMode.init(rawValue:)) ?? .mouseCursor

        let sortRaw = defaults.string(forKey: Keys.sortOrder)
        self.sortOrder = sortRaw.flatMap(SwitcherSortOrder.init(rawValue:)) ?? .mru

        let delay = defaults.object(forKey: Keys.revealDelayMs) as? Int ?? Self.defaultRevealDelayMs
        self.revealDelayMs = Self.clampDelay(delay)

        let letterTimeout = defaults.object(forKey: Keys.letterChainTimeoutMs) as? Int ?? Self.defaultLetterChainTimeoutMs
        self.letterChainTimeoutMs = Self.clampLetterChainTimeout(letterTimeout)

        let sizeRaw = defaults.string(forKey: Keys.panelSize)
        self.panelSize = sizeRaw.flatMap(PanelSize.init(rawValue:)) ?? .standard

        self.gridMaxColumns = defaults.object(forKey: Keys.gridMaxColumns) as? Int ?? 0

        // Exceptions: honor the new key if present, otherwise build a first-run
        // default — carry over the pre-Exceptions excluded-app list as hide=.always
        // entries, and seed Finder to "show only with open windows". Persisted
        // immediately because `CatalogFilter` reads the new key from UserDefaults
        // off-main and never sees the legacy key.
        if let stored = defaults.array(forKey: Keys.appExceptions) as? [[String: String]] {
            self.appExceptions = stored.compactMap(AppException.init(dictionary:))
        } else {
            var initial = (defaults.stringArray(forKey: Keys.legacyExcludedBundleIDs) ?? [])
                .map { AppException(bundleID: $0, hide: .always, ignore: .never) }
            if !initial.contains(where: { $0.bundleID == Self.finderBundleID }) {
                initial.append(AppException(bundleID: Self.finderBundleID, hide: .whenNoWindows, ignore: .never))
            }
            self.appExceptions = initial
            defaults.set(initial.map(\.dictionary), forKey: Keys.appExceptions)
        }
        self.pinnedBundleIDs = defaults.stringArray(forKey: Keys.pinnedBundleIDs) ?? []
        self.hideAllExcludedBundleIDs = defaults.stringArray(forKey: Keys.hideAllExcludedBundleIDs) ?? []
        self.showMinimizedWindows = defaults.object(forKey: Keys.showMinimizedWindows) as? Bool ?? true
        self.showHiddenApps = defaults.object(forKey: Keys.showHiddenApps) as? Bool ?? true
        self.showWindowlessApps = defaults.object(forKey: Keys.showWindowlessApps) as? Bool ?? true
        self.applicationsOnly = defaults.object(forKey: Keys.applicationsOnly) as? Bool ?? false
        self.fuzzySearchEnabled = defaults.object(forKey: Keys.fuzzySearchEnabled) as? Bool ?? true
        self.letterHintsEnabled = defaults.object(forKey: Keys.letterHintsEnabled) as? Bool ?? true

        let dismissRaw = defaults.string(forKey: Keys.searchDismissMode)
        self.searchDismissMode = dismissRaw.flatMap(SearchDismissMode.init(rawValue:)) ?? .holdModifier

        self.searchIncludesLaunchableApps = defaults.object(forKey: Keys.searchIncludesLaunchableApps) as? Bool ?? true
        self.showRecentlyClosed = defaults.object(forKey: Keys.showRecentlyClosed) as? Bool ?? false
        self.recentlyClosedLimit = defaults.object(forKey: Keys.recentlyClosedLimit) as? Int ?? 5

        self.hapticOnCommit = defaults.object(forKey: Keys.hapticOnCommit) as? Bool ?? false
        self.soundOnCommit = defaults.object(forKey: Keys.soundOnCommit) as? Bool ?? false

        let accentRaw = defaults.string(forKey: Keys.accentChoice)
        self.accentChoice = accentRaw.flatMap(SwitcherAccent.init(rawValue:)) ?? .system

        self.hideMenuBarIcon = defaults.object(forKey: Keys.hideMenuBarIcon) as? Bool ?? false

        self.experimentalSwipeTrigger = defaults.object(forKey: Keys.experimentalSwipeTrigger) as? Bool ?? false
        let swipeModeRaw = defaults.string(forKey: Keys.swipeMode)
        self.swipeMode = swipeModeRaw.flatMap(SwipeMode.init(rawValue:)) ?? .openSwitcher
        self.swipeReverseDirection = defaults.object(forKey: Keys.swipeReverseDirection) as? Bool ?? false
        self.swipeCommitOnRelease = defaults.object(forKey: Keys.swipeCommitOnRelease) as? Bool ?? false
        let sensitivity = defaults.object(forKey: Keys.swipeSensitivity) as? Int ?? Self.defaultSwipeSensitivity
        self.swipeSensitivity = Self.clampSwipeSensitivity(sensitivity)
        self.scrollToSwitch = defaults.object(forKey: Keys.scrollToSwitch) as? Bool ?? true
        self.scrollReverseDirection = defaults.object(forKey: Keys.scrollReverseDirection) as? Bool ?? false
        self.clickOutsideToDismiss = defaults.object(forKey: Keys.clickOutsideToDismiss) as? Bool ?? true
        self.vimNavigationEnabled = defaults.object(forKey: Keys.vimNavigationEnabled) as? Bool ?? false
        self.cycleTileWidths = defaults.object(forKey: Keys.cycleTileWidths) as? Bool ?? false
        self.experimentalInstantSpaceSwitch = defaults.object(forKey: Keys.experimentalInstantSpaceSwitch) as? Bool ?? false
        self.tabDrillEnabled = defaults.object(forKey: Keys.tabDrillEnabled) as? Bool ?? true
        self.expandTabsAsWindows = defaults.object(forKey: Keys.expandTabsAsWindows) as? Bool ?? false
        self.expandBrowserTabsAsWindows = defaults.object(forKey: Keys.expandBrowserTabsAsWindows) as? Bool ?? false
        // Badges graduated out of the Experimental tab and now default on. Honor
        // the new key if present, otherwise carry over a choice made under the
        // old experimental key, otherwise default to on.
        if let stored = defaults.object(forKey: Keys.showUnreadBadges) as? Bool {
            self.showUnreadBadges = stored
        } else if let legacy = defaults.object(forKey: Keys.legacyUnreadBadges) as? Bool {
            self.showUnreadBadges = legacy
        } else {
            self.showUnreadBadges = true
        }

        self.showWindowTitleLabel = defaults.object(forKey: Keys.showWindowTitleLabel) as? Bool ?? true
        self.showApplicationNames = defaults.object(forKey: Keys.showApplicationNames) as? Bool ?? true
        let opacity = defaults.object(forKey: Keys.panelOpacity) as? Int ?? 100
        self.panelOpacity = Self.clampOpacity(opacity)
        let radius = defaults.object(forKey: Keys.panelCornerRadius) as? Int ?? 0
        self.panelCornerRadius = Self.clampCornerRadius(radius)
        self.customAccentHex = defaults.string(forKey: Keys.customAccentHex)
        let materialRaw = defaults.string(forKey: Keys.backdropMaterial)
        self.backdropMaterial = materialRaw.flatMap(BackdropMaterial.init(rawValue:)) ?? .hud
        self.currentSpaceOnly = defaults.object(forKey: Keys.currentSpaceOnly) as? Bool ?? false
        self.directActivationBindings = Self.normalizeBindings(defaults.stringArray(forKey: Keys.directActivationBindings) ?? [])
        self.scopedShortcutScopes = Self.loadScopes(defaults.stringArray(forKey: Keys.scopedShortcutScopes))
        self.mouseHoverSelectionEnabled = defaults.object(forKey: Keys.mouseHoverSelectionEnabled) as? Bool ?? true
        self.mouseClickSelectionEnabled = defaults.object(forKey: Keys.mouseClickSelectionEnabled) as? Bool ?? true
        self.hoverActionsEnabled = defaults.object(forKey: Keys.hoverActionsEnabled) as? Bool ?? false
        self.hoverShowClose = defaults.object(forKey: Keys.hoverShowClose) as? Bool ?? true
        self.hoverShowMinimize = defaults.object(forKey: Keys.hoverShowMinimize) as? Bool ?? true
        self.hoverShowMaximize = defaults.object(forKey: Keys.hoverShowMaximize) as? Bool ?? true
        self.hoverShowHide = defaults.object(forKey: Keys.hoverShowHide) as? Bool ?? true
        self.hoverShowQuit = defaults.object(forKey: Keys.hoverShowQuit) as? Bool ?? true
        self.hoverShowForceQuit = defaults.object(forKey: Keys.hoverShowForceQuit) as? Bool ?? false
        self.hideFromScreenSharing = defaults.object(forKey: Keys.hideFromScreenSharing) as? Bool ?? false
    }

    /// Re-read every preference from `UserDefaults` into the published
    /// properties. Used after importing a settings file so open Settings panes
    /// and the live switcher pick up the new values without a restart — the
    /// `@Published` assignments fire `objectWillChange` and the per-property
    /// publishers `SwitcherController` subscribes to. The didSet observers
    /// persist the same value back (a no-op when unchanged), so this is safe to
    /// call repeatedly. No legacy-key migration here — that runs once in `init`.
    func reloadFromDefaults() {
        let defaults = UserDefaults.standard

        switcherLayoutMode = defaults.string(forKey: Keys.switcherLayoutMode).flatMap(SwitcherLayoutMode.init(rawValue:)) ?? .gridView
        switcherDisplayMode = defaults.string(forKey: Keys.switcherDisplayMode)
            .flatMap(SwitcherDisplayMode.init(rawValue:)) ?? .mouseCursor
        sortOrder = defaults.string(forKey: Keys.sortOrder).flatMap(SwitcherSortOrder.init(rawValue:)) ?? .mru
        revealDelayMs = Self.clampDelay(defaults.object(forKey: Keys.revealDelayMs) as? Int ?? Self.defaultRevealDelayMs)
        letterChainTimeoutMs = Self.clampLetterChainTimeout(defaults.object(forKey: Keys.letterChainTimeoutMs) as? Int ?? Self.defaultLetterChainTimeoutMs)
        panelSize = defaults.string(forKey: Keys.panelSize).flatMap(PanelSize.init(rawValue:)) ?? .standard
        gridMaxColumns = defaults.object(forKey: Keys.gridMaxColumns) as? Int ?? 0

        if let stored = defaults.array(forKey: Keys.appExceptions) as? [[String: String]] {
            appExceptions = stored.compactMap(AppException.init(dictionary:))
        } else {
            appExceptions = []
        }
        pinnedBundleIDs = defaults.stringArray(forKey: Keys.pinnedBundleIDs) ?? []
        hideAllExcludedBundleIDs = defaults.stringArray(forKey: Keys.hideAllExcludedBundleIDs) ?? []

        showMinimizedWindows = defaults.object(forKey: Keys.showMinimizedWindows) as? Bool ?? true
        showHiddenApps = defaults.object(forKey: Keys.showHiddenApps) as? Bool ?? true
        showWindowlessApps = defaults.object(forKey: Keys.showWindowlessApps) as? Bool ?? true
        applicationsOnly = defaults.object(forKey: Keys.applicationsOnly) as? Bool ?? false
        fuzzySearchEnabled = defaults.object(forKey: Keys.fuzzySearchEnabled) as? Bool ?? true
        letterHintsEnabled = defaults.object(forKey: Keys.letterHintsEnabled) as? Bool ?? true
        searchDismissMode = defaults.string(forKey: Keys.searchDismissMode).flatMap(SearchDismissMode.init(rawValue:)) ?? .holdModifier
        searchIncludesLaunchableApps = defaults.object(forKey: Keys.searchIncludesLaunchableApps) as? Bool ?? true
        showRecentlyClosed = defaults.object(forKey: Keys.showRecentlyClosed) as? Bool ?? false
        recentlyClosedLimit = defaults.object(forKey: Keys.recentlyClosedLimit) as? Int ?? 5

        hapticOnCommit = defaults.object(forKey: Keys.hapticOnCommit) as? Bool ?? false
        soundOnCommit = defaults.object(forKey: Keys.soundOnCommit) as? Bool ?? false
        accentChoice = defaults.string(forKey: Keys.accentChoice).flatMap(SwitcherAccent.init(rawValue:)) ?? .system
        hideMenuBarIcon = defaults.object(forKey: Keys.hideMenuBarIcon) as? Bool ?? false

        experimentalSwipeTrigger = defaults.object(forKey: Keys.experimentalSwipeTrigger) as? Bool ?? false
        swipeMode = defaults.string(forKey: Keys.swipeMode).flatMap(SwipeMode.init(rawValue:)) ?? .openSwitcher
        swipeReverseDirection = defaults.object(forKey: Keys.swipeReverseDirection) as? Bool ?? false
        swipeCommitOnRelease = defaults.object(forKey: Keys.swipeCommitOnRelease) as? Bool ?? false
        swipeSensitivity = Self.clampSwipeSensitivity(defaults.object(forKey: Keys.swipeSensitivity) as? Int ?? Self.defaultSwipeSensitivity)
        scrollToSwitch = defaults.object(forKey: Keys.scrollToSwitch) as? Bool ?? true
        scrollReverseDirection = defaults.object(forKey: Keys.scrollReverseDirection) as? Bool ?? false
        clickOutsideToDismiss = defaults.object(forKey: Keys.clickOutsideToDismiss) as? Bool ?? true
        vimNavigationEnabled = defaults.object(forKey: Keys.vimNavigationEnabled) as? Bool ?? false
        mouseHoverSelectionEnabled = defaults.object(forKey: Keys.mouseHoverSelectionEnabled) as? Bool ?? true
        mouseClickSelectionEnabled = defaults.object(forKey: Keys.mouseClickSelectionEnabled) as? Bool ?? true
        cycleTileWidths = defaults.object(forKey: Keys.cycleTileWidths) as? Bool ?? false
        experimentalInstantSpaceSwitch = defaults.object(forKey: Keys.experimentalInstantSpaceSwitch) as? Bool ?? false
        tabDrillEnabled = defaults.object(forKey: Keys.tabDrillEnabled) as? Bool ?? true
        expandTabsAsWindows = defaults.object(forKey: Keys.expandTabsAsWindows) as? Bool ?? false
        expandBrowserTabsAsWindows = defaults.object(forKey: Keys.expandBrowserTabsAsWindows) as? Bool ?? false
        showUnreadBadges = defaults.object(forKey: Keys.showUnreadBadges) as? Bool ?? true

        showWindowTitleLabel = defaults.object(forKey: Keys.showWindowTitleLabel) as? Bool ?? true
        showApplicationNames = defaults.object(forKey: Keys.showApplicationNames) as? Bool ?? true
        panelOpacity = Self.clampOpacity(defaults.object(forKey: Keys.panelOpacity) as? Int ?? 100)
        panelCornerRadius = Self.clampCornerRadius(defaults.object(forKey: Keys.panelCornerRadius) as? Int ?? 0)
        customAccentHex = defaults.string(forKey: Keys.customAccentHex)
        backdropMaterial = defaults.string(forKey: Keys.backdropMaterial).flatMap(BackdropMaterial.init(rawValue:)) ?? .hud
        currentSpaceOnly = defaults.object(forKey: Keys.currentSpaceOnly) as? Bool ?? false
        directActivationBindings = Self.normalizeBindings(defaults.stringArray(forKey: Keys.directActivationBindings) ?? [])
        scopedShortcutScopes = Self.loadScopes(defaults.stringArray(forKey: Keys.scopedShortcutScopes))

        hoverActionsEnabled = defaults.object(forKey: Keys.hoverActionsEnabled) as? Bool ?? false
        hoverShowClose = defaults.object(forKey: Keys.hoverShowClose) as? Bool ?? true
        hoverShowMinimize = defaults.object(forKey: Keys.hoverShowMinimize) as? Bool ?? true
        hoverShowMaximize = defaults.object(forKey: Keys.hoverShowMaximize) as? Bool ?? true
        hoverShowHide = defaults.object(forKey: Keys.hoverShowHide) as? Bool ?? true
        hoverShowQuit = defaults.object(forKey: Keys.hoverShowQuit) as? Bool ?? true
        hoverShowForceQuit = defaults.object(forKey: Keys.hoverShowForceQuit) as? Bool ?? false
        hideFromScreenSharing = defaults.object(forKey: Keys.hideFromScreenSharing) as? Bool ?? false
    }
}
