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
    /// Dead ids are pruned against the live window set on every use in
    /// `sortRowsGlobally`; `globalCap` bounds growth for windows the sort
    /// never gets a chance to prune (e.g. the user never opens the switcher).
    private var globalOrder: [CGWindowID] = []
    private let globalCap = 200
    private var termObserver: NSObjectProtocol?
    /// Hard ceiling on remembered windows per app. `bump` only ever prepends, so
    /// without a cap a long-running app that opens and closes many windows would
    /// accumulate dead CGWindowIDs for its whole lifetime. `sortRows` prunes ids
    /// against the live window set; this bound covers apps the user never invokes
    /// Cmd+` on (where only `bump` runs).
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
                self?.order.removeValue(forKey: pid)
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
        guard var list = order[pid], !list.isEmpty, rows.count > 1 else { return rows }
        let sorted = sortRows(rows, by: &list)
        // The list only ever grew (bump prepends, nothing removes dead ids), so
        // the in-use prune above is the primary bound on per-pid growth; drop
        // the key entirely once it empties.
        order[pid] = list.isEmpty ? nil : list
        return sorted
    }

    /// Re-orders `rows` by flat cross-app window recency (the `.mruWindows`
    /// sort): each window sorts by its rank in `globalOrder`, newest first,
    /// interleaving windows of different apps. Windowless rows (`cgWindowID == 0`)
    /// and windows never seen by the tracker fall to the back at `rank = Int.max`,
    /// keeping their incoming relative (app-MRU) order via the offset tiebreak.
    func sortRowsGlobally(_ rows: [SwitcherRow]) -> [SwitcherRow] {
        guard !globalOrder.isEmpty, rows.count > 1 else { return rows }
        return sortRows(rows, by: &globalOrder)
    }

    /// Shared core for the per-app and global sorts: rank `rows` by each
    /// window's position in `order` (newest first), pruning ids whose windows
    /// have since closed back into `order`. Rows whose window is unknown or
    /// windowless (`cgWindowID == 0`) fall to the back at `rank = Int.max`,
    /// stable on their incoming offset. Callers guarantee `order` is non-empty
    /// and `rows.count > 1`.
    private func sortRows(_ rows: [SwitcherRow], by order: inout [CGWindowID]) -> [SwitcherRow] {
        // Resolve each row's CGWindowID once; reused for both the dead-id prune
        // and the rank lookup below. Prefer the id resolved during the window
        // scan; only fall back to a live `_AXUIElementGetWindow` for rows that
        // lack one.
        let rowWids = rows.enumerated().map { offset, row -> (wid: CGWindowID, offset: Int, row: SwitcherRow) in
            let wid = row.cgWindowID != 0 ? row.cgWindowID : (row.window.map { PrivateAPI.cgWindowId(of: $0) } ?? 0)
            return (wid, offset, row)
        }

        let liveWids = Set(rowWids.compactMap { $0.wid != 0 ? $0.wid : nil })
        let pruned = order.filter { liveWids.contains($0) }
        if pruned.count != order.count { order = pruned }
        guard !pruned.isEmpty else { return rows }

        var rank: [CGWindowID: Int] = [:]
        rank.reserveCapacity(pruned.count)
        for (i, wid) in pruned.enumerated() { rank[wid] = i }

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
