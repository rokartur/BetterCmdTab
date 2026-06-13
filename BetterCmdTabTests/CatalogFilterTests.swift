import CoreGraphics
import Foundation
import Testing
@testable import BetterCmdTab

@Suite("CatalogFilter")
struct CatalogFilterTests {

    private func config(
        hideModes: [String: HideWindowsMode] = [:],
        pinned: [String] = [],
        showMinimized: Bool = true,
        showHidden: Bool = true,
        showWindowless: Bool = true,
        currentSpaceOnly: Bool = false,
        sortOrder: SwitcherSortOrder = .mru
    ) -> CatalogFilter.Config {
        CatalogFilter.Config(hideModes: hideModes, pinned: pinned, showMinimized: showMinimized, showHidden: showHidden, showWindowless: showWindowless, currentSpaceOnly: currentSpaceOnly, sortOrder: sortOrder)
    }

    // MARK: - isIdentity

    @Test("identity config short-circuits filtering")
    func identity() {
        #expect(config().isIdentity)
        #expect(!config(hideModes: ["a": .always]).isIdentity)
        #expect(!config(pinned: ["a"]).isIdentity)
        #expect(!config(showMinimized: false).isIdentity)
        #expect(!config(showHidden: false).isIdentity)
        #expect(!config(showWindowless: false).isIdentity)
        #expect(!config(sortOrder: .alphabetical).isIdentity)
        #expect(!config(sortOrder: .launchOrder).isIdentity)
        // .mruWindows is not identity: the full filter path must run so the
        // cross-app window sort can be applied downstream in SwitcherController.
        #expect(!config(sortOrder: .mruWindows).isIdentity)
    }

    // MARK: - applications-only collapse

    @Test("applications-only keeps the first window of each app")
    func applicationsOnlyCollapsesByPid() {
        // pids 7,7,9,7,9 → keep first 7 (idx 0) and first 9 (idx 2).
        let kept = CatalogFilter.keptApplicationIndices(
            pids: [7, 7, 9, 7, 9],
            placeholders: [false, false, false, false, false])
        #expect(kept == [0, 2])
    }

    @Test("applications-only passes through pid-less and placeholder rows")
    func applicationsOnlyKeepsSpecialRows() {
        // nil pid (launchable / recently-closed) is always kept; duplicate pids
        // still collapse around them.
        let pidless = CatalogFilter.keptApplicationIndices(
            pids: [nil, 4, 4, nil],
            placeholders: [false, false, false, false])
        #expect(pidless == [0, 1, 3])

        // A placeholder row is kept even though its pid duplicates a real row's.
        let withPlaceholder = CatalogFilter.keptApplicationIndices(
            pids: [5, 5],
            placeholders: [true, false])
        #expect(withPlaceholder == [0, 1])
    }

    // MARK: - includes

    @Test("permissive config keeps minimized and hidden rows")
    func permissiveKeepsAll() {
        let cfg = config()
        #expect(CatalogFilter.includes(bundleID: "com.x", isPlaceholder: false, isMinimized: true, appHidden: true, cfg))
    }

    @Test("hide=always bundle id is dropped")
    func hideAlways() {
        let cfg = config(hideModes: ["com.x": .always])
        #expect(!CatalogFilter.includes(bundleID: "com.x", isPlaceholder: false, isMinimized: false, appHidden: false, cfg))
        #expect(CatalogFilter.includes(bundleID: "com.y", isPlaceholder: false, isMinimized: false, appHidden: false, cfg))
    }

    @Test("hide=whenNoWindows drops only the windowless row")
    func hideWhenNoWindows() {
        let cfg = config(hideModes: ["com.x": .whenNoWindows])
        // No window → dropped, even though the global windowless toggle is on.
        #expect(!CatalogFilter.includes(bundleID: "com.x", isPlaceholder: false, isMinimized: false, appHidden: false, hasWindow: false, cfg))
        // Has a window → kept.
        #expect(CatalogFilter.includes(bundleID: "com.x", isPlaceholder: false, isMinimized: false, appHidden: false, hasWindow: true, cfg))
    }

    @Test("hide=dontHide is neutral — global toggles still apply")
    func hideDontHide() {
        // A dontHide exception adds no hiding, so the global minimized toggle wins.
        let cfg = config(hideModes: ["com.x": .dontHide], showMinimized: false)
        #expect(!CatalogFilter.includes(bundleID: "com.x", isPlaceholder: false, isMinimized: true, appHidden: false, cfg))
        #expect(CatalogFilter.includes(bundleID: "com.x", isPlaceholder: false, isMinimized: false, appHidden: false, cfg))
    }

    @Test("placeholders are always kept, even when hidden")
    func placeholderKept() {
        let cfg = config(hideModes: ["com.x": .always], showMinimized: false, showHidden: false)
        #expect(CatalogFilter.includes(bundleID: "com.x", isPlaceholder: true, isMinimized: true, appHidden: true, cfg))
    }

