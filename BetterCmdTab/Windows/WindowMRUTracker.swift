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
    }

    /// Promote the app's currently focused window to MRU front by querying AX
    /// directly. Call this at the start of a Cmd+` chord so external focus
    /// changes (user clicked a different window manually) are reflected before
    /// rows get reordered.
    func syncFrontWindow(pid: pid_t) {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.05)
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let focusedVal = focused,
              CFGetTypeID(focusedVal) == AXUIElementGetTypeID() else { return }
        let element = focusedVal as! AXUIElement
        let wid = PrivateAPI.cgWindowId(of: element)
        if wid != 0 { bump(pid: pid, wid: wid) }
    }

    /// Re-orders `rows` so MRU-known windows come first in MRU order; unknown
    /// windows (or windowless placeholder rows) follow in their original
    /// position. Caller passes rows already filtered to a single pid.
    func sortRows(_ rows: [SwitcherRow], forPid pid: pid_t) -> [SwitcherRow] {
        guard let mruList = order[pid], !mruList.isEmpty, rows.count > 1 else { return rows }

        // Resolve each row's CGWindowID once; reused for both the dead-id prune
        // and the rank lookup below.
        let rowWids = rows.enumerated().map { offset, row -> (wid: CGWindowID, offset: Int, row: SwitcherRow) in
            // Prefer the id resolved during the window scan; only fall back to a
            // live `_AXUIElementGetWindow` for rows that lack one.
            let wid = row.cgWindowID != 0 ? row.cgWindowID : (row.window.map { PrivateAPI.cgWindowId(of: $0) } ?? 0)
            return (wid, offset, row)
        }

        // Drop ids whose windows have since closed. The list only ever grew
        // (bump prepends, nothing removed dead ids), so realign it to the live
        // window set on every use — this is the primary bound on per-pid growth.
        let liveWids = Set(rowWids.compactMap { $0.wid != 0 ? $0.wid : nil })
        let prunedList = mruList.filter { liveWids.contains($0) }
        if prunedList.count != mruList.count {
            order[pid] = prunedList.isEmpty ? nil : prunedList
        }
        guard !prunedList.isEmpty else { return rows }

        var rank: [CGWindowID: Int] = [:]
        rank.reserveCapacity(prunedList.count)
        for (i, wid) in prunedList.enumerated() { rank[wid] = i }

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
