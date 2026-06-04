import Testing
import CoreGraphics
@testable import BetterCmdTab

/// The brute-force AX token scan is expensive (up to a 256-id sweep of
/// cross-process AX IPCs). When a CG-hint window can never resolve to an AX
/// window (a HUD/NSPanel/sheet sized like a window), the scan used to re-run in
/// full on every refresh — driving a continuous storm under a chatty app. These
/// cover the pure decision seam that memoizes the uncoverable wids so the repeat
/// sweep is skipped, without ever dropping a real (or native-tab) window.
@Suite("Brute AX scan decision")
struct BruteAXScanDecisionTests {

    @Test("first sweep runs, then the memo suppresses the repeat")
    func memoSuppressesAfterFirstSweep() {
        let expected: Set<CGWindowID> = [1, 2, 9]   // 9 = unresolvable HUD surface
        let coveredByAXList: Set<CGWindowID> = [1, 2]

        // First bump: no memo yet → the sweep must run.
        #expect(WindowEnumerator.needsBruteScan(
            isRegularApp: true,
            expectedCGWindowIDs: expected,
            coveredWids: coveredByAXList,
            knownUncoverable: []
        ))

        // The sweep finds nothing for 9 → it is recorded as uncoverable.
        let memo = WindowEnumerator.uncoverableWids(
            expectedCGWindowIDs: expected,
            coveredWids: coveredByAXList
        )
        #expect(memo == [9])

        // Next bump, same hint: 9 is subtracted → already covered → no sweep.
        #expect(!WindowEnumerator.needsBruteScan(
            isRegularApp: true,
            expectedCGWindowIDs: expected,
            coveredWids: coveredByAXList,
            knownUncoverable: memo
        ))
    }

    @Test("a genuinely new window re-arms the sweep despite the memo")
    func newRealWidReArms() {
        // 9 is memoized uncoverable; a real new window 3 appears in the hint.
        #expect(WindowEnumerator.needsBruteScan(
            isRegularApp: true,
            expectedCGWindowIDs: [1, 2, 9, 3],
            coveredWids: [1, 2],
            knownUncoverable: [9]
        ))
    }

    @Test("native background tabs are never memoized as uncoverable")
    func nativeTabsAlwaysScan() {
        // Front tab 1 is AX-listed; background tabs 2,3 are brute-only (coverable).
        let expected: Set<CGWindowID> = [1, 2, 3]
        let coveredByAXList: Set<CGWindowID> = [1]

        // Pre-sweep: tabs not yet covered → scan runs.
        #expect(WindowEnumerator.needsBruteScan(
            isRegularApp: true,
            expectedCGWindowIDs: expected,
            coveredWids: coveredByAXList,
            knownUncoverable: []
        ))

        // After the sweep covers all three, nothing is uncoverable → the memo
        // stays empty, so the next refresh still scans (tabs need the brute path).
        let memo = WindowEnumerator.uncoverableWids(
            expectedCGWindowIDs: expected,
            coveredWids: [1, 2, 3]
        )
        #expect(memo.isEmpty)
        #expect(WindowEnumerator.needsBruteScan(
            isRegularApp: true,
            expectedCGWindowIDs: expected,
            coveredWids: coveredByAXList,
            knownUncoverable: memo
        ))
    }

    @Test("a coverable (e.g. late fullscreen) wid is never recorded uncoverable")
    func coverableWidNotMemoized() {
        // 77 is found by the sweep this time → must not enter the memo, so it can
        // never be wrongly suppressed on a later refresh.
        #expect(WindowEnumerator.uncoverableWids(
            expectedCGWindowIDs: [1, 2, 77],
            coveredWids: [1, 2, 77]
        ).isEmpty)
    }

    @Test("uncoverableWids self-prunes wids already covered")
    func uncoverablePrunes() {
        #expect(WindowEnumerator.uncoverableWids(
            expectedCGWindowIDs: [1, 2],
            coveredWids: [1, 2, 5]
        ).isEmpty)
    }

    @Test("an irregular (accessory) app never brute-scans")
    func irregularAppNeverScans() {
        #expect(!WindowEnumerator.needsBruteScan(
            isRegularApp: false,
            expectedCGWindowIDs: [1, 2, 9],
            coveredWids: [],
            knownUncoverable: []
        ))
    }

    @Test("an empty CG hint never brute-scans")
    func emptyHintNeverScans() {
        #expect(!WindowEnumerator.needsBruteScan(
            isRegularApp: true,
            expectedCGWindowIDs: [],
            coveredWids: [],
            knownUncoverable: []
        ))
    }
}
