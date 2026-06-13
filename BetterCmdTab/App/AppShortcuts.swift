import AppKit
import BetterShortcuts

// Strongly-typed names for BetterCmdTab's two switcher triggers. The recorded
// shortcuts are stored by the BetterShortcuts package but are NOT registered
// as live Carbon hotkeys — no `onKeyDown`/`onKeyUp` handler is attached, so the
// package never steals the combo. The CGEvent tap in `HotkeyTap` remains the
// runtime engine; it reads the stored shortcut and decomposes it into a held
// modifier + tap key (see `SwitcherController.pushHotkeyConfig`).
extension BetterShortcuts.Name {
    static let switchApps = Self("switchApps", default: .init(.tab, modifiers: .command))
    static let switchWindows = Self("switchWindows", default: .init(.backtick, modifiers: .command))

    /// Number of direct-activation slots. Mirrors `Preferences.directActivationSlotCount`.
    static let directActivateSlotCount = 9

    /// "Jump straight to this app" hotkeys, slot 1…N. No defaults — these are
    /// live Carbon hotkeys (unlike the switcher triggers): a handler registered
    /// via `BetterShortcuts.onKeyDown` fires them, so the user assigns the combo.
    static let directActivate: [Self] = (1...directActivateSlotCount).map { Self("directActivate\($0)") }

    /// The raw-value prefix shared by every `directActivate` slot name.
    static let directActivatePrefix = "directActivate"

    /// Number of scoped-switch slots. Mirrors `Preferences.scopedShortcutSlotCount`.
    static let scopedSwitchSlotCount = 3

    /// "Open the switcher filtered to a scope" hotkeys, slot 1…N. Like the
    /// direct-activation slots these are live Carbon hotkeys (a `BetterShortcuts.onKeyDown`
    /// handler fires them); the scope each shows lives in `Preferences.scopedShortcutScopes`.
    static let scopedSwitch: [Self] = (1...scopedSwitchSlotCount).map { Self("scopedSwitch\($0)") }

    /// The raw-value prefix shared by every `scopedSwitch` slot name.
    static let scopedSwitchPrefix = "scopedSwitch"

    // MARK: In-panel action keys (tap-driven, like the switcher triggers)

    /// Keys that act on the highlighted window WHILE the switcher is open
    /// (close / minimize / hide / quit). Like `switchApps`/`switchWindows`
    /// these are stored by BetterShortcuts but have NO `onKeyDown` handler, so
    /// the package never registers a global Carbon hotkey (binding ⌘W must not
    /// hijack Close everywhere). The CGEvent tap reads the stored shortcut's
    /// keycode and matches it while switching. Defaults are ⌘W/⌘M/⌘H/⌘Q — ⌘ is
    /// held the whole time the switcher is open, so it reads naturally.
    static let panelClose = Self("panelClose", default: .init(.w, modifiers: .command))
    static let panelMinimize = Self("panelMinimize", default: .init(.m, modifiers: .command))
    static let panelHide = Self("panelHide", default: .init(.h, modifiers: .command))
    static let panelQuit = Self("panelQuit", default: .init(.q, modifiers: .command))
    static let panelFullscreen = Self("panelFullscreen", default: .init(.f, modifiers: .command))

    /// All in-panel action-key names, paired with a stable label.
    static let panelActionKeys: [(name: Self, title: String)] = [
        (.panelClose, String(localized: "Close window")),
        (.panelMinimize, String(localized: "Minimize window")),
        (.panelHide, String(localized: "Hide app")),
        (.panelQuit, String(localized: "Quit app")),
        (.panelFullscreen, String(localized: "Full screen")),
    ]

    // MARK: Window-management hotkeys (global + in-switcher)

    /// Arrange the focused/highlighted window — tile to a half, maximize, or
    /// center. These ARE live global hotkeys (a `BetterShortcuts.onKeyDown`
    /// handler in `WindowManagement` fires them on the frontmost window when the
    /// switcher is closed). While the switcher is open the CGEvent tap consumes
    /// the same chord first and arranges the highlighted window instead, so the
    /// global handler doesn't double-fire. Defaults are ⌃⌘ + arrows.
    static let windowTileLeft = Self("windowTileLeft", default: .init(.leftArrow, modifiers: [.control, .command]))
    static let windowTileRight = Self("windowTileRight", default: .init(.rightArrow, modifiers: [.control, .command]))
    static let windowMaximize = Self("windowMaximize", default: .init(.upArrow, modifiers: [.control, .command]))
    static let windowCenter = Self("windowCenter", default: .init(.downArrow, modifiers: [.control, .command]))

