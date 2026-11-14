import Testing
@testable import BetterCmdTab

/// Covers `MRUTracker.noteLaunch`, which ranks an app that launched without
/// activating behind the current and previous apps instead of last, so a
/// quick ⌘Tab still returns to the previous app.
@MainActor
@Suite("MRUTracker launch placement")
struct MRUTrackerLaunchTests {

    @Test("a launched app goes right behind the previous app")
    func launchedAppGoesThird() {
        let tracker = MRUTracker()
        tracker.bump(3)
        tracker.bump(2)
        tracker.bump(1)
        tracker.noteLaunch(9)
        #expect(tracker.order == [1, 2, 9, 3])
    }

    @Test("a launched app goes right behind the current app when there is no previous app")
    func launchedAppGoesSecondBehindOnlyApp() {
        let tracker = MRUTracker()
        tracker.bump(1)
        tracker.noteLaunch(9)
        #expect(tracker.order == [1, 9])
    }

    @Test("a launched app goes first when no app is ranked")
    func launchedAppGoesFirstWhenEmpty() {
        let tracker = MRUTracker()
        tracker.noteLaunch(9)
        #expect(tracker.order == [9])
    }

    @Test("an app that activated before its launch note keeps its place")
    func alreadyRankedAppKeepsPlace() {
        let tracker = MRUTracker()
        tracker.bump(2)
        tracker.bump(9)
        tracker.noteLaunch(9)
        #expect(tracker.order == [9, 2])
    }
}
