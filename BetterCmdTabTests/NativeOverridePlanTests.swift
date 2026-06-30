import Carbon.HIToolbox
import Testing
@testable import BetterCmdTab

/// Pure-logic coverage for `computeNativeOverridePlan` — the single decision that
/// drives the on-demand symbolic-hotkey disable (Issue A), the secure-input
/// in-panel switching chords, and the full in-panel parity chords (nav, commit,
/// letter-jump, fuzzy search, panel actions, tab drill). No WindowServer / AppKit.
@Suite("Native override plan")
struct NativeOverridePlanTests {
    static let cmd = UInt32(cmdKey)
    static let shift = UInt32(shiftKey)
    static let opt = UInt32(optionKey)

    static func native() -> TriggerSpec {
        TriggerSpec(appKeyCode: 48, appCarbonModifiers: cmd, appIsCommandOnly: true,
                    windowKeyCode: 50, windowCarbonModifiers: cmd, windowIsCommandOnly: true)
    }
    /// ⌥Tab app / ⌥` window — not the reserved native chord.
    static func remapped() -> TriggerSpec {
        TriggerSpec(appKeyCode: 48, appCarbonModifiers: opt, appIsCommandOnly: false,
                    windowKeyCode: 50, windowCarbonModifiers: opt, windowIsCommandOnly: false)
    }

    /// Default panel-action keys: W/M/H/Q/F.
    static let panelActions: [PanelActionSpec] = [
        PanelActionSpec(keyCode: 13, action: .close),
        PanelActionSpec(keyCode: 46, action: .minimize),
        PanelActionSpec(keyCode: 4, action: .hide),
        PanelActionSpec(keyCode: 12, action: .quit),
        PanelActionSpec(keyCode: 3, action: .fullscreen),
    ]

    static let navKinds: Set<ChordSpec.Kind> = [.navUp, .navDown, .navLeft, .navRight, .commit, .escape]
    static func hasNav(_ plan: NativeOverridePlan) -> Bool {
        plan.carbonChords.contains { navKinds.contains($0.kind) }
    }
    static func has(_ plan: NativeOverridePlan, _ keyCode: UInt32, _ kind: ChordSpec.Kind, _ mod: UInt32 = cmd) -> Bool {
        plan.carbonChords.contains(ChordSpec(keyCode: keyCode, modifiers: mod, kind: kind))
    }
    static func kinds(_ plan: NativeOverridePlan, _ keyCode: UInt32) -> [ChordSpec.Kind] {
        plan.carbonChords.filter { $0.keyCode == keyCode }.map(\.kind)
    }

    // MARK: Always-armed — switching chords + symbolic disable regardless of SEI

    @Test func secureInputOff_native_stillArmsSwitcher() {
        // The switcher is always armed so it wins the instant the tap goes deaf:
        // native ⌘Tab disabled + the 4 switching chords registered even off SEI.
        // No in-panel parity chords off SEI (the tap handles those).
        for open in [false, true] {
            let plan = computeNativeOverridePlan(trigger: Self.native(), secureInputActive: false,
                                                 panelOpen: open, holdModifierDown: open,
                                                 panelActions: Self.panelActions)
            #expect(plan.symbolicKeysToDisable == [1, 2, 6])
            #expect(plan.carbonChords.count == 4)
            #expect(!Self.hasNav(plan))
        }
    }

    @Test func secureInputOff_remapped_armsRemappedChordsNoSymbolicDisable() {
        // ⌥Tab reserves no system symbolic hotkey (nothing to disable, so no
        // crash-strand risk), but the Carbon chords are still always registered.
        let plan = computeNativeOverridePlan(trigger: Self.remapped(), secureInputActive: false,
                                             panelOpen: false, holdModifierDown: false)
        #expect(plan.symbolicKeysToDisable.isEmpty)
        #expect(plan.carbonChords.count == 4)
        #expect(plan.carbonChords.contains(ChordSpec(keyCode: 48, modifiers: Self.opt, kind: .nextApp)))
    }

