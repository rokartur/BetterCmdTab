import CoreGraphics

/// Select from cached, already-scoped browser windows before allocating display
/// rows. Tab positions are activation coordinates, never recency ranks.
@MainActor
enum BrowserTabSelection {
    struct Window {
        let pid: pid_t
        let wid: CGWindowID
        let tabs: [BrowserTabInfo]
        let activeIndex: Int
        let statusPriority: Int
        let focusedIndex: Int?
    }

    struct Result {
        /// Original tab indices, in recency order, keyed by the input window offset.
        var indices: [Int: [Int]] = [:]
        /// With no observed tabs, retain one window as the browser's entry point.
        var fallbackWindows = Set<Int>()
    }

    private struct Candidate {
        let window: Int
        let index: Int
        let rank: Int
        let priority: Int
    }

    static func select(_ windows: [Window], ranking: BrowserTabMRUTracker.Ranking, limit: Int) -> Result {
        var candidates: [Candidate] = []
        var firstWindow: [pid_t: Int] = [:]
        for (offset, window) in windows.enumerated() {
            if firstWindow[window.pid] == nil { firstWindow[window.pid] = offset }
            for (index, tab) in window.tabs.enumerated() {
                let focused = window.focusedIndex == index
                guard let rank = ranking.rank(for: BrowserTabMRUTracker.tabKey(wid: window.wid, title: tab.title))
                    ?? (focused ? -1 : nil) else { continue }
                candidates.append(Candidate(window: offset, index: index,
                                            rank: focused ? -1 : rank,
                                            priority: window.statusPriority))
            }
        }
        func copy(_ candidate: Candidate) -> SwitcherRow.BrowserTabCopy? {
            let window = windows[candidate.window]
            let tab = window.tabs[candidate.index]
            return SwitcherRow.mirroredTabKey(pid: window.pid, index: candidate.index, url: tab.url, title: tab.title)
        }
        func isActive(_ candidate: Candidate) -> Bool {
            let window = windows[candidate.window]
            return window.activeIndex == candidate.index || window.focusedIndex == candidate.index
        }
        candidates.sort {
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            if $0.window != $1.window { return $0.window < $1.window }
            return $0.index < $1.index
        }
        // Keep active mirror copies, suppress inactive duplicates, then charge
        // every surviving copy against the same per-browser quota.
        var listed = Set(candidates.compactMap { candidate -> SwitcherRow.BrowserTabCopy? in
            isActive(candidate) ? copy(candidate) : nil
        })
        candidates = candidates.filter { candidate in
            guard !isActive(candidate), let key = copy(candidate) else { return true }
            return listed.insert(key).inserted
        }
        var result = Result()
        var counts: [pid_t: Int] = [:]
        for candidate in candidates {
            let pid = windows[candidate.window].pid
            guard limit <= 0 || counts[pid, default: 0] < limit else { continue }
            result.indices[candidate.window, default: []].append(candidate.index)
            counts[pid, default: 0] += 1
        }
        for (pid, offset) in firstWindow where counts[pid] == nil {
            result.fallbackWindows.insert(offset)
        }
        return result
    }
}
