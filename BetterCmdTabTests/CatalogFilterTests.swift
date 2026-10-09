import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import BetterCmdTab

@Suite("CatalogFilter")
struct CatalogFilterTests {

    private func config(
        hideModes: [String: HideWindowsMode] = [:],
        showMinimized: Bool = true,
        showHidden: Bool = true,
        showWindowless: Bool = true
    ) -> CatalogFilter.Config {
        CatalogFilter.Config(
            hideModes: hideModes, excludedTitleFragments: [:], pinned: [],
            showMinimized: showMinimized, showHidden: showHidden, showWindowless: showWindowless,
            spaceScope: .allSpaces, sortOrder: .mru, sinkHiddenApps: true,
            sinkMinimizedWindows: true)
    }

    // MARK: - includes

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

    @Test("window-title exclusions are app-scoped and case/diacritic insensitive")
    func windowTitleExclusions() {
        let app = NSRunningApplication.current
        let ownBundleID = app.bundleIdentifier ?? ""
        let rows = [
            SwitcherRow(app: app, window: AXUIElementCreateSystemWide(), windowTitle: "Picture-in-Picture", isMinimized: false),
            SwitcherRow(app: app, window: AXUIElementCreateSystemWide(), windowTitle: "RéSUMé — Draft", isMinimized: false),
            SwitcherRow(app: app, window: AXUIElementCreateSystemWide(), windowTitle: "Main document", isMinimized: false),
        ]
        let filtered = CatalogFilter.filterExcludedWindowTitles(
            rows,
            [ownBundleID: ["picture-in-picture", "resume"]]
        )
        #expect(filtered.map(\.windowTitle) == ["Main document"])
    }

    @Test("placeholders are always kept, even when hidden")
    func placeholderKept() {
        let cfg = config(hideModes: ["com.x": .always], showMinimized: false, showHidden: false)
        #expect(CatalogFilter.includes(bundleID: "com.x", isPlaceholder: true, isMinimized: true, appHidden: true, cfg))
    }

    // MARK: - filteredApps window state (#112)

    @Test("app-level filter matches the row filter once window state is known")
    func filteredAppsWindowState() {
        let app = NSRunningApplication.current
        let pid = app.pid
        let cfg = config(showWindowless: false)
        // Window state known, app windowless → dropped, same as the panel.
        #expect(CatalogFilter.filteredApps([app], cfg, windowedPids: []).isEmpty)
        // App has a window → kept.
        #expect(CatalogFilter.filteredApps([app], cfg, windowedPids: [pid]) == [app])
        // Window state unknown (cold cache) → kept; missing data never hides.
        #expect(CatalogFilter.filteredApps([app], cfg, windowedPids: nil) == [app])

        // The per-app whenNoWindows exception applies at app level too.
        if let bid = app.bundleIdentifier {
            let exc = config(hideModes: [bid: .whenNoWindows])
            #expect(CatalogFilter.filteredApps([app], exc, windowedPids: []).isEmpty)
            #expect(CatalogFilter.filteredApps([app], exc, windowedPids: [pid]) == [app])
            #expect(CatalogFilter.filteredApps([app], exc, windowedPids: nil) == [app])
        }
    }

    // MARK: - pinnedToFront (used by filteredRows and the .mruWindows re-pin)

    /// A launchable row carries an arbitrary bundle id with `isPlaceholder == false`,
    /// which is all `pinnedToFront` keys on — lets us test pin ordering without
    /// constructing live `NSRunningApplication`s.
    private func launchRow(_ bundleID: String, name: String? = nil) -> SwitcherRow {
        SwitcherRow(launchable: InstalledApp(name: name ?? bundleID, bundleID: bundleID, url: URL(fileURLWithPath: "/Applications/\(bundleID).app")))
    }

    @Test("pinnedToFront lifts pinned apps to the front in pin order")
    func pinnedToFrontOrdersByPin() {
        let rows = [launchRow("com.a"), launchRow("com.b"), launchRow("com.c")]
        // Pin c then a; the unpinned b trails behind them.
        let result = CatalogFilter.pinnedToFront(rows, ["com.c", "com.a"])
        #expect(result.map(\.bundleIdentifier) == ["com.c", "com.a", "com.b"])
    }

    // MARK: - sort order

    @Test("dock sort puts kept apps in Dock order, then the rest by pid, keeping an app's rows together")
    func dockSort() {
        let items = [
            (id: "late", pid: pid_t(9)), (id: "mail", pid: pid_t(5)), (id: "early", pid: pid_t(2)),
            (id: "finder", pid: pid_t(7)), (id: "mail", pid: pid_t(5)),
        ]
        let result = CatalogFilter.sortedByDock(
            items, dockBundleIDs: ["finder", "mail", "notRunning"], bundleID: { $0.id }, pid: { $0.pid }
        )
        #expect(result.map(\.id) == ["finder", "mail", "mail", "early", "late"])
    }