    // MARK: Secure input disables only the reserved chord

    @Test func secureInputOn_native_panelClosed_disablesCmdTabAndCmdBacktick() {
        let plan = computeNativeOverridePlan(trigger: Self.native(), secureInputActive: true,
                                             panelOpen: false, holdModifierDown: false)
        #expect(plan.symbolicKeysToDisable == [1, 2, 6])
        // 4 switching chords (app ⌘Tab + window ⌘` differ), no in-panel chords.
        #expect(plan.carbonChords.count == 4)
        #expect(!Self.hasNav(plan))
        #expect(plan.carbonChords.contains(ChordSpec(keyCode: 48, modifiers: Self.cmd, kind: .nextApp)))
        #expect(plan.carbonChords.contains(ChordSpec(keyCode: 48, modifiers: Self.cmd | Self.shift, kind: .prevApp)))
        #expect(plan.carbonChords.contains(ChordSpec(keyCode: 50, modifiers: Self.cmd, kind: .nextWindow)))
        #expect(plan.carbonChords.contains(ChordSpec(keyCode: 50, modifiers: Self.cmd | Self.shift, kind: .prevWindow)))
    }

    @Test func secureInputOn_windowChordEqualsApp_noDuplicateWindowChords() {
        // App and window mapped to the same chord (⌘Tab) — only app native, and
        // the window chord must not be re-registered as a duplicate.
        let spec = TriggerSpec(appKeyCode: 48, appCarbonModifiers: Self.cmd, appIsCommandOnly: true,
                               windowKeyCode: 48, windowCarbonModifiers: Self.cmd, windowIsCommandOnly: true)
        let plan = computeNativeOverridePlan(trigger: spec, secureInputActive: true,
                                             panelOpen: false, holdModifierDown: false)
        #expect(plan.symbolicKeysToDisable == [1, 2])   // windowKeyCode 48 != 50 ⇒ no [6]
        #expect(plan.carbonChords.count == 2)            // nextApp + prevApp only
    }

    @Test func secureInputOn_remapped_disablesNothing_registersRemappedChords() {
        let plan = computeNativeOverridePlan(trigger: Self.remapped(), secureInputActive: true,
                                             panelOpen: false, holdModifierDown: false)
        #expect(plan.symbolicKeysToDisable.isEmpty)
        #expect(plan.carbonChords.count == 4)
        #expect(plan.carbonChords.contains(ChordSpec(keyCode: 48, modifiers: Self.opt, kind: .nextApp)))
        #expect(plan.carbonChords.contains(ChordSpec(keyCode: 50, modifiers: Self.opt | Self.shift, kind: .prevWindow)))
    }

    @Test func secureInputOn_appNativeWindowRemapped_disablesOnlyCmdTab() {
        let spec = TriggerSpec(appKeyCode: 48, appCarbonModifiers: Self.cmd, appIsCommandOnly: true,
                               windowKeyCode: 50, windowCarbonModifiers: Self.opt, windowIsCommandOnly: false)
        let plan = computeNativeOverridePlan(trigger: spec, secureInputActive: true,
                                             panelOpen: false, holdModifierDown: false)
        #expect(plan.symbolicKeysToDisable == [1, 2])
        #expect(plan.carbonChords.count == 4)            // app ≠ window ⇒ window chords too
    }

    // MARK: In-panel — gated on panel open AND hold modifier down

    @Test func panelOpen_holdReleased_noInPanelChords() {
        // Panel open but the hold modifier is up (gesture / stay-open / scoped):
        // only the switching chords, so a plain ⌘C is never intercepted.
        let plan = computeNativeOverridePlan(trigger: Self.native(), secureInputActive: true,
                                             panelOpen: true, holdModifierDown: false,
                                             panelActions: Self.panelActions)
        #expect(!Self.hasNav(plan))
        #expect(plan.carbonChords.count == 4)
    }

