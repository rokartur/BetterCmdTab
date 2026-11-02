import AppKit
import Testing
@testable import BetterCmdTab

@Suite("Browser tab MRU candidate selection")
@MainActor
struct BrowserTabSelectionTests {
    private func window(pid: Int32 = 1, wid: UInt32 = 1, count: Int = 10,
                        active: Int = 0, priority: Int = 0, focused: Int? = nil) -> BrowserTabSelection.Window {
        .init(pid: pid, wid: wid,
              tabs: (1...count).map { BrowserTabInfo(title: "Tab \($0)", url: "https://test.invalid/\($0)") },
              activeIndex: active, statusPriority: priority, focusedIndex: focused)
    }

    @Test("five non-adjacent visits select five recent tabs, with original activation indices")
    func nonAdjacentVisits() {
        let tracker = BrowserTabMRUTracker()
        for number in [10, 2, 8, 4, 6] { tracker.bump(.tab(1, "Tab \(number)")) }
        let result = BrowserTabSelection.select([window(active: 5)], ranking: tracker.ranking(), limit: 5)
        #expect(result.indices[0] == [5, 3, 7, 1, 9])
        #expect(result.fallbackWindows.isEmpty)
    }

    @Test("the limit spans windows of one browser and is independent for another browser")
    func perBrowserQuota() {
        let tracker = BrowserTabMRUTracker()
        tracker.bump(.tab(1, "Tab 9"))
        tracker.bump(.tab(2, "Tab 3"))
        tracker.bump(.tab(1, "Tab 5"))
        tracker.bump(.tab(3, "Tab 8"))
        let result = BrowserTabSelection.select(
            [window(), window(wid: 2), window(pid: 2, wid: 3)], ranking: tracker.ranking(), limit: 2)
        #expect(result.indices[0] == [4])
        #expect(result.indices[1] == [2])
        #expect(result.indices[2] == [7])
    }

    @Test("background active tabs neither fill spare slots nor escape the quota")
    func historyShortage() {
        let tracker = BrowserTabMRUTracker()
        tracker.bump(.tab(1, "Tab 9"))
        let result = BrowserTabSelection.select([window(), window(wid: 2)], ranking: tracker.ranking(), limit: 5)
        #expect(result.indices[0] == [8])
        #expect(result.indices[1] == nil)
        #expect(result.fallbackWindows.isEmpty)
    }

    @Test("no tab history retains one browser window instead of invented recency")
    func coldStart() {
        let tracker = BrowserTabMRUTracker()
        tracker.bump(.window(1))
        let result = BrowserTabSelection.select(
            [window(), window(wid: 2), window(pid: 2, wid: 3)], ranking: tracker.ranking(), limit: 5)
        #expect(result.indices.isEmpty)
        #expect(result.fallbackWindows == [0, 2])
    }

    @Test("the genuinely focused tab is included and counts toward the limit")
    func focusedTab() {
        let tracker = BrowserTabMRUTracker()
        tracker.bump(.tab(1, "Tab 2"))
        tracker.bump(.tab(1, "Tab 3"))
        let result = BrowserTabSelection.select(
            [window(active: 8, focused: 8), window(wid: 2, active: 7)], ranking: tracker.ranking(), limit: 2)
        #expect(result.indices[0] == [8, 2])
        #expect(result.indices[1] == nil)
    }

    @Test("zero removes the quota without treating unknown tabs as visits")
    func unlimitedKnownHistory() {
        let tracker = BrowserTabMRUTracker()
        for n in [9, 2, 7] { tracker.bump(.tab(1, "Tab \(n)")) }
        let result = BrowserTabSelection.select([window()], ranking: tracker.ranking(), limit: 0)
        #expect(result.indices[0] == [6, 1, 8])
    }

    @Test("a history entry on an excluded window cannot displace an eligible tab")
    func excludedWindow() {
        let tracker = BrowserTabMRUTracker()
        tracker.bump(.tab(1, "Tab 4"))
        tracker.bump(.tab(2, "Tab 9"))
        let result = BrowserTabSelection.select([window()], ranking: tracker.ranking(), limit: 1)
        #expect(result.indices[0] == [3])
    }

    @Test("selection and row sorting share Chromium suffix matching")
    func chromiumSuffix() {
        let tracker = BrowserTabMRUTracker()
        tracker.bump(.tab(1, "  Tab 7 - Google Chrome - Work  "))
        #expect(tracker.ranking().rank(for: .tab(1, "Tab 7")) == 0)
        #expect(tracker.ranking().rank(for: .tab(1, "Tab")) == nil)
        let result = BrowserTabSelection.select([window()], ranking: tracker.ranking(), limit: 5)
        #expect(result.indices[0] == [6])
    }

    @Test("a newer AX-title visit outranks an older exact commit key")
    func newerSuffixVisit() {
        let tracker = BrowserTabMRUTracker()
        tracker.bump(.tab(1, "Tab 7"))
        tracker.bump(.tab(1, "Tab 4"))
        tracker.bump(.tab(1, "Tab 7 - Google Chrome - Work"))
        #expect(tracker.ranking().rank(for: .tab(1, "Tab 7")) == 0)
        let result = BrowserTabSelection.select([window()], ranking: tracker.ranking(), limit: 1)
        #expect(result.indices[0] == [6])
    }