    // MARK: - phantom-window filtering

    private func win(
        _ offset: Int,
        _ pid: pid_t,
        _ wid: CGWindowID,
        onScreen: Bool,
        minimized: Bool = false,
        tabSibling: Bool = false,
        hasTitle: Bool = false
    ) -> CatalogFilter.PhantomWindowCandidate {
        CatalogFilter.PhantomWindowCandidate(
            offset: offset,
            pid: pid,
            wid: wid,
            onScreen: onScreen,
            isMinimized: minimized,
            isTabSibling: tabSibling,
            hasTitle: hasTitle
        )
    }

    @Test("phantom dropped when its app has an on-screen sibling")
    func phantomDroppedWithOnScreenSibling() {
        // The Teams case: pid 7's real chat window (9168) is on screen, its
        // never-shown BrowserWindow (49502) is off screen and WindowServer
        // positively reports it spaceless → only the phantom is dropped.
        let rows = [win(0, 7, 9168, onScreen: true), win(1, 7, 49502, onScreen: false)]
        let drop = CatalogFilter.phantomWindowOffsets(windowRows: rows, resolvedCandidateWids: [], spacelessWids: [49502])
        #expect(drop == [1])
    }

    @Test("Stage Manager keeps titled spaceless windows")
    func stageManagerWindowsKept() {
        let rows = (0..<4).map { win($0, 7, CGWindowID(100 + $0), onScreen: true, hasTitle: true) }
            + (4..<10).map { win($0, 7, CGWindowID(100 + $0), onScreen: false, hasTitle: true) }
            + [win(10, 7, 999, onScreen: false)]
        let drop = CatalogFilter.phantomWindowOffsets(
            windowRows: rows,
            resolvedCandidateWids: [],
            spacelessWids: Set((4..<10).map { CGWindowID(100 + $0) } + [999])
        )
        #expect(drop == [10])
    }

    @Test("spaceless window kept when it's the app's only window")
    func soleSpacelessWindowKept() {
        // Nothing resolved/on-screen for pid 5 → its app has no window known to
        // occupy a Space, so even a confirmed-spaceless lone window is kept
        // rather than vanishing entirely from the switcher.
        let rows = [win(0, 5, 100, onScreen: false)]
        let drop = CatalogFilter.phantomWindowOffsets(windowRows: rows, resolvedCandidateWids: [], spacelessWids: [100])
        #expect(drop.isEmpty)
    }

    @Test("minimized window kept even if WindowServer reports it spaceless")
    func minimizedSpacelessKept() {
        // pid 7: on-screen sibling (9168) + a MINIMIZED window (49502) that
        // failed to map to a Space. A minimized window is a real user window (the
        // Electron phantom is never minimized), so it must not be dropped.
        let rows = [win(0, 7, 9168, onScreen: true), win(1, 7, 49502, onScreen: false, minimized: true)]
        let drop = CatalogFilter.phantomWindowOffsets(windowRows: rows, resolvedCandidateWids: [], spacelessWids: [49502])
        #expect(drop.isEmpty)
    }

    @Test("tab-sibling row kept even though it is spaceless (expand tabs as windows)")
    func tabSiblingSpacelessKept() {
        // "Expand tabs as windows": the front tab (9168) is on screen, its
        // tabbed-away sibling (49502) is ordered out and spaceless — the same
        // WindowServer signature as an Electron phantom. The isTabSibling flag
        // set at enumeration must exempt it, or the expand option shows nothing.
        let rows = [win(0, 7, 9168, onScreen: true), win(1, 7, 49502, onScreen: false, tabSibling: true)]
        let drop = CatalogFilter.phantomWindowOffsets(windowRows: rows, resolvedCandidateWids: [], spacelessWids: [49502])
        #expect(drop.isEmpty)
    }

    // MARK: - stranded-app rescue (#168)