    @Test func inPanelChords_requireSecureInput_panelOpen_andHold() {
        let off = computeNativeOverridePlan(trigger: Self.native(), secureInputActive: false,
                                            panelOpen: true, holdModifierDown: true)
        #expect(!Self.hasNav(off))
        let closed = computeNativeOverridePlan(trigger: Self.native(), secureInputActive: true,
                                               panelOpen: false, holdModifierDown: true)
        #expect(!Self.hasNav(closed))
    }

    // MARK: In-panel — normal mode full parity

    @Test func normalMode_addsNavCommitLetterJumpAndActions() {
        let plan = computeNativeOverridePlan(trigger: Self.native(), secureInputActive: true,
                                             panelOpen: true, holdModifierDown: true,
                                             searchActive: false, tabDrillActive: false,
                                             panelActions: Self.panelActions)
        // Nav + commit (Return + keypad Enter) + escape.
        #expect(Self.has(plan, 126, .navUp))
        #expect(Self.has(plan, 125, .navDown))
        #expect(Self.has(plan, 123, .navLeft))
        #expect(Self.has(plan, 124, .navRight))
        #expect(Self.has(plan, 36, .commit))
        #expect(Self.has(plan, 76, .commit))     // keypad Enter
        #expect(Self.has(plan, 53, .escape))
        // Mode toggles.
        #expect(Self.has(plan, 44, .toggleSearch))
        #expect(Self.has(plan, 42, .enterTabDrill))
        // Letter-jump over an alphabet keycode (S = 1).
        #expect(Self.has(plan, 1, .letterJump))
        // Panel actions present; their keycode wins the dedupe over letter-jump.
        #expect(Self.has(plan, 13, .close))
        #expect(Self.kinds(plan, 13) == [.close])
        #expect(Self.has(plan, 4, .hide))
    }

    @Test func normalMode_noSpaceChord() {
        let plan = computeNativeOverridePlan(trigger: Self.native(), secureInputActive: true,
                                             panelOpen: true, holdModifierDown: true,
                                             panelActions: Self.panelActions)
        #expect(Self.kinds(plan, 49).isEmpty)    // ⌘Space reserved for Spotlight
    }

    @Test func normalMode_remappedModifierQualifiesParity() {
        let plan = computeNativeOverridePlan(trigger: Self.remapped(), secureInputActive: true,
                                             panelOpen: true, holdModifierDown: true,
                                             panelActions: Self.panelActions)
        #expect(Self.has(plan, 1, .letterJump, Self.opt))
        #expect(Self.has(plan, 36, .commit, Self.opt))
        #expect(!Self.has(plan, 1, .letterJump, Self.cmd))
    }

    // MARK: In-panel — vim navigation parity

    @Test func vimEnabled_registersHJKLAsNavAndWinsOverActionsAndLetterJump() {
        let plan = computeNativeOverridePlan(trigger: Self.native(), secureInputActive: true,
                                             panelOpen: true, holdModifierDown: true,
                                             panelActions: Self.panelActions,
                                             vimNavigationEnabled: true)
        // h/j/k/l mirror the arrows (h←, l→, k↑, j↓)…
        #expect(Self.has(plan, 4, .navLeft))
        #expect(Self.has(plan, 37, .navRight))
        #expect(Self.has(plan, 40, .navUp))
        #expect(Self.has(plan, 38, .navDown))
        // …and win the dedupe outright. 'h' (keycode 4) is the default Hide
        // action key, but vim is appended first, so the only kind on each of
        // these keys is the nav motion — never .hide / .letterJump.
        #expect(Self.kinds(plan, 4) == [.navLeft])
        #expect(Self.kinds(plan, 37) == [.navRight])
        #expect(Self.kinds(plan, 40) == [.navUp])
        #expect(Self.kinds(plan, 38) == [.navDown])
    }

