import AppKit
import BetterShortcuts
import os

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
    /// Set by `SwitcherController` at startup. Invoked with the entry's stable id
    /// and its scope when its shortcut fires. The id lets the controller look up
    /// that entry's per-shortcut override (#74).
    static var onTrigger: ((Int, SwitchScope) -> Void)?

    /// Names that already have a Carbon `onKeyDown` handler installed. Stable ids
    /// are never reused, so a name is only ever registered once per launch.
    private static var installedNames: Set<String> = []

    /// Install handlers for every current scoped-list entry. Call once at startup
    /// (after `Preferences` has loaded its list).
    static func installHandlers() {
        for entry in Preferences.shared.scopedShortcuts {
            installHandler(for: entry)
        }
    }

    /// Install the Carbon handler for one entry, mapping its recorded trigger to
    /// the entry's id. Idempotent — a re-install for the same name is ignored.
    /// Call when the user adds a new entry at runtime.
    static func installHandler(for entry: ScopedShortcut) {
        let name = BetterShortcuts.Name(entry.shortcutName)
        // A slot bound to a reserved switcher trigger chord (⌘Tab / ⌘` / Shift-reverse)
        // can never fire — the always-armed survivor trigger owns it — and registering
        // it only spews eventHotKeyExistsErr (-9878). Skip it, and DON'T mark it
        // installed, so a later remap to a free chord still registers (issue #16).
        guard !BetterShortcuts.isBoundToReservedTriggerChord(name) else {
            Log.hotkey.warning("scoped shortcut \(entry.id) is bound to a reserved switcher chord — not registering")
            return
        }
        guard installedNames.insert(entry.shortcutName).inserted else { return }
        let id = entry.id
        BetterShortcuts.onKeyDown(for: name) {
            // BetterShortcuts invokes this on the main thread inside
            // `MainActor.assumeIsolated`; mirror that to reach our isolation.
            MainActor.assumeIsolated { trigger(id: id) }
        }
    }

    /// Tear down the Carbon handler for a removed entry: drop its `onKeyDown`
    /// closure (otherwise it lingers in `BetterShortcuts.legacyKeyDownHandlers`
    /// for the app's lifetime) and free its name so `installedNames` can't grow
    /// unbounded across add/remove churn. Call when the user deletes an entry.
    static func removeHandler(for shortcutName: String) {
        guard installedNames.remove(shortcutName) != nil else { return }
        BetterShortcuts.removeHandler(for: BetterShortcuts.Name(shortcutName))
    }

    private static func trigger(id: Int) {
        // Re-read live: the entry may have been removed (then its recorded trigger
        // was cleared, so this normally can't fire) or its scope changed.
        guard let entry = Preferences.shared.scopedShortcuts.first(where: { $0.id == id }) else { return }
        onTrigger?(id, entry.scope)
    }
}
