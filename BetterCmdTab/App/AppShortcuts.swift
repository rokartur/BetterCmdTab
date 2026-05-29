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
}

extension BetterShortcuts.Name: @retroactive CaseIterable {
    public static var allCases: [Self] { [.switchApps, .switchWindows] + directActivate + scopedSwitch }

    /// Human-readable label used by the recorder's conflict alert.
    var displayName: String {
        switch self {
        case .switchApps: return "Switch apps"
        case .switchWindows: return "Switch windows"
        default:
            if rawValue.hasPrefix(Self.directActivatePrefix) {
                let slot = rawValue.dropFirst(Self.directActivatePrefix.count)
                return "Direct activation \(slot)"
            }
            if rawValue.hasPrefix(Self.scopedSwitchPrefix) {
                let slot = rawValue.dropFirst(Self.scopedSwitchPrefix.count)
                return "Scoped shortcut \(slot)"
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
