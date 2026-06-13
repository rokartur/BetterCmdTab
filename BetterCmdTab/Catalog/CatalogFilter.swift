import AppKit
import CoreGraphics

/// Applies the user's catalog-filter preferences (per-app hide rules, pinned
/// apps, minimized/hidden visibility) to produced switcher rows and app lists.
///
/// `config()` is `nonisolated` and reads `UserDefaults` directly: the cold
/// catalog paths (`AppCatalog.snapshot`, `AppCatalogCache.computeEntries`) run
/// off the main actor, where the `@MainActor` `Preferences` singleton can't be
/// touched. `UserDefaults` reads are thread-safe and the keys are shared with
/// `Preferences.Keys` so the two never drift.
enum CatalogFilter {
    struct Config: Sendable {
        /// Per-app hide override, keyed by bundle ID. Only entries that actually
        /// hide something are stored — a `.dontHide` exception is neutral and
        /// omitted, so an absent key means "apply the global toggles".
        let hideModes: [String: HideWindowsMode]
        let pinned: [String]
        let showMinimized: Bool
        let showHidden: Bool
        let showWindowless: Bool
        let currentSpaceOnly: Bool
        let sortOrder: SwitcherSortOrder

        /// No filtering and no reordering — lets callers skip work entirely.
        var isIdentity: Bool {
            hideModes.isEmpty && pinned.isEmpty && showMinimized && showHidden && showWindowless && !currentSpaceOnly && sortOrder == .mru
        }
    }

    nonisolated static func config() -> Config {
        let defaults = UserDefaults.standard
        var hideModes: [String: HideWindowsMode] = [:]
        if let raw = defaults.array(forKey: Preferences.Keys.appExceptions) as? [[String: String]] {
            for entry in raw {
                guard let bid = entry["bundleID"], !bid.isEmpty else { continue }
                let mode = entry["hide"].flatMap(HideWindowsMode.init) ?? .dontHide
                if mode != .dontHide { hideModes[bid] = mode }
            }
        }
        let sortRaw = defaults.string(forKey: Preferences.Keys.sortOrder)
        return Config(
            hideModes: hideModes,
            pinned: defaults.stringArray(forKey: Preferences.Keys.pinnedBundleIDs) ?? [],
            showMinimized: defaults.object(forKey: Preferences.Keys.showMinimizedWindows) as? Bool ?? true,
            showHidden: defaults.object(forKey: Preferences.Keys.showHiddenApps) as? Bool ?? true,
            showWindowless: defaults.object(forKey: Preferences.Keys.showWindowlessApps) as? Bool ?? true,
            currentSpaceOnly: defaults.object(forKey: Preferences.Keys.currentSpaceOnly) as? Bool ?? false,
            sortOrder: sortRaw.flatMap(SwitcherSortOrder.init(rawValue:)) ?? .mru
        )
    }

    /// Drop apps hidden by their exception and (optionally) minimized/hidden
    /// windows, then move pinned apps to the front in pin order. Placeholders
    /// (cache-warm rows) are never filtered or reordered.
    static func filteredRows(_ rows: [SwitcherRow], _ cfg: Config) -> [SwitcherRow] {
        // Resolve Space membership once and share it across both Space-based
        // filters so a reveal never queries the same window's Space twice. The
        // current-Space filter needs every window's Space; the phantom filter
        // only cares about off-screen windows, so when current-Space is off we
        // resolve just those (see resolveSpaces).
        let spaces = resolveSpaces(rows, needsAllWindows: cfg.currentSpaceOnly)

        // Drop Electron-style phantom windows first, unconditionally. These are
        // never-shown helper windows the user can't reach (not a preference), so
        // they're removed even under an identity config that skips the rest.
        let rows = filterPhantomWindows(rows, spaces)
        if cfg.isIdentity { return rows }
        var filtered = rows.filter {
            includes(bundleID: $0.bundleIdentifier, isPlaceholder: $0.isPlaceholder, isMinimized: $0.isMinimized, appHidden: $0.isHidden, hasWindow: $0.window != nil, cfg)
        }
        if cfg.sortOrder != .mru {
            filtered = applySortOrder(filtered, cfg.sortOrder, name: { $0.appName }, pid: { $0.pid })
        }
        filtered = pinnedToFront(filtered, cfg.pinned)
        if cfg.currentSpaceOnly {
            filtered = filterToCurrentSpace(filtered, spaces)
        }
        return filtered
    }

