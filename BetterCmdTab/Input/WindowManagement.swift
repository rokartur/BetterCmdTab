import AppKit
import BetterShortcuts

/// Wires the window-management hotkeys (#7) as global BetterShortcuts hotkeys so
/// they always arrange the *frontmost app's focused window*, whether or not the
/// switcher is open:
///
/// - **Switcher closed:** these `onKeyDown` handlers fire directly.
/// - **Switcher open:** the CGEvent tap in `HotkeyTap` matches the same chord
///   first (it intercepts keys while switching) and arranges the frontmost
///   focused window via `SwitcherController`, consuming the event so these
///   global handlers don't also fire. The switcher panel is a non-activating
///   `NSPanel`, so the frontmost app stays the user's real window — the chord
///   acts on it, not on the highlighted switcher row. The tap's chord map is
///   derived from the same BetterShortcuts bindings (see
///   `SwitcherController.pushWindowMgmtBindings`), so there's a single source
///   of truth.
///
/// Handlers are installed once at launch; they read the live binding through
/// BetterShortcuts, so changing a shortcut takes effect without re-registering.
@MainActor
enum WindowManagement {
    /// The window-management chords are matched directly by the CGEvent tap
    /// (`HotkeyTap.windowMgmtFullMap`, derived from BetterShortcuts) both when the
    /// switcher is open and closed — that's what actually fires the arrange. These
    /// BetterShortcuts handlers stay as the secure-input fallback (where the tap
    /// is bypassed). BetterShortcuts ≥ 0.1.2 resolves an unset binding to the
    /// `Name`'s declared default inside `getShortcut`, and `onKeyDown` →
    /// `registerShortcutIfNeeded` reads through `getShortcut`, so the default
    /// Carbon hot key registers and dispatches with no seeding required. Not
    /// seeding also keeps the default live: a future change to a bundled default
    /// isn't frozen into UserDefaults for existing users.
    static func installHandlers() {
        for (name, arrangement) in arrangementByName {
            BetterShortcuts.onKeyDown(for: name) {
                MainActor.assumeIsolated {
                    Activator.arrangeFrontmostWindow(arrangement)
                }
            }
        }
        // Restore-previous-size isn't a computed `WindowArrangement` (it replays a
        // stored frame), so it's wired separately from `arrangementByName`.
        BetterShortcuts.onKeyDown(for: .windowRestorePrevious) {
            MainActor.assumeIsolated {
                Activator.restoreFrontmostWindowFrame()
            }
        }
    }

    /// Map each window-management shortcut name to the arrangement it performs.
    private static var arrangementByName: [(BetterShortcuts.Name, WindowArrangement)] {
        [
            (.windowTileLeft, .tileLeftHalf),
            (.windowTileRight, .tileRightHalf),
            (.windowTileTopLeft, .tileTopLeft),
            (.windowTileTopRight, .tileTopRight),
            (.windowTileBottomLeft, .tileBottomLeft),
            (.windowTileBottomRight, .tileBottomRight),
            (.windowMaximize, .maximize),
            (.windowCenter, .center),
        ]
    }
}
