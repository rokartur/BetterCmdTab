import AppKit
import Combine
import Foundation

enum SwitcherLayoutMode: String, CaseIterable {
    case list
    case gridView = "iconDock"
    /// alt-tab-style view: a wrapping grid of live window thumbnails. Needs the
    /// Screen Recording permission to capture previews; falls back to the app
    /// icon per tile when capture is unavailable.
    case windowPreview

    var displayName: String {
        switch self {
        case .list: return "List"
        case .gridView: return "Grid View"
        case .windowPreview: return "Previews"
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
    /// User-supplied color; the actual value lives in `Preferences.customAccentHex`.
    /// Resolve via `Preferences.shared.resolvedAccent`, not `resolved`, so the hex
    /// is read on the main actor.
    case custom

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
        case .custom: return "Custom…"
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
        case .hud: return "HUD (default)"
        case .sidebar: return "Sidebar"
        case .menu: return "Menu"
        case .popover: return "Popover"
        case .fullScreen: return "Full Screen"
        case .underWindow: return "Under Window"
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

    var displayName: String {
        switch self {
        case .openSwitcher: return "Open switcher"
        case .switchSpaces: return "Switch Spaces"
        }
    }
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

    // Trigger keys are stored by the BetterShortcuts package
    // (see BetterShortcuts.Name.switchApps / .switchWindows), not here.

    static let defaultRevealDelayMs = 100
    static let revealDelayRange: ClosedRange<Int> = 40...500

    static let defaultSwipeSensitivity = 5
    static let swipeSensitivityRange: ClosedRange<Int> = 1...10

    static let panelOpacityRange: ClosedRange<Int> = 30...100
    /// `0` means "automatic" (track the size-derived metric); above that the
    /// user pins an explicit radius in points.
    static let panelCornerRadiusRange: ClosedRange<Int> = 0...40

    /// Number of direct-activation hotkey slots. Each slot binds a recorded
    /// shortcut (stored by BetterShortcuts) to a target app bundle ID.
    static let directActivationSlotCount = 9

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
        static let experimentalInstantSpaceSwitch = "Switcher.experimentalInstantSpaceSwitch"
        static let showUnreadBadges = "Switcher.showUnreadBadges"
        /// Pre-graduation key (badges used to live behind the Experimental tab);
        /// read once at launch to carry a user's earlier choice over to the new key.
        static let legacyUnreadBadges = "Switcher.experimentalUnreadBadges"
        static let showWindowTitleLabel = "Switcher.showWindowTitleLabel"
        static let panelOpacity = "Switcher.panelOpacity"
        static let panelCornerRadius = "Switcher.panelCornerRadius"
        static let customAccentHex = "Switcher.customAccentHex"
        static let backdropMaterial = "Switcher.backdropMaterial"
        static let currentSpaceOnly = "Switcher.currentSpaceOnly"
        static let experimentalMoveToSpace = "Switcher.experimentalMoveToSpace"
        static let directActivationBindings = "Switcher.directActivationBindings"
        static let hoverActionsEnabled = "Switcher.hoverActionsEnabled"
        static let hoverShowClose = "Switcher.hoverShowClose"
        static let hoverShowMinimize = "Switcher.hoverShowMinimize"
        static let hoverShowMaximize = "Switcher.hoverShowMaximize"
        static let hoverShowHide = "Switcher.hoverShowHide"
        static let hoverShowQuit = "Switcher.hoverShowQuit"
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

    /// Experimental: allow ⌘⇧← / ⌘⇧→ to move the highlighted window to the
    /// adjacent Space (private SkyLight APIs). Off by default — fragile.
    /// Display moves (⌘⇧↑ / ⌘⇧↓ and across monitors) use stable AX APIs and are
    /// always available. [[experimental-features]]
    @Published var experimentalMoveToSpace: Bool {
        didSet {
            guard oldValue != experimentalMoveToSpace else { return }
            UserDefaults.standard.set(experimentalMoveToSpace, forKey: Keys.experimentalMoveToSpace)
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

    static func clampSwipeSensitivity(_ value: Int) -> Int {
        min(swipeSensitivityRange.upperBound, max(swipeSensitivityRange.lowerBound, value))
    }

    static func clampOpacity(_ value: Int) -> Int {
        min(panelOpacityRange.upperBound, max(panelOpacityRange.lowerBound, value))
    }

    static func clampCornerRadius(_ value: Int) -> Int {
        min(panelCornerRadiusRange.upperBound, max(panelCornerRadiusRange.lowerBound, value))
    }

    /// Pads/truncates to exactly `directActivationSlotCount` entries.
    static func normalizeBindings(_ value: [String]) -> [String] {
        var out = Array(value.prefix(directActivationSlotCount))
        while out.count < directActivationSlotCount { out.append("") }
        return out
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
        self.experimentalInstantSpaceSwitch = defaults.object(forKey: Keys.experimentalInstantSpaceSwitch) as? Bool ?? false
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
        let opacity = defaults.object(forKey: Keys.panelOpacity) as? Int ?? 100
        self.panelOpacity = Self.clampOpacity(opacity)
        let radius = defaults.object(forKey: Keys.panelCornerRadius) as? Int ?? 0
        self.panelCornerRadius = Self.clampCornerRadius(radius)
        self.customAccentHex = defaults.string(forKey: Keys.customAccentHex)
        let materialRaw = defaults.string(forKey: Keys.backdropMaterial)
        self.backdropMaterial = materialRaw.flatMap(BackdropMaterial.init(rawValue:)) ?? .hud
        self.currentSpaceOnly = defaults.object(forKey: Keys.currentSpaceOnly) as? Bool ?? false
        self.experimentalMoveToSpace = defaults.object(forKey: Keys.experimentalMoveToSpace) as? Bool ?? false
        self.directActivationBindings = Self.normalizeBindings(defaults.stringArray(forKey: Keys.directActivationBindings) ?? [])
        self.hoverActionsEnabled = defaults.object(forKey: Keys.hoverActionsEnabled) as? Bool ?? false
        self.hoverShowClose = defaults.object(forKey: Keys.hoverShowClose) as? Bool ?? true
        self.hoverShowMinimize = defaults.object(forKey: Keys.hoverShowMinimize) as? Bool ?? true
        self.hoverShowMaximize = defaults.object(forKey: Keys.hoverShowMaximize) as? Bool ?? true
        self.hoverShowHide = defaults.object(forKey: Keys.hoverShowHide) as? Bool ?? true
        self.hoverShowQuit = defaults.object(forKey: Keys.hoverShowQuit) as? Bool ?? true
    }
}
