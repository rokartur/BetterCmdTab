import Testing
@testable import BetterCmdTab

/// Pure-logic coverage for `AppCatalogCache.statusPriority`'s bucketing —
/// specifically the `sinkHiddenApps` gate behind "Move hidden apps to the
/// bottom". Exercises the primitive-typed core (not the `SwitcherRow`
/// wrapper) since `SwitcherRow.isHidden` reads a live `NSRunningApplication`,
/// which can't be faked as hidden for the test host process.
@MainActor
@Suite("AppCatalogCache statusPriority")
struct AppCatalogCacheStatusPriorityTests {

    @Test("hidden apps sink to the end when sinkHiddenApps is on")
    func hiddenSinksWhenOn() {
        let priority = AppCatalogCache.statusPriority(
            hasWindow: true, isPlaceholder: false, isHidden: true, isMinimized: false, sinkHiddenApps: true
        )
        #expect(priority == 2)
    }

    @Test("hidden apps keep their normal position when sinkHiddenApps is off")
    func hiddenStaysPutWhenOff() {
        let priority = AppCatalogCache.statusPriority(
            hasWindow: true, isPlaceholder: false, isHidden: true, isMinimized: false, sinkHiddenApps: false
        )
        #expect(priority == 0)
    }

    @Test("a hidden+minimized app falls back to the minimized bucket when sinkHiddenApps is off")
    func hiddenMinimizedFallsToMinimizedBucket() {
        let priority = AppCatalogCache.statusPriority(
            hasWindow: true, isPlaceholder: false, isHidden: true, isMinimized: true, sinkHiddenApps: false
        )
        #expect(priority == 1)
    }

    @Test("windowless rows always sink to the end regardless of sinkHiddenApps")
    func windowlessAlwaysSinks() {
        #expect(AppCatalogCache.statusPriority(hasWindow: false, isPlaceholder: false, isHidden: false, isMinimized: false, sinkHiddenApps: false) == 2)
        #expect(AppCatalogCache.statusPriority(hasWindow: false, isPlaceholder: false, isHidden: false, isMinimized: false, sinkHiddenApps: true) == 2)
    }

    @Test("placeholders stay at normal priority even without a window")
    func placeholdersStayNormal() {
        #expect(AppCatalogCache.statusPriority(hasWindow: false, isPlaceholder: true, isHidden: false, isMinimized: false, sinkHiddenApps: true) == 0)
    }

    @Test("a visible, non-minimized app is always priority 0")
    func normalAppStaysAtFront() {
        #expect(AppCatalogCache.statusPriority(hasWindow: true, isPlaceholder: false, isHidden: false, isMinimized: false, sinkHiddenApps: true) == 0)
    }
}
