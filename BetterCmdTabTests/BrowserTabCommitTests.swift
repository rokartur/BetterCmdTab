import Testing
@testable import BetterCmdTab

@Suite("Browser tab commit: raise vs select")
struct BrowserTabCommitTests {
    private let tabs = [
        BrowserTabInfo(title: "Inbox", url: "https://test.invalid/1"),
        BrowserTabInfo(title: "Docs", url: "https://test.invalid/2"),
        BrowserTabInfo(title: "New Tab", url: "https://test.invalid/3"),
        BrowserTabInfo(title: "New Tab", url: "https://test.invalid/4"),
    ]

    @Test func liveTitleNamesTheTabRaises() {
        #expect(SwitcherController.raisesWindowToShowTab(at: 1, tabs: tabs, liveWindowTitle: "Docs"))
    }

    @Test func chromiumSuffixedTitleRaises() {
        #expect(SwitcherController.raisesWindowToShowTab(at: 0, tabs: tabs, liveWindowTitle: "Inbox - Google Chrome"))
    }

    @Test func liveTitleNamesAnotherTabSelects() {
        #expect(!SwitcherController.raisesWindowToShowTab(at: 0, tabs: tabs, liveWindowTitle: "Docs"))
    }

    @Test func failedTitleReadSelects() {
        #expect(!SwitcherController.raisesWindowToShowTab(at: 0, tabs: tabs, liveWindowTitle: ""))
    }

    @Test func sharedTitleSelects() {
        #expect(!SwitcherController.raisesWindowToShowTab(at: 2, tabs: tabs, liveWindowTitle: "New Tab"))
    }

    @Test func uncachedTabsSelect() {
        #expect(!SwitcherController.raisesWindowToShowTab(at: 0, tabs: [], liveWindowTitle: "Inbox"))
    }
}