    /// Collapse a window-level row list to one row per application (classic
    /// ⌘Tab). Keeps the first row of each process id — which, after the upstream
    /// `statusPriority` sort, is that app's frontmost/active window — so selecting
    /// the row activates the app on its current window. Rows without a pid
    /// (launchables, recently-closed) and placeholders pass through untouched, so
    /// search/launcher results and cache-warm rows are unaffected.
    ///
    /// Applied by `SwitcherController` on the app-switch reveal paths only — not
    /// inside `filteredRows`, so the cache stays a canonical per-window list that
    /// the windows-only (⌘`) and current-app-windows scope paths can still read in
    /// full.
    static func collapseToApplications(_ rows: [SwitcherRow]) -> [SwitcherRow] {
        keptApplicationIndices(pids: rows.map(\.pid), placeholders: rows.map(\.isPlaceholder))
            .map { rows[$0] }
    }

    /// Pure index-level core of `collapseToApplications`, split out so it can be
    /// unit-tested without constructing `NSRunningApplication`s. Returns the
    /// indices to keep: the first occurrence of each pid, plus every index whose
    /// pid is nil (launchables / recently-closed) or that is a placeholder.
    static func keptApplicationIndices(pids: [pid_t?], placeholders: [Bool]) -> [Int] {
        var seen = Set<pid_t>()
        var kept: [Int] = []
        kept.reserveCapacity(pids.count)
        for i in pids.indices {
            let isPlaceholder = i < placeholders.count && placeholders[i]
            if isPlaceholder {
                kept.append(i)                       // cache-warm rows pass through
            } else if let pid = pids[i] {
                if seen.insert(pid).inserted { kept.append(i) }  // first window of the app
            } else {
                kept.append(i)                       // no pid (launchable / recently-closed)
            }
        }
        return kept
    }

    /// Space membership resolved once per `filteredRows` call and shared by the
    /// phantom filter and the current-Space filter, so neither re-queries
    /// WindowServer for the same window. `spaceByWindow` maps each *resolved*
    /// window id to its first Space; `onScreen` is the set of currently visible
    /// window ids; `activeSpace` is nil when the private Space API is
    /// unavailable, in which case both filters no-op.
    struct SpaceResolution {
        let spaceByWindow: [CGWindowID: UInt64]
        let onScreen: Set<CGWindowID>
        let activeSpace: UInt64?

        /// Space API unavailable — callers degrade to showing every window.
        static let unavailable = SpaceResolution(spaceByWindow: [:], onScreen: [], activeSpace: nil)
    }

    /// Resolve Space membership for `rows`. When `needsAllWindows` is true (the
    /// current-Space filter is active) every window is queried; otherwise only
    /// off-screen windows are — an on-screen window is by definition on a Space,
    /// so the phantom filter doesn't need it and we skip that per-window IPC.
    static func resolveSpaces(_ rows: [SwitcherRow], needsAllWindows: Bool) -> SpaceResolution {
        guard let active = PrivateAPI.activeSpace() else { return .unavailable }
        let onScreen = onScreenWindowIDs()
        // Unique wids to resolve (browser-tab rows can share a parent wid).
        var wids = Set<CGWindowID>()
        for row in rows where row.cgWindowID != 0 {
            if needsAllWindows || !onScreen.contains(row.cgWindowID) {
                wids.insert(row.cgWindowID)
            }
        }
        let spaceByWindow = wids.isEmpty ? [:] : PrivateAPI.spaces(forWindows: Array(wids))
        return SpaceResolution(spaceByWindow: spaceByWindow, onScreen: onScreen, activeSpace: active)
    }

    /// Drop windows that live on a Space other than the one in focus. Rows
    /// without a real window (windowless apps, launchables, recents) and any
    /// window whose Space can't be resolved — including multi-Space (All
    /// Desktops / sticky) windows, which `PrivateAPI.spaces(forWindows:)`
    /// leaves unresolved — are kept, so the filter only ever hides windows
    /// it's certain are elsewhere. Reads Space membership from the shared
    /// `SpaceResolution`; degrades to a no-op when it's unavailable.
    /// Convenience for standalone callers outside the `filteredRows` pipeline
    /// (e.g. the windows-only scope path) that don't already hold a shared
    /// `SpaceResolution`. Resolves every window's Space, then filters.
    static func filterToCurrentSpace(_ rows: [SwitcherRow]) -> [SwitcherRow] {
        filterToCurrentSpace(rows, resolveSpaces(rows, needsAllWindows: true))
    }

    static func filterToCurrentSpace(_ rows: [SwitcherRow], _ spaces: SpaceResolution) -> [SwitcherRow] {
        guard let active = spaces.activeSpace, !spaces.spaceByWindow.isEmpty else { return rows }
        var dropOffsets = Set<Int>()
        for (offset, row) in rows.enumerated() where row.cgWindowID != 0 {
            if let space = spaces.spaceByWindow[row.cgWindowID], space != active {
                dropOffsets.insert(offset)
            }
        }
        if dropOffsets.isEmpty { return rows }
        return rows.enumerated().filter { !dropOffsets.contains($0.offset) }.map(\.element)
    }

