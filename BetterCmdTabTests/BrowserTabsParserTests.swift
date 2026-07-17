import CoreGraphics
import Testing
@testable import BetterCmdTab

@Suite("BrowserTabs parser")
struct BrowserTabsParserTests {
    @Test("parses URLs, empty URLs, duplicate titles, windows, and numeric active indices")
    func parsesBatchedWindows() {
        let first = "Window A\u{1E}2\u{1E}Same\u{1C}https://one.test/a\u{1F}Same\u{1C}"
        let second = "Window B\u{1E}1\u{1E}Other\u{1C}https://two.test/b#fragment"

        let windows = BrowserTabs.parseAllWindowTabs(first + "\u{1D}" + second)

        #expect(windows.count == 2)
        #expect(windows[0].activeIndex == 1)
        #expect(windows[0].tabs == [
            BrowserTabInfo(title: "Same", url: "https://one.test/a"),
            BrowserTabInfo(title: "Same", url: ""),
        ])
        #expect(windows[1].title == "Window B")
        #expect(windows[1].activeIndex == 0)
        #expect(windows[1].tabs[0].url == "https://two.test/b#fragment")
    }

    @Test("clamps an invalid active index without title matching")
    func clampsActiveIndex() {
        let windows = BrowserTabs.parseAllWindowTabs("Window\u{1E}99\u{1E}A\u{1C}u\u{1F}B\u{1C}v")
        #expect(windows.first?.activeIndex == 1)
    }

    @Test("parses the optional bounds field and tolerates a missing or malformed one")
    func parsesBounds() {
        let withBounds = "W1\u{1E}1\u{1E}A\u{1C}u\u{1E}10 20 810 620"
        let noBounds = "W2\u{1E}1\u{1E}B\u{1C}v"
        let malformed = "W3\u{1E}1\u{1E}C\u{1C}w\u{1E}10 twenty 810"

        let windows = BrowserTabs.parseAllWindowTabs(
            withBounds + "\u{1D}" + noBounds + "\u{1D}" + malformed
        )

        #expect(windows.count == 3)
        #expect(windows[0].bounds == CGRect(x: 10, y: 20, width: 800, height: 600))
        #expect(windows[1].bounds == nil)
        #expect(windows[2].bounds == nil)
    }

    @Test("rejects inverted bounds (right/bottom not past left/top)")
    func rejectsInvertedBounds() {
        let windows = BrowserTabs.parseAllWindowTabs("W\u{1E}1\u{1E}A\u{1C}u\u{1E}810 620 10 20")
        #expect(windows.first?.bounds == nil)
    }
}
