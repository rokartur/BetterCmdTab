import AppKit
import ApplicationServices
import Testing
@testable import BetterCmdTab

@Suite("SwitcherRow display")
struct SwitcherRowTests {

    /// The test process itself is a running application — use it as a stand-in
    /// for any NSRunningApplication. Properties we exercise (localizedName, pid)
    /// are guaranteed non-nil for the current process.
    private var hostApp: NSRunningApplication { .current }

    /// A throwaway AX element. `SwitcherRow.from` never messages it — so the app
    /// element of the test process is a fine stand-in.
    private func axElement() -> AXUIElement { AXUIElementCreateApplication(getpid()) }

    private func windowInfo(tabWindows: Int, titles: [String], title: String = "Window") -> WindowInfo {
        WindowInfo(
            ref: axElement(),
            cgWindowID: 42,
            title: title,
            isMinimized: false,
            tabWindows: (0..<tabWindows).map { i in
                TabWindowRef(ref: axElement(), title: titles.indices.contains(i) ? titles[i] : "", cgWindowID: CGWindowID(100 + i))
            }
        )
    }

    @Test("placeholder rows always show app name")
    func placeholderShowsAppName() {
        let row = SwitcherRow(
            app: hostApp,
            window: nil,
            windowTitle: "ignored",
            isMinimized: false,
            isPlaceholder: true
        )
        #expect(row.displayTitle == row.appName)
    }

    @Test("nil window collapses to app name regardless of stored title")
    func nilWindowShowsAppName() {
        let row = SwitcherRow(
            app: hostApp,
            window: nil,
            windowTitle: "stale title",
            isMinimized: false
        )
        #expect(row.displayTitle == row.appName)
    }

    @Test("windowTitleText is empty when the row would fall back to the app name")
    func windowTitleTextHidesAppNameFallback() {
        // window == nil → displayTitle returns appName, windowTitleText returns "".
        let nilWin = SwitcherRow(app: hostApp, window: nil, windowTitle: "stale title", isMinimized: false)
        #expect(nilWin.windowTitleText == "")

        // placeholder → "".
        let placeholder = SwitcherRow(app: hostApp, window: nil, windowTitle: "ignored",
                                      isMinimized: false, isPlaceholder: true)
        #expect(placeholder.windowTitleText == "")

        // launchable → window is nil → "".
        let installed = InstalledApp(name: "Widget Studio", bundleID: "com.example.widgetstudio",
                                     url: URL(fileURLWithPath: "/Applications/Widget Studio.app"))
        #expect(SwitcherRow(launchable: installed).windowTitleText == "")
    }

    @Test("windowTitleText returns the real window title when one exists")
    func windowTitleTextKeepsRealTitle() {
        // Non-nil window with a title → windowTitleText == that title (not the app name).
        let row = SwitcherRow(app: hostApp, window: axElement(), windowTitle: "Inbox — Mail",
                              isMinimized: false, cgWindowID: 99)
        #expect(row.windowTitleText == "Inbox — Mail")
    }

    @Test("windowTitleText falls back to the app name for a blank-titled real window")
    func windowTitleTextBlankTitleFallsBackToAppName() {
        // A real window with an empty AX title (PWA / some Electron windows) must
        // surface the app name, not an empty string — the Grid names-hidden tile
        // relies on this so it never renders a textless icon.
        let row = SwitcherRow(app: hostApp, window: axElement(), windowTitle: "",
                              isMinimized: false, cgWindowID: 7)
        #expect(row.windowTitleText == row.appName)
        #expect(!row.windowTitleText.isEmpty)
    }

    @Test("recently-closed rows keep their title, and fall back to app name when blank")
    func recentlyClosedTitleSlots() {
        // Entry with a real title → titleSlot/windowTitleText return it; the app-name
        // slot is empty when names are hidden and the app name when shown.
        let titled = SwitcherRow(recentlyClosed: RecentEntry(
            bundleID: "com.example.notes", appName: "Notes", title: "Groceries",
            documentPath: nil, closedAt: Date()))
        #expect(titled.windowTitleText == "Groceries")
        #expect(titled.titleSlot(showAppNames: false) == "Groceries")
        #expect(titled.titleSlot(showAppNames: true) == "Groceries")
        #expect(titled.appNameSlot(showAppNames: false) == "")
        #expect(titled.appNameSlot(showAppNames: true) == "Notes")

        // App-level reopen entry with a blank title (RecentlyClosedStore records ⌘Q
        // with title: "") must fall back to the app name, not render blank — the
        // Previews layout shows windowTitleText verbatim with no "Reopen" fallback.
        let blank = SwitcherRow(recentlyClosed: RecentEntry(
            bundleID: "com.example.notes", appName: "Notes", title: "",
            documentPath: nil, closedAt: Date()))
        #expect(blank.windowTitleText == "Notes")
        #expect(blank.titleSlot(showAppNames: false) == "Notes")
        #expect(blank.titleSlot(showAppNames: true) == "Notes")
    }

