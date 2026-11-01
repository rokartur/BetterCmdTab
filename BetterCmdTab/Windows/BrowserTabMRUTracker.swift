import ApplicationServices
import CoreGraphics

/// Unified most-recently-used ordering that treats each **browser tab** as a
/// first-class entry alongside ordinary windows, backing the "browser tab MRU"
/// mode (#39). The flat `.mruWindows` sort keys every row by its CGWindowID, so
/// all tabs of one browser window collapse to a single recency slot and ⌘Tab
/// can only return to the previous *window*, never the previous *tab*. This
/// tracker distinguishes the two:
///
/// - `.window(wid)` — an ordinary window (or a browser window whose tabs aren't
///   expanded), keyed by its CGWindowID, exactly like `WindowMRUTracker`.
/// - `.tab(wid, title)` — one browser tab. Tabs share their parent window's
///   CGWindowID, so the active tab's title is the only cheap per-tab identity we
///   have (read straight off the window's AX title — no Apple Events). Title
///   churn on navigation just renames the entry the user is already on, which is
///   harmless: it still points at "the tab they're looking at".
///   The AX title an entry records is not always the tab title a displayed row
///   carries: Chromium suffixes the window title with the browser (and profile)
///   name, so `sortRows` matches those through
///   `BrowserTabs.windowTitle(_:matchesTab:)` (#157).
///
/// Fed by `BrowserTabFocusObserver` (in-browser tab switches) and the switcher's
/// focus/commit paths. Pure ordering — no AX/Apple Events here, so it's unit
/// testable. Dead ids/titles never match a live row, so stale entries are
/// harmless; the cap is the only cleanup needed.
@MainActor
final class BrowserTabMRUTracker {
    enum Key: Hashable {
        case window(CGWindowID)
        case tab(CGWindowID, String)

        var wid: CGWindowID {
            switch self {
            case .window(let w), .tab(let w, _): return w
            }
        }
    }

    /// Flat unified recency, newest first.
    private(set) var order: [Key] = []
    /// Hard ceiling. `bump` only prepends, so without a cap a long session that
    /// cycles many tabs would grow unbounded. Dead entries never match a row, so
    /// the cap (plus `forgetWindow` on close) is the only cleanup.
    private let cap = 300

    /// Promote `key` to the front. A no-op-free move: existing occurrences are
    /// removed first so recency is exact, not duplicated.
    func bump(_ key: Key) {
        guard key.wid != 0 else { return }
        order.removeAll { $0 == key }
        order.insert(key, at: 0)
        if order.count > cap { order.removeLast(order.count - cap) }
    }

    /// Drop every entry (window slot and all tab slots) for a closed window id.
    func forgetWindow(_ wid: CGWindowID) {
        guard wid != 0 else { return }
        order.removeAll { $0.wid == wid }
    }

    /// A tab key with a normalized title. Tab titles reach the tracker from two
    /// sources — the AX window title (observer / focus) and the osascript tab list
    /// (displayed rows) — which the cache already matches on a *trimmed* basis. Trim
    /// here too so a stray whitespace difference between the two can't split one tab
    /// into two recency entries (the current tab would then miss row 0). A window
    /// title that carries more than the tab title (Chromium's browser/profile
    /// suffix) can't be canonicalized here — the tab list it has to match isn't
    /// known at bump time — so `sortRows` reconciles that pair instead.
    static func tabKey(wid: CGWindowID, title: String) -> Key {
        .tab(wid, title.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The MRU key for a displayed row: a tab row keys by (parent wid, trimmed tab
    /// title); any other windowed row keys by its CGWindowID. Windowless rows
    /// (placeholder / launchable / recently-closed, `cgWindowID == 0`) have no
    /// recency → nil.
    static func key(for row: SwitcherRow) -> Key? {
        guard row.cgWindowID != 0 else { return nil }
        if row.browserTab != nil { return tabKey(wid: row.cgWindowID, title: row.windowTitle) }
        return .window(row.cgWindowID)
    }

    /// Re-order already-expanded `rows` by unified tab+window recency, newest
    /// first. Rows whose key is unknown (never focused) or windowless fall to the
    /// back at `rank = Int.max`, stable on their incoming offset so they keep the
    /// caller's prior order. Mirrors `WindowMRUTracker.sortRows` so the two sorts
    /// behave identically apart from the richer key.
    func sortRows(_ rows: [SwitcherRow]) -> [SwitcherRow] {
        guard !order.isEmpty, rows.count > 1 else { return rows }
        var rank: [Key: Int] = [:]
        rank.reserveCapacity(order.count)
        for (i, k) in order.enumerated() { rank[k] = i }
        // Built on the first exact miss only, so a reveal where every row hits its
        // key — Safari, single-profile Chromium — pays nothing extra.
        var tabRanks: [CGWindowID: [(rank: Int, title: String)]]?
        let indexed = rows.enumerated().map { offset, row -> (rank: Int, offset: Int, row: SwitcherRow) in
            guard let key = Self.key(for: row) else { return (Int.max, offset, row) }
            if let exact = rank[key] { return (exact, offset, row) }
            let byWindow = tabRanks ?? Self.tabRanksByWindow(order)
            tabRanks = byWindow
            switch key {
            case .window(let wid):
                // A browser window shown whole (tabs not scanned yet, or grouped by its rule, #253) ranks as its newest tab.
                return (byWindow[wid]?.first?.rank ?? Int.max, offset, row)
            case .tab(let wid, let tabTitle):
                let matched = byWindow[wid]?.first { BrowserTabs.windowTitle($0.title, matchesTab: tabTitle) }
                return (matched?.rank ?? Int.max, offset, row)
            }
        }
        return indexed.sorted { lhs, rhs in
            lhs.rank != rhs.rank ? lhs.rank < rhs.rank : lhs.offset < rhs.offset
        }.map(\.row)
    }

    /// Tab entries grouped by their parent window id, newest first — the index
    /// `sortRows` falls back to when a row's tab title isn't the whole AX window
    /// title the bump recorded. Scanning only the row's own window keeps the
    /// fallback to a handful of comparisons instead of the whole 300-entry order.
    private static func tabRanksByWindow(_ order: [Key]) -> [CGWindowID: [(rank: Int, title: String)]] {
        var out: [CGWindowID: [(rank: Int, title: String)]] = [:]
        for (rank, key) in order.enumerated() {
            if case .tab(let wid, let title) = key { out[wid, default: []].append((rank, title)) }
        }
        return out
    }
}
