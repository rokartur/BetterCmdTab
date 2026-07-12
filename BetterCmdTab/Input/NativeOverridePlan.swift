import Carbon.HIToolbox

/// Pure, side-effect-free description of how the app should override the native
/// macOS keyboard state right now. Everything in this file is plain value logic
/// (no AppKit, no WindowServer calls) so it can be unit-tested exhaustively.
///
/// **Always-armed.** The native ⌘Tab switcher is kept suppressed — the symbolic
/// hotkey disabled and our `RegisterEventHotKey` trigger registered — the *whole*
/// time the app runs, not just while another app holds Secure Event Input. The
/// reason is timing: when a password field grabs Secure Event Input the CGEvent
/// tap goes deaf *instantly*, but there is no notification for that transition
/// (only a poll), so a "disable on demand" scheme leaves a gap in which neither
/// the (now deaf) tap nor a (not-yet-registered) Carbon hot key handles ⌘Tab and
/// the **native** switcher fires. Arming both up front closes that gap: under
/// normal input the head-insert tap consumes ⌘Tab and opens our switcher (the
/// Carbon hot key never fires — the tap wins); the instant the tap goes deaf the
/// already-registered Carbon hot key takes over with no gap. The accepted cost:
/// the symbolic-hotkey disable outlives the process, so a crash / force-quit
/// leaves the system ⌘Tab disabled until the next launch (auto-healed via
/// `healStaleSymbolicHotkeyDisable`), the Privacy-pane Restore button, or
/// re-login.
///
/// Under Secure Event Input the tap is fully deaf, so the *only* keys that reach
/// the app are ⌘-qualified Carbon hot keys (plus the mouse). To make every
/// in-panel action work there, this plan *additionally* registers the whole
/// in-panel key set as modifier-qualified Carbon chords while the panel is open
/// and the hold modifier is physically down — letter-jump, fuzzy search, the
/// panel actions and tab drill included. Those are gated on secure input (when
/// the tap is alive it handles them directly and wins, so registering them then
/// is needless churn). Releasing the modifier is detected separately (no event is
/// delivered for it under secure input — see `HoldModifierMonitor`) and commits.

/// The configured trigger, in the Carbon terms the override decision needs.
///
/// `appEnabled` / `windowEnabled` are `false` when the user has *cleared* that
/// shortcut (BetterShortcuts' explicit "disabled" marker). A disabled trigger
/// reserves no native chord: its symbolic-hotkey disable and Carbon chords are
/// both dropped, so the native macOS ⌘Tab (or ⌘`) keeps working. They default
/// to `true` so existing call sites and tests describe an enabled trigger.
struct TriggerSpec: Equatable {
    var appEnabled: Bool = true
    var appKeyCode: UInt32
    var appCarbonModifiers: UInt32
    var appIsCommandOnly: Bool
    var windowEnabled: Bool = true
    var windowKeyCode: UInt32
    var windowCarbonModifiers: UInt32
    var windowIsCommandOnly: Bool
}

/// A Carbon chord to keep registered, expressed in pure terms. Mapped to
/// `CarbonHotkeyTrigger.Chord` (and `HotkeyTap.Event`) at the apply site.
struct ChordSpec: Equatable {
    enum Kind {
        case nextApp, prevApp, nextWindow, prevWindow
        case navUp, navDown, navLeft, navRight
        case commit, escape
        case toggleSearch, searchBackspace
        case enterTabDrill, exitTabDrill, tabPrev, tabNext, commitTab
        /// Generic alphanumeric key. The apply site resolves the keycode to a
        /// character for the current layout and emits letter-jump / search input.
        case letterJump, searchChar
        /// In-panel action keys (rebindable W/M/H/Q/F).
        case close, minimize, hide, quit, fullscreen
    }
    var keyCode: UInt32
    var modifiers: UInt32
    var kind: Kind
}

/// A rebindable in-panel action key (W/M/H/Q/F), as a keycode + the action it
/// performs. Built from the BetterShortcuts bindings at the call site.
struct PanelActionSpec: Equatable {
    var keyCode: UInt32
    var action: ChordSpec.Kind
}