    @Test("equal title ranks do not merge separate tabs or windows")
    func equalTitlesAreNotIdentity() {
        let tracker = BrowserTabMRUTracker()
        tracker.bump(.tab(1, "Same"))
        let w = BrowserTabSelection.Window(pid: 1, wid: 1,
            tabs: [.init(title: "Same", url: "a"), .init(title: "Same", url: "b")],
            activeIndex: 0, statusPriority: 0, focusedIndex: nil)
        let result = BrowserTabSelection.select([w], ranking: tracker.ranking(), limit: 5)
        #expect(result.indices[0] == [0, 1])
    }

    @Test("inactive mirrors do not consume slots, active mirrors still obey the quota")
    func mirrorsBeforeQuota() {
        let tracker = BrowserTabMRUTracker()
        tracker.bump(.tab(1, "Tab 1"))
        tracker.bump(.tab(2, "Tab 1"))
        tracker.bump(.tab(1, "Tab 4"))
        let result = BrowserTabSelection.select(
            [window(active: 3), window(wid: 2, active: 0)], ranking: tracker.ranking(), limit: 2)
        #expect(result.indices[0] == [3])
        #expect(result.indices[1] == [0])
        let capped = BrowserTabSelection.select(
            [window(), window(wid: 2)], ranking: tracker.ranking(), limit: 1)
        #expect(capped.indices.values.reduce(0) { $0 + $1.count } == 1)
    }

    @Test("existing visible-before-minimized priority is respected when choosing the quota")
    func statusPriority() {
        let tracker = BrowserTabMRUTracker()
        tracker.bump(.tab(1, "Tab 5"))
        tracker.bump(.tab(2, "Tab 9"))
        let result = BrowserTabSelection.select(
            [window(), window(wid: 2, priority: 1)], ranking: tracker.ranking(), limit: 1)
        #expect(result.indices[0] == [4])
        #expect(result.indices[1] == nil)
    }

    @Test("the newest inactive mirror wins over its earlier catalog copy")
    func newestInactiveMirror() {
        let tracker = BrowserTabMRUTracker()
        tracker.bump(.tab(1, "Tab 1"))
        tracker.bump(.tab(2, "Tab 1"))
        let result = BrowserTabSelection.select(
            [window(active: 4), window(wid: 2, active: 4)], ranking: tracker.ranking(), limit: 1)
        #expect(result.indices[0] == nil)
        #expect(result.indices[1] == [0])
    }

    @Test("a refresh replaces equal-looking rows when the target window changes")
    func equalLookingRefresh() {
        let first = SwitcherRow(app: .current, window: nil, windowTitle: "Same", isMinimized: false, cgWindowID: 1)
        let second = SwitcherRow(app: .current, window: nil, windowTitle: "Same", isMinimized: false, cgWindowID: 2)
        #expect(SwitcherController.rowsDifferVisibly([first], [second]))
        #expect(!SwitcherController.rowsDifferVisibly([first], [first]))
    }

    @Test("the indexed title rule matches the existing rule, including punctuation and whitespace", arguments: [
        "Inbox", " Inbox - Google Chrome - Work ", "Notes - Draft — Chrome",
        "A - - Chrome", "Title  - Chrome", "Title\t - Chrome", "—", " - Chrome",
        "", " \n ", "标题 — Chrome", "A – B - Chrome", "啊 - Chrome", "🔎 - Chrome", "Object\u{FFFC} - Chrome"
    ])
    func indexedTitleRule(window: String) {
        let tracker = BrowserTabMRUTracker()
        tracker.bump(.tab(1, window))
        let ranking = tracker.ranking()
        let candidates = [window, "", "Inbox", "Inbox - Google Chrome", "Notes", "Notes - Draft",
                          "A", "A -", "Title", "Title ", "Title\t", "—", "Chrome", "标题", "A – B",
                          "Other", "啊", "🔎", "Object\u{FFFC}"]
        for tab in candidates {
            let exact = window.trimmingCharacters(in: .whitespacesAndNewlines)
                == tab.trimmingCharacters(in: .whitespacesAndNewlines)
            let expected = exact || BrowserTabs.windowTitle(window, matchesTab: tab)
            #expect((ranking.rank(for: .tab(1, tab)) != nil) == expected,
                    "window=\(window), tab=\(tab)")
        }
    }

    @Test("spaces are not silently removed inside a title; overlapping separators remain valid")
    func titleBoundaries() {
        let tracker = BrowserTabMRUTracker()
        tracker.bump(.tab(1, "Title  - Chrome"))
        tracker.bump(.tab(2, "A - - Chrome"))
        let ranking = tracker.ranking()
        #expect(ranking.rank(for: .tab(1, "Title")) == nil)
        #expect(ranking.rank(for: .tab(2, "A -")) == 0)
    }

    @Test("rank snapshots stay immutable while new visits and closes invalidate the cached index")
    func rankingInvalidation() {
        let tracker = BrowserTabMRUTracker()
        tracker.bump(.tab(1, "First"))
        let before = tracker.ranking()
        tracker.bump(.tab(1, "Second"))
        #expect(tracker.ranking().rank(for: .tab(1, "First")) == 1)
        #expect(before.rank(for: .tab(1, "First")) == 0)
        tracker.forgetWindow(1)
        #expect(tracker.ranking().rank(for: .tab(1, "Second")) == nil)
        #expect(tracker.ranking().rank(for: .window(1)) == nil)
    }
}
