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
}
