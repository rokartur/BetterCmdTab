import AppKit
import ApplicationServices
import Testing
@testable import BetterCmdTab

/// Pure-logic coverage for `SwitcherController.sinkInactiveBrowserTabs` — the
/// window-recency fallback that keeps only a browser window's active tab at the
/// window's slot and sinks its inactive tabs (#97). `@MainActor` because the
/// core re-buckets via the `@MainActor` `AppCatalogCache.statusPriority`.
@MainActor
@Suite("Sink inactive browser tabs")
struct SinkInactiveBrowserTabsTests {

    /// The test process itself stands in for any NSRunningApplication.
    private var hostApp: NSRunningApplication { .current }

    /// Two distinct AX tokens so two "windows" hash/compare as different
    /// `AXRef`s. Neither is ever messaged — they're identity keys only.
    private let browserWindow = AXUIElementCreateApplication(getpid())
    private let otherWindow = AXUIElementCreateSystemWide()

    private func windowRow(_ win: AXUIElement?, title: String, minimized: Bool = false) -> SwitcherRow {
        SwitcherRow(app: hostApp, window: win, windowTitle: title, isMinimized: minimized)
    }

    /// Expanded tab rows for `browserWindow` (needs 2+ titles to expand).
    private func tabRows(_ titles: [String]) -> [SwitcherRow] {
        windowRow(browserWindow, title: titles.first ?? "").browserTabRows(tabTitles: titles)
    }

    @Test("inactive tabs sink behind other windows; the active tab keeps the slot")
    func inactiveTabsSink() {
        let rows = tabRows(["Inbox", "Docs", "News"]) + [windowRow(otherWindow, title: "Editor")]
        let out = SwitcherController.sinkInactiveBrowserTabs(
            rows,
            activeIndex: [AXRef(element: browserWindow): 1],
            pinnedIDs: []
        )
        #expect(out.map(\.windowTitle) == ["Docs", "Editor", "Inbox", "News"])
    }

    @Test("a window without a cached active-tab index stays whole")
    func uncachedWindowStaysWhole() {
        let rows = tabRows(["Inbox", "Docs"]) + [windowRow(otherWindow, title: "Editor")]
        let out = SwitcherController.sinkInactiveBrowserTabs(rows, activeIndex: [:], pinnedIDs: [])
        #expect(out.map(\.windowTitle) == rows.map(\.windowTitle))
    }

    @Test("sunk visible tabs still rank above hidden/minimized rows")
    func sunkTabsStayAboveStatusBuckets() {
        let rows = tabRows(["Inbox", "Docs"])
            + [windowRow(otherWindow, title: "Minimized", minimized: true),
               windowRow(nil, title: "Windowless")]
        let out = SwitcherController.sinkInactiveBrowserTabs(
            rows,
            activeIndex: [AXRef(element: browserWindow): 0],
            pinnedIDs: []
        )
        #expect(out.map(\.windowTitle) == ["Inbox", "Docs", "Minimized", "Windowless"])
    }

    @Test("pinned apps get the front back after the sink")
    func pinnedAppsKeepFront() {
        let pinned = SwitcherRow(launchable: InstalledApp(
            name: "Pinned",
            bundleID: "com.example.pinned",
            url: URL(fileURLWithPath: "/Applications/Pinned.app")
        ))
        let rows = tabRows(["Inbox", "Docs"]) + [pinned]
        let out = SwitcherController.sinkInactiveBrowserTabs(
            rows,
            activeIndex: [AXRef(element: browserWindow): 0],
            pinnedIDs: ["com.example.pinned"]
        )
        #expect(out.first?.bundleIdentifier == "com.example.pinned")
        #expect(out.dropFirst().map(\.windowTitle) == ["Inbox", "Docs"])
    }

    @Test("rows without expanded tabs pass through untouched")
    func noTabsIdentity() {
        let rows = [windowRow(browserWindow, title: "One"), windowRow(otherWindow, title: "Two")]
        let out = SwitcherController.sinkInactiveBrowserTabs(
            rows,
            activeIndex: [AXRef(element: browserWindow): 0],
            pinnedIDs: []
        )
        #expect(out.map(\.windowTitle) == ["One", "Two"])
    }
}
