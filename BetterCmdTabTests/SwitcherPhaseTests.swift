import AppKit
import ApplicationServices
import CoreGraphics
import Testing
@testable import BetterCmdTab

/// Pure-logic coverage for the `SwitcherController.Phase` flags that drive the
/// hot-path tap. The exact bug behind issue #16 ("Cmd+Q/W stop working after a
/// while") was a non-idle but panel-less `.primed` phase whose flag was treated
/// the same as `.visible`, so the tap kept swallowing the in-panel action keys
/// (⌘W/⌘Q/⌘M/⌘H/⌘F) while the controller no-op'd them. These invariants pin the
/// two flags apart so a refactor can't collapse them again.
@Suite("Switcher phase flags")
struct SwitcherPhaseTests {
    @Test func isSwitching_trueWheneverNonIdle() {
        #expect(!SwitcherController.Phase.idle.isSwitching)
        #expect(SwitcherController.Phase.primed.isSwitching)
        #expect(SwitcherController.Phase.visible.isSwitching)
    }

    @Test func presentsPanel_onlyWhenVisible() {
        // The whole point of #16: `.primed` is switching but presents NO panel,
        // so the action keys must not be swallowed there.
        #expect(!SwitcherController.Phase.idle.presentsPanel)
        #expect(!SwitcherController.Phase.primed.presentsPanel)
        #expect(SwitcherController.Phase.visible.presentsPanel)
    }

    @Test func isPrimed_onlyForPrimed() {
        #expect(!SwitcherController.Phase.idle.isPrimed)
        #expect(SwitcherController.Phase.primed.isPrimed)
        #expect(!SwitcherController.Phase.visible.isPrimed)
    }

    /// The watchdog only ever force-cancels a stranded `.primed`; it must never
    /// tear down a live panel (`.visible`) or a clean `.idle`.
    @Test func watchdogTargetsPrimedOnly() {
        let forceIdle: (SwitcherController.Phase) -> Bool = { $0.isPrimed }
        #expect(forceIdle(.primed))
        #expect(!forceIdle(.visible))
        #expect(!forceIdle(.idle))
    }
}

/// Pure-logic coverage for the fast-tap rescue: when the ⌘-release was dropped by
/// the tap (it gates `.releaseCmd` on `isSwitchingNow()`, set only once the main
/// thread reaches `.primed`), the controller re-reads the live modifier state and
/// commits instead of stranding the panel. This isolates the "release already
/// missed?" decision from the impure `CGEventSource` read.
@Suite("Switcher fast-tap rescue")
struct SwitcherReleaseMissedTests {
    @Test func missed_whenNeitherHoldModifierDown() {
        // ⌘Tab / ⌘` defaults: both triggers use Command. No modifier down → the
        // user already let go, so the release was missed and we must commit.
        #expect(SwitcherController.releaseAlreadyMissed(flags: [], appMask: .maskCommand, windowMask: .maskCommand))
    }

    @Test func notMissed_whileHoldModifierStillDown() {
        // ⌘ still physically held → normal hold-to-browse, reveal the panel.
        #expect(!SwitcherController.releaseAlreadyMissed(flags: [.maskCommand], appMask: .maskCommand, windowMask: .maskCommand))
        // Extra modifiers alongside the hold modifier don't count as released.
        #expect(!SwitcherController.releaseAlreadyMissed(flags: [.maskCommand, .maskShift], appMask: .maskCommand, windowMask: .maskCommand))
    }

    @Test func notMissed_whenEitherTriggerModifierDown() {
        // Distinct app/window hold modifiers (e.g. ⌘ for apps, ⌥ for windows):
        // either one still down means the switch is live.
        #expect(!SwitcherController.releaseAlreadyMissed(flags: [.maskAlternate], appMask: .maskCommand, windowMask: .maskAlternate))
        #expect(!SwitcherController.releaseAlreadyMissed(flags: [.maskCommand], appMask: .maskCommand, windowMask: .maskAlternate))
        // Neither of the two trigger modifiers down → missed (a stray Shift is not
        // a hold modifier).
        #expect(SwitcherController.releaseAlreadyMissed(flags: [.maskShift], appMask: .maskCommand, windowMask: .maskAlternate))
    }

    @Test func disabledTrigger_contributesNoHold() {
        // A cleared shortcut passes a nil mask: it must never count as held, so an
        // incidentally-held ⌘ can't mask the real (Control) window hold modifier.
        #expect(SwitcherController.releaseAlreadyMissed(flags: [.maskCommand], appMask: nil, windowMask: .maskControl))
        // The live window modifier still down → not missed.
        #expect(!SwitcherController.releaseAlreadyMissed(flags: [.maskControl], appMask: nil, windowMask: .maskControl))
        // Both triggers disabled → nothing to hold, so the release is always missed.
        #expect(SwitcherController.releaseAlreadyMissed(flags: [.maskCommand], appMask: nil, windowMask: nil))
    }
}

