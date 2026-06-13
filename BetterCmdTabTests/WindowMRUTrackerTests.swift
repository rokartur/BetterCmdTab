import AppKit
import Testing
@testable import BetterCmdTab

/// Covers the flat cross-app window-recency sort (`.mruWindows`) backed by
/// `WindowMRUTracker.globalOrder`. The per-app `sortRows(forPid:)` path shares
/// the same ranking shape; these focus on the global sort the feature adds.
///
/// Rows are built with a real `cgWindowID` and `window: nil` so the sort reads
/// the id directly — no live AX messaging. `NSRunningApplication.current` backs
/// every row; the global sort ignores pid, so the same app is fine throughout.
@MainActor
@Suite("WindowMRUTracker global sort")
struct WindowMRUTrackerTests {

    private func row(_ wid: CGWindowID, title: String = "") -> SwitcherRow {
        SwitcherRow(app: .current, window: nil, windowTitle: title, isMinimized: false, cgWindowID: wid)
    }

    @Test("orders windows by recency, newest first")
    func ordersByRecency() {
        let tracker = WindowMRUTracker()
        tracker.bump(pid: 1, wid: 10)
        tracker.bump(pid: 2, wid: 20)
        tracker.bump(pid: 1, wid: 30)
        // globalOrder is now [30, 20, 10] — most recent first.
        let sorted = tracker.sortRowsGlobally([row(10), row(20), row(30)])
        #expect(sorted.map(\.cgWindowID) == [30, 20, 10])
    }

    @Test("re-focusing a window moves it to the front")
    func reBumpMovesToFront() {
        let tracker = WindowMRUTracker()
        tracker.bump(pid: 1, wid: 10)
        tracker.bump(pid: 2, wid: 20)
        tracker.bump(pid: 1, wid: 10) // 10 focused again → ahead of 20
        let sorted = tracker.sortRowsGlobally([row(20), row(10)])
        #expect(sorted.map(\.cgWindowID) == [10, 20])
    }

    @Test("windows interleave across apps by focus time")
    func interleavesAcrossApps() {
        let tracker = WindowMRUTracker()
        // App 1 owns 10 & 11, app 2 owns 20 & 21; focus order interleaves them.
        tracker.bump(pid: 1, wid: 10)
        tracker.bump(pid: 2, wid: 20)
        tracker.bump(pid: 1, wid: 11)
        tracker.bump(pid: 2, wid: 21)
        // globalOrder [21, 11, 20, 10] — not grouped by app.
        let rows = [row(10), row(11), row(20), row(21)]
        let sorted = tracker.sortRowsGlobally(rows)
        #expect(sorted.map(\.cgWindowID) == [21, 11, 20, 10])
    }

    @Test("unseen windows sink to the back, keeping their incoming order")
    func unknownWindowsToBack() {
        let tracker = WindowMRUTracker()
        tracker.bump(pid: 1, wid: 10)
        // 99 and 88 were never focused → rank Int.max, stable on original offset.
        let sorted = tracker.sortRowsGlobally([row(99), row(10), row(88)])
        #expect(sorted.map(\.cgWindowID) == [10, 99, 88])
    }

    @Test("windowless rows sink to the back, stable among themselves")
    func windowlessRowsToBack() {
        let tracker = WindowMRUTracker()
        tracker.bump(pid: 1, wid: 10)
        tracker.bump(pid: 2, wid: 20)
        let rows = [row(0, title: "wl1"), row(10), row(0, title: "wl2"), row(20)]
        let sorted = tracker.sortRowsGlobally(rows)
        #expect(sorted.map(\.cgWindowID) == [20, 10, 0, 0])
        // The two windowless rows keep their incoming relative order.
        #expect(sorted[2].windowTitle == "wl1")
        #expect(sorted[3].windowTitle == "wl2")
    }

    @Test("closed windows in the order are ignored")
    func deadIdsPruned() {
        let tracker = WindowMRUTracker()
        tracker.bump(pid: 1, wid: 10)
        tracker.bump(pid: 2, wid: 20)
        tracker.bump(pid: 1, wid: 30)
        // 20's window has since closed — only 10 and 30 remain on screen.
        let sorted = tracker.sortRowsGlobally([row(10), row(30)])
        #expect(sorted.map(\.cgWindowID) == [30, 10])
    }

    @Test("sorting a filtered row set does not erase recency of hidden live windows")
    func filteredSortKeepsHiddenWindowRecency() {
        let tracker = WindowMRUTracker()
        tracker.bump(pid: 1, wid: 10)
        tracker.bump(pid: 1, wid: 20)
        tracker.bump(pid: 1, wid: 30)
        // globalOrder [30, 20, 10]. A Current-Space-only (or hide-minimized)
        // pass filters 20's live window out of the rows for this sort.
        _ = tracker.sortRowsGlobally([row(10), row(30)])
        // Back in view: 20's recency must have survived the filtered sort.
        let sorted = tracker.sortRowsGlobally([row(10), row(20), row(30)])
        #expect(sorted.map(\.cgWindowID) == [30, 20, 10])
    }

    @Test("per-app sort keeps recency of windows filtered from the row set")
    func perAppFilteredSortKeepsRecency() {
        let tracker = WindowMRUTracker()
        tracker.bump(pid: 1, wid: 10)
        tracker.bump(pid: 1, wid: 20)
        tracker.bump(pid: 1, wid: 30)
        // order[1] == [30, 20, 10]; 20 is hidden from this Cmd+` pass.
        _ = tracker.sortRows([row(10), row(30)], forPid: 1)
        let sorted = tracker.sortRows([row(10), row(20), row(30)], forPid: 1)
        #expect(sorted.map(\.cgWindowID) == [30, 20, 10])
    }

    @Test("empty order leaves rows untouched")
    func emptyOrderIsIdentity() {
        let tracker = WindowMRUTracker()
        let sorted = tracker.sortRowsGlobally([row(10), row(20)])
        #expect(sorted.map(\.cgWindowID) == [10, 20])
    }

    @Test("a single row is returned unchanged")
    func singleRowUnchanged() {
        let tracker = WindowMRUTracker()
        tracker.bump(pid: 1, wid: 10)
        let sorted = tracker.sortRowsGlobally([row(10)])
        #expect(sorted.map(\.cgWindowID) == [10])
    }

    @Test("wid 0 is never recorded in the order")
    func zeroWidNotRecorded() {
        let tracker = WindowMRUTracker()
        tracker.bump(pid: 1, wid: 0) // ignored by bump's guard
        tracker.bump(pid: 1, wid: 10)
        // Only 10 is ranked; the windowless row stays behind it.
        let sorted = tracker.sortRowsGlobally([row(0, title: "wl"), row(10)])
        #expect(sorted.map(\.cgWindowID) == [10, 0])
    }
}
