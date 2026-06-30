import AppKit
import BetterShortcuts
import os

/// Wires the direct-activation hotkeys: a user-assigned global shortcut jumps
/// straight to a chosen app (launching it if needed), without opening the
/// switcher. Each slot binds a `BetterShortcuts.Name` to a bundle ID stored in
/// `Preferences.directActivationBindings`.
///
/// Unlike the switcher triggers (driven by the CGEvent tap so the system ⌘Tab
/// is suppressed), these are ordinary Carbon hotkeys handled by BetterShortcuts:
/// a registered `onKeyDown` handler fires whenever the user's chosen combo is
/// pressed. Handlers are installed once at launch and read the binding live, so
/// changing a slot's target app takes effect without re-registering.
@MainActor
enum DirectActivation {
    static func installHandlers() {
        for (index, name) in BetterShortcuts.Name.directActivate.enumerated() {
            // Skip a slot bound to a reserved switcher trigger chord (⌘Tab / ⌘` /
            // Shift-reverse): the survivor trigger already owns it, so registering
            // would only spew eventHotKeyExistsErr (-9878) (issue #16).
            guard !BetterShortcuts.isBoundToReservedTriggerChord(name) else {
                Log.hotkey.warning("direct-activation slot \(index + 1) is bound to a reserved switcher chord — not registering")
                continue
            }
            BetterShortcuts.onKeyDown(for: name) {
                // BetterShortcuts invokes this on the main thread inside
                // `MainActor.assumeIsolated`; mirror that to reach our isolation.
                MainActor.assumeIsolated { activate(slot: index) }
            }
        }
    }

    private static func activate(slot: Int) {
        let bindings = Preferences.shared.directActivationBindings
        guard bindings.indices.contains(slot) else { return }
        let bundleID = bindings[slot]
        guard !bundleID.isEmpty else { return }
        Activator.activateOrLaunch(bundleID: bundleID)
    }
}