/// Pure-logic coverage for the `.visible` release-to-commit liveness backstop —
/// the recovery the prior #16 fixes lacked. A keyboard ⌘Tab panel closes on the
/// tap's single ⌘-release `flagsChanged`; if that event is dropped the panel
/// welds into `.visible` and the tap keeps swallowing ⌘W/⌘Q. The backstop polls
/// the live modifier and commits a missed release — but only for a panel where
/// releasing ⌘ would actually commit, and never when `HoldModifierMonitor`
/// already owns the release under Secure Event Input. These pin that arming
/// matrix so it can't silently widen (perpetual poll) or narrow (re-strand).
@Suite("Switcher visible-release backstop")
struct SwitcherVisibleReleaseBackstopTests {
    /// Helper with the common-case defaults: a live keyboard ⌘Tab panel.
    private func arm(
        phase: SwitcherController.Phase = .visible,
        primedByHeldChord: Bool = true,
        stickyOpen: Bool = false,
        tabDrillActive: Bool = false,
        secureInputActive: Bool = false
    ) -> Bool {
        SwitcherController.shouldArmVisibleReleaseBackstop(
            phase: phase,
            primedByHeldChord: primedByHeldChord,
            stickyOpen: stickyOpen,
            tabDrillActive: tabDrillActive,
            secureInputActive: secureInputActive
        )
    }

    @Test func arms_forLiveKeyboardPanel() {
        // The primary issue #16 case: a held-chord ⌘Tab panel on screen under
        // normal input — releasing ⌘ commits, so the backstop must guard it.
        #expect(arm())
    }

    @Test func off_whenNotVisible() {
        // Closed (the ~99.99% case) and panel-less `.primed` (owned by
        // primedWatchdog) schedule no timer.
        #expect(!arm(phase: .idle))
        #expect(!arm(phase: .primed))
    }

    @Test func off_forGestureOrScopedOpens() {
        // Gesture / scoped opens carry `primedByHeldChord == false`: they are
        // sticky and never commit on release, so the backstop must stay off.
        #expect(!arm(primedByHeldChord: false))
    }

    @Test func off_whenParkedSticky() {
        // Mouse detach / stay-open search parks the panel (`stickyOpen`): releasing
        // ⌘ no longer commits, so polling would only waste wakes.
        #expect(!arm(stickyOpen: true))
    }

    @Test func on_whenDrilledIntoTabStrip() {
        // Tab drill-in forces `stickyOpen` true but STILL commits the highlighted
        // tab on release — so a dropped release there must be recovered too. This
        // is the gap a naive `!stickyOpen` gate would leave open.
        #expect(arm(stickyOpen: true, tabDrillActive: true))
    }

    @Test func arms_underSecureInput_forFlagsStateIndependentRecovery() {
        // Secure input is intentionally NOT excluded (issue #16): HoldModifierMonitor's
        // release poll reads the same CGEventSource.flagsState that can stick reporting
        // ⌘-held, so the backstop must also run under secure input to drive the
        // flagsState-independent no-interaction force-close.
        #expect(arm(secureInputActive: true))
        #expect(arm(stickyOpen: true, tabDrillActive: true, secureInputActive: true))
        // Sticky-without-drill still never arms, secure input or not.
        #expect(!arm(stickyOpen: true, secureInputActive: true))
    }

    @Test func drivesTapWeldHealFlag_heldChordOnly() {
        // This same predicate is the single source of truth for the tap's
        // `modifierHeldPanelFlag` weld self-heal (issue #16): on a live keyDown the
        // tap refuses to swallow an action key / letter-jump when the panel is
        // held-chord (flag true) AND the event's flags show the hold modifier up,
        // tearing the welded panel down instead. So the flag must be true exactly
        // for a held-chord panel (heal-eligible) and false for a deliberate stay-open
        // / gesture / scoped park, where bare keys must keep routing to the panel.
        #expect(arm())                          // held-chord ⌘Tab → heal-eligible
        #expect(!arm(stickyOpen: true))         // parked stay-open → bare keys route
        #expect(!arm(primedByHeldChord: false)) // gesture / scoped → bare keys route
    }
}

/// The backstop's no-interaction force-close is a flagsState-independent escape from
/// a panel welded open by a STUCK `CGEventSource.flagsState`. That stick only happens
/// under Secure Event Input (the tap is deaf and HoldModifierMonitor polls the same
/// lying state). Under NORMAL input flagsState is authoritative and the fast path
/// recovers any dropped release, so a held ⌘ must keep the panel open indefinitely —
/// force-closing it stranded a user holding ⌘ while reading the panel (issue: ⌘Tab
/// hold + idle closed after 4s). These pin the gate to secure input only.
@Suite("Switcher stranded-visible force-close")
struct SwitcherStrandedVisibleTests {
    private let ceiling: TimeInterval = 4

