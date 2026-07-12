import AppKit
import ApplicationServices
import CoreGraphics
import Testing
@testable import BetterCmdTab

/// Pure-logic coverage for the experimental browser-tab MRU (#39): tabs are
/// first-class recency entries interleaved with ordinary windows, so ⌘Tab can
/// return to the previously used *tab*, not just the previous window. Exercises
/// the key mapping and the unified sort without any AX/Apple Events.
@MainActor
@Suite("Browser tab MRU")
struct BrowserTabMRUTrackerTests {
    private var hostApp: NSRunningApplication { .current }
    private func axElement() -> AXUIElement { AXUIElementCreateApplication(getpid()) }

    private func windowRow(wid: CGWindowID, title: String = "W") -> SwitcherRow {
        SwitcherRow(app: hostApp, window: axElement(), windowTitle: title, isMinimized: false, cgWindowID: wid)
    }
    /// Expand one browser window (wid) into per-tab rows, mirroring the live path.
    private func tabRows(wid: CGWindowID, titles: [String]) -> [SwitcherRow] {
        let parent = SwitcherRow(app: hostApp, window: axElement(),
                                 windowTitle: titles.first ?? "", isMinimized: false, cgWindowID: wid)
        return parent.browserTabRows(tabTitles: titles)
    }

    @Test func keyDistinguishesTabWindowAndWindowless() {
        #expect(BrowserTabMRUTracker.key(for: windowRow(wid: 10)) == .window(10))
        let tabs = tabRows(wid: 20, titles: ["A", "B"])
        #expect(BrowserTabMRUTracker.key(for: tabs[0]) == .tab(20, "A"))
        #expect(BrowserTabMRUTracker.key(for: tabs[1]) == .tab(20, "B"))
        // Windowless row (cgWindowID 0) has no recency key.
        let windowless = SwitcherRow(app: hostApp, window: nil, windowTitle: "", isMinimized: false)
        #expect(BrowserTabMRUTracker.key(for: windowless) == nil)
    }

    @Test func sortRowsOrdersByTabRecency() {
        let t = BrowserTabMRUTracker()
        let tabs = tabRows(wid: 5, titles: ["Inbox", "Docs", "News"])
        // The user last viewed News, then Docs — Inbox never focused.
        t.bump(.tab(5, "News"))
        t.bump(.tab(5, "Docs"))
        // Docs (newest), News, then Inbox (unknown → back, stable on incoming order).
        #expect(t.sortRows(tabs).map(\.windowTitle) == ["Docs", "News", "Inbox"])
    }

    @Test func unknownKeysKeepIncomingOrderAtBack() {
        let t = BrowserTabMRUTracker()
        t.bump(.window(3))   // only window 3 is known
        let sorted = t.sortRows([windowRow(wid: 1), windowRow(wid: 2), windowRow(wid: 3)])
        // 3 floats to the front; 1 and 2 (unknown) keep their incoming order.
        #expect(sorted.map(\.cgWindowID) == [3, 1, 2])
    }

    @Test func tabsAndWindowsShareOneTimeline() {
        let t = BrowserTabMRUTracker()
        let finder = windowRow(wid: 1, title: "Finder")
        let tabs = tabRows(wid: 9, titles: ["T1", "T2"])
        // Focus T1, then Finder, then T2 → recency T2, Finder, T1. A tab can rank
        // between two windows — the whole point versus the window-only sort.
        t.bump(.tab(9, "T1"))
        t.bump(.window(1))
        t.bump(.tab(9, "T2"))
        #expect(t.sortRows([finder, tabs[0], tabs[1]]).map(\.windowTitle) == ["T2", "Finder", "T1"])
    }

    @Test func bumpDeduplicatesSoRecencyIsExact() {
        let t = BrowserTabMRUTracker()
        t.bump(.tab(2, "A"))
        t.bump(.tab(2, "B"))
        t.bump(.tab(2, "A"))   // re-focusing A moves it back to front, not a 2nd copy
        #expect(t.order == [.tab(2, "A"), .tab(2, "B")])
    }

    @Test func forgetWindowDropsAllItsEntries() {
        let t = BrowserTabMRUTracker()
        t.bump(.tab(7, "A"))
        t.bump(.window(7))
        t.bump(.tab(8, "X"))
        t.forgetWindow(7)
        #expect(t.order.allSatisfy { $0.wid != 7 })
        #expect(t.order == [.tab(8, "X")])
    }

    @Test func windowlessAndZeroWidAreIgnored() {
        let t = BrowserTabMRUTracker()
        t.bump(.window(0))   // a 0 wid is windowless — never tracked
        #expect(t.order.isEmpty)
    }

    @Test func tabKeyTrimsTitleSoWhitespaceDoesNotSplitEntries() {
        // The observer (AX title) and the displayed rows (osascript title) can
        // differ by stray whitespace; trimming both onto one key keeps the current
        // tab from being a separate entry that misses row 0.
        #expect(BrowserTabMRUTracker.tabKey(wid: 3, title: "  Inbox \n") == .tab(3, "Inbox"))
        let t = BrowserTabMRUTracker()
        t.bump(BrowserTabMRUTracker.tabKey(wid: 3, title: " Inbox "))   // whitespacey AX title
        // Clean osascript row titles — the trimmed bump still matches "Inbox".
        #expect(t.sortRows(tabRows(wid: 3, titles: ["Inbox", "Docs"])).first?.windowTitle == "Inbox")
    }
}