    /// Drop "phantom" windows: real CGWindow-backed rows that have never been
    /// mapped to a Space. Electron apps (Teams, Signal, …) keep a hidden
    /// `BrowserWindow` that the AX window list still reports — it has a valid
    /// CGWindowID and standard subrole but a blank title, so it surfaces as a
    /// duplicate row labelled with the bare app name. A never-shown window
    /// belongs to no Space; minimized, hidden-app, other-Space and fullscreen
    /// windows all keep theirs.
    ///
    /// Two guards keep the failure bias on the safe side — drop only what we're
    /// sure is unreachable, never the user's actual window:
    ///   1. Only *off-screen* windows are candidates. An on-screen window is by
    ///      definition on a Space, so it's skipped without a Space query — which
    ///      also bounds the per-window `CGSCopySpacesForWindows` IPCs to the few
    ///      off-screen rows instead of every row on every reveal.
    ///   2. A spaceless window is dropped only when its app *also* has a window
    ///      that does occupy a Space (on-screen, or an off-screen sibling that
    ///      resolved). A phantom always coexists with the app's real window, so
    ///      this still catches it — but if an app's *only* window fails to
    ///      resolve (a transient WindowServer miss), it's kept rather than
    ///      vanishing from the switcher.
    ///
    /// Reads Space membership from the shared `SpaceResolution`; degrades to a
    /// no-op when it's unavailable.
    static func filterPhantomWindows(_ rows: [SwitcherRow], _ spaces: SpaceResolution) -> [SwitcherRow] {
        guard spaces.activeSpace != nil else { return rows }

        // Every window-bearing row tagged with whether WindowServer currently
        // shows it. The wid is the one captured at enumeration time (no AX
        // round-trip). Rows without a real window (placeholders/launchables/
        // recents) carry wid 0 or no pid and are never candidates.
        let windowRows: [(offset: Int, pid: pid_t, wid: CGWindowID, onScreen: Bool)] =
            rows.enumerated().compactMap { idx, row in
                guard row.cgWindowID != 0, let pid = row.pid else { return nil }
                return (idx, pid, row.cgWindowID, spaces.onScreen.contains(row.cgWindowID))
            }
        // `spaceByWindow` holds every wid that resolved to a Space (on-screen
        // windows are included only when the current-Space filter forced a full
        // query; otherwise on-screen rows are covered by their on-screen flag).
        let dropOffsets = phantomWindowOffsets(
            windowRows: windowRows,
            resolvedCandidateWids: Set(spaces.spaceByWindow.keys)
        )
        if dropOffsets.isEmpty { return rows }
        return rows.enumerated().filter { !dropOffsets.contains($0.offset) }.map(\.element)
    }

    /// Pure index-level core of `filterPhantomWindows`, split out so it can be
    /// unit-tested without CGS calls or `SwitcherRow`/AX. `windowRows` is every
    /// window-bearing row (offset, owning pid, wid, on-screen flag);
    /// `resolvedCandidateWids` is the set of off-screen wids that resolved to a
    /// Space. Returns the offsets to drop: off-screen, spaceless windows whose
    /// app occupies a Space elsewhere (so a real window exists and this one is
    /// the never-shown helper).
    static func phantomWindowOffsets(
        windowRows: [(offset: Int, pid: pid_t, wid: CGWindowID, onScreen: Bool)],
        resolvedCandidateWids: Set<CGWindowID>
    ) -> Set<Int> {
        // Apps with at least one window known to occupy a Space: any on-screen
        // window, or any off-screen window that resolved.
        var pidsOccupyingSpace = Set<pid_t>()
        for r in windowRows where r.onScreen || resolvedCandidateWids.contains(r.wid) {
            pidsOccupyingSpace.insert(r.pid)
        }
        var drop = Set<Int>()
        for r in windowRows
        where !r.onScreen
            && !resolvedCandidateWids.contains(r.wid)
            && pidsOccupyingSpace.contains(r.pid) {
            drop.insert(r.offset)
        }
        return drop
    }

    /// WindowServer ids currently visible on the active Space(s), via one
    /// `CGWindowListCopyWindowInfo` call. Used to skip the per-window Space query
    /// for windows already known to be on screen (and therefore on a Space).
    private static func onScreenWindowIDs() -> Set<CGWindowID> {
        guard let arr = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [NSDictionary] else {
            return []
        }
        var ids = Set<CGWindowID>()
        ids.reserveCapacity(arr.count)
        for entry in arr {
            if let n = entry[kCGWindowNumber as String] as? Int { ids.insert(CGWindowID(n)) }
        }
        return ids
    }

