import AppKit

@MainActor
final class SwitcherController: SwitcherViewDelegate {
    enum Phase {
        case idle
        case primed
        case visible
    }

    private let hotkey = HotkeyTap()
    private let mru = MRUTracker()
    private let cache = AppCatalogCache()
    private let panel = SwitcherPanel()
    private let view: SwitcherView

    private var phase: Phase = .idle
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

    let revealDelay: TimeInterval = 0.100

    init() {
        view = SwitcherView(frame: .zero)
        panel.contentView = view
        view.delegate = self
    }

    func start() {
        mru.start()
        cache.start(mru: mru)
        let installed = hotkey.install()
        if !installed {
            NSLog("[BetterCmdTab] CGEventTap installation failed — Accessibility not trusted?")
            return
        }
        hotkey.onEvent = { [weak self] event in
            guard let self else { return }
            self.handle(event)
        }
        hotkey.isSwitching = { [weak self] in
            guard let self else { return false }
            return self.phase != .idle
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.prewarmPanel()
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

    func switcherViewDidStep(dx: Int, dy: Int) {
        guard phase == .visible, !rows.isEmpty else { return }
        if dy != 0 { advanceLinearVisible(by: dy, wrap: false) }
        if dx != 0 { advanceColumn(by: dx) }
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
            advance(by: 1, wrap: false)
        case .prevRow:
            advance(by: -1, wrap: false)
        case .releaseCmd, .commit:
            commit()
        case .escape:
            cancel()
        case .closeWindow:
            performOnVisibleTarget { Activator.closeWindow($0) }
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
            let selfPid = getpid()
            guard let front = NSWorkspace.shared.frontmostApplication,
                  front.processIdentifier != selfPid else { return }
            windowsOnlyMode = true
            windowsOnlyPid = front.processIdentifier
            windowsOnlyPrimedDelta = delta
            primedApps = [front]
            primedIndex = 0
            NSLog("[BetterCmdTab] advanceWindowsOnly idle: front=\(front.localizedName ?? "?")[\(front.processIdentifier)] delta=\(delta)")
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
            primedApps = AppCatalog.fastAppList(orderedBy: mru.order)
            guard !primedApps.isEmpty else { return }
            if primedApps.count == 1 {
                primedIndex = 0
            } else if delta > 0 {
                primedIndex = 1
            } else {
                primedIndex = primedApps.count - 1
            }
            let preview = primedApps.prefix(4).map { "\($0.localizedName ?? "?")[\($0.processIdentifier)]" }.joined(separator: " | ")
            NSLog("[BetterCmdTab] advance idle: delta=\(delta), primedIdx=\(primedIndex), apps=\(preview)")
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

        let snapshotApps = primedApps
        let targetIdx = primedIndex
        let targetPid = snapshotApps.indices.contains(targetIdx)
            ? snapshotApps[targetIdx].processIdentifier : nil

        let cachedRows = cache.rows(orderedBy: mru.order)
        if !cachedRows.isEmpty {
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

        currentMetrics = SwitcherMetrics.forScreen(SwitcherPanel.preferredScreen())
        view.configure(rows: rows, labels: labels, selectedIndex: index, metrics: currentMetrics, highlightPrefix: letterBuffer)
        panel.present()
        phase = .visible

        let mruOrder = mru.order
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            let fresh = AppCatalog.snapshot(orderedBy: mruOrder)
            DispatchQueue.main.async {
                self?.applyFullSnapshot(fresh, anchorPid: targetPid)
            }
        }
    }

    private func revealWindowsOnly(pid: pid_t) {
        var filtered = cache.rows(orderedBy: mru.order).filter { $0.pid == pid }
        if filtered.isEmpty {
            filtered = AppCatalog.snapshot(orderedBy: mru.order).filter { $0.pid == pid }
        }
        let hasWindow = filtered.contains { $0.window != nil }
        if !hasWindow {
            cancel()
            return
        }
        rows = filtered
        labels = RowLabels.labels(for: rows)
        let count = rows.count
        let delta = windowsOnlyPrimedDelta
        index = count > 0 ? ((delta % count) + count) % count : 0

        currentMetrics = SwitcherMetrics.forScreen(SwitcherPanel.preferredScreen())
        view.configure(rows: rows, labels: labels, selectedIndex: index, metrics: currentMetrics, highlightPrefix: letterBuffer)
        panel.present()
        phase = .visible

        let mruOrder = mru.order
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            let fresh = AppCatalog.snapshot(orderedBy: mruOrder).filter { $0.pid == pid }
            DispatchQueue.main.async {
                self?.applyWindowsOnlySnapshot(fresh)
            }
        }
    }

    private func applyWindowsOnlySnapshot(_ fresh: [SwitcherRow]) {
        guard phase == .visible, windowsOnlyMode else { return }
        if fresh.isEmpty { cancel(); return }
        rows = fresh
        labels = RowLabels.labels(for: rows)
        index = min(index, rows.count - 1)
        applyPrefixReorder()
    }

    private func applyFullSnapshot(_ fresh: [SwitcherRow], anchorPid: pid_t?) {
        guard phase == .visible else { return }
        if fresh.isEmpty { cancel(); return }
        rows = fresh
        labels = RowLabels.labels(for: rows)
        if let pid = anchorPid, let match = rows.firstIndex(where: { $0.pid == pid }) {
            index = match
        } else {
            index = min(index, rows.count - 1)
        }
        applyPrefixReorder()
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
                NSLog("[BetterCmdTab] commit visible: row=\(row.appName)[\(row.pid)] title=\(row.windowTitle)")
                pendingActivation = { Activator.activate(row) }
            }
        case .primed:
            if primedApps.indices.contains(primedIndex) {
                let app = primedApps[primedIndex]
                NSLog("[BetterCmdTab] commit primed: app=\(app.localizedName ?? "?")[\(app.processIdentifier)] idx=\(primedIndex)")
                pendingActivation = { Activator.activateApp(app) }
            }
        case .idle:
            break
        }

