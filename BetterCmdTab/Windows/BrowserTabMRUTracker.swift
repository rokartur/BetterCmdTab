import ApplicationServices
import CoreGraphics

/// Unified most-recently-used ordering that treats each **browser tab** as a
/// first-class entry alongside ordinary windows, backing the experimental
/// "browser tab MRU" mode (#39). The flat `.mruWindows` sort keys every row by
/// its CGWindowID, so all tabs of one browser window collapse to a single
/// recency slot and ⌘Tab can only return to the previous *window*, never the
/// previous *tab*. This tracker distinguishes the two:
///
/// - `.window(wid)` — an ordinary window (or a browser window whose tabs aren't
///   expanded), keyed by its CGWindowID, exactly like `WindowMRUTracker`.
/// - `.tab(wid, title)` — one browser tab. Tabs share their parent window's
///   CGWindowID, so the active tab's title is the only cheap per-tab identity we
///   have (read straight off the window's AX title — no Apple Events). Title
///   churn on navigation just renames the entry the user is already on, which is
///   harmless: it still points at "the tab they're looking at".
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
    /// into two recency entries (the current tab would then miss row 0).
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
        let indexed = rows.enumerated().map { offset, row -> (rank: Int, offset: Int, row: SwitcherRow) in
            let r = Self.key(for: row).flatMap { rank[$0] } ?? Int.max
            return (r, offset, row)
        }
        return indexed.sorted { lhs, rhs in
            lhs.rank != rhs.rank ? lhs.rank < rhs.rank : lhs.offset < rhs.offset
        }.map(\.row)
    }
}