    /// Row-level inclusion test split out so it can be unit-tested without
    /// constructing `NSRunningApplication` instances. Placeholders are always
    /// kept (transient cache-warm rows).
    static func includes(bundleID: String?, isPlaceholder: Bool, isMinimized: Bool, appHidden: Bool, hasWindow: Bool = true, _ cfg: Config) -> Bool {
        if isPlaceholder { return true }
        if let bid = bundleID, let mode = cfg.hideModes[bid] {
            switch mode {
            case .always: return false
            case .whenNoWindows: if !hasWindow { return false }
            case .dontHide: break
            }
        }
        if !cfg.showMinimized, isMinimized { return false }
        if !cfg.showHidden, appHidden { return false }
        if !cfg.showWindowless, !hasWindow { return false }
        return true
    }

    /// Same hide + pin reordering for the primed app list. Window state isn't
    /// known at the app level, so only `always`-hidden apps are dropped here
    /// (the `whenNoWindows` rule is enforced on the full row list); hidden apps
    /// are still dropped per the global toggle.
    static func filteredApps(_ apps: [NSRunningApplication], _ cfg: Config) -> [NSRunningApplication] {
        if cfg.isIdentity { return apps }
        var filtered = apps.filter { app in
            if let bid = app.bundleIdentifier, cfg.hideModes[bid] == .always { return false }
            if !cfg.showHidden, app.isHidden { return false }
            return true
        }
        if cfg.sortOrder != .mru {
            filtered = applySortOrder(filtered, cfg.sortOrder, name: { $0.localizedName ?? "" }, pid: { $0.processIdentifier })
        }
        guard !cfg.pinned.isEmpty else { return filtered }
        return stablePartition(filtered) { app in
            app.bundleIdentifier.flatMap { cfg.pinned.firstIndex(of: $0) }
        }
    }

    /// Reorder by the user's global sort preference. `.mru` returns the input
    /// untouched (the caller skips calling it then). `.mruWindows` also returns
    /// the input here — the cross-app window sort is applied later in
    /// `SwitcherController`, which owns the `WindowMRUTracker` it needs.
    /// Alphabetical sorts by app name (case-insensitive); launch order by pid
    /// ascending (older process first). Both are stable on the incoming offset,
    /// so equal keys keep their order — that preserves each app's window
    /// grouping/status ordering.
    static func applySortOrder<T>(_ items: [T], _ order: SwitcherSortOrder, name: (T) -> String, pid: (T) -> pid_t?) -> [T] {
        switch order {
        case .mru, .mruWindows:
            return items
        case .alphabetical:
            return sortedStably(items) { name($0).lowercased() }
        case .launchOrder:
            return sortedStably(items) { Int(pid($0) ?? pid_t.max) }
        }
    }

    /// Stable sort: decorate with the original offset and tie-break on it so
    /// equal-key elements keep their incoming order (Swift's `sort` isn't stable).
    static func sortedStably<T, K: Comparable>(_ items: [T], by key: (T) -> K) -> [T] {
        items.enumerated()
            .map { (offset: $0.offset, key: key($0.element), item: $0.element) }
            .sorted { $0.key != $1.key ? $0.key < $1.key : $0.offset < $1.offset }
            .map(\.item)
    }

    /// Lift rows whose app is pinned to the front, in pin order; non-pinned rows
    /// keep their relative order behind them. Placeholders are never pinned.
    /// Stable on offset, so each pinned app's internal window ordering is
    /// preserved. No-op when nothing is pinned. Shared by `filteredRows` and the
    /// `.mruWindows` re-pin in `SwitcherController` (the window-recency sort
    /// reorders the whole list and must restore pins afterwards).
    static func pinnedToFront(_ rows: [SwitcherRow], _ pinnedIDs: [String]) -> [SwitcherRow] {
        guard !pinnedIDs.isEmpty else { return rows }
        return stablePartition(rows) { row in
            row.isPlaceholder ? nil : row.bundleIdentifier.flatMap { pinnedIDs.firstIndex(of: $0) }
        }
    }

    /// Move items with a non-nil rank to the front, ordered by (rank, original
    /// offset); everything else keeps its relative order behind them. Stable on
    /// offset preserves each pinned app's internal window ordering (active
    /// window before minimized) produced by the upstream `statusPriority` sort.
    static func stablePartition<T>(_ items: [T], rank: (T) -> Int?) -> [T] {
        var pinned: [(rank: Int, offset: Int, item: T)] = []
        var rest: [T] = []
        rest.reserveCapacity(items.count)
        for (offset, item) in items.enumerated() {
            if let r = rank(item) {
                pinned.append((r, offset, item))
            } else {
                rest.append(item)
            }
        }
        if pinned.isEmpty { return items }
        pinned.sort { $0.rank != $1.rank ? $0.rank < $1.rank : $0.offset < $1.offset }
        return pinned.map(\.item) + rest
    }
}
