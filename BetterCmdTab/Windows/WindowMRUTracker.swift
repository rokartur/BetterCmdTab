import AppKit
import ApplicationServices
import CoreGraphics

/// Per-app most-recently-used ordering of window CGWindowIDs.
///
/// CGWindowList z-order roughly reflects per-app window recency, but it lags
/// briefly after our own raise and can reshuffle after Mission Control /
/// Space changes. Cmd+` needs deterministic "previous window" semantics —
/// same idea as MRUTracker has for apps — so window picks are sourced from
/// this tracker, with z-order as the tail fallback for windows we have not
/// yet observed.
@MainActor
final class WindowMRUTracker {
    private var order: [pid_t: [CGWindowID]] = [:]
    /// Flat cross-app window recency, newest first, backing the `.mruWindows`
    /// sort order. Maintained alongside the per-app `order` map by `bump`.
    /// Ids of a terminated app are purged by the termination observer;
    /// `globalCap` bounds growth from windows that close while their app
    /// lives (dead ids never match a live row, so they are harmless to rank).
    private var globalOrder: [CGWindowID] = []
    private let globalCap = 200
    private var termObserver: NSObjectProtocol?
    /// Hard ceiling on remembered windows per app. `bump` only ever prepends,
    /// so without a cap a long-running app that opens and closes many windows
    /// would accumulate dead CGWindowIDs for its whole lifetime. This cap
    /// (plus removal on app termination) is the only cleanup — the rows
    /// reaching `sortRows` are display-filtered, so pruning against them
    /// would erase recency of live windows (see `sortRows(_:by:)`).
    private let perAppCap = 64

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        termObserver = nc.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Confirmed-dead purge: the app is gone, so every window we
                // remembered for it is too.
                if let dead = self.order.removeValue(forKey: pid), !dead.isEmpty {
                    let deadSet = Set(dead)
                    self.globalOrder.removeAll { deadSet.contains($0) }
                }
            }
        }
    }

    nonisolated deinit {
        if let obs = MainActor.assumeIsolated({ termObserver }) {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
    }

    func bump(pid: pid_t, wid: CGWindowID) {
        guard wid != 0 else { return }
        var list = order[pid] ?? []
        list.removeAll { $0 == wid }
        list.insert(wid, at: 0)
        if list.count > perAppCap { list.removeLast(list.count - perAppCap) }
        order[pid] = list

        globalOrder.removeAll { $0 == wid }
        globalOrder.insert(wid, at: 0)
        if globalOrder.count > globalCap { globalOrder.removeLast(globalOrder.count - globalCap) }
    }

    /// Promote the app's currently focused window to MRU front by querying AX
    /// directly. Call this at the start of a Cmd+` chord so external focus
    /// changes (user clicked a different window manually) are reflected before
    /// rows get reordered.
    func syncFrontWindow(pid: pid_t) {
        let wid = Self.focusedWindowID(pid: pid)
        if wid != 0 { bump(pid: pid, wid: wid) }
    }

    /// Resolve the pid's focused-window CGWindowID via a blocking AX query.
    /// `nonisolated` so callers can run it off the main thread — the AX calls
    /// here can stall for the full messaging timeout if the target app is
    /// unresponsive, which must never happen on the main run loop.
    nonisolated static func focusedWindowID(pid: pid_t) -> CGWindowID {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.05)
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let focusedVal = focused,
              CFGetTypeID(focusedVal) == AXUIElementGetTypeID() else { return 0 }
        return PrivateAPI.cgWindowId(of: focusedVal as! AXUIElement)
    }

    /// Re-orders `rows` so MRU-known windows come first in MRU order; unknown
    /// windows (or windowless placeholder rows) follow in their original
    /// position. Caller passes rows already filtered to a single pid.
    func sortRows(_ rows: [SwitcherRow], forPid pid: pid_t) -> [SwitcherRow] {
        guard let list = order[pid], !list.isEmpty, rows.count > 1 else { return rows }
        return sortRows(rows, by: list)
    }

    /// Re-orders each contiguous run of same-pid windowed rows by that app's
    /// per-app recency (`sortRows(forPid:)`), leaving run boundaries and every
    /// other row in place. The app-grouped sorts (.mru / alphabetical / launch
    /// order) apply this so each app's leading row — the one
    /// `collapseToApplications` elects, the pid selection anchor lands on, and
    /// a ⌘Tab app commit activates — is the app's most recently used window
    /// instead of the AX scan order (#83, #30). Runs never span status buckets
    /// (the catalog orders buckets before any app's rows repeat), so a recently
    /// focused but since-minimized window can't jump ahead of a visible one.
    func sortRowsWithinAppRuns(_ rows: [SwitcherRow]) -> [SwitcherRow] {
        guard !order.isEmpty, rows.count > 1 else { return rows }
        let ranges = Self.windowRunRanges(
            pids: rows.map(\.pid),
            windowed: rows.map { $0.window != nil || $0.cgWindowID != 0 }
        )
        guard !ranges.isEmpty else { return rows }
        var result = rows
        for range in ranges {
            guard let pid = result[range.lowerBound].pid, order[pid] != nil else { continue }
            result.replaceSubrange(range, with: sortRows(Array(result[range]), forPid: pid))
        }
        return result
    }

    /// Pure index-level core of `sortRowsWithinAppRuns`, split out so run
    /// detection is unit-testable without live AX rows: the maximal contiguous
    /// ranges (length ≥ 2) of windowed rows sharing one non-nil pid. A
    /// windowless row — or a different pid — ends the run it interrupts.
    static func windowRunRanges(pids: [pid_t?], windowed: [Bool]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var i = 0
        while i < pids.count {
            guard let pid = pids[i], windowed[i] else { i += 1; continue }
            var j = i + 1
            while j < pids.count, pids[j] == pid, windowed[j] { j += 1 }
            if j - i > 1 { ranges.append(i..<j) }
            i = j
        }
        return ranges
    }

    /// Re-orders `rows` by flat cross-app window recency (the `.mruWindows`
    /// sort): each window sorts by its rank in `globalOrder`, newest first,
    /// interleaving windows of different apps. Windowless rows (`cgWindowID == 0`)
    /// and windows never seen by the tracker fall to the back at `rank = Int.max`,
    /// keeping their incoming relative (app-MRU) order via the offset tiebreak.
    func sortRowsGlobally(_ rows: [SwitcherRow]) -> [SwitcherRow] {
        guard !globalOrder.isEmpty, rows.count > 1 else { return rows }
        return sortRows(rows, by: globalOrder)
    }

    /// Shared core for the per-app and global sorts: rank `rows` by each
    /// window's position in `order` (newest first). Rows whose window is
    /// unknown or windowless (`cgWindowID == 0`) fall to the back at
    /// `rank = Int.max`, stable on their incoming offset. Callers guarantee
    /// `order` is non-empty and `rows.count > 1`.
    ///
    /// Deliberately does NOT prune `order` against `rows`: the incoming rows
    /// are display-filtered (Current-Space-only, hide-minimized, hide rules),
    /// so an id absent here may belong to a live window whose recency must
    /// survive. Closed windows' ids never match a row — harmless to ranking —
    /// and growth stays bounded by the caps plus the termination purge.
    private func sortRows(_ rows: [SwitcherRow], by order: [CGWindowID]) -> [SwitcherRow] {
        // Resolve each row's CGWindowID once for the rank lookup below. Prefer
        // the id resolved during the window scan; only fall back to a live
        // `_AXUIElementGetWindow` for rows that lack one.
        let rowWids = rows.enumerated().map { offset, row -> (wid: CGWindowID, offset: Int, row: SwitcherRow) in
            let wid = row.cgWindowID != 0 ? row.cgWindowID : (row.window.map { PrivateAPI.cgWindowId(of: $0) } ?? 0)
            return (wid, offset, row)
        }

        var rank: [CGWindowID: Int] = [:]
        rank.reserveCapacity(order.count)
        for (i, wid) in order.enumerated() { rank[wid] = i }

        let indexed = rowWids.map { wid, offset, row -> (rank: Int, original: Int, row: SwitcherRow) in
            let r = (wid != 0 ? rank[wid] : nil) ?? Int.max
            return (r, offset, row)
        }
        return indexed.sorted { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            return lhs.original < rhs.original
        }.map { $0.row }
    }
}