    @Test("an app that loses every window row is re-admitted at its first index")
    func strandedAppRescued() {
        // pid 7 keeps a row, pid 9 loses both — only 9 needs rescuing, and it comes
        // back at index 1 so its MRU position is unchanged.
        #expect(CatalogFilter.strandedAppIndices(
            pids: [7, 9, 9], kept: [true, false, false], rescuable: [true, true, true]) == [1])
        #expect(CatalogFilter.strandedAppIndices(
            pids: [7, 9, 9], kept: [true, false, true], rescuable: [true, true, true]).isEmpty)
    }

    @Test("an app hidden on purpose is never rescued")
    func deliberatelyHiddenAppNotRescued() {
        // The whole point of the rescue is reachability, not overriding an
        // "always hide this app" exception.
        #expect(CatalogFilter.strandedAppIndices(
            pids: [9, 9], kept: [false, false], rescuable: [false, false]).isEmpty)
    }

    @Test("a ⌘H-hidden app stays out when show hidden apps is off (#196)")
    func hiddenAppNotRescued() {
        #expect(!CatalogFilter.isRescuable(bundleID: "com.x", appHidden: true, hasWindow: true,
                                           config(showMinimized: false, showHidden: false)))
        #expect(CatalogFilter.isRescuable(bundleID: "com.x", appHidden: true, hasWindow: true,
                                          config(showMinimized: false)))
    }

    // MARK: - filterToAllowedSpaces (cached-wid path) + degrade

    /// A window-bearing row for the current process carrying an explicit wid; `window` can be nil.
    private func spaceRow(_ wid: CGWindowID, minimized: Bool = false, tabSibling: Bool = false) -> SwitcherRow {
        SwitcherRow(app: .current, window: nil, windowTitle: "", isMinimized: minimized, cgWindowID: wid, isTabSibling: tabSibling)
    }

    private func resolution(
        spaceByWindow: [CGWindowID: UInt64],
        spaceless: Set<CGWindowID> = [],
        allowedSpaces: Set<UInt64>
    ) -> CatalogFilter.SpaceResolution {
        CatalogFilter.SpaceResolution(spaceByWindow: spaceByWindow, confirmedSpaceless: spaceless, onScreen: [], allowedSpaces: allowedSpaces)
    }

    // 10 is the front tab on another Space, 50 is on the current Space, 20-40 are spaceless.
    @Test("narrowed scope drops a spaceless background tab, keeps minimized and expanded-tab rows")
    func narrowedScopeDropsSpacelessTab() {
        let rows = [spaceRow(10), spaceRow(20), spaceRow(30, tabSibling: true), spaceRow(40, minimized: true), spaceRow(50)]
        let spaces = resolution(spaceByWindow: [10: 200, 50: 100], spaceless: [20, 30, 40], allowedSpaces: [100])
        let kept = CatalogFilter.filterToAllowedSpaces(rows, spaces, stageManager: false)
        #expect(kept.map(\.cgWindowID) == [30, 40, 50])
    }

    @Test("Stage Manager keeps spaceless off-stage windows under a narrowed scope (#116)")
    func stageManagerKeepsSpacelessRows() {
        let rows = [spaceRow(10), spaceRow(20)]
        let spaces = resolution(spaceByWindow: [10: 100], spaceless: [20], allowedSpaces: [100])
        let kept = CatalogFilter.filterToAllowedSpaces(rows, spaces, stageManager: true)
        #expect(kept.map(\.cgWindowID) == [10, 20])
    }

    @Test("current-Space filter drops a window on another Space, keeps active-Space")
    func currentSpaceDropsOtherSpace() {
        let active: UInt64 = 100
        let rows = [spaceRow(10), spaceRow(20)]   // 10 on active space, 20 elsewhere
        let res = resolution(spaceByWindow: [10: active, 20: 200], allowedSpaces: [active])
        let kept = CatalogFilter.filterToAllowedSpaces(rows, res)
        #expect(kept.map(\.cgWindowID) == [10])
    }

    @Test("visible-Spaces filter keeps each display's on-screen Space, drops the rest")
    func visibleSpacesKeepsEveryDisplaysSpace() {
        // Two displays: active Space 100 (display 1) and visible Space 300
        // (display 2); Space 200 is a background Space of display 1 (#57).
        let rows = [spaceRow(10), spaceRow(20), spaceRow(30)]
        let res = resolution(spaceByWindow: [10: 100, 20: 200, 30: 300], allowedSpaces: [100, 300])
        let kept = CatalogFilter.filterToAllowedSpaces(rows, res)
        #expect(kept.map(\.cgWindowID) == [10, 30])
    }

    @Test("both Space filters no-op on the unavailable resolution")
    func unavailableResolutionDegradesToNoOp() {
        let rows = [spaceRow(10), spaceRow(20)]
        #expect(CatalogFilter.filterToAllowedSpaces(rows, .unavailable).count == 2)
        #expect(CatalogFilter.filterPhantomWindows(rows, .unavailable).count == 2)
    }

    // MARK: - Space-resolution memo reuse

    @Test("memo reuse requires same scope, fresh age, and covered wids")
    func spaceMemoReuseDecision() {
        let memoWids: Set<CGWindowID> = [10, 20, 30]
        // Identical repeat within the TTL — reuse.
        #expect(CatalogFilter.spaceMemoValid(
            scope: .allSpaces, candidates: memoWids,
            memoScope: .allSpaces, memoWids: memoWids, age: 0.05))
        // A subset (scoped re-filter of the same catalog) — reuse.
        #expect(CatalogFilter.spaceMemoValid(
            scope: .allSpaces, candidates: [10, 30],
            memoScope: .allSpaces, memoWids: memoWids, age: 0.05))
        // A new window appeared — must re-resolve.
        #expect(!CatalogFilter.spaceMemoValid(
            scope: .allSpaces, candidates: [10, 20, 40],
            memoScope: .allSpaces, memoWids: memoWids, age: 0.05))
        // Scope changed — must re-resolve.
        #expect(!CatalogFilter.spaceMemoValid(
            scope: .currentSpace, candidates: [10],
            memoScope: .allSpaces, memoWids: memoWids, age: 0.05))
        // Expired or non-monotonic age — must re-resolve.
        #expect(!CatalogFilter.spaceMemoValid(
            scope: .allSpaces, candidates: [10],
            memoScope: .allSpaces, memoWids: memoWids, age: CatalogFilter.spaceMemoTTL))
        #expect(!CatalogFilter.spaceMemoValid(
            scope: .allSpaces, candidates: [10],
            memoScope: .allSpaces, memoWids: memoWids, age: -0.01))
        // Empty candidate set is covered by any memo (nothing to resolve).
        #expect(CatalogFilter.spaceMemoValid(
            scope: .allSpaces, candidates: [],
            memoScope: .allSpaces, memoWids: memoWids, age: 0.05))
    }
}

