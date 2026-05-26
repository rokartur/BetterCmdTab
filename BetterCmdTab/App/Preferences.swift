import AppKit
import Combine
import Foundation

enum SwitcherLayoutMode: String, CaseIterable {
    case list
    case gridView = "iconDock"

    var displayName: String {
        switch self {
        case .list: return "List"
        case .gridView: return "Grid View"
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
        case .holdModifier: return "Hold ⌘"
        case .stayOpen: return "Stay open until I choose"
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

    var displayName: String {
        switch self {
        case .system: return "System"
        case .blue: return "Blue"
        case .purple: return "Purple"
        case .pink: return "Pink"
        case .red: return "Red"
        case .orange: return "Orange"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .graphite: return "Graphite"
        }
    }

    /// Fixed color, or `nil` when the choice tracks the system accent.
    var color: NSColor? {
        switch self {
        case .system: return nil
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
    /// keeps it appearance-reactive (light/dark) like the rest of AppKit.
    var resolved: NSColor { color ?? .controlAccentColor }
}

/// Overall size multiplier applied to the switcher panel (icons, text, spacing).
enum PanelSize: String, CaseIterable {
    case small
    case standard
    case large

    var scale: CGFloat {
        switch self {
        case .small: return 0.85
        case .standard: return 1.0
        case .large: return 1.2
        }
    }

    var displayName: String {
        switch self {
        case .small: return "Small"
        case .standard: return "Default"
        case .large: return "Large"
        }
    }
}

@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    // Trigger keys are stored by the KeyboardShortcuts library
    // (see KeyboardShortcuts.Name.switchApps / .switchWindows), not here.

    static let defaultRevealDelayMs = 100
    static let revealDelayRange: ClosedRange<Int> = 40...500

    static let defaultSwipeSensitivity = 5
    static let swipeSensitivityRange: ClosedRange<Int> = 1...10

    // Internal (not private): `CatalogFilter` reads the catalog-related keys
    // directly from `UserDefaults` off the main actor, so the key strings must
    // be shared rather than duplicated.
    enum Keys {
        static let switcherLayoutMode = "Switcher.layoutMode"
        static let revealDelayMs = "Switcher.revealDelayMs"
        static let panelSize = "Switcher.panelSize"
        static let gridMaxColumns = "Switcher.gridMaxColumns"
        static let excludedBundleIDs = "Switcher.excludedBundleIDs"
        static let pinnedBundleIDs = "Switcher.pinnedBundleIDs"
        static let showMinimizedWindows = "Switcher.showMinimizedWindows"
        static let showHiddenApps = "Switcher.showHiddenApps"
        static let showWindowlessApps = "Switcher.showWindowlessApps"
        static let fuzzySearchEnabled = "Switcher.fuzzySearchEnabled"
        static let searchDismissMode = "Switcher.searchDismissMode"
        static let searchIncludesLaunchableApps = "Switcher.searchIncludesLaunchableApps"
        static let showRecentlyClosed = "Switcher.showRecentlyClosed"
        static let recentlyClosedLimit = "Switcher.recentlyClosedLimit"
        static let hapticOnCommit = "Switcher.hapticOnCommit"
        static let soundOnCommit = "Switcher.soundOnCommit"
        static let accentChoice = "Switcher.accentChoice"
        static let hideMenuBarIcon = "Switcher.hideMenuBarIcon"
        static let experimentalSwipeTrigger = "Switcher.experimentalSwipeTrigger"
        static let swipeReverseDirection = "Switcher.swipeReverseDirection"
        static let swipeCommitOnRelease = "Switcher.swipeCommitOnRelease"
        static let swipeSensitivity = "Switcher.swipeSensitivity"
        static let experimentalInstantSpaceSwitch = "Switcher.experimentalInstantSpaceSwitch"
        static let experimentalUnreadBadges = "Switcher.experimentalUnreadBadges"
    }

    @Published var switcherLayoutMode: SwitcherLayoutMode {
        didSet {
            guard oldValue != switcherLayoutMode else { return }
            UserDefaults.standard.set(switcherLayoutMode.rawValue, forKey: Keys.switcherLayoutMode)
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

    @Published var panelSize: PanelSize {
        didSet {
            guard oldValue != panelSize else { return }
            UserDefaults.standard.set(panelSize.rawValue, forKey: Keys.panelSize)
        }
    }

    /// Maximum columns in Grid layout. `0` = automatic (width-driven).
    @Published var gridMaxColumns: Int {
        didSet {
            guard oldValue != gridMaxColumns else { return }
            UserDefaults.standard.set(gridMaxColumns, forKey: Keys.gridMaxColumns)
        }
    }

    /// Bundle identifiers of apps hidden from the switcher entirely.
    @Published var excludedBundleIDs: Set<String> {
        didSet {
            guard oldValue != excludedBundleIDs else { return }
            UserDefaults.standard.set(Array(excludedBundleIDs), forKey: Keys.excludedBundleIDs)
        }
    }

    /// Bundle identifiers forced to the front of the switcher. Order is the
    /// pin order (first pinned shows first), independent of MRU.
    @Published var pinnedBundleIDs: [String] {
        didSet {
            guard oldValue != pinnedBundleIDs else { return }
            UserDefaults.standard.set(pinnedBundleIDs, forKey: Keys.pinnedBundleIDs)
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

    /// Enable the type-to-filter fuzzy search mode (entered with `/`).
    @Published var fuzzySearchEnabled: Bool {
        didSet {
            guard oldValue != fuzzySearchEnabled else { return }
            UserDefaults.standard.set(fuzzySearchEnabled, forKey: Keys.fuzzySearchEnabled)
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

    /// Experimental: show app unread-badge counts read from the Dock via the
    /// Accessibility API. Fragile and locale-dependent; off by default.
    @Published var experimentalUnreadBadges: Bool {
        didSet {
            guard oldValue != experimentalUnreadBadges else { return }
            UserDefaults.standard.set(experimentalUnreadBadges, forKey: Keys.experimentalUnreadBadges)
        }
    }

    static func clampDelay(_ value: Int) -> Int {
        min(revealDelayRange.upperBound, max(revealDelayRange.lowerBound, value))
    }

    static func clampSwipeSensitivity(_ value: Int) -> Int {
        min(swipeSensitivityRange.upperBound, max(swipeSensitivityRange.lowerBound, value))
    }

    private init() {
        let defaults = UserDefaults.standard

        let layoutRaw = defaults.string(forKey: Keys.switcherLayoutMode)
        self.switcherLayoutMode = layoutRaw.flatMap(SwitcherLayoutMode.init(rawValue:)) ?? .gridView

        let delay = defaults.object(forKey: Keys.revealDelayMs) as? Int ?? Self.defaultRevealDelayMs
        self.revealDelayMs = Self.clampDelay(delay)

        let sizeRaw = defaults.string(forKey: Keys.panelSize)
        self.panelSize = sizeRaw.flatMap(PanelSize.init(rawValue:)) ?? .standard

        self.gridMaxColumns = defaults.object(forKey: Keys.gridMaxColumns) as? Int ?? 0

        self.excludedBundleIDs = Set(defaults.stringArray(forKey: Keys.excludedBundleIDs) ?? [])
        self.pinnedBundleIDs = defaults.stringArray(forKey: Keys.pinnedBundleIDs) ?? []
        self.showMinimizedWindows = defaults.object(forKey: Keys.showMinimizedWindows) as? Bool ?? true
        self.showHiddenApps = defaults.object(forKey: Keys.showHiddenApps) as? Bool ?? true
        self.showWindowlessApps = defaults.object(forKey: Keys.showWindowlessApps) as? Bool ?? true
        self.fuzzySearchEnabled = defaults.object(forKey: Keys.fuzzySearchEnabled) as? Bool ?? true

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
        self.swipeReverseDirection = defaults.object(forKey: Keys.swipeReverseDirection) as? Bool ?? false
        self.swipeCommitOnRelease = defaults.object(forKey: Keys.swipeCommitOnRelease) as? Bool ?? false
        let sensitivity = defaults.object(forKey: Keys.swipeSensitivity) as? Int ?? Self.defaultSwipeSensitivity
        self.swipeSensitivity = Self.clampSwipeSensitivity(sensitivity)
        self.experimentalInstantSpaceSwitch = defaults.object(forKey: Keys.experimentalInstantSpaceSwitch) as? Bool ?? false
        self.experimentalUnreadBadges = defaults.object(forKey: Keys.experimentalUnreadBadges) as? Bool ?? false
    }
}
