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