@Suite("CatalogFilter applications-only collapse")
struct CatalogFilterCollapseTests {

    @Test("applications-only elects a visible window without moving the app (#159)")
    func applicationsOnlySkipsMinimizedRepresentative() {
        // pid 7 leads with a just-minimized window: the app keeps slot 0 (its MRU
        // position) but is represented by the visible window at index 2, so
        // committing the row raises it instead of un-minimizing.
        let kept = CatalogFilter.keptApplicationIndices(
            pids: [7, 9, 7],
            placeholders: [false, false, false],
            minimized: [true, false, false],
            preferVisible: true)
        #expect(kept == [2, 1])

        // Every window minimized — nothing to upgrade to, the first row stands.
        let allMinimized = CatalogFilter.keptApplicationIndices(
            pids: [7, 7],
            placeholders: [false, false],
            minimized: [true, true],
            preferVisible: true)
        #expect(allMinimized == [0])
    }

    /// The other half of #159: turning "move minimized windows to the bottom" off
    /// means the user wants pure recency, so a collapsed app row must stay on its
    /// most recent window even when that window is minimized. Same input as
    /// `applicationsOnlySkipsMinimizedRepresentative`, opposite election — without
    /// the gate the feature silently does nothing in applications-only mode.
    @Test("applications-only keeps a minimized representative when sinking is off (#159)")
    func applicationsOnlyKeepsMinimizedRepresentativeWhenNotSinking() {
        let kept = CatalogFilter.keptApplicationIndices(
            pids: [7, 9, 7],
            placeholders: [false, false, false],
            minimized: [true, false, false],
            preferVisible: false)
        #expect(kept == [0, 1])

        // The slot/row-index case must not upgrade either.
        let laterSlot = CatalogFilter.keptApplicationIndices(
            pids: [7, 7, 9, 9],
            placeholders: [false, false, false, false],
            minimized: [false, false, true, false],
            preferVisible: false)
        #expect(laterSlot == [0, 2])
    }

    /// The upgrade bookkeeping runs in two coordinate spaces: `slot` indexes into
    /// `kept`, while `kept[slot]` indexes into `minimized`. Every other case here
    /// keeps them accidentally equal because no earlier row was ever collapsed.
    /// Here pid 7 collapses first, so pid 9's slot (1) is no longer its row index
    /// (2) — reading `minimized[slot]` instead of `isMinimized(kept[slot])` would
    /// wrongly return [0, 2].
    @Test("applications-only upgrades correctly when a pid's slot differs from its row index")
    func applicationsOnlyUpgradeUsesRowIndexNotSlot() {
        let kept = CatalogFilter.keptApplicationIndices(
            pids: [7, 7, 9, 9],
            placeholders: [false, false, false, false],
            minimized: [false, false, true, false],
            preferVisible: true)
        #expect(kept == [0, 3])
    }
}
