import AppKit
import BetterShortcuts

/// Wires the scoped-switch shortcuts: a user-assigned global shortcut opens the
/// switcher already filtered to a `SwitchScope` (all windows / current Space /
/// current app's windows / minimized), instead of the full app list.
///
/// Like `DirectActivation`, these are ordinary Carbon hotkeys handled by
/// BetterShortcuts (not the CGEvent tap): a registered `onKeyDown` handler fires
/// on the user's combo and forwards the slot's scope to `onTrigger`, which
/// `SwitcherController` sets to open a sticky, pre-filtered panel. Handlers are
/// installed once at launch and read the slot's scope live, so changing a slot's
/// scope takes effect without re-registering.
@MainActor
enum ScopedSwitch {
    /// Set by `SwitcherController` at startup. Invoked with the slot index and the
    /// slot's scope when its shortcut fires. The slot index lets the controller
    /// look up that slot's per-shortcut override (#74).
    static var onTrigger: ((Int, SwitchScope) -> Void)?

    static func installHandlers() {
        for (index, name) in BetterShortcuts.Name.scopedSwitch.enumerated() {
            BetterShortcuts.onKeyDown(for: name) {
                // BetterShortcuts invokes this on the main thread inside
                // `MainActor.assumeIsolated`; mirror that to reach our isolation.
                MainActor.assumeIsolated { trigger(slot: index) }
            }
        }
    }

    private static func trigger(slot: Int) {
        let scopes = Preferences.shared.scopedShortcutScopes
        guard scopes.indices.contains(slot) else { return }
        onTrigger?(slot, scopes[slot])
    }
}