    @Test func vimDisabled_leavesHideAndLetterJumpIntact() {
        // Default (vim off): keycode 4 stays the Hide action; j/k/l stay
        // letter-jump — no nav chords leak onto those keys.
        let plan = computeNativeOverridePlan(trigger: Self.native(), secureInputActive: true,
                                             panelOpen: true, holdModifierDown: true,
                                             panelActions: Self.panelActions,
                                             vimNavigationEnabled: false)
        #expect(Self.kinds(plan, 4) == [.hide])
        #expect(Self.has(plan, 38, .letterJump))
        #expect(Self.has(plan, 40, .letterJump))
        #expect(Self.has(plan, 37, .letterJump))
    }

    @Test func vimEnabled_searchMode_lettersStillTypeIntoQuery() {
        // Search is handled before vim on the tap, so under SEI h/j/k/l must
        // type into the query, not navigate — no vim nav chords in search mode.
        let plan = computeNativeOverridePlan(trigger: Self.native(), secureInputActive: true,
                                             panelOpen: true, holdModifierDown: true,
                                             searchActive: true,
                                             panelActions: Self.panelActions,
                                             vimNavigationEnabled: true)
        #expect(Self.kinds(plan, 4) == [.searchChar])
        #expect(Self.kinds(plan, 38) == [.searchChar])
        #expect(!plan.carbonChords.contains { Self.navKinds.contains($0.kind) && $0.keyCode == 4 })
    }

    // MARK: In-panel — search mode

    @Test func searchMode_lettersBecomeSearchInput_noLetterJumpNoDrill() {
        let plan = computeNativeOverridePlan(trigger: Self.native(), secureInputActive: true,
                                             panelOpen: true, holdModifierDown: true,
                                             searchActive: true,
                                             panelActions: Self.panelActions)
        #expect(Self.has(plan, 1, .searchChar))           // S typed into the query
        #expect(Self.has(plan, 42, .searchChar))          // backslash is a query char in search
        #expect(Self.has(plan, 51, .searchBackspace))     // Delete
        #expect(Self.has(plan, 44, .toggleSearch))        // ⌘/ exits search
        #expect(!plan.carbonChords.contains { $0.kind == .letterJump })
        #expect(!plan.carbonChords.contains { $0.kind == .enterTabDrill })
        // No panel-action chords in search (W typed, not "close").
        #expect(!plan.carbonChords.contains { $0.kind == .close })
        // ⌘/ stays toggle-search, never a search char (dedupe / no overlap).
        #expect(Self.kinds(plan, 44) == [.toggleSearch])
    }

    // MARK: In-panel — tab drill mode

    @Test func drillMode_arrowsStepTabs_returnCommitsTab() {
        let plan = computeNativeOverridePlan(trigger: Self.native(), secureInputActive: true,
                                             panelOpen: true, holdModifierDown: true,
                                             tabDrillActive: true,
                                             panelActions: Self.panelActions)
        #expect(Self.has(plan, 123, .tabPrev))
        #expect(Self.has(plan, 124, .tabNext))
        #expect(Self.has(plan, 36, .commitTab))
        #expect(Self.has(plan, 76, .commitTab))
        #expect(Self.has(plan, 42, .exitTabDrill))
        #expect(Self.has(plan, 53, .exitTabDrill))
        // Drill steals the arrows from selection nav and the letters entirely.
        #expect(!plan.carbonChords.contains { $0.kind == .navUp })
        #expect(!plan.carbonChords.contains { $0.kind == .letterJump })
    }

    // MARK: Determinism (supports idempotent apply)

    @Test func planIsDeterministic() {
        let a = computeNativeOverridePlan(trigger: Self.native(), secureInputActive: true,
                                          panelOpen: true, holdModifierDown: true,
                                          searchActive: false, tabDrillActive: false,
                                          panelActions: Self.panelActions)
        let b = computeNativeOverridePlan(trigger: Self.native(), secureInputActive: true,
                                          panelOpen: true, holdModifierDown: true,
                                          searchActive: false, tabDrillActive: false,
                                          panelActions: Self.panelActions)
        #expect(a == b)
    }