    @Test("previews title prefixes the app name when names are shown (#125)")
    func previewTitleSlotPrefixesAppName() {
        let row = SwitcherRow(app: hostApp, window: axElement(), windowTitle: "Inbox",
                              isMinimized: false, cgWindowID: 7)
        #expect(row.previewTitleSlot(showAppNames: true) == "\(row.appName) — Inbox")
        #expect(row.previewTitleSlot(showAppNames: false) == "Inbox")

        // Windowless / blank-titled rows show just the app name — never "Name — Name".
        let windowless = SwitcherRow(app: hostApp, window: nil, windowTitle: "", isMinimized: false)
        #expect(windowless.previewTitleSlot(showAppNames: true) == windowless.appName)
        let blank = SwitcherRow(app: hostApp, window: axElement(), windowTitle: "",
                                isMinimized: false, cgWindowID: 8)
        #expect(blank.previewTitleSlot(showAppNames: true) == blank.appName)

        // Recently-closed rows prefix too.
        let closed = SwitcherRow(recentlyClosed: RecentEntry(
            bundleID: "com.example.notes", appName: "Notes", title: "Groceries",
            documentPath: nil, closedAt: Date()))
        #expect(closed.previewTitleSlot(showAppNames: true) == "Notes — Groceries")

        // Browser tabs keep the bare tab title (app repeats on every sibling tab).
        let tab = browserWindowRow(title: "Browser Window").browserTabRows(tabTitles: ["Docs"]).first!
        #expect(tab.previewTitleSlot(showAppNames: true) == "Docs")
    }

    @Test("empty window title falls back to app name")
    func emptyTitleFallback() {
        // window must be non-nil to enter the title branch — but we can't
        // construct a real AXUIElement easily. Skip; covered indirectly by
        // displayTitle logic via integration.
    }

    @Test("pid passthrough matches host app")
    func pidPassthrough() {
        let row = SwitcherRow(
            app: hostApp,
            window: nil,
            windowTitle: "",
            isMinimized: false
        )
        #expect(row.pid == hostApp.processIdentifier)
    }

    @Test("appName mirrors localizedName")
    func appNameMirrors() {
        let row = SwitcherRow(
            app: hostApp,
            window: nil,
            windowTitle: "",
            isMinimized: false
        )
        #expect(row.appName == (hostApp.localizedName ?? ""))
    }

    @Test("launchable row carries installed-app fields and has no pid")
    func launchableFields() {
        let installed = InstalledApp(
            name: "Widget Studio",
            bundleID: "com.example.widgetstudio",
            url: URL(fileURLWithPath: "/Applications/Widget Studio.app")
        )
        let row = SwitcherRow(launchable: installed)
        #expect(row.isLaunchable)
        #expect(row.app == nil)
        #expect(row.pid == nil)
        #expect(row.appName == "Widget Studio")
        #expect(row.bundleIdentifier == "com.example.widgetstudio")
        #expect(row.displayTitle == "Widget Studio")
        #expect(!row.isHidden)
    }

    @Test("running row reports itself as not launchable")
    func runningNotLaunchable() {
        let row = SwitcherRow(app: hostApp, window: nil, windowTitle: "", isMinimized: false)
        #expect(!row.isLaunchable)
        #expect(row.app != nil)
    }

    // MARK: - native window-tab rows

    @Test("from carries the window's native tab siblings for the peek")
    func fromCarriesTabWindows() {
        let info = windowInfo(tabWindows: 3, titles: ["A", "B", "C"], title: "Window A")
        let row = SwitcherRow.from(app: hostApp, window: info)
        #expect(row.tabWindows.count == 3)
        #expect(row.hasTabs)                      // peekable with `\`
        #expect(row.windowTitle == "Window A")    // front tab's title
        #expect(row.cgWindowID == 42)
        #expect(row.tabWindows.map(\.title) == ["A", "B", "C"])
    }

    @Test("a plain window (no tab siblings) is not peekable")
    func plainWindowNoTabs() {
        let info = WindowInfo(ref: axElement(), cgWindowID: 7, title: "Solo", isMinimized: false)
        let row = SwitcherRow.from(app: hostApp, window: info)
        #expect(row.tabWindows.isEmpty)
        #expect(!row.hasTabs)
    }

    // MARK: - inline browser-tab rows

