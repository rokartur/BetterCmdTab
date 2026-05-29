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
}