    @Test func allChordKeyModifierPairsAreUnique() {
        // RegisterEventHotKey rejects duplicate (keyCode, modifiers) pairs.
        for (search, drill) in [(false, false), (true, false), (false, true)] {
            let plan = computeNativeOverridePlan(trigger: Self.native(), secureInputActive: true,
                                                 panelOpen: true, holdModifierDown: true,
                                                 searchActive: search, tabDrillActive: drill,
                                                 panelActions: Self.panelActions)
            let pairs = plan.carbonChords.map { ($0.keyCode, $0.modifiers) }
            let unique = Set(pairs.map { (UInt64($0.0) << 32) | UInt64($0.1) })
            #expect(unique.count == pairs.count)
        }
    }

    // MARK: Disabled trigger (Issue #21 — a cleared shortcut must free the chord)

    /// ⌘Tab app cleared, ⌘` window still native.
    static func appDisabled() -> TriggerSpec {
        TriggerSpec(appEnabled: false, appKeyCode: 48, appCarbonModifiers: cmd, appIsCommandOnly: true,
                    windowEnabled: true, windowKeyCode: 50, windowCarbonModifiers: cmd, windowIsCommandOnly: true)
    }
    /// ⌘` window cleared, ⌘Tab app still native.
    static func windowDisabled() -> TriggerSpec {
        TriggerSpec(appEnabled: true, appKeyCode: 48, appCarbonModifiers: cmd, appIsCommandOnly: true,
                    windowEnabled: false, windowKeyCode: 50, windowCarbonModifiers: cmd, windowIsCommandOnly: true)
    }

    @Test func appDisabled_freesNativeCommandTab_keepsWindow() {
        let plan = computeNativeOverridePlan(trigger: Self.appDisabled(), secureInputActive: false,
                                             panelOpen: false, holdModifierDown: false)
        // The native ⌘Tab / ⌘⇧Tab symbolic hotkeys are NOT disabled — they go back
        // to the OS. The window chord (⌘`, id 6) is still claimed.
        #expect(plan.symbolicKeysToDisable == [6])
        // No app switching chords; the window pair survives.
        #expect(!plan.carbonChords.contains { $0.kind == .nextApp || $0.kind == .prevApp })
        #expect(plan.carbonChords.contains { $0.kind == .nextWindow })
        #expect(plan.carbonChords.contains { $0.kind == .prevWindow })
    }

    @Test func windowDisabled_freesNativeBacktick_keepsApp() {
        let plan = computeNativeOverridePlan(trigger: Self.windowDisabled(), secureInputActive: false,
                                             panelOpen: false, holdModifierDown: false)
        #expect(plan.symbolicKeysToDisable == [1, 2])
        #expect(plan.carbonChords.contains { $0.kind == .nextApp })
        #expect(plan.carbonChords.contains { $0.kind == .prevApp })
        #expect(!plan.carbonChords.contains { $0.kind == .nextWindow || $0.kind == .prevWindow })
    }

    @Test func bothDisabled_emptyPlan_evenUnderSecureInputWithPanelOpen() {
        // Nothing reserved, nothing registered — the native switcher is fully
        // restored, and no in-panel parity chords leak in under secure input.
        let trigger = TriggerSpec(appEnabled: false, appKeyCode: 48, appCarbonModifiers: Self.cmd, appIsCommandOnly: true,
                                  windowEnabled: false, windowKeyCode: 50, windowCarbonModifiers: Self.cmd, windowIsCommandOnly: true)
        let plan = computeNativeOverridePlan(trigger: trigger, secureInputActive: true,
                                             panelOpen: true, holdModifierDown: true,
                                             panelActions: Self.panelActions)
        #expect(plan.symbolicKeysToDisable.isEmpty)
        #expect(plan.carbonChords.isEmpty)
    }