    private func browserWindowRow(title: String) -> SwitcherRow {
        SwitcherRow(app: hostApp, window: axElement(), windowTitle: title, isMinimized: false, cgWindowID: 99)
    }

    @Test("browserTabRows yields one row per tab, indexed in order")
    func browserTabsExpandPerTab() {
        let parent = browserWindowRow(title: "Browser Window")
        let rows = parent.browserTabRows(tabTitles: ["Inbox", "Docs", "News"])
        #expect(rows.count == 3)
        #expect(rows.map(\.browserTab?.index) == [0, 1, 2])
        // Each tab row shows its tab title, points at the parent window's id, and
        // carries the parent window's title for AppleScript resolution.
        #expect(rows.map(\.displayTitle) == ["Inbox", "Docs", "News"])
        #expect(rows.allSatisfy { $0.cgWindowID == 99 })
        #expect(rows.allSatisfy { $0.browserTab?.parentTitle == "Browser Window" })
        #expect(rows.allSatisfy { $0.window != nil })
    }

    @Test("browser tab rows carry URL, active state, and page-stable preview keys")
    func browserTabIdentity() {
        let parent = browserWindowRow(title: "Browser Window")
        let rows = parent.browserTabRows(tabs: [
            BrowserTabInfo(title: "Duplicate", url: "https://example.test/a#one"),
            BrowserTabInfo(title: "Duplicate", url: "https://example.test/b"),
        ], activeIndex: 1)

        #expect(rows[0].browserTab?.url == "https://example.test/a#one")
        #expect(rows.map(\.browserTab?.isActive) == [false, true])
        #expect(rows[0].browserTabPreviewKey?.pageIdentity == "https://example.test/a")
        #expect(rows[0].browserTabPreviewKey != rows[1].browserTabPreviewKey)

        let reordered = parent.browserTabRows(tabs: [
            BrowserTabInfo(title: "Duplicate", url: "https://example.test/b"),
            BrowserTabInfo(title: "Duplicate", url: "https://example.test/a#two"),
        ], activeIndex: 0)
        #expect(rows[0].browserTabPreviewKey != reordered[0].browserTabPreviewKey)
        #expect(rows[0].browserTabPreviewKey != reordered[1].browserTabPreviewKey) // index is part of identity
    }

    @Test("a single tab expands into a tab row; an empty window stays collapsed")
    func browserTabsSingleTabExpands() {
        let parent = browserWindowRow(title: "Solo")
        // Single tab → a real tab row (carries the URL, so the row gets a
        // favicon + #131 browser badge instead of the bare app icon).
        let single = parent.browserTabRows(tabTitles: ["Only"])
        #expect(single.count == 1)
        #expect(single.first?.browserTab?.index == 0)
        // Empty (negative-cached) window keeps its collapsed identity.
        #expect(parent.browserTabRows(tabTitles: []).count == 1)
        #expect(parent.browserTabRows(tabTitles: []).first?.browserTab == nil)
    }

    @Test("browserTabRows is a no-op for a non-running subject")
    func browserTabsNoExpandLaunchable() {
        let installed = InstalledApp(
            name: "Browser",
            bundleID: "com.example.browser",
            url: URL(fileURLWithPath: "/Applications/Browser.app")
        )
        let row = SwitcherRow(launchable: installed)
        let out = row.browserTabRows(tabTitles: ["A", "B"])
        #expect(out.count == 1)
        #expect(out.first?.browserTab == nil)
    }

    @Test("collapsedFromBrowserTab inverts browserTabRows")
    func browserTabCollapseRoundTrip() {
        let parent = browserWindowRow(title: "Parent")
        let tabs = parent.browserTabRows(tabTitles: ["A", "B", "C"])
        #expect(tabs.count == 3)
        // Each expanded tab collapses back to the same parent-window row: the
        // window title is restored from parentTitle and the tab marker is gone.
        for tab in tabs {
            #expect(tab.browserTab != nil)
            let collapsed = tab.collapsedFromBrowserTab()
            #expect(collapsed.browserTab == nil)
            #expect(collapsed.windowTitle == "Parent")
            #expect(collapsed.cgWindowID == parent.cgWindowID)
            #expect(collapsed.isMinimized == parent.isMinimized)
            #expect(collapsed.isFullscreen == parent.isFullscreen)
            #expect(collapsed.pid == parent.pid)
        }
    }

    @Test("collapsedFromBrowserTab is identity for a non-tab row")
    func collapseNonTabRowIsIdentity() {
        let parent = browserWindowRow(title: "Parent")
        let collapsed = parent.collapsedFromBrowserTab()
        #expect(collapsed.browserTab == nil)
        #expect(collapsed.windowTitle == parent.windowTitle)
    }
}