    @Test("minimized windows dropped when disabled")
    func minimizedToggle() {
        let cfg = config(showMinimized: false)
        #expect(!CatalogFilter.includes(bundleID: "com.x", isPlaceholder: false, isMinimized: true, appHidden: false, cfg))
        #expect(CatalogFilter.includes(bundleID: "com.x", isPlaceholder: false, isMinimized: false, appHidden: false, cfg))
    }

    @Test("hidden apps dropped when disabled")
    func hiddenToggle() {
        let cfg = config(showHidden: false)
        #expect(!CatalogFilter.includes(bundleID: "com.x", isPlaceholder: false, isMinimized: false, appHidden: true, cfg))
        #expect(CatalogFilter.includes(bundleID: "com.x", isPlaceholder: false, isMinimized: false, appHidden: false, cfg))
    }

    @Test("windowless apps dropped when disabled")
    func windowlessToggle() {
        let cfg = config(showWindowless: false)
        #expect(!CatalogFilter.includes(bundleID: "com.x", isPlaceholder: false, isMinimized: false, appHidden: false, hasWindow: false, cfg))
        #expect(CatalogFilter.includes(bundleID: "com.x", isPlaceholder: false, isMinimized: false, appHidden: false, hasWindow: true, cfg))
        // Placeholders survive even with no window.
        #expect(CatalogFilter.includes(bundleID: "com.x", isPlaceholder: true, isMinimized: false, appHidden: false, hasWindow: false, cfg))
    }

    // MARK: - stablePartition (pin reordering)

    @Test("no pins preserves original order")
    func noPins() {
        let result = CatalogFilter.stablePartition([1, 2, 3, 4]) { _ in nil }
        #expect(result == [1, 2, 3, 4])
    }

    @Test("pinned items move to front ordered by rank")
    func pinnedByRank() {
        let ranks = ["30": 0, "10": 1]
        let result = CatalogFilter.stablePartition([10, 20, 30, 40]) { ranks[String($0)] }
        #expect(result == [30, 10, 20, 40])
    }

    @Test("same-rank pinned items keep original order (stable)")
    func stableWithinRank() {
        // Even values share rank 0; odd values are not pinned.
        let result = CatalogFilter.stablePartition([1, 2, 3, 4, 5]) { $0 % 2 == 0 ? 0 : nil }
        #expect(result == [2, 4, 1, 3, 5])
    }

    // MARK: - pinnedToFront (used by filteredRows and the .mruWindows re-pin)

    /// A launchable row carries an arbitrary bundle id with `isPlaceholder == false`,
    /// which is all `pinnedToFront` keys on — lets us test pin ordering without
    /// constructing live `NSRunningApplication`s.
    private func launchRow(_ bundleID: String, name: String? = nil) -> SwitcherRow {
        SwitcherRow(launchable: InstalledApp(name: name ?? bundleID, bundleID: bundleID, url: URL(fileURLWithPath: "/Applications/\(bundleID).app")))
    }

    @Test("pinnedToFront with no pins returns rows unchanged")
    func pinnedToFrontNoPins() {
        let rows = [launchRow("com.a"), launchRow("com.b")]
        let result = CatalogFilter.pinnedToFront(rows, [])
        #expect(result.map(\.bundleIdentifier) == ["com.a", "com.b"])
    }

    @Test("pinnedToFront lifts pinned apps to the front in pin order")
    func pinnedToFrontOrdersByPin() {
        let rows = [launchRow("com.a"), launchRow("com.b"), launchRow("com.c")]
        // Pin c then a; the unpinned b trails behind them.
        let result = CatalogFilter.pinnedToFront(rows, ["com.c", "com.a"])
        #expect(result.map(\.bundleIdentifier) == ["com.c", "com.a", "com.b"])
    }

    @Test("pinnedToFront keeps a pinned app's windows in incoming order")
    func pinnedToFrontStableWithinApp() {
        // The .mruWindows re-pin relies on this: two windows of the pinned app
        // arrive recency-ordered (w1 before w2) with an unpinned app between
        // them; after re-pinning they stay w1, w2 at the front.
        let rows = [launchRow("com.a", name: "w1"), launchRow("com.b"), launchRow("com.a", name: "w2")]
        let result = CatalogFilter.pinnedToFront(rows, ["com.a"])
        #expect(result.map(\.appName) == ["w1", "w2", "com.b"])
    }

    // MARK: - sort order

    @Test("stable sort keeps equal-key order")
    func sortedStablyKeepsOrder() {
        let items = [(k: 1, tag: "a"), (k: 1, tag: "b"), (k: 0, tag: "c")]
        let result = CatalogFilter.sortedStably(items) { $0.k }
        #expect(result.map(\.tag) == ["c", "a", "b"])
    }