    /// Quarter-screen corner tiles. Defaults are ⌃⌘ + [ ] ; ' — laid out like the
    /// physical key positions (top row [ ] over bottom row ; ', left over right).
    static let windowTileTopLeft = Self("windowTileTopLeft", default: .init(.leftBracket, modifiers: [.control, .command]))
    static let windowTileTopRight = Self("windowTileTopRight", default: .init(.rightBracket, modifiers: [.control, .command]))
    static let windowTileBottomLeft = Self("windowTileBottomLeft", default: .init(.semicolon, modifiers: [.control, .command]))
    static let windowTileBottomRight = Self("windowTileBottomRight", default: .init(.quote, modifiers: [.control, .command]))

    /// Restore the focused/highlighted window to the frame it had BEFORE the last
    /// tile / maximize / move-to-display — e.g. maximize → tile-left → this returns
    /// the maximized frame. Re-enters native full screen if the window was
    /// full-screen before the arrange. Default ⌃⌘⌫.
    static let windowRestorePrevious = Self("windowRestorePrevious", default: .init(.delete, modifiers: [.control, .command]))

    // MARK: Global window-visibility hotkeys

    /// Hide every app at once (clear to the desktop) / bring them all back. Live
    /// global Carbon hotkeys fired by `BetterShortcuts.onKeyDown` handlers in
    /// `WindowManagement`. No defaults — like `directActivate`, these act
    /// system-wide, so the user assigns the combo rather than us claiming one
    /// unasked (and risking a clash with a system or app shortcut). Not part of
    /// `windowMgmt`, so the CGEvent tap's chord map ignores them — they're plain
    /// global hotkeys, not in-switcher chords.
    static let hideAllWindows = Self("hideAllWindows")
    static let showAllWindows = Self("showAllWindows")

    /// The global window-visibility names, paired with a stable label.
    static let globalWindowActions: [(name: Self, title: String)] = [
        (.hideAllWindows, String(localized: "Hide all windows")),
        (.showAllWindows, String(localized: "Show all windows")),
    ]

    /// All window-management names, paired with a stable label.
    static let windowMgmt: [(name: Self, title: String)] = [
        (.windowTileLeft, String(localized: "Tile left half")),
        (.windowTileRight, String(localized: "Tile right half")),
        (.windowTileTopLeft, String(localized: "Tile top-left corner")),
        (.windowTileTopRight, String(localized: "Tile top-right corner")),
        (.windowTileBottomLeft, String(localized: "Tile bottom-left corner")),
        (.windowTileBottomRight, String(localized: "Tile bottom-right corner")),
        (.windowMaximize, String(localized: "Maximize")),
        (.windowCenter, String(localized: "Center")),
        (.windowRestorePrevious, String(localized: "Restore previous size")),
    ]
}

extension BetterShortcuts.Name: @retroactive CaseIterable {
    public static var allCases: [Self] {
        [.switchApps, .switchWindows]
            + directActivate
            + scopedSwitch
            + panelActionKeys.map(\.name)
            + windowMgmt.map(\.name)
            + globalWindowActions.map(\.name)
    }

    /// Human-readable label used by the recorder's conflict alert.
    var displayName: String {
        switch self {
        case .switchApps: return String(localized: "Switch apps")
        case .switchWindows: return String(localized: "Switch windows")
        default:
            if rawValue.hasPrefix(Self.directActivatePrefix),
               let slot = Int(rawValue.dropFirst(Self.directActivatePrefix.count)) {
                return String(localized: "Direct activation \(slot)")
            }
            if rawValue.hasPrefix(Self.scopedSwitchPrefix),
               let slot = Int(rawValue.dropFirst(Self.scopedSwitchPrefix.count)) {
                return String(localized: "Scoped shortcut \(slot)")
            }
            if let panel = Self.panelActionKeys.first(where: { $0.name == self }) {
                return panel.title
            }
            if let wm = Self.windowMgmt.first(where: { $0.name == self }) {
                return wm.title
            }
            if let gw = Self.globalWindowActions.first(where: { $0.name == self }) {
                return gw.title
            }
            return rawValue
        }
    }
}

extension BetterShortcuts {
    /// Wire the package's conflict-alert label provider to our `displayName`s. Call once at launch.
    static func installDisplayNames() {
        BetterShortcuts.displayName = { $0.displayName }
    }
}
