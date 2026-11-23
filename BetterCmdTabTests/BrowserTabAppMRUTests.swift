import AppKit
import Testing
@testable import BetterCmdTab

@Suite("Browser tab MRU within applications")
@MainActor
struct BrowserTabAppMRUTests {
    @Test("app order stays fixed while each browser's tabs cross window boundaries")
    func preserveAppSlots() {
        let result = BrowserTabMRUTracker.appSlotOrder(
            pids: [1, 1, 1, 2, 2, 3, 3], priorities: [0, 0, 0, 0, 0, 0, 0],
            rankedIndices: [4, 2, 5, 0, 3, 6, 1], includedPids: [1, 2])
        #expect(result == [2, 0, 1, 4, 3, 5, 6])
    }

    @Test("status-split app slots and non-browser rows retain their places")
    func splitSlots() {
        let result = BrowserTabMRUTracker.appSlotOrder(
            pids: [1, nil, 2, 1, 3, 3], priorities: [0, 0, 0, 0, 0, 0],
            rankedIndices: [5, 3, 2, 0, 4, 1], includedPids: [1])
        #expect(result == [3, 1, 2, 0, 4, 5])
    }

    @Test("app recency keeps a non-browser app's window order across status buckets")
    func appRecencyKeepsWindowOrder() {
        let minimized = SwitcherRow(app: .current, window: nil, windowTitle: "w2", isMinimized: true, cgWindowID: 2)
        let visible = SwitcherRow(app: .current, window: nil, windowTitle: "w1", isMinimized: false, cgWindowID: 1)
        let sorted = SwitcherController.tabRecencyOrder(
            [minimized, visible], appGrouped: true, tabMRU: BrowserTabMRUTracker(), pinnedBundleIDs: []
        ) { $0.isMinimized ? 1 : 0 }
        #expect(sorted.map(\.cgWindowID) == [2, 1])
    }

    @Test("minimized recency cannot move another application ahead after status bucketing")
    func statusBucketsPreserveAppOrder() {
        #expect(BrowserTabMRUTracker.appSlotOrder(
            pids: [1, 2, 1, 2], priorities: [0, 0, 1, 1],
            rankedIndices: [2, 3, 1, 0], includedPids: [1, 2]) == [0, 1, 2, 3])
    }

    @Test("tabs are independent entries, not consecutive groups of parent windows")
    func rowsAcrossWindows() {
        let tracker = BrowserTabMRUTracker()
        tracker.bump(.tab(1, "A"))
        tracker.bump(.tab(2, "C"))
        tracker.bump(.tab(1, "B"))
        tracker.bump(.tab(2, "D"))
        func row(_ wid: UInt32, _ index: Int, _ title: String) -> SwitcherRow {
            SwitcherRow(app: .current, window: nil, windowTitle: title, isMinimized: false, cgWindowID: wid,
                        browserTab: .init(index: index, parentTitle: "Parent", url: "", isActive: false))
        }
        let rows = [row(1, 0, "A"), row(1, 1, "B"), row(2, 0, "C"), row(2, 1, "D")]
        let sorted = tracker.sortRowsWithinApps(rows, browserPids: [rows[0].pid!], priorities: [0, 0, 0, 0])
        #expect(sorted.map(\.windowTitle) == ["D", "B", "C", "A"])
        #expect(sorted.map(\.cgWindowID) == [2, 1, 2, 1])
        #expect(sorted.compactMap { $0.browserTab?.index } == [1, 1, 0, 0])
    }

    @Test("a window excluded by the tab quota remains reachable in app recency")
    func quotaKeepsWholeWindow() {
        let tracker = BrowserTabMRUTracker()
        let visits: [(UInt32, String)] = [(2, "B1"), (1, "A1"), (1, "A2")]
        for (wid, title) in visits {
            tracker.bump(.tab(wid, title))
        }
        let pid = NSRunningApplication.current.pid
        let whole = SwitcherRow(app: .current, window: nil, windowTitle: "Window B",
                                isMinimized: false, cgWindowID: 2)
        let tabs = ["A1", "A2"].enumerated().map { index, title in
            SwitcherRow(app: .current, window: nil, windowTitle: title, isMinimized: false, cgWindowID: 1,
                        browserTab: .init(index: index, parentTitle: "Window A", url: title, isActive: index == 1))
        }
        let sorted = tracker.sortRowsWithinApps([whole] + tabs, browserPids: [pid], priorities: [0, 0, 0])
        #expect(sorted.map(\.windowTitle) == ["A2", "A1", "Window B"])
        #expect(sorted.last?.browserTab == nil)
    }

    @Test("unlimited app recency keeps unobserved tabs after the used tabs")
    func unlimitedIncludesUnobservedTabs() {
        let tracker = BrowserTabMRUTracker()
        tracker.bump(.tab(1, "A2"))
        let pid = NSRunningApplication.current.pid
        let tabs = ["A1", "A2", "A3"].map { BrowserTabInfo(title: $0, url: $0) }
        let rows = tabs.enumerated().map { index, tab in
            SwitcherRow(app: .current, window: nil, windowTitle: tab.title, isMinimized: false, cgWindowID: 1,
                        browserTab: .init(index: index, parentTitle: "Window A", url: tab.url, isActive: index == 1))
        }
        let sorted = tracker.sortRowsWithinApps(rows, browserPids: [pid], priorities: [0, 0, 0])
        #expect(sorted.map(\.windowTitle) == ["A2", "A1", "A3"])
    }
}
