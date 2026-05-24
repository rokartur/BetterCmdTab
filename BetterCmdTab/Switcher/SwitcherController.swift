import AppKit
import os

@MainActor
final class SwitcherController: SwitcherViewDelegate {
    enum Phase {
        case idle
        case primed
        case visible
    }

    private let hotkey = HotkeyTap()
    private let mru = MRUTracker()
    private let windowMRU = WindowMRUTracker()
    private let cache = AppCatalogCache()
    private let panel = SwitcherPanel()
    private let view: SwitcherView

    private var _phase: Phase = .idle
    private var primedApps: [NSRunningApplication] = []
    private var primedIndex: Int = 0
    private var rows: [SwitcherRow] = []
    private var labels: [String] = []
    private var index: Int = 0
    private var revealTimer: Timer?
    private var currentMetrics: SwitcherMetrics = .baseline
    private var letterBuffer: String = ""
    private var letterBufferTimer: Timer?
    private var windowsOnlyMode: Bool = false
    private var windowsOnlyPid: pid_t? = nil
    private var windowsOnlyPrimedDelta: Int = 0

    /// Signatures of windows the user just closed locally. Any cache refresh
    /// completing before the AX close has propagated would otherwise re-add
    /// the row (flicker). Each entry is dropped once the cache agrees the
    /// window is gone, or after `tombstoneTTL` as a fallback for closes that
    /// silently fail. Matching uses CGWindowID when available and falls back
    /// to (pid, title) — CGWindowID can transiently come back 0 on a freshly
    /// destroyed AX element, which would otherwise let the row slip through.
    private struct ClosedWindowSignature {
        let pid: pid_t
        let cgWindowId: CGWindowID
        let title: String
        let recordedAt: Date
    }
    private var closedTombstones: [ClosedWindowSignature] = []
    private let tombstoneTTL: TimeInterval = 2.0

    /// Monotonic token bumped on every `reveal()` and `cancel()`. Background
    /// callbacks capture the value at dispatch time and bail out on return if
    /// the token has changed — prevents rapid Cmd+Tab → Esc → Cmd+Tab from
    /// landing stale rows after a fresh reveal.
    private var revealGeneration: UInt64 = 0

    let revealDelay: TimeInterval = 0.100