    @Test func neverForceClosesUnderNormalInputWithoutRecentFlap() {
        // The reported bug: ⌘ genuinely held, no steering, and no recent SEI flap —
        // normal input must NEVER force-close, no matter how long the panel idles.
        #expect(!SwitcherController.shouldForceCloseStrandedVisible(
            secureInputActive: false, withinPostSecureWindow: false, idle: 0))
        #expect(!SwitcherController.shouldForceCloseStrandedVisible(
            secureInputActive: false, withinPostSecureWindow: false, idle: ceiling + 1))
        #expect(!SwitcherController.shouldForceCloseStrandedVisible(
            secureInputActive: false, withinPostSecureWindow: false, idle: 3600))
    }

    @Test func forceClosesPastCeilingUnderSecureInput() {
        // Secure input + idle beyond the ceiling: the only flagsState-independent
        // heal for a welded-open panel (issue #16).
        #expect(SwitcherController.shouldForceCloseStrandedVisible(
            secureInputActive: true, withinPostSecureWindow: false, idle: ceiling + 0.5))
    }

    @Test func holdsBelowCeilingUnderSecureInput() {
        // Within the ceiling, even under secure input, a recently-steered panel is
        // left alone — the stamp is fresh, so don't yank it.
        #expect(!SwitcherController.shouldForceCloseStrandedVisible(
            secureInputActive: true, withinPostSecureWindow: false, idle: 0))
        #expect(!SwitcherController.shouldForceCloseStrandedVisible(
            secureInputActive: true, withinPostSecureWindow: false, idle: ceiling - 0.5))
        // Boundary: exactly at the ceiling is not yet past it (strict `>`).
        #expect(!SwitcherController.shouldForceCloseStrandedVisible(
            secureInputActive: true, withinPostSecureWindow: false, idle: ceiling))
    }

    @Test func forceClosesPastCeilingWithinPostSecureWindow() {
        // The residual #16 gap: SEI has flapped OFF (secureInputActive false) but a
        // ⌘-held flagsState latch can outlive the SEI→OFF edge, so the bounded
        // post-SEI window must still force-close a stranded panel past the ceiling
        // even with secure input reported off.
        #expect(SwitcherController.shouldForceCloseStrandedVisible(
            secureInputActive: false, withinPostSecureWindow: true, idle: ceiling + 0.5))
    }

    @Test func holdsBelowCeilingWithinPostSecureWindow() {
        // The post-SEI window still respects the idle ceiling — a freshly-steered
        // panel right after a flap is not yanked before it goes quiet.
        #expect(!SwitcherController.shouldForceCloseStrandedVisible(
            secureInputActive: false, withinPostSecureWindow: true, idle: ceiling - 0.5))
        #expect(!SwitcherController.shouldForceCloseStrandedVisible(
            secureInputActive: false, withinPostSecureWindow: true, idle: ceiling))
    }
}

/// Pure-logic coverage for the browser-tab active-tab landing (#39). After a
/// window-MRU step expands a browser window into per-tab rows, the selection must
/// land on the window's ACTIVE tab — not snap to tab 1 — when the collapsed row's
/// title didn't survive expansion (Chrome's " — Google Chrome" suffix, trimmed
/// whitespace, a duplicate title) so the exact-title `keyMatches` missed and the
/// pid fallback would otherwise pick the window's first row.
@Suite("Switcher browser active-tab landing")
struct SwitcherActiveBrowserTabTests {
    private var hostApp: NSRunningApplication { .current }
    private func axElement() -> AXUIElement { AXUIElementCreateApplication(getpid()) }

    /// One browser window expanded into three tab rows, preceded by an unrelated
    /// windowless row — mirrors the post-expansion `rows` the reveal re-map sees.
    private func expandedRows(window: AXUIElement) -> [SwitcherRow] {
        let parent = SwitcherRow(app: hostApp, window: window, windowTitle: "Browser",
                                 isMinimized: false, cgWindowID: 99)
        let tabs = parent.browserTabRows(tabTitles: ["Inbox", "Docs", "News"])
        let other = SwitcherRow(app: hostApp, window: nil, windowTitle: "", isMinimized: false)
        return [other] + tabs   // [windowless, tab0, tab1, tab2]
    }

    @Test func landsOnActiveTab_notTabOne() {
        let win = axElement()
        let rows = expandedRows(window: win)
        // Active tab is the third (index 2) → row position 3, NOT the first tab (1).
        #expect(SwitcherController.activeBrowserTabIndex(
            in: rows, window: AXRef(element: win), activeTabIndex: 2) == 3)
        // First tab active → its row, position 1.
        #expect(SwitcherController.activeBrowserTabIndex(
            in: rows, window: AXRef(element: win), activeTabIndex: 0) == 1)
    }

    @Test func nilWhenNoTabRowAtThatIndex() {
        let win = axElement()
        let rows = expandedRows(window: win)
        // An active index past the tab count has no matching row → nil, so the caller
        // falls back to the pid match instead of mis-selecting.
        #expect(SwitcherController.activeBrowserTabIndex(
            in: rows, window: AXRef(element: win), activeTabIndex: 9) == nil)
    }

    @Test func nilWhenWindowHasNoTabRows() {
        let win = axElement()
        // No expanded browser rows at all → nil.
        let rows = [SwitcherRow(app: hostApp, window: nil, windowTitle: "", isMinimized: false)]
        #expect(SwitcherController.activeBrowserTabIndex(
            in: rows, window: AXRef(element: win), activeTabIndex: 0) == nil)
    }
}