/// The complete override decision for a given state.
struct NativeOverridePlan: Equatable {
    /// Raw symbolic-hotkey ids to leave disabled; everything else re-enabled.
    var symbolicKeysToDisable: [Int32]
    /// The full set of Carbon chords to have registered now (switching chords +
    /// any in-panel chords). Replaces the registration wholesale.
    var carbonChords: [ChordSpec]
}

/// Physical-position virtual keycodes for the letters and digits — the candidate
/// keys for letter-jump (normal mode) and fuzzy-search input. They are layout
/// independent (the keycode is the physical key); the produced character is
/// resolved per layout at the apply site, and non-matching keys are harmlessly
/// ignored downstream.
private let alphanumericKeyCodes: [UInt32] = [
    0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 14, 15, 16, 17, // A S D F H G Z X C V B Q W E R Y T
    31, 32, 34, 35, 37, 38, 40, 45, 46,                       // O U I P L J K N M
    18, 19, 20, 21, 22, 23, 25, 26, 28, 29,                   // 1 2 3 4 6 5 9 7 8 0
]

/// Extra printable punctuation keycodes accepted as fuzzy-search input. Excludes
/// Slash (44, toggles search), Grave (50, the window chord) and Space (49, would
/// collide with Spotlight's ⌘Space).
private let searchPunctuationKeyCodes: [UInt32] = [
    24, 27, 30, 33, 39, 41, 43, 47, 42, // = - ] [ ' ; , . \
]

// Fixed control keycodes (kVK_*) used for in-panel chords.
private let kcReturn: UInt32 = 36
private let kcKeypadEnter: UInt32 = 76
private let kcEscape: UInt32 = 53
private let kcDelete: UInt32 = 51
private let kcSlash: UInt32 = 44
private let kcBackslash: UInt32 = 42
private let kcLeft: UInt32 = 123
private let kcRight: UInt32 = 124
private let kcDown: UInt32 = 125
private let kcUp: UInt32 = 126

// Physical-position keycodes for the vim motion keys, used only for the
// Secure-Event-Input parity chords (h←, l→, k↑, j↓). Correct for the common
// layouts that keep h/j/k/l in their standard spots; the live tap path is
// char-based via `HotkeyTap.vimNavigationEvent`, so a heavily-remapped layout
// only diverges here under Secure Event Input (an accepted edge).
private let kcVimH: UInt32 = 4
private let kcVimL: UInt32 = 37
private let kcVimJ: UInt32 = 38
private let kcVimK: UInt32 = 40

