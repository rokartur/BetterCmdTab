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
