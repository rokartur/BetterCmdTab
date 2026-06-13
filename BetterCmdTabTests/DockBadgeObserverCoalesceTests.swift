import Testing
@testable import BetterCmdTab

/// `DockBadgeObserver` collapses a burst of Dock AX notifications into a single
/// debounced refresh via `BadgeRefreshLatch`. These cover that pure coalescing
/// seam: a burst arms exactly once, and the latch re-arms only after it fires.
@Suite("Dock badge refresh latch")
struct DockBadgeObserverCoalesceTests {

    @Test("first arm schedules, the rest of the burst is swallowed")
    func burstArmsOnce() {
        var latch = BadgeRefreshLatch()
        #expect(latch.arm() == true)   // false → true: schedule the debounced pass
        #expect(latch.arm() == false)  // already scheduled
        #expect(latch.arm() == false)
        #expect(latch.scheduled == true)
    }

    @Test("re-arms only after the scheduled pass fires (disarm)")
    func rearmsAfterDisarm() {
        var latch = BadgeRefreshLatch()
        #expect(latch.arm() == true)
        latch.disarm()                 // the debounced pass fired
        #expect(latch.scheduled == false)
        #expect(latch.arm() == true)   // a fresh burst schedules again
    }

    @Test("a fresh latch starts disarmed")
    func startsDisarmed() {
        let latch = BadgeRefreshLatch()
        #expect(latch.scheduled == false)
    }

    @Test("disarm is idempotent")
    func disarmIdempotent() {
        var latch = BadgeRefreshLatch()
        latch.disarm()
        #expect(latch.scheduled == false)
        _ = latch.arm()
        latch.disarm()
        latch.disarm()
        #expect(latch.scheduled == false)
    }
}

/// `DockBadgeReader.snapshot()` refuses to start a second Dock scan while one is
/// still blocked (the panel-open poll ticks faster than a stalled Dock answers)
/// and hands refused callers the last completed map instead. These cover that
/// pure begin/end/last seam in `DockBadgeScanLatch`.
@Suite("Dock badge scan latch")
struct DockBadgeScanLatchTests {

    @Test("only one scan owns the latch; end re-opens it")
    func singleScanInFlight() {
        let latch = DockBadgeScanLatch()
        #expect(latch.begin() == true)    // owner of the scan
        #expect(latch.begin() == false)   // poll tick while the scan is blocked
        latch.end(["com.apple.mail": "3"])
        #expect(latch.begin() == true)    // next tick scans again
    }

    @Test("a refused tick reads the last completed result")
    func refusedTickGetsLastResult() {
        let latch = DockBadgeScanLatch()
        #expect(latch.lastResult().isEmpty) // cold start: nothing scanned yet
        #expect(latch.begin() == true)
        latch.end(["com.apple.mail": "3"])  // first scan completes
        #expect(latch.begin() == true)      // second scan starts…
        #expect(latch.begin() == false)     // …and a tick during it is refused
        #expect(latch.lastResult() == ["com.apple.mail": "3"])
    }
}
