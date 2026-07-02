import Testing
@testable import BetterCmdTab

/// Covers the per-pid focus-resolve coalescing that feeds the window MRU: a
/// notification burst collapses to one resolve, but a change arriving while a
/// resolve is in flight must schedule exactly one re-run instead of being
/// dropped (#85 — the dropped trailing change lost the newly focused window).
@Suite("FocusSyncCoalescer")
struct FocusSyncCoalescerTests {

    @Test("first change starts a resolve")
    func firstChangeStarts() {
        var c = FocusSyncCoalescer()
        let started = c.begin(1)
        #expect(started)
    }

    @Test("changes mid-flight coalesce into one re-run")
    func midFlightCoalescesToOneRerun() {
        var c = FocusSyncCoalescer()
        _ = c.begin(1)
        // A burst lands while the resolve is in flight — none start a new one.
        let second = c.begin(1)
        let third = c.begin(1)
        #expect(!second)
        #expect(!third)
        // The flight lands: exactly one re-run is owed for the whole burst.
        let rerun = c.finish(1)
        #expect(rerun)
        let restarted = c.begin(1)
        #expect(restarted)
        // …and the re-run itself owes nothing once it lands quietly.
        let owed = c.finish(1)
        #expect(!owed)
    }

    @Test("a quiet flight owes no re-run")
    func quietFlightNoRerun() {
        var c = FocusSyncCoalescer()
        _ = c.begin(1)
        let rerun = c.finish(1)
        #expect(!rerun)
        let restarted = c.begin(1)
        #expect(restarted)
    }

    @Test("pids coalesce independently")
    func pidsIndependent() {
        var c = FocusSyncCoalescer()
        _ = c.begin(1)
        let otherPid = c.begin(2)
        #expect(otherPid)
        let dupe = c.begin(1)
        #expect(!dupe)
        // pid 2 lands quietly; pid 1 still owes its re-run.
        let quiet = c.finish(2)
        #expect(!quiet)
        let rerun = c.finish(1)
        #expect(rerun)
    }
}
