import Foundation
import Testing
@testable import BetterCmdTab

@Suite("FocusResolveRetry")
struct FocusResolveRetryTests {

    @Test("an empty resolve for the frontmost app walks the schedule, then stops")
    func walksTheSchedule() {
        let delays = FocusResolveRetry.delays
        for attempt in delays.indices {
            #expect(FocusResolveRetry.delay(afterAttempt: attempt, resolved: false, isFrontmost: true) == delays[attempt])
        }
        #expect(FocusResolveRetry.delay(afterAttempt: delays.count, resolved: false, isFrontmost: true) == nil)
    }

    @Test("a resolve that found a window is never retried")
    func resolvedIsFinal() {
        #expect(FocusResolveRetry.delay(afterAttempt: 0, resolved: true, isFrontmost: true) == nil)
    }

    @Test("an app the user has left is not asked again")
    func backgroundAppIsLeftAlone() {
        #expect(FocusResolveRetry.delay(afterAttempt: 0, resolved: false, isFrontmost: false) == nil)
    }

    @Test("an out-of-range attempt yields no retry")
    func outOfRangeAttempt() {
        #expect(FocusResolveRetry.delay(afterAttempt: -1, resolved: false, isFrontmost: true) == nil)
    }

    @Test("a retry that lands after the user left does not bump")
    func lateRetryDoesNotBump() {
        #expect(!FocusResolveRetry.mayBump(attempt: 1, resolved: true, isFrontmost: false))
        #expect(FocusResolveRetry.mayBump(attempt: 1, resolved: true, isFrontmost: true))
    }

    @Test("the first resolve bumps even when the app is no longer frontmost")
    func firstResolveBumps() {
        #expect(FocusResolveRetry.mayBump(attempt: 0, resolved: true, isFrontmost: false))
        #expect(!FocusResolveRetry.mayBump(attempt: 0, resolved: false, isFrontmost: true))
    }
}