    @Test("mru sort returns input unchanged")
    func mruSortIsIdentity() {
        let items = [(name: "z", pid: pid_t(9)), (name: "a", pid: pid_t(1))]
        let result = CatalogFilter.applySortOrder(items, .mru, name: { $0.name }, pid: { $0.pid })
        #expect(result.map(\.pid) == [9, 1])
    }

    @Test("mruWindows sort returns input unchanged (sorted downstream)")
    func mruWindowsSortIsIdentity() {
        // The flat window sort is applied in SwitcherController from
        // WindowMRUTracker, not here — applySortOrder leaves the input as-is.
        let items = [(name: "z", pid: pid_t(9)), (name: "a", pid: pid_t(1))]
        let result = CatalogFilter.applySortOrder(items, .mruWindows, name: { $0.name }, pid: { $0.pid })
        #expect(result.map(\.pid) == [9, 1])
    }

    @Test("alphabetical sort orders by name, case-insensitive")
    func alphabeticalSort() {
        let items = [(name: "Banana", pid: pid_t(3)), (name: "apple", pid: pid_t(1)), (name: "Cherry", pid: pid_t(2))]
        let result = CatalogFilter.applySortOrder(items, .alphabetical, name: { $0.name }, pid: { $0.pid })
        #expect(result.map(\.name) == ["apple", "Banana", "Cherry"])
    }

    @Test("launch-order sort orders by pid ascending")
    func launchOrderSort() {
        let items = [(name: "a", pid: pid_t(3)), (name: "b", pid: pid_t(1)), (name: "c", pid: pid_t(2))]
        let result = CatalogFilter.applySortOrder(items, .launchOrder, name: { $0.name }, pid: { $0.pid })
        #expect(result.map(\.pid) == [1, 2, 3])
    }

    // MARK: - phantom-window filtering

    private func win(_ offset: Int, _ pid: pid_t, _ wid: CGWindowID, onScreen: Bool)
        -> (offset: Int, pid: pid_t, wid: CGWindowID, onScreen: Bool) {
        (offset, pid, wid, onScreen)
    }

    @Test("phantom dropped when its app has an on-screen sibling")
    func phantomDroppedWithOnScreenSibling() {
        // The Teams case: pid 7's real chat window (9168) is on screen, its
        // never-shown BrowserWindow (49502) is off screen and resolves to no
        // Space → only the phantom is dropped.
        let rows = [win(0, 7, 9168, onScreen: true), win(1, 7, 49502, onScreen: false)]
        let drop = CatalogFilter.phantomWindowOffsets(windowRows: rows, resolvedCandidateWids: [])
        #expect(drop == [1])
    }

    @Test("phantom dropped when its app has an off-screen sibling that resolved")
    func phantomDroppedWithResolvedSibling() {
        // Neither window is on screen, but the real one (9168) resolves to a
        // Space (e.g. it's on another desktop); the phantom (49502) does not.
        let rows = [win(0, 7, 9168, onScreen: false), win(1, 7, 49502, onScreen: false)]
        let drop = CatalogFilter.phantomWindowOffsets(windowRows: rows, resolvedCandidateWids: [9168])
        #expect(drop == [1])
    }

    @Test("off-screen spaceless window kept when it's the app's only window")
    func soleUnresolvedWindowKept() {
        // No on-screen window and nothing resolved for pid 5 → its app has no
        // window known to occupy a Space, so a transient query miss must NOT
        // drop the user's only window.
        let rows = [win(0, 5, 100, onScreen: false)]
        let drop = CatalogFilter.phantomWindowOffsets(windowRows: rows, resolvedCandidateWids: [])
        #expect(drop.isEmpty)
    }

    @Test("on-screen windows are never dropped")
    func onScreenWindowsNeverDropped() {
        let rows = [win(0, 1, 200, onScreen: true), win(1, 2, 201, onScreen: true)]
        let drop = CatalogFilter.phantomWindowOffsets(windowRows: rows, resolvedCandidateWids: [])
        #expect(drop.isEmpty)
    }

    @Test("phantom decision is per-app, not global")
    func phantomDecisionIsPerApp() {
        // pid 7 has a real on-screen window + a phantom; pid 9 has a single
        // off-screen unresolved window. Only pid 7's phantom is dropped — pid 9's
        // lone window is kept because pid 9 occupies no known Space.
        let rows = [
            win(0, 7, 9168, onScreen: true),
            win(1, 7, 49502, onScreen: false),
            win(2, 9, 300, onScreen: false),
        ]
        let drop = CatalogFilter.phantomWindowOffsets(windowRows: rows, resolvedCandidateWids: [])
        #expect(drop == [1])
    }

    @Test("all windows kept when every off-screen window resolves")
    func allResolvedKeepsEverything() {
        let rows = [win(0, 1, 100, onScreen: false), win(1, 1, 200, onScreen: false)]
        let drop = CatalogFilter.phantomWindowOffsets(windowRows: rows, resolvedCandidateWids: [100, 200])
        #expect(drop.isEmpty)
    }
}