        phase = .idle
        panel.dismiss()
        primedApps = []
        rows = []
        windowsOnlyMode = false
        windowsOnlyPid = nil
        windowsOnlyPrimedDelta = 0
        resetLetterBuffer()
        pendingActivation?()
    }

    private func cancel() {
        revealTimer?.invalidate()
        revealTimer = nil
        phase = .idle
        panel.dismiss()
        primedApps = []
        rows = []
        windowsOnlyMode = false
        windowsOnlyPid = nil
        windowsOnlyPrimedDelta = 0
        resetLetterBuffer()
    }

    private func performOnVisibleTarget(_ action: (SwitcherRow) -> Void) {
        guard phase == .visible, rows.indices.contains(index) else { return }
        action(rows[index])
        let snapshot = rowFingerprint(rows)
        scheduleRefresh(previous: snapshot, retriesLeft: 6)
    }

    private struct RowFingerprint: Equatable {
        let entries: [Entry]
        struct Entry: Equatable {
            let pid: pid_t
            let title: String
            let hasWindow: Bool
            let isMinimized: Bool
            let isHidden: Bool
        }
    }

    private func rowFingerprint(_ rows: [SwitcherRow]) -> RowFingerprint {
        RowFingerprint(entries: rows.map {
            .init(
                pid: $0.pid,
                title: $0.windowTitle,
                hasWindow: $0.window != nil,
                isMinimized: $0.isMinimized,
                isHidden: $0.app.isHidden
            )
        })
    }

    private func scheduleRefresh(previous: RowFingerprint, retriesLeft: Int) {
        let delay: TimeInterval = retriesLeft >= 4 ? 0.08 : 0.12
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.refreshRows(previous: previous, retriesLeft: retriesLeft)
        }
    }

    private func refreshRows(previous: RowFingerprint, retriesLeft: Int) {
        guard phase == .visible else { return }
        let fresh = AppCatalog.snapshot(orderedBy: mru.order)
        let freshFingerprint = rowFingerprint(fresh)

        if freshFingerprint == previous && retriesLeft > 0 {
            scheduleRefresh(previous: previous, retriesLeft: retriesLeft - 1)
            return
        }

        if fresh.isEmpty {
            cancel()
            return
        }
        rows = fresh
        labels = RowLabels.labels(for: rows)
        index = min(index, rows.count - 1)
        applyPrefixReorder()
    }

    private func applyPrefixReorder() {
        guard phase == .visible else { return }
        let prefix = letterBuffer
        if prefix.isEmpty {
            view.configure(rows: rows, labels: labels, selectedIndex: index, metrics: currentMetrics, highlightPrefix: "")
            panel.present()
            return
        }

        let selectedKey = rows.indices.contains(index) ? (rows[index].pid, rows[index].windowTitle, rows[index].window != nil) : nil

        var matchingRows: [SwitcherRow] = []
        var matchingLabels: [String] = []
        var otherRows: [SwitcherRow] = []
        var otherLabels: [String] = []
        for i in 0..<rows.count {
            if labels[i].hasPrefix(prefix) {
                matchingRows.append(rows[i])
                matchingLabels.append(labels[i])
            } else {
                otherRows.append(rows[i])
                otherLabels.append(labels[i])
            }
        }
        rows = matchingRows + otherRows
        labels = matchingLabels + otherLabels

        if let key = selectedKey, let restored = rows.firstIndex(where: { $0.pid == key.0 && $0.windowTitle == key.1 && ($0.window != nil) == key.2 }) {
            index = restored
        } else if !matchingRows.isEmpty {
            index = 0
        } else {
            index = min(index, rows.count - 1)
        }
        view.configure(rows: rows, labels: labels, selectedIndex: index, metrics: currentMetrics, highlightPrefix: prefix)
        panel.present()
    }
}
