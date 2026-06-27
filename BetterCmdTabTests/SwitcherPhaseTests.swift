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

    @Test func off_underSecureInput() {
        // Under Secure Event Input `HoldModifierMonitor` owns the release poll;
        // running both would double-poll, so this backstop stands down.
        #expect(!arm(secureInputActive: true))
        // Even drilled-in, secure input keeps it off (no double-poll).
        #expect(!arm(stickyOpen: true, tabDrillActive: true, secureInputActive: true))
    }
}