    init() {
        view = SwitcherView(frame: .zero)
        panel.contentView = view
        view.delegate = self
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.phase == .visible, self.panel.isVisible else { return }
                self.panel.makeKeyAndOrderFront(nil)
            }
        }
        // Display config changed — monitor (re)connected, resolution / HiDPI
        // scaling / DDC mode swap. If the switcher is showing, recompute metrics
        // for the new active screen and reposition; otherwise the next reveal
        // picks up correct values automatically since `reveal()` rebuilds
        // metrics from `SwitcherPanel.preferredScreen()` each time.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleScreenParametersChange()
            }
        }
    }

    private func handleScreenParametersChange() {
        guard phase == .visible, !rows.isEmpty else { return }
        currentMetrics = SwitcherMetrics.forScreen(SwitcherPanel.preferredScreen(), layoutMode: Preferences.shared.switcherLayoutMode)
        view.configure(rows: rows, labels: labels, selectedIndex: index, metrics: currentMetrics, highlightPrefix: letterBuffer)
        panel.present()
    }

    func start() {
        mru.start()
        windowMRU.start()
        cache.start(mru: mru)
        let installed = hotkey.install()
        if !installed {
            Log.switcher.error("CGEventTap installation failed — Accessibility not trusted?")
            return
        }
        hotkey.onEvent = { [weak self] event in
            guard let self else { return }
            self.handle(event)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.prewarmPanel()
        }
    }

    private var phase: Phase {
        get { _phase }
        set {
            _phase = newValue
            hotkey.setSwitching(newValue != .idle)
        }
    }

    private func prewarmPanel() {
        let placeholder = SwitcherRow(
            app: NSRunningApplication.current,
            window: nil,
            windowTitle: "",
            isMinimized: false,
            isPlaceholder: true
        )
        view.configure(rows: [placeholder], labels: [""], selectedIndex: 0, metrics: .baseline, highlightPrefix: "")
        panel.setFrame(NSRect(x: -20000, y: -20000, width: 200, height: 80), display: false)
        panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.panel.orderOut(nil)
        }
    }

    func switcherViewDidHover(index: Int) {
        guard phase == .visible else { return }
        guard rows.indices.contains(index), index != self.index else { return }
        self.index = index
        view.setSelectedIndex(index)
    }

    func switcherViewDidClick(index: Int) {
        guard phase == .visible else { return }
        guard rows.indices.contains(index) else { return }
        self.index = index
        commit()
    }

    private func handle(_ event: HotkeyTap.Event) {
        switch event {
        case .nextApp:
            advance(by: 1, wrap: true)
        case .prevApp:
            advance(by: -1, wrap: true)
        case .nextWindow:
            advanceWindowsOnly(by: 1)
        case .prevWindow:
            advanceWindowsOnly(by: -1)
        case .nextRow:
            advanceVerticalOrLinear(by: 1)
        case .prevRow:
            advanceVerticalOrLinear(by: -1)
        case .spatialRight:
            advanceHorizontal(by: 1)
        case .spatialLeft:
            advanceHorizontal(by: -1)
        case .releaseCmd, .commit:
            commit()
        case .escape:
            cancel()
        case .closeWindow:
            performCloseAction()
        case .minimizeWindow:
            performOnVisibleTarget { Activator.minimizeWindow($0) }
        case .hideApp:
            performOnVisibleTarget { Activator.hideApp($0) }
        case .quitApp:
            performOnVisibleTarget { Activator.quitApp($0) }
        case .letterInput(let ch):
            handleLetter(ch)
        }
    }

    private func handleLetter(_ ch: Character) {
        guard phase == .visible, !rows.isEmpty, !labels.isEmpty else { return }

        let attempt = letterBuffer + String(ch)

        if let idx = labels.firstIndex(of: attempt) {
            let isPrefixOfLonger = labels.contains { $0 != attempt && $0.hasPrefix(attempt) }
            if isPrefixOfLonger {
                letterBuffer = attempt
                applyPrefixReorder()
                index = 0
                view.setSelectedIndex(index)
                scheduleLetterBufferReset()
                return
            }
            index = idx
            view.setSelectedIndex(idx)
            resetLetterBuffer()
            commit()
            return
        }

        if labels.contains(where: { $0.hasPrefix(attempt) }) {
            letterBuffer = attempt
            applyPrefixReorder()
            index = 0
            view.setSelectedIndex(index)
            scheduleLetterBufferReset()
            return
        }

        let single = String(ch)
        if let idx = labels.firstIndex(of: single) {
            let isPrefixOfLonger = labels.contains { $0 != single && $0.hasPrefix(single) }
            if isPrefixOfLonger {
                letterBuffer = single
                applyPrefixReorder()
                index = 0
                view.setSelectedIndex(index)
                scheduleLetterBufferReset()
                return
            }
            index = idx
            view.setSelectedIndex(idx)
            resetLetterBuffer()
            commit()
            return
        }
        if labels.contains(where: { $0.hasPrefix(single) }) {
            letterBuffer = single
            applyPrefixReorder()
            index = 0
            view.setSelectedIndex(index)
            scheduleLetterBufferReset()
            return
        }
        letterBuffer = ""
        applyPrefixReorder()
    }

    private func scheduleLetterBufferReset() {
        letterBufferTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.letterBuffer = ""
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        letterBufferTimer = timer
    }

    private func resetLetterBuffer() {
        let hadPrefix = !letterBuffer.isEmpty
        letterBuffer = ""
        letterBufferTimer?.invalidate()
        letterBufferTimer = nil
        if hadPrefix, phase == .visible {
            applyPrefixReorder()
        }
    }

    private func advanceWindowsOnly(by delta: Int) {
        switch phase {
        case .idle:
            mru.syncFrontmost()
            // Kick a cache refresh now so the snapshot has the full
            // ~revealDelay window to settle before reveal() reads it — keeps
            // windows created without an AX windowCreated event (or whose
            // bumpApp finished before AX registered them) from popping in
            // mid-presentation.
            cache.scheduleFullRefresh()
            let selfPid = getpid()
            guard let front = NSWorkspace.shared.frontmostApplication,
                  front.processIdentifier != selfPid else { return }
            // Promote the truly-current window of the front app to MRU[0]
            // before we freeze the snapshot. Catches manual clicks the user
            // made between Cmd+` chords that our own activations did not see.
            windowMRU.syncFrontWindow(pid: front.processIdentifier)
            windowsOnlyMode = true
            windowsOnlyPid = front.processIdentifier
            windowsOnlyPrimedDelta = delta
            primedApps = [front]
            primedIndex = 0
            schedulePrimedReveal()
        case .primed:
            windowsOnlyPrimedDelta += delta
        case .visible:
            advanceLinearVisible(by: delta, wrap: true)
        }
    }

    private func advance(by delta: Int, wrap: Bool) {
        switch phase {
        case .idle:
            mru.syncFrontmost()
            // Pre-warm the catalog before the ~100ms primed delay elapses so
            // reveal() reads an up-to-date cache instead of stale rows that
            // then visibly re-populate after the panel appears.
            cache.scheduleFullRefresh()
            primedApps = AppCatalog.fastAppList(orderedBy: mru.order)
            guard !primedApps.isEmpty else { return }
            if primedApps.count == 1 {
                primedIndex = 0
            } else if delta > 0 {
                primedIndex = 1
            } else {
                primedIndex = primedApps.count - 1
            }
            schedulePrimedReveal()
        case .primed:
            guard !primedApps.isEmpty else { return }
            if wrap {
                primedIndex = ((primedIndex + delta) % primedApps.count + primedApps.count) % primedApps.count
            } else {
                primedIndex = max(0, min(primedApps.count - 1, primedIndex + delta))
            }
        case .visible:
            advanceLinearVisible(by: delta, wrap: wrap)
        }
    }

    private func advanceLinearVisible(by delta: Int, wrap: Bool) {
        guard !rows.isEmpty else { return }
        if wrap {
            index = ((index + delta) % rows.count + rows.count) % rows.count
        } else {
            index = max(0, min(rows.count - 1, index + delta))
        }
        view.setSelectedIndex(index)
    }

    private func advanceColumn(by delta: Int) {
        guard !rows.isEmpty else { return }
        let rpc = max(1, view.rowsPerColumn)
        let candidate = index + delta * rpc
        index = max(0, min(rows.count - 1, candidate))
        view.setSelectedIndex(index)
    }

    /// In icon-dock mode with 2+ rows, Up/Down picks the tile in the
    /// neighboring row whose horizontal midpoint is closest to the current
    /// tile's, wrapping to the opposite-end row at the edges. In list mode it
    /// wraps within the current column (stays in same column). In single-row
    /// icon-dock it falls back to linear wrap.
    private func advanceVerticalOrLinear(by delta: Int) {
        if phase == .visible,
           currentMetrics.layoutMode == .gridView,
           view.rowsPerColumn > 1 {
            if let newIndex = view.neighboringRowIndex(from: index, direction: delta, wrap: true) {
                index = newIndex
                view.setSelectedIndex(index)
            }
            return
        }
        if phase == .visible, currentMetrics.layoutMode == .list {
            wrapWithinColumn(by: delta)
            return
        }
        advance(by: delta, wrap: true)
    }

    /// In multi-column list mode, Left/Right jumps a full column over and
    /// wraps between the first and last columns. In single-column list or
    /// icon-dock, it falls back to linear wrap.
    private func advanceHorizontal(by delta: Int) {
        if phase == .visible, currentMetrics.layoutMode == .list {
            if view.columnCount > 1 {
                wrapBetweenColumns(by: delta)
            } else {
                advanceLinearVisible(by: delta, wrap: true)
            }
            return
        }
        advance(by: delta, wrap: true)
    }

    /// Within the current list-mode column, advance by `delta` and wrap at the
    /// top/bottom of that column (respecting that the last column may have
    /// fewer items than rowsPerColumn).
    private func wrapWithinColumn(by delta: Int) {
        guard !rows.isEmpty else { return }
        let rpc = max(1, view.rowsPerColumn)
        let currentCol = index / rpc
        let currentRow = index % rpc
        let firstInCol = currentCol * rpc
        let lastInColExclusive = min(firstInCol + rpc, rows.count)
        let itemsInCol = max(1, lastInColExclusive - firstInCol)
        let newRow = ((currentRow + delta) % itemsInCol + itemsInCol) % itemsInCol
        index = firstInCol + newRow
        view.setSelectedIndex(index)
    }

    /// Move horizontally between list-mode columns with wrap. The row offset
    /// within the column is preserved (clamped if the target column is short).
    private func wrapBetweenColumns(by delta: Int) {
        guard !rows.isEmpty else { return }
        let rpc = max(1, view.rowsPerColumn)
        let cols = max(1, view.columnCount)
        let currentCol = index / rpc
        let currentRow = index % rpc
        let newCol = ((currentCol + delta) % cols + cols) % cols
        let firstInNewCol = newCol * rpc
        let lastInNewColExclusive = min(firstInNewCol + rpc, rows.count)
        let itemsInNewCol = max(1, lastInNewColExclusive - firstInNewCol)
        let newRow = min(currentRow, itemsInNewCol - 1)
        index = firstInNewCol + newRow
        view.setSelectedIndex(index)
    }

    private func schedulePrimedReveal() {
        phase = .primed
        revealTimer?.invalidate()
        let timer = Timer(timeInterval: revealDelay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reveal()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        revealTimer = timer
    }

    private func reveal() {
        guard phase == .primed else { return }
        mru.syncFrontmost()

        if windowsOnlyMode, let pid = windowsOnlyPid {
            revealWindowsOnly(pid: pid)
            return
        }

        revealGeneration &+= 1
        let gen = revealGeneration

        let snapshotApps = primedApps
        let targetIdx = primedIndex
        let targetPid = snapshotApps.indices.contains(targetIdx)
            ? snapshotApps[targetIdx].processIdentifier : nil

        let cachedRows = cache.rows(orderedBy: mru.order)
        let hadCachedRows = !cachedRows.isEmpty
        if hadCachedRows {
            rows = cachedRows
            labels = RowLabels.labels(for: rows)
            if let pid = targetPid, let match = rows.firstIndex(where: { $0.pid == pid }) {
                index = match
            } else {
                index = 0
            }
        } else {
            rows = snapshotApps.map { app in
                SwitcherRow(
                    app: app,
                    window: nil,
                    windowTitle: "",
                    isMinimized: false,
                    isPlaceholder: true
                )
            }
            labels = RowLabels.labels(for: rows)
            index = max(0, min(targetIdx, rows.count - 1))
        }
        guard !rows.isEmpty else { cancel(); return }

        currentMetrics = SwitcherMetrics.forScreen(SwitcherPanel.preferredScreen(), layoutMode: Preferences.shared.switcherLayoutMode)
        view.configure(rows: rows, labels: labels, selectedIndex: index, metrics: currentMetrics, highlightPrefix: letterBuffer)
        panel.present()
        phase = .visible
        cache.setPanelVisible(true)

        if hadCachedRows {
            // Cache already fresh — kick a background refresh through the cache
            // layer (single AX scan, not a duplicate) and re-apply when ready.
            cache.scheduleFullRefresh { [weak self] in
                guard let self, gen == self.revealGeneration else { return }
                let fresh = self.cache.rows(orderedBy: self.mru.order)
                self.applyFullSnapshot(fresh, anchorPid: targetPid)
            }
        } else {
            // No cache yet — must do an immediate AX scan to populate rows.
            let mruOrder = mru.order
            DispatchQueue.global(qos: .userInteractive).async { [weak self] in
                let fresh = AppCatalog.snapshot(orderedBy: mruOrder)
                DispatchQueue.main.async {
                    guard let self, gen == self.revealGeneration else { return }
                    self.applyFullSnapshot(fresh, anchorPid: targetPid)
                }
            }
        }
    }

    private func revealWindowsOnly(pid: pid_t) {
        revealGeneration &+= 1
        let gen = revealGeneration

        var filtered = cache.rows(orderedBy: mru.order).filter { $0.pid == pid }
        if filtered.isEmpty {
            filtered = AppCatalog.snapshot(orderedBy: mru.order).filter { $0.pid == pid }
        }
        let hasWindow = filtered.contains { $0.window != nil }
        if !hasWindow {
            cancel()
            return
        }
        filtered = windowMRU.sortRows(filtered, forPid: pid)
        rows = filtered
        labels = RowLabels.labels(for: rows)
        let count = rows.count
        let delta = windowsOnlyPrimedDelta
        index = count > 0 ? ((delta % count) + count) % count : 0

        currentMetrics = SwitcherMetrics.forScreen(SwitcherPanel.preferredScreen(), layoutMode: Preferences.shared.switcherLayoutMode)
        view.configure(rows: rows, labels: labels, selectedIndex: index, metrics: currentMetrics, highlightPrefix: letterBuffer)
        panel.present()
        phase = .visible
        cache.setPanelVisible(true)

        cache.scheduleFullRefresh { [weak self] in
            guard let self, gen == self.revealGeneration else { return }
            let fresh = self.cache.rows(orderedBy: self.mru.order).filter { $0.pid == pid }
            self.applyWindowsOnlySnapshot(fresh)
        }
    }

    private func applyWindowsOnlySnapshot(_ fresh: [SwitcherRow]) {
        guard phase == .visible, windowsOnlyMode else { return }
        if fresh.isEmpty { cancel(); return }
        let sorted = windowsOnlyPid.map { windowMRU.sortRows(fresh, forPid: $0) } ?? fresh
        rows = sorted
        labels = RowLabels.labels(for: rows)
        index = min(index, rows.count - 1)
        applyPrefixReorder()
    }

    private func applyFullSnapshot(_ fresh: [SwitcherRow], anchorPid: pid_t?) {
        guard phase == .visible else { return }
        if fresh.isEmpty { cancel(); return }

        // Preserve the user's current selection (by identity) so a Tab press
        // landing between reveal-from-cache and this background-refreshed apply
        // isn't reverted to the originally-primed app. Fall back to anchorPid
        // only if the current row can't be found in the fresh snapshot.
        let currentKey: (pid_t, String, Bool)? = rows.indices.contains(index)
            ? (rows[index].pid, rows[index].windowTitle, rows[index].window != nil)
            : nil

        rows = fresh
        labels = RowLabels.labels(for: rows)
        if let key = currentKey,
           let restored = rows.firstIndex(where: { $0.pid == key.0 && $0.windowTitle == key.1 && ($0.window != nil) == key.2 }) {
            index = restored
        } else if let pid = anchorPid, let match = rows.firstIndex(where: { $0.pid == pid }) {
            index = match
        } else {
            index = min(index, rows.count - 1)
        }
        applyPrefixReorder()
    }

    /// Select the window-switch target for a fast Cmd+` chord that commits
    /// while still in the primed phase (release of Cmd before the panel
    /// reveals). Mirrors the linear advance the visible phase would have
    /// produced: sort the front app's windows by MRU, then pick `delta`
    /// positions away from the current front window with wrap.
    private func pickWindowsOnlyTarget(pid: pid_t, delta: Int) -> SwitcherRow? {
        var candidates = cache.rows(orderedBy: mru.order).filter { $0.pid == pid && $0.window != nil }
        if candidates.isEmpty {
            candidates = AppCatalog.snapshot(orderedBy: mru.order).filter { $0.pid == pid && $0.window != nil }
        }
        guard !candidates.isEmpty else { return nil }
        candidates = windowMRU.sortRows(candidates, forPid: pid)
        let count = candidates.count
        let target = ((delta % count) + count) % count
        return candidates[target]
    }

    private func bumpWindowMRUIfPossible(for row: SwitcherRow) {
        guard let win = row.window else { return }
        let wid = PrivateAPI.cgWindowId(of: win)
        guard wid != 0 else { return }
        windowMRU.bump(pid: row.pid, wid: wid)
    }

    private func commit() {
        revealTimer?.invalidate()
        revealTimer = nil
        let currentPhase = phase
        var pendingActivation: (() -> Void)? = nil

        switch currentPhase {
        case .visible:
            if rows.indices.contains(index) {
                let row = rows[index]
                mru.bump(row.pid)
                bumpWindowMRUIfPossible(for: row)
                pendingActivation = { Activator.activate(row) }
            }
        case .primed:
            if windowsOnlyMode, let pid = windowsOnlyPid,
               let row = pickWindowsOnlyTarget(pid: pid, delta: windowsOnlyPrimedDelta) {
                mru.bump(row.pid)
                bumpWindowMRUIfPossible(for: row)
                pendingActivation = { Activator.activate(row) }
            } else if primedApps.indices.contains(primedIndex) {
                let app = primedApps[primedIndex]
                mru.bump(app.processIdentifier)
                pendingActivation = { Activator.activateApp(app) }
            }
        case .idle:
            break
        }

        revealGeneration &+= 1
        phase = .idle
        cache.setPanelVisible(false)
        panel.dismiss()
        primedApps = []
        rows = []
        windowsOnlyMode = false
        windowsOnlyPid = nil
        windowsOnlyPrimedDelta = 0
        closedTombstones.removeAll()
        resetLetterBuffer()
        pendingActivation?()
    }

    private func cancel() {
        revealTimer?.invalidate()
        revealTimer = nil
        revealGeneration &+= 1
        phase = .idle
        cache.setPanelVisible(false)
        panel.dismiss()
        primedApps = []
        rows = []
        windowsOnlyMode = false
        windowsOnlyPid = nil
        windowsOnlyPrimedDelta = 0
        closedTombstones.removeAll()
        resetLetterBuffer()
    }

    private func performOnVisibleTarget(_ action: (SwitcherRow) -> Void) {
        guard phase == .visible, rows.indices.contains(index) else { return }
        action(rows[index])
        scheduleVisibleRefresh(after: 0.25)
    }

    private func performCloseAction() {
        guard phase == .visible, rows.indices.contains(index) else { return }
        let row = rows[index]

        if row.isFullscreen {
            Activator.closeWindow(row)
            cancel()
            return
        }

        recordClosedTombstone(for: row)
        Activator.closeWindow(row)

        let closedApp = row.app
        let closedPid = row.pid
        rows.remove(at: index)

        // If this was the only window for a regular app, demote the app to a
        // windowless row at the end of the list right now. Otherwise the app
        // visibly vanishes for ~250ms (until the cache refresh + tombstone
        // filter substitute one) — closing the window shouldn't make the app
        // flicker out of the switcher.
        if closedApp.activationPolicy == .regular,
           !rows.contains(where: { $0.pid == closedPid }) {
            rows.append(SwitcherRow(
                app: closedApp,
                window: nil,
                windowTitle: "",
                isMinimized: false
            ))
        }

        if rows.isEmpty {
            cancel()
            return
        }
        labels = RowLabels.labels(for: rows)
        index = min(index, rows.count - 1)
        applyPrefixReorder()

        scheduleVisibleRefresh(after: 0.25)
    }

    /// Refresh visible rows from the AX cache after a window action. The
    /// `delay` parameter is critical: actions like close / minimize / hide
    /// dispatch async AX requests that take ~100–200ms to propagate. Without
    /// the delay the snapshot fires before the target app updates and reports
    /// the still-present window, re-adding the row that was just locally
    /// removed. Generation token prevents stale apply if the panel was
    /// dismissed in the meantime.
    private func scheduleVisibleRefresh(after delay: TimeInterval = 0) {
        let gen = revealGeneration
        let apply = { [weak self] in
            guard let self, gen == self.revealGeneration, self.phase == .visible else { return }
            self.cache.scheduleFullRefresh { [weak self] in
                guard let self, gen == self.revealGeneration, self.phase == .visible else { return }
                let fresh = self.filterClosedTombstones(self.cache.rows(orderedBy: self.mru.order))
                if fresh.isEmpty {
                    self.cancel()
                    return
                }
                // Preserve selection by row identity (pid + title + hasWindow).
                // Plain index clamping silently shifts the highlight onto a
                // different window when the fresh snapshot reorders rows (MRU
                // bump after close changing focus is the common trigger), which
                // makes the next close action hit the wrong window.
                let currentKey: (pid_t, String, Bool)? = self.rows.indices.contains(self.index)
                    ? (self.rows[self.index].pid, self.rows[self.index].windowTitle, self.rows[self.index].window != nil)
                    : nil
                self.rows = fresh
                self.labels = RowLabels.labels(for: fresh)
                if let key = currentKey,
                   let restored = fresh.firstIndex(where: { $0.pid == key.0 && $0.windowTitle == key.1 && ($0.window != nil) == key.2 }) {
                    self.index = restored
                } else {
                    self.index = min(self.index, fresh.count - 1)
                }
                self.applyPrefixReorder()
            }
        }
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: apply)
        } else {
            apply()
        }
    }

    private func recordClosedTombstone(for row: SwitcherRow) {
        let wid = row.window.map { PrivateAPI.cgWindowId(of: $0) } ?? 0
        // Record even when wid == 0 — title fallback still catches it.
        closedTombstones.append(ClosedWindowSignature(
            pid: row.pid,
            cgWindowId: wid,
            title: row.windowTitle,
            recordedAt: Date()
        ))
    }

    /// Drops rows whose `(pid, CGWindowID)` — or `(pid, title)` when the AX
    /// id is unavailable — was just locally closed but whose AX destruction
    /// hasn't propagated yet. Tombstones self-clear when the cache no longer
    /// reports the window (cache caught up), or after `tombstoneTTL` for
    /// closes that silently fail.
    private func filterClosedTombstones(_ snapshot: [SwitcherRow]) -> [SwitcherRow] {
        if closedTombstones.isEmpty { return snapshot }
        let now = Date()
        closedTombstones.removeAll { now.timeIntervalSince($0.recordedAt) >= tombstoneTTL }
        if closedTombstones.isEmpty { return snapshot }

        func signatureMatches(_ sig: ClosedWindowSignature, row: SwitcherRow, rowWid: CGWindowID) -> Bool {
            guard sig.pid == row.pid else { return false }
            if sig.cgWindowId != 0 && rowWid != 0 {
                return sig.cgWindowId == rowWid
            }
            // CGWindowID unavailable on either side — fall back to title.
            // Skip empty titles to avoid hiding sibling untitled windows.
            guard !sig.title.isEmpty else { return false }
            return sig.title == row.windowTitle
        }

        var result: [SwitcherRow] = []
        result.reserveCapacity(snapshot.count)
        var matchedSigIndices = Set<Int>()
        var keptPids = Set<pid_t>()
        // Track each pid whose every row got tombstoned. If a regular app ends
        // up fully hidden (close-last-window race: cache still lists the dying
        // AX window because the destroy hasn't propagated), substitute a
        // windowless row appended at the end — matches the windowless-apps-go-
        // last sort order applied elsewhere and avoids the row jumping
        // mid-list once the cache catches up. `discovery` keeps multiple
        // substitutions in original snapshot order.
        var firstHiddenByPid: [pid_t: (app: NSRunningApplication, discovery: Int)] = [:]
        var discoveryCounter = 0
        for row in snapshot {
            let rowWid = row.window.map { PrivateAPI.cgWindowId(of: $0) } ?? 0
            var hidden = false
            for (i, sig) in closedTombstones.enumerated() {
                if signatureMatches(sig, row: row, rowWid: rowWid) {
                    matchedSigIndices.insert(i)
                    hidden = true
                    break
                }
            }
            if !hidden {
                result.append(row)
                keptPids.insert(row.pid)
            } else if firstHiddenByPid[row.pid] == nil {
                firstHiddenByPid[row.pid] = (app: row.app, discovery: discoveryCounter)
                discoveryCounter += 1
            }
        }
        let placeholders = firstHiddenByPid
            .filter { !keptPids.contains($0.key) && $0.value.app.activationPolicy == .regular }
            .map { $0.value }
            .sorted { $0.discovery < $1.discovery }
        for placeholder in placeholders {
            result.append(SwitcherRow(
                app: placeholder.app,
                window: nil,
                windowTitle: "",
                isMinimized: false
            ))
        }
        // Drop tombstones whose windows the cache no longer reports — the
        // close has fully propagated, so no further protection needed.
        closedTombstones = closedTombstones.enumerated()
            .compactMap { matchedSigIndices.contains($0.offset) ? $0.element : nil }
        return result
    }

    private func applyPrefixReorder() {
        guard phase == .visible else { return }
        let prefix = letterBuffer
        if prefix.isEmpty {
            view.configure(rows: rows, labels: labels, selectedIndex: index, metrics: currentMetrics, highlightPrefix: "")
            panel.present()
            return
        }

        let n = rows.count
        let selectedKey: (pid_t, String, Bool)? = rows.indices.contains(index)
            ? (rows[index].pid, rows[index].windowTitle, rows[index].window != nil)
            : nil

        // Single pass: collect match indices, then non-match indices. One array.
        var orderIdx: [Int] = []
        orderIdx.reserveCapacity(n)
        var matchCount = 0
        for i in 0..<n {
            if labels[i].hasPrefix(prefix) {
                orderIdx.append(i)
                matchCount += 1
            }
        }
        for i in 0..<n where !labels[i].hasPrefix(prefix) {
            orderIdx.append(i)
        }

        var newRows: [SwitcherRow] = []
        newRows.reserveCapacity(n)
        var newLabels: [String] = []
        newLabels.reserveCapacity(n)
        for i in orderIdx {
            newRows.append(rows[i])
            newLabels.append(labels[i])
        }
        rows = newRows
        labels = newLabels

        if let key = selectedKey, let restored = rows.firstIndex(where: { $0.pid == key.0 && $0.windowTitle == key.1 && ($0.window != nil) == key.2 }) {
            index = restored
        } else if matchCount > 0 {
            index = 0
        } else {
            index = min(index, rows.count - 1)
        }
        view.configure(rows: rows, labels: labels, selectedIndex: index, metrics: currentMetrics, highlightPrefix: prefix)
        panel.present()
    }
}