/// Decide the native-override state.
///
/// - Parameters:
///   - trigger: the configured app/window switch chords.
///   - secureInputActive: `IsSecureEventInputEnabled()` — another app holds
///     Secure Event Input, so the tap is deaf and the Carbon fallback must drive.
///     Only gates the *in-panel parity* chords; the switching chords + symbolic
///     disable are armed regardless (see the always-armed note above).
///   - panelOpen: the switcher panel is showing (`phase != .idle`).
///   - holdModifierDown: the trigger's hold modifier is physically down right
///     now. The in-panel chords are registered only then — a ⌘-qualified chord
///     can't fire without ⌘ anyway, and gating on the live hold keeps the chords
///     from globally intercepting e.g. ⌘C while the panel lingers open with the
///     modifier already released (gesture / stay-open / scoped open).
///   - searchActive / tabDrillActive: the current in-panel mode, which decides
///     whether the letter keys are letter-jump or search input, and whether the
///     arrows step the selection or the tab strip.
///   - panelActions: the rebindable in-panel action keys (W/M/H/Q/F).
///   - vimNavigationEnabled: the opt-in vim h/j/k/l navigation preference. When
///     on, h/j/k/l are registered as arrow-motion chords ahead of the panel
///     actions and letter-jump so they win the dedupe — mirroring the tap, where
///     the vim branch precedes `panelKeyMap` and letter-jump.
func computeNativeOverridePlan(
    trigger: TriggerSpec,
    secureInputActive: Bool,
    panelOpen: Bool,
    holdModifierDown: Bool,
    searchActive: Bool = false,
    tabDrillActive: Bool = false,
    panelActions: [PanelActionSpec] = [],
    vimNavigationEnabled: Bool = false
) -> NativeOverridePlan {
    // Always-armed: disable the native symbolic hotkey and register the Carbon
    // switching chords regardless of the secure-input state, so our switcher wins
    // the instant the tap goes deaf — no poll-gap where the native ⌘Tab fires.

    // Symbolic hotkeys to free so RegisterEventHotKey can claim the reserved
    // native chord. Only when the trigger IS that reserved chord (⌘Tab / ⌘`);
    // a remapped trigger reserves nothing, so nothing is disabled. A *disabled*
    // trigger likewise frees nothing — the user wants the native chord back.
    var symbolic: [Int32] = []
    // Free the native symbolic hotkey that reserves a chord we register on the
    // Carbon survivor, keyed on the ACTUAL reserved chord regardless of which role
    // (app/window) holds it. The old role-pinned test (`appKeyCode == 48` /
    // `windowKeyCode == 50`) missed a swapped/remapped binding — e.g. the window
    // switch on ⌘Tab (kc 48) or the app switch on ⌘` (kc 50) — leaving the native
    // symbolic hotkey enabled while we still RegisterEventHotKey that exact chord,
    // so macOS rejects it with eventHotKeyExistsErr (-9878) on every retry forever
    // (issue #16). The `||` dedupes when both roles sit on the same keycode.
    func reservesCommandOnly(_ keyCode: UInt32) -> Bool {
        (trigger.appEnabled && trigger.appIsCommandOnly && trigger.appKeyCode == keyCode)
            || (trigger.windowEnabled && trigger.windowIsCommandOnly && trigger.windowKeyCode == keyCode)
    }
    if reservesCommandOnly(48) {
        symbolic.append(PrivateAPI.SymbolicHotKey.commandTab.rawValue)      // 1
        symbolic.append(PrivateAPI.SymbolicHotKey.commandShiftTab.rawValue) // 2
    }
    if reservesCommandOnly(50) {
        symbolic.append(PrivateAPI.SymbolicHotKey.commandKeyAboveTab.rawValue) // 6
    }

    // Carbon switching chords (the secure-input survivor trigger). Built exactly
    // as the live tap config: forward + Shift-reverse for the app chord, and the
    // same for the window chord only when it differs (a duplicate chord would be
    // rejected by RegisterEventHotKey). Always registered so the panel can be
    // *opened* the instant the tap goes deaf.
    let shift = UInt32(shiftKey)
    var chords: [ChordSpec] = []
    if trigger.appEnabled {
        chords.append(ChordSpec(keyCode: trigger.appKeyCode, modifiers: trigger.appCarbonModifiers, kind: .nextApp))
        chords.append(ChordSpec(keyCode: trigger.appKeyCode, modifiers: trigger.appCarbonModifiers | shift, kind: .prevApp))
    }
    // Register the window chord when it's enabled and isn't a duplicate of the
    // app chord (RegisterEventHotKey rejects duplicates). With the app chord
    // disabled there's nothing to duplicate, so the window chord always stands.
    if trigger.windowEnabled
        && (!trigger.appEnabled
            || trigger.windowKeyCode != trigger.appKeyCode
            || trigger.windowCarbonModifiers != trigger.appCarbonModifiers) {
        chords.append(ChordSpec(keyCode: trigger.windowKeyCode, modifiers: trigger.windowCarbonModifiers, kind: .nextWindow))
        chords.append(ChordSpec(keyCode: trigger.windowKeyCode, modifiers: trigger.windowCarbonModifiers | shift, kind: .prevWindow))
    }

    // In-panel parity. Registered while the panel is open and the hold modifier
    // is physically down. Every chord is qualified with that same modifier so it
    // only fires while the user is "in switcher mode" and never captures a plain
    // key from the focused password field. The remaining true limit under secure
    // input: once the modifier is released in stay-open/sticky mode, no key can
    // reach a background app — only the mouse works (documented).
    if secureInputActive && panelOpen && holdModifierDown && (trigger.appEnabled || trigger.windowEnabled) {
        // Qualify the in-panel chords with the hold modifier of whichever trigger
        // is live (they share ⌘ by default); the app trigger wins when both exist.
        let mod = trigger.appEnabled ? trigger.appCarbonModifiers : trigger.windowCarbonModifiers
        // Control/navigation chords first so they win the (keyCode, modifiers)
        // dedupe over the generic letter/search block below.
        if tabDrillActive {
            chords.append(ChordSpec(keyCode: kcLeft, modifiers: mod, kind: .tabPrev))
            chords.append(ChordSpec(keyCode: kcRight, modifiers: mod, kind: .tabNext))
            chords.append(ChordSpec(keyCode: kcReturn, modifiers: mod, kind: .commitTab))
            chords.append(ChordSpec(keyCode: kcKeypadEnter, modifiers: mod, kind: .commitTab))
            chords.append(ChordSpec(keyCode: kcBackslash, modifiers: mod, kind: .exitTabDrill))
            chords.append(ChordSpec(keyCode: kcEscape, modifiers: mod, kind: .exitTabDrill))
        } else {
            chords.append(ChordSpec(keyCode: kcReturn, modifiers: mod, kind: .commit))
            chords.append(ChordSpec(keyCode: kcKeypadEnter, modifiers: mod, kind: .commit))
            chords.append(ChordSpec(keyCode: kcEscape, modifiers: mod, kind: .escape))
            chords.append(ChordSpec(keyCode: kcUp, modifiers: mod, kind: .navUp))
            chords.append(ChordSpec(keyCode: kcDown, modifiers: mod, kind: .navDown))
            chords.append(ChordSpec(keyCode: kcLeft, modifiers: mod, kind: .navLeft))
            chords.append(ChordSpec(keyCode: kcRight, modifiers: mod, kind: .navRight))
            chords.append(ChordSpec(keyCode: kcSlash, modifiers: mod, kind: .toggleSearch))

            if searchActive {
                chords.append(ChordSpec(keyCode: kcDelete, modifiers: mod, kind: .searchBackspace))
                for kc in alphanumericKeyCodes + searchPunctuationKeyCodes {
                    chords.append(ChordSpec(keyCode: kc, modifiers: mod, kind: .searchChar))
                }
            } else {
                chords.append(ChordSpec(keyCode: kcBackslash, modifiers: mod, kind: .enterTabDrill))
                // Vim navigation parity with the tap: h/j/k/l mirror the arrows
                // (h←, l→, k↑, j↓). Appended before the panel actions and the
                // generic letter-jump loop so the first-wins dedupe makes vim win
                // over both — mirroring the tap, where the vim branch precedes
                // `panelKeyMap` and letter-jump (so vim `h` beats a Hide binding
                // on the same key).
                if vimNavigationEnabled {
                    chords.append(ChordSpec(keyCode: kcVimH, modifiers: mod, kind: .navLeft))
                    chords.append(ChordSpec(keyCode: kcVimL, modifiers: mod, kind: .navRight))
                    chords.append(ChordSpec(keyCode: kcVimK, modifiers: mod, kind: .navUp))
                    chords.append(ChordSpec(keyCode: kcVimJ, modifiers: mod, kind: .navDown))
                }
                // Panel actions before letter-jump so an action key (e.g. W) wins
                // the dedupe over letter-jump on the same keycode.
                for action in panelActions {
                    chords.append(ChordSpec(keyCode: action.keyCode, modifiers: mod, kind: action.action))
                }
                for kc in alphanumericKeyCodes {
                    chords.append(ChordSpec(keyCode: kc, modifiers: mod, kind: .letterJump))
                }
            }
        }
    }

    // Dedupe by (keyCode, modifiers), first-wins — RegisterEventHotKey rejects a
    // duplicate registration, and first-wins lets the specific control/action
    // chords above take precedence over the generic letter/search block.
    var seen = Set<UInt64>()
    var deduped: [ChordSpec] = []
    deduped.reserveCapacity(chords.count)
    for chord in chords {
        let key = (UInt64(chord.keyCode) << 32) | UInt64(chord.modifiers)
        if seen.insert(key).inserted { deduped.append(chord) }
    }

    return NativeOverridePlan(symbolicKeysToDisable: symbolic, carbonChords: deduped)
}
