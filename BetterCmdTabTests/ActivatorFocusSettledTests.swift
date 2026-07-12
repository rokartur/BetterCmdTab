import CoreGraphics
import Testing
@testable import BetterCmdTab

/// Covers the pure decision core of the post-activation focus verify
/// (`Activator.focusSettled`): CGWindowID comparison when both sides resolved
/// one, AX element identity as the fallback when either id is unavailable.
@Suite("Activator focus-settled decision")
struct ActivatorFocusSettledTests {

    @Test("matching window ids settle")
    func matchingWidsSettle() {
        #expect(Activator.focusSettled(targetWid: 42, focusedWid: 42, sameElement: false))
    }

    @Test("differing window ids do not settle")
    func differingWidsDoNotSettle() {
        #expect(!Activator.focusSettled(targetWid: 42, focusedWid: 7, sameElement: false))
    }

    @Test("unresolved focused id falls back to element identity")
    func unresolvedFocusedIdUsesElement() {
        #expect(Activator.focusSettled(targetWid: 42, focusedWid: 0, sameElement: true))
        #expect(!Activator.focusSettled(targetWid: 42, focusedWid: 0, sameElement: false))
    }

    @Test("unresolved target id falls back to element identity")
    func unresolvedTargetIdUsesElement() {
        #expect(Activator.focusSettled(targetWid: 0, focusedWid: 7, sameElement: true))
        #expect(!Activator.focusSettled(targetWid: 0, focusedWid: 7, sameElement: false))
    }

    @Test("nothing resolved and no element match reads as not settled")
    func nothingResolvedNotSettled() {
        #expect(!Activator.focusSettled(targetWid: 0, focusedWid: 0, sameElement: false))
    }
}

/// Covers the pure raise-id fallback (`Activator.resolvedWindowID`): the live
/// `_AXUIElementGetWindow` resolve wins when it succeeded; the enumeration-time
/// cached id (`SwitcherRow.cgWindowID`) backs it up when the AX element has
/// gone stale — the Electron fast-switch case where the app activated but its
/// window stayed behind because the SLPS raise was skipped on `wid == 0`.
@Suite("Activator resolved-window-id fallback")
struct ActivatorResolvedWindowIDTests {

    @Test("live resolve wins when available")
    func liveWins() {
        #expect(Activator.resolvedWindowID(live: 42, cached: 7) == 42)
    }

    @Test("stale element falls back to the cached id")
    func staleFallsBackToCached() {
        #expect(Activator.resolvedWindowID(live: 0, cached: 7) == 7)
    }

    @Test("nothing resolved stays zero")
    func nothingResolvedStaysZero() {
        #expect(Activator.resolvedWindowID(live: 0, cached: 0) == 0)
    }
}
