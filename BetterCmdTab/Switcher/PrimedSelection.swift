import AppKit

/// Index math for the quick-tap (primed) selection: which app a ⌘Tab press lands on before
/// the panel shows. Pure, so the tests drive it without a controller.
enum PrimedSelection {
    /// Start index for the first primed step. `anchor` is the frontmost app's
    /// position in the primed list (#88, #278); nil reproduces the legacy
    /// head-anchored start (step 1 → 1, step -1 → count-1).
    static func startIndex(count: Int, step: Int, anchor: Int?) -> Int {
        guard count > 1 else { return 0 }
        return ((((anchor ?? 0) + step) % count) + count) % count
    }

    /// `step` seeds `primedStepDelta`. Middle mode (#251) seeds 0, so the Space remap
    /// re-decides the frontmost skip. `excludedAt` is the slot of a frontmost app the list
    /// leaves out (#190, #278), now held by the next app, so a forward press seeds 0.
    static func start(
        count: Int, delta: Int, anchor: Int?, startsInMiddle: Bool, excludedAt: Int? = nil
    ) -> (index: Int, step: Int) {
        let direction = delta > 0 ? 1 : -1
        if startsInMiddle {
            return (middleStartIndex(count: count, front: anchor, direction: direction, taps: 0), 0)
        }
        if let excludedAt {
            let step = direction > 0 ? 0 : -1
            return (startIndex(count: count, step: step, anchor: excludedAt), step)
        }
        let step = count == 1 ? 0 : direction
        return (startIndex(count: count, step: step, anchor: anchor), step)
    }

    /// The middle app, or one step from it in the press `direction` when it is
    /// the frontmost app, so a quick tap still switches; then `taps` more steps.
    static func middleStartIndex(count: Int, front: Int?, direction: Int, taps: Int) -> Int {
        let middle = count / 2
        let skip = count > 1 && middle == front ? direction : 0
        return startIndex(count: count, step: skip + taps, anchor: middle)
    }

    /// The frontmost app's index in `primed` as `anchor`, or, when the list leaves it out
    /// (#190's exclusion, a windowless Finder hidden by its exception), the index the list's
    /// order would give it as `missingAt`. Pinned apps can sit ahead of it under any sort (#278).
    static func frontSlot(
        of front: NSRunningApplication?, in primed: [NSRunningApplication], sort: SwitcherSortOrder, pinned: [String]
    ) -> (anchor: Int?, missingAt: Int?) {
        guard let front else { return (nil, nil) }
        if let index = primed.firstIndex(where: { $0.pid == front.pid }) { return (index, nil) }
        return (nil, CatalogFilter.ordered([front] + primed, sort: sort, pinned: pinned).firstIndex { $0.pid == front.pid })
    }

    /// Most recent sorts reorder on every switch, so they have no fixed middle to start on.
    /// Exhaustive on purpose: a new sort case must consciously pick a side.
    static func startsInMiddle(sort: SwitcherSortOrder, selection: InitialSelection) -> Bool {
        switch sort {
        case .alphabetical, .launchOrder, .dock: return selection == .middle
        case .mru, .mruWindows: return false
        }
    }

    /// Pure core of `eligiblePrimedApp`, split out so the Space-scope remap
    /// (#126) can be unit-tested without constructing `NSRunningApplication`s.
    /// Filters the primed pid list down to `eligiblePids` (apps that kept a row
    /// after the Space-scope filter), then steps by the accumulated tap delta
    /// exactly like `startIndex` walks the full list. `anchorPid` is the
    /// frontmost app (#88, #278); `startsInMiddle` starts on the middle eligible
    /// app instead (#251), where `step` counts the presses after the first one,
    /// made in `direction`.
    /// `excludedAt`, the slot of a frontmost app the list leaves out, anchors on the
    /// first eligible app at or after that index (#190, #278).
    /// Returns an index into `primedPids`; nil when nothing is eligible.
    static func eligibleIndex(
        primedPids: [pid_t], eligiblePids: Set<pid_t>, step: Int, direction: Int, anchorPid: pid_t?,
        startsInMiddle: Bool, excludedAt: Int? = nil
    ) -> Int? {
        let eligible = primedPids.enumerated().filter { eligiblePids.contains($0.element) }
        guard !eligible.isEmpty else { return nil }
        let front = anchorPid.flatMap { pid in eligible.firstIndex { $0.element == pid } }
        let next = excludedAt.map { at in eligible.firstIndex { $0.offset >= at } ?? eligible.count }
        let index = startsInMiddle
            ? middleStartIndex(count: eligible.count, front: front, direction: direction, taps: step)
            : startIndex(count: eligible.count, step: step, anchor: next ?? front)
        return eligible[index].offset
    }

    /// Row `step` reaches in a recency-sorted list, counted from the frontmost app's newest
    /// row, which pinned apps can push off row 0 (#278). `appsAhead` is set when the primed
    /// list leaves the frontmost app out, to the apps listed ahead of its slot: its rows are
    /// skipped too (an accessory app has rows but no primed entry), so step 0 lands on the
    /// first other row past them.
    static func recencyRowIndex(rowPids: [pid_t?], front: pid_t?, appsAhead: [pid_t]?, step: Int) -> Int {
        guard let appsAhead else {
            guard !rowPids.isEmpty else { return 0 }
            let base = front.flatMap { rowPids.firstIndex(of: $0) } ?? 0
            return ((base + step) % rowPids.count + rowPids.count) % rowPids.count
        }
        let others = rowPids.indices.filter { rowPids[$0] != front }
        guard !others.isEmpty else { return 0 }
        let base = others.prefix { index in appsAhead.contains { $0 == rowPids[index] } }.count
        return others[((base + step) % others.count + others.count) % others.count]
    }
}
