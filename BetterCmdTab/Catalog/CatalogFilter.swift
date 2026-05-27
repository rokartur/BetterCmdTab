import AppKit

/// Applies the user's catalog-filter preferences (excluded apps, pinned apps,
/// minimized/hidden visibility) to produced switcher rows and app lists.
///
/// `config()` is `nonisolated` and reads `UserDefaults` directly: the cold
/// catalog paths (`AppCatalog.snapshot`, `AppCatalogCache.computeEntries`) run
/// off the main actor, where the `@MainActor` `Preferences` singleton can't be
/// touched. `UserDefaults` reads are thread-safe and the keys are shared with
/// `Preferences.Keys` so the two never drift.
enum CatalogFilter {
    struct Config: Sendable {
        let excluded: Set<String>
        let pinned: [String]
        let showMinimized: Bool
        let showHidden: Bool
        let showWindowless: Bool
        let currentSpaceOnly: Bool

        /// No filtering and no reordering — lets callers skip work entirely.
        var isIdentity: Bool {
            excluded.isEmpty && pinned.isEmpty && showMinimized && showHidden && showWindowless && !currentSpaceOnly
        }
    }

    nonisolated static func config() -> Config {
        let defaults = UserDefaults.standard
        return Config(
            excluded: Set(defaults.stringArray(forKey: Preferences.Keys.excludedBundleIDs) ?? []),
            pinned: defaults.stringArray(forKey: Preferences.Keys.pinnedBundleIDs) ?? [],
            showMinimized: defaults.object(forKey: Preferences.Keys.showMinimizedWindows) as? Bool ?? true,
            showHidden: defaults.object(forKey: Preferences.Keys.showHiddenApps) as? Bool ?? true,
            showWindowless: defaults.object(forKey: Preferences.Keys.showWindowlessApps) as? Bool ?? true,
            currentSpaceOnly: defaults.object(forKey: Preferences.Keys.currentSpaceOnly) as? Bool ?? false
        )
    }

    /// Drop excluded apps and (optionally) minimized/hidden windows, then move
    /// pinned apps to the front in pin order. Placeholders (cache-warm rows)
    /// are never filtered or reordered.
    static func filteredRows(_ rows: [SwitcherRow], _ cfg: Config) -> [SwitcherRow] {
        if cfg.isIdentity { return rows }
        var filtered = rows.filter {
            includes(bundleID: $0.bundleIdentifier, isPlaceholder: $0.isPlaceholder, isMinimized: $0.isMinimized, appHidden: $0.isHidden, hasWindow: $0.window != nil, cfg)
        }
        if !cfg.pinned.isEmpty {
            filtered = stablePartition(filtered) { row in
                row.isPlaceholder ? nil : row.bundleIdentifier.flatMap { cfg.pinned.firstIndex(of: $0) }
            }
        }
        if cfg.currentSpaceOnly {
            filtered = filterToCurrentSpace(filtered)
        }
        return filtered
    }

    /// Drop windows that live on a Space other than the one in focus. Rows
    /// without a real window (windowless apps, launchables, recents) and any
    /// window whose Space can't be resolved are kept, so the filter only ever
    /// hides windows it's certain are elsewhere. Degrades to a no-op when the
    /// private Space APIs are unavailable.
    private static func filterToCurrentSpace(_ rows: [SwitcherRow]) -> [SwitcherRow] {
        guard let active = PrivateAPI.activeSpace() else { return rows }
        let widByOffset: [(offset: Int, wid: CGWindowID)] = rows.enumerated().compactMap { idx, row in
            guard let window = row.window else { return nil }
            let wid = PrivateAPI.cgWindowId(of: window)
            return wid == 0 ? nil : (idx, wid)
        }
        guard !widByOffset.isEmpty else { return rows }
        let spaceByWindow = PrivateAPI.spaces(forWindows: widByOffset.map(\.wid))
        guard !spaceByWindow.isEmpty else { return rows }
        var dropOffsets = Set<Int>()
        for (offset, wid) in widByOffset {
            if let space = spaceByWindow[wid], space != active { dropOffsets.insert(offset) }
        }
        if dropOffsets.isEmpty { return rows }
        return rows.enumerated().filter { !dropOffsets.contains($0.offset) }.map(\.element)
    }

    /// Row-level inclusion test split out so it can be unit-tested without
    /// constructing `NSRunningApplication` instances. Placeholders are always
    /// kept (transient cache-warm rows).
    static func includes(bundleID: String?, isPlaceholder: Bool, isMinimized: Bool, appHidden: Bool, hasWindow: Bool = true, _ cfg: Config) -> Bool {
        if isPlaceholder { return true }
        if let bid = bundleID, cfg.excluded.contains(bid) { return false }
        if !cfg.showMinimized, isMinimized { return false }
        if !cfg.showHidden, appHidden { return false }
        if !cfg.showWindowless, !hasWindow { return false }
        return true
    }

    /// Same exclusion + pin reordering for the primed app list (window state
    /// doesn't apply at the app level, but hidden apps are still dropped).
    static func filteredApps(_ apps: [NSRunningApplication], _ cfg: Config) -> [NSRunningApplication] {
        if cfg.isIdentity { return apps }
        let filtered = apps.filter { app in
            if let bid = app.bundleIdentifier, cfg.excluded.contains(bid) { return false }
            if !cfg.showHidden, app.isHidden { return false }
            return true
        }
        guard !cfg.pinned.isEmpty else { return filtered }
        return stablePartition(filtered) { app in
            app.bundleIdentifier.flatMap { cfg.pinned.firstIndex(of: $0) }
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