    // MARK: Role-decoupled symbolic disable (issue #16 — a swapped/remapped trigger
    // that still lands on a reserved native chord must free that chord's symbolic
    // hotkey regardless of which role holds it, or RegisterEventHotKey -9878s forever)

    @Test func windowMappedToCmdTab_freesCmdTabSymbolic() {
        // Window switch bound to ⌘Tab (kc 48), app on ⌘` (kc 50). The old
        // role-pinned guard (appKeyCode == 48 only) left ⌘Tab's symbolic hotkey
        // enabled while still registering ⌘Tab on the survivor → permanent -9878.
        let trigger = TriggerSpec(appKeyCode: 50, appCarbonModifiers: Self.cmd, appIsCommandOnly: true,
                                  windowKeyCode: 48, windowCarbonModifiers: Self.cmd, windowIsCommandOnly: true)
        let plan = computeNativeOverridePlan(trigger: trigger, secureInputActive: false,
                                             panelOpen: false, holdModifierDown: false)
        #expect(Set(plan.symbolicKeysToDisable) == [1, 2, 6])
    }

    @Test func appMappedToBacktick_freesBacktickSymbolic() {
        // App switch bound to ⌘` (kc 50): id 6 must be freed via the app role.
        let trigger = TriggerSpec(appKeyCode: 50, appCarbonModifiers: Self.cmd, appIsCommandOnly: true,
                                  windowKeyCode: 0, windowCarbonModifiers: Self.cmd, windowIsCommandOnly: false)
        let plan = computeNativeOverridePlan(trigger: trigger, secureInputActive: false,
                                             panelOpen: false, holdModifierDown: false)
        #expect(plan.symbolicKeysToDisable.contains(6))
    }

    @Test func swappedTriggers_disableBothChordSets() {
        // App on ⌘` (kc 50), window on ⌘Tab (kc 48) — the full swap. Both reserved
        // native chords must be freed: {1,2} (⌘Tab/⌘⇧Tab) and {6} (⌘`).
        let trigger = TriggerSpec(appKeyCode: 50, appCarbonModifiers: Self.cmd, appIsCommandOnly: true,
                                  windowKeyCode: 48, windowCarbonModifiers: Self.cmd, windowIsCommandOnly: true)
        let plan = computeNativeOverridePlan(trigger: trigger, secureInputActive: false,
                                             panelOpen: false, holdModifierDown: false)
        #expect(Set(plan.symbolicKeysToDisable) == [1, 2, 6])
    }

    @Test func bothRolesOnCmdTab_noDuplicateSymbolic() {
        // Both roles on ⌘Tab (kc 48): the `||` must dedupe to exactly {1,2}, not
        // append the pair twice.
        let trigger = TriggerSpec(appKeyCode: 48, appCarbonModifiers: Self.cmd, appIsCommandOnly: true,
                                  windowKeyCode: 48, windowCarbonModifiers: Self.cmd, windowIsCommandOnly: true)
        let plan = computeNativeOverridePlan(trigger: trigger, secureInputActive: false,
                                             panelOpen: false, holdModifierDown: false)
        #expect(plan.symbolicKeysToDisable == [1, 2])
    }

    @Test func remappedToOption_onReservedKeycode_freesNothing() {
        // ⌥Tab (kc 48 but NOT command-only) reserves no native symbolic hotkey —
        // the keycode alone must not trigger a disable.
        let trigger = TriggerSpec(appKeyCode: 48, appCarbonModifiers: Self.opt, appIsCommandOnly: false,
                                  windowKeyCode: 50, windowCarbonModifiers: Self.opt, windowIsCommandOnly: false)
        let plan = computeNativeOverridePlan(trigger: trigger, secureInputActive: false,
                                             panelOpen: false, holdModifierDown: false)
        #expect(plan.symbolicKeysToDisable.isEmpty)
    }
}
