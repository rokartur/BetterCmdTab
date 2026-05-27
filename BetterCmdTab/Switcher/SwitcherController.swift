import AppKit
import BetterShortcuts
import Combine
import os

@MainActor
final class SwitcherController: SwitcherViewDelegate {
    enum Phase {
        case idle
        case primed
        case visible
    }

    private let hotkey = HotkeyTap()
    private let swipeTrigger = SwipeTrigger()
    private let spaceSwipeSuppressor = SpaceSwipeSuppressor()
    private let mru = MRUTracker()
    private let windowMRU = WindowMRUTracker()
    private let cache = AppCatalogCache()
    private let panel = SwitcherPanel()
    private let view: SwitcherView

    private var _phase: Phase = .idle
    private var primedApps: [NSRunningApplication] = []
    private var primedIndex: Int = 0
    /// Canonical catalog set for the current reveal. `rows`/`labels` are the
    /// *displayed* derivation (fuzzy-filtered or letter-prefix-reordered);
    /// `baseRows`/`baseLabels` are the unfiltered source so the search query
    /// can widen again on backspace. Kept in sync by every refresh path.
    private var baseRows: [SwitcherRow] = [] {
        didSet { baseFoldedValid = false }
    }
    private var baseLabels: [String] = []
    /// Diacritic-folded (app name, window title) per `baseRows` entry, rebuilt
    /// lazily when `baseRows` changes so fuzzy search folds each row once per
    /// row-set change rather than re-folding every row on every keystroke.
    private var baseFolded: [(app: String, title: String)] = []
    private var baseFoldedValid = false
    private var rows: [SwitcherRow] = []
    private var labels: [String] = []
    /// Hint letters to render on tiles — empty when the user disabled letter
    /// hints, so no per-window letter is drawn. The internal `labels` array is
    /// kept populated for search reordering regardless.
    private var displayLabels: [String] { Preferences.shared.letterHintsEnabled ? labels : [] }
    private var index: Int = 0
    private var revealTimer: Timer?
    private var currentMetrics: SwitcherMetrics = .baseline
    private var letterBuffer: String = ""
    private var letterBufferTimer: Timer?
    /// Fuzzy-search mode (entered with `/`). While active, typed characters
    /// build `searchQuery` and the displayed rows are filtered by fuzzy match
    /// on app name + window title.
    private var searchActive: Bool = false
    private var searchQuery: String = ""
    /// Set once the switcher has detached from the held modifier in
    /// `.stayOpen` search mode: from then on, releasing ⌘ (or any other
    /// modifier) no longer commits — only Return or a mouse click does.
    private var stickyOpen: Bool = false
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

    private var cancellables = Set<AnyCancellable>()

    /// Tap-vs-hold threshold, user-tunable. Read live so a settings change takes
    /// effect on the next chord without restart.
    var revealDelay: TimeInterval { Double(Preferences.shared.revealDelayMs) / 1000.0 }

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
        // Prune the visible panel the moment an app actually terminates. The
        // post-action refresh is a fixed 250ms guess that misses apps which
        // quit slowly (confirmation dialog, slow teardown) — their row lingered
        // until the next reveal. This removes it exactly when the app is gone.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            Task { @MainActor [weak self] in
                guard let self, let pid else { return }
                self.handleAppTerminated(pid: pid)
            }
        }
        // Re-render the visible panel when an app hides or unhides. An app that
        // hides itself when its last window closes (Electron apps) would
        // otherwise keep showing the just-closed "no window" state until the
        // next reveal — `SwitcherRow.isHidden` is read live, so re-rendering the
        // current rows is enough to flip the status glyph the instant it hides.
        for name in [NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] note in
                let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
                Task { @MainActor [weak self] in
                    guard let self, let pid else { return }
                    self.handleAppHiddenChanged(pid: pid)
                }
            }
        }
    }

    private func handleAppHiddenChanged(pid: pid_t) {
        guard phase == .visible, baseRows.contains(where: { $0.pid == pid }) else { return }
        // No re-sort needed: windowless and hidden share a status bucket (see
        // `statusPriority`), so the row keeps its place — only the live glyph
        // changes. `refreshDisplay` re-renders from the current `baseRows`.
        refreshDisplay()
    }

    private func handleAppTerminated(pid: pid_t) {
        guard phase == .visible, baseRows.contains(where: { $0.pid == pid }) else { return }
        baseRows.removeAll { $0.pid == pid }
        if baseRows.isEmpty {
            cancel()
            return
        }
        baseLabels = RowLabels.labels(for: baseRows)
        refreshDisplay()
    }

    private func handleScreenParametersChange() {
        // `baseRows`, not `rows`: in fuzzy-search mode an empty filtered result
        // is still a visible panel that must track screen changes.
        guard phase == .visible, !baseRows.isEmpty else { return }
        currentMetrics = SwitcherMetrics.forScreen(SwitcherPanel.preferredScreen(), layoutMode: Preferences.shared.switcherLayoutMode, userScale: Preferences.shared.panelSize.scale, letterHints: Preferences.shared.letterHintsEnabled)
        refreshDisplay()
    }

    func start() {
        mru.start()
        windowMRU.start()
        cache.start(mru: mru)
        RecentlyClosedStore.shared.start()
        let installed = hotkey.install()
        if !installed {
            Log.switcher.error("CGEventTap installation failed — Accessibility not trusted?")
            return
        }
        hotkey.onEvent = { [weak self] event in
            guard let self else { return }
            self.handle(event)
        }
        // While recording, the tap consumes the chord and hands it back here as a
        // CGEvent. Re-post it as an NSEvent so the active RecorderCocoa (which
        // listens via an in-app monitor) captures it — system-reserved combos
        // like ⌘Tab never reach that monitor on their own.
        hotkey.onRecordingKeyDown = { cgEvent in
            guard let nsEvent = NSEvent(cgEvent: cgEvent) else { return }
            NSApp.postEvent(nsEvent, atStart: true)
        }
        pushHotkeyConfig()
        // The BetterShortcuts recorders persist the user's trigger choices and
        // post this notification on change — re-derive the tap config live.
        NotificationCenter.default.publisher(
            for: Notification.Name("BetterShortcuts_shortcutByNameDidChange")
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in self?.pushHotkeyConfig() }
        .store(in: &cancellables)
        // Put the tap into recording mode while a recorder is capturing so the
        // chord is forwarded to the recorder instead of triggering the switcher.
        NotificationCenter.default.publisher(
            for: Notification.Name("BetterShortcuts_recorderActiveStatusDidChange")
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] note in
            let active = (note.userInfo?["isActive"] as? Bool) ?? false
            self?.hotkey.setRecording(active)
        }
        .store(in: &cancellables)
        // Experimental swipe trigger: wire the callback and enable/disable it
        // live from the preference.
        swipeTrigger.onSwipe = { [weak self] delta in
            self?.triggerFromGesture(delta: delta)
        }
        swipeTrigger.onCommit = { [weak self] in
            self?.commitFromGesture()
        }
        swipeTrigger.setReverseDirection(Preferences.shared.swipeReverseDirection)
        swipeTrigger.setCommitOnRelease(Preferences.shared.swipeCommitOnRelease)
        swipeTrigger.setSensitivity(Preferences.shared.swipeSensitivity)
        swipeTrigger.setOneShot(Preferences.shared.swipeMode == .switchSpaces)
        swipeTrigger.setEnabled(Preferences.shared.experimentalSwipeTrigger)
        // The swipe takes over three-finger horizontal Spaces navigation, so
        // suppress the system Space-swipe whenever the swipe is enabled.
        spaceSwipeSuppressor.setEnabled(Preferences.shared.experimentalSwipeTrigger)
        Preferences.shared.$experimentalSwipeTrigger
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                self?.swipeTrigger.setEnabled(enabled)
                self?.spaceSwipeSuppressor.setEnabled(enabled)
            }
            .store(in: &cancellables)
        Preferences.shared.$swipeReverseDirection
            .receive(on: DispatchQueue.main)
            .sink { [weak self] reverse in self?.swipeTrigger.setReverseDirection(reverse) }
            .store(in: &cancellables)
        Preferences.shared.$swipeCommitOnRelease
            .receive(on: DispatchQueue.main)
            .sink { [weak self] commit in self?.swipeTrigger.setCommitOnRelease(commit) }
            .store(in: &cancellables)
        Preferences.shared.$swipeSensitivity
            .receive(on: DispatchQueue.main)
            .sink { [weak self] level in self?.swipeTrigger.setSensitivity(level) }
            .store(in: &cancellables)
        Preferences.shared.$swipeMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mode in self?.swipeTrigger.setOneShot(mode == .switchSpaces) }
            .store(in: &cancellables)

        // Mouse scroll-to-switch: stepped by the hotkey tap (it sees scroll
        // events and can consume them); wire enable + direction live.
        hotkey.setScrollEnabled(Preferences.shared.scrollToSwitch)
        hotkey.setScrollReverse(Preferences.shared.scrollReverseDirection)
        Preferences.shared.$scrollToSwitch
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in self?.hotkey.setScrollEnabled(enabled) }
            .store(in: &cancellables)
        Preferences.shared.$scrollReverseDirection
            .receive(on: DispatchQueue.main)
            .sink { [weak self] reverse in self?.hotkey.setScrollReverse(reverse) }
            .store(in: &cancellables)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.prewarmPanel()
        }
    }

    /// Experimental: open or advance the switcher from a trackpad swipe — no
    /// held modifier. The panel is opened in sticky mode (`stickyOpen`), so a
    /// stray modifier release won't commit; the user commits with Return or a
    /// click, or dismisses with Esc, exactly like stay-open search.
    private func triggerFromGesture(delta: Int) {
        // In "switch Spaces" mode the swipe never opens the switcher — each step
        // jumps to the adjacent Space instead.
        if Preferences.shared.swipeMode == .switchSpaces {
            PrivateAPI.switchSpaceWrapping(rightward: delta > 0)
            return
        }
        switch phase {
        case .visible:
            advanceLinearVisible(by: delta, wrap: true)
        case .primed:
            advance(by: delta, wrap: true)
        case .idle:
            mru.syncFrontmost()
            cache.scheduleFullRefresh()
            primedApps = AppCatalog.fastAppList(orderedBy: mru.order)
            guard !primedApps.isEmpty else { return }
            primedIndex = primedApps.count == 1 ? 0 : (delta > 0 ? 1 : primedApps.count - 1)
            phase = .primed
            reveal()
            // After reveal lands the panel in `.visible`, detach from any
            // modifier so releasing one never commits a gesture-opened switcher.
            stickyOpen = true
        }
    }

    /// Lifting all fingers off the trackpad commits the gesture-opened switcher
    /// when "commit on release" is enabled. No-op when nothing is showing.
    private func commitFromGesture() {
        guard phase != .idle else { return }
        commit()
    }

    private func pushHotkeyConfig() {
        let app = Self.hotkeyTrigger(for: .switchApps, defaultKey: 48)
        let window = Self.hotkeyTrigger(for: .switchWindows, defaultKey: 50)
        hotkey.updateConfig(HotkeyTap.Config(
            appModifier: app.modifier,
            appKey: app.key,
            windowModifier: window.modifier,
            windowKey: window.key
        ))
    }

    /// Decompose a recorded shortcut into a held modifier mask + tap keycode for
    /// the CGEvent tap. Falls back to Command + `defaultKey` when unset. Shift is
    /// dropped (reserved for reverse stepping); a hold modifier is guaranteed
    /// because the recorder rejects shortcuts without one.
    private static func hotkeyTrigger(
        for name: BetterShortcuts.Name,
        defaultKey: Int64
    ) -> (modifier: CGEventFlags, key: Int64) {
        guard let shortcut = BetterShortcuts.getShortcut(for: name) else {
            return (.maskCommand, defaultKey)
        }
        var flags: CGEventFlags = []
        let modifiers = shortcut.modifiers
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if flags.isEmpty { flags = .maskCommand }
        return (flags, Int64(shortcut.carbonKeyCode))
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

    /// A hover action button on a specific row was clicked. Point the current
    /// index at that row, then run the same path as the keyboard W/M/H/Q actions
    /// (plus zoom, which has no keyboard binding).
    func switcherViewDidInvokeAction(_ action: RowAction, atIndex index: Int) {
        guard phase == .visible, rows.indices.contains(index) else { return }
        self.index = index
        view.setSelectedIndex(index)
        // The user is now interacting with the mouse: detach from the held
        // modifier so releasing ⌘ no longer commits (which would switch to the
        // app instead of running the clicked action). Commit stays available via
        // a tile click, Return, or Esc to dismiss.
        stickyOpen = true
        switch action {
        case .close:
            performCloseAction()
        case .minimize:
            performOnVisibleTarget { Activator.minimizeWindow($0) }
        case .maximize:
            performOnVisibleTarget { Activator.zoomWindow($0) }
        case .hide:
            performOnVisibleTarget { Activator.hideApp($0) }
        case .quit:
            performQuitAction()
        }
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
        case .moveWindowLeft:
            performMove(.left)
        case .moveWindowRight:
            performMove(.right)
        case .moveWindowUp:
            performMove(.up)
        case .moveWindowDown:
            performMove(.down)
        case .releaseCmd:
            handleModifierRelease()
        case .commit:
            commit()
        case .escape:
            if searchActive { exitSearch() } else { cancel() }
        case .toggleSearch:
            toggleSearch()
        case .searchInput(let ch):
            handleSearchInput(ch)
        case .searchBackspace:
            handleSearchBackspace()
        case .closeWindow:
            performCloseAction()
        case .minimizeWindow:
            performOnVisibleTarget { Activator.minimizeWindow($0) }
        case .hideApp:
            performOnVisibleTarget { Activator.hideApp($0) }
        case .quitApp:
            performQuitAction()
        case .letterInput(let ch):
            handleLetter(ch)
        }
    }

    private func handleLetter(_ ch: Character) {
        guard Preferences.shared.letterHintsEnabled else { return }
        guard phase == .visible, !rows.isEmpty, !labels.isEmpty else { return }

        let attempt = letterBuffer + String(ch)

        if let idx = labels.firstIndex(of: attempt) {
            let isPrefixOfLonger = labels.contains { $0 != attempt && $0.hasPrefix(attempt) }
            if isPrefixOfLonger {
                letterBuffer = attempt
                refreshDisplay(resetSelectionToTop: true)
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
            refreshDisplay(resetSelectionToTop: true)
            scheduleLetterBufferReset()
            return
        }

        let single = String(ch)
        if let idx = labels.firstIndex(of: single) {
            let isPrefixOfLonger = labels.contains { $0 != single && $0.hasPrefix(single) }
            if isPrefixOfLonger {
                letterBuffer = single
                refreshDisplay(resetSelectionToTop: true)
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
            refreshDisplay(resetSelectionToTop: true)
            scheduleLetterBufferReset()
            return
        }
        letterBuffer = ""
        refreshDisplay()
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
            refreshDisplay()
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
           currentMetrics.layoutMode.isGridLike,
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
        refreshAuxiliaryIndicators()

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
            baseRows = cachedRows
            baseLabels = RowLabels.labels(for: baseRows)
            rows = baseRows
            labels = baseLabels
            if let pid = targetPid, let match = rows.firstIndex(where: { $0.pid == pid }) {
                index = match
            } else {
                index = 0
            }
        } else {
            baseRows = snapshotApps.map { app in
                SwitcherRow(
                    app: app,
                    window: nil,
                    windowTitle: "",
                    isMinimized: false,
                    isPlaceholder: true
                )
            }
            baseLabels = RowLabels.labels(for: baseRows)
            rows = baseRows
            labels = baseLabels
            index = max(0, min(targetIdx, rows.count - 1))
        }
        guard !rows.isEmpty else { cancel(); return }

        currentMetrics = SwitcherMetrics.forScreen(SwitcherPanel.preferredScreen(), layoutMode: Preferences.shared.switcherLayoutMode, userScale: Preferences.shared.panelSize.scale, letterHints: Preferences.shared.letterHintsEnabled)
        view.configure(rows: rows, labels: displayLabels, selectedIndex: index, metrics: currentMetrics, highlightPrefix: letterBuffer)
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

    /// Audio-playing pids (CoreAudio) and Dock unread badges (the Dock's AX
    /// tree) both come from synchronous system queries that don't belong on the
    /// reveal critical path. Run them on a background queue and repaint the
    /// indicators when they land: the panel shows instantly with the previous
    /// snapshot (or no indicators on a cold first reveal) and patches the rest
    /// in within a few ms.
    private func refreshAuxiliaryIndicators() {
        let wantsBadges = Preferences.shared.showUnreadBadges
        if !wantsBadges { DockBadgeReader.shared.clear() }
        let scanBadges = wantsBadges && DockBadgeReader.shared.shouldRefresh()
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            let pids = AudioActivityMonitor.snapshot()
            let badges = scanBadges ? DockBadgeReader.snapshot() : nil
            DispatchQueue.main.async {
                AudioActivityMonitor.shared.apply(pids)
                if let badges { DockBadgeReader.shared.apply(badges) }
                guard let self, self.phase == .visible else { return }
                self.refreshDisplay()
            }
        }
    }

    private func revealWindowsOnly(pid: pid_t) {
        revealGeneration &+= 1
        let gen = revealGeneration

        let cached = cache.rows(orderedBy: mru.order).filter { $0.pid == pid }
        if !cached.isEmpty {
            guard cached.contains(where: { $0.window != nil }) else { cancel(); return }
            presentWindowsOnly(cached, pid: pid)
            scheduleWindowsOnlyRefresh(pid: pid, gen: gen)
        } else {
            // Cold cache — the full AX scan is expensive, so run it off the main
            // thread and present (or cancel) when it returns instead of stalling
            // the reveal. A fast chord that releases ⌘ before this lands commits
            // through `pickWindowsOnlyTarget` (primed phase); the generation
            // guard drops this stale apply.
            let mruOrder = mru.order
            DispatchQueue.global(qos: .userInteractive).async { [weak self] in
                let fresh = AppCatalog.snapshot(orderedBy: mruOrder).filter { $0.pid == pid }
                DispatchQueue.main.async {
                    guard let self, gen == self.revealGeneration, self.phase == .primed else { return }
                    guard fresh.contains(where: { $0.window != nil }) else { self.cancel(); return }
                    self.presentWindowsOnly(fresh, pid: pid)
                    self.scheduleWindowsOnlyRefresh(pid: pid, gen: gen)
                }
            }
        }
    }

    private func presentWindowsOnly(_ filtered: [SwitcherRow], pid: pid_t) {
        let sorted = windowMRU.sortRows(filtered, forPid: pid)
        baseRows = sorted
        baseLabels = RowLabels.labels(for: baseRows)
        rows = baseRows
        labels = baseLabels
        let count = rows.count
        let delta = windowsOnlyPrimedDelta
        index = count > 0 ? ((delta % count) + count) % count : 0

        currentMetrics = SwitcherMetrics.forScreen(SwitcherPanel.preferredScreen(), layoutMode: Preferences.shared.switcherLayoutMode, userScale: Preferences.shared.panelSize.scale, letterHints: Preferences.shared.letterHintsEnabled)
        view.configure(rows: rows, labels: displayLabels, selectedIndex: index, metrics: currentMetrics, highlightPrefix: letterBuffer)
        panel.present()
        phase = .visible
        cache.setPanelVisible(true)
    }

    private func scheduleWindowsOnlyRefresh(pid: pid_t, gen: UInt64) {
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
        baseRows = sorted
        baseLabels = RowLabels.labels(for: baseRows)
        refreshDisplay()
    }

    private func applyFullSnapshot(_ fresh: [SwitcherRow], anchorPid: pid_t?) {
        guard phase == .visible else { return }
        if fresh.isEmpty { cancel(); return }

        // `refreshDisplay` preserves the user's current selection by identity so
        // a Tab press landing between reveal-from-cache and this
        // background-refreshed apply isn't reverted to the originally-primed
        // app, falling back to `anchorPid` only if the row is gone.
        baseRows = fresh
        baseLabels = RowLabels.labels(for: baseRows)
        refreshDisplay(anchorPid: anchorPid)
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

    /// The row the visible switcher would activate for `app`: its frontmost
    /// catalogued window. The catalog gives an app either one windowless row or
    /// one row per window (windowed rows sort first), so the first windowed row
    /// for the pid is the frontmost — matching reveal()'s `firstIndex(by: pid)`
    /// pick. Reads the warm cache first, then falls back to a fresh AX snapshot
    /// when cold — the same two-tier lookup as `pickWindowsOnlyTarget`. Returns
    /// nil for a windowless app so the caller can fall back to `activateApp`.
    private func primedAppTargetRow(for app: NSRunningApplication) -> SwitcherRow? {
        let pid = app.processIdentifier
        if let row = cache.rows(orderedBy: mru.order).first(where: { $0.pid == pid && $0.window != nil }) {
            return row
        }
        return AppCatalog.snapshot(orderedBy: mru.order).first(where: { $0.pid == pid && $0.window != nil })
    }

    private func bumpWindowMRUIfPossible(for row: SwitcherRow) {
        guard let win = row.window, let pid = row.pid else { return }
        let wid = PrivateAPI.cgWindowId(of: win)
        guard wid != 0 else { return }
        windowMRU.bump(pid: pid, wid: wid)
    }

    private func commit() {
        revealTimer?.invalidate()
        revealTimer = nil
        let currentPhase = phase
        let instantSpace = Preferences.shared.experimentalInstantSpaceSwitch
        var pendingActivation: (() -> Void)? = nil

        switch currentPhase {
        case .visible:
            if rows.indices.contains(index) {
                let row = rows[index]
                if let pid = row.pid { mru.bump(pid) }
                bumpWindowMRUIfPossible(for: row)
                pendingActivation = { Activator.activate(row, instantSpace: instantSpace) }
            }
        case .primed:
            if windowsOnlyMode, let pid = windowsOnlyPid,
               let row = pickWindowsOnlyTarget(pid: pid, delta: windowsOnlyPrimedDelta) {
                if let p = row.pid { mru.bump(p) }
                bumpWindowMRUIfPossible(for: row)
                pendingActivation = { Activator.activate(row, instantSpace: instantSpace) }
            } else if primedApps.indices.contains(primedIndex) {
                let app = primedApps[primedIndex]
                mru.bump(app.processIdentifier)
                // Activate through the app's frontmost catalogued window — the
                // same row the visible switcher would have committed — so a
                // fast ⌘⇥ tap jumps Spaces / exits full screen exactly like
                // releasing ⌘ over the panel. `activateApp` carries no window
                // and no `instantSpace`, so it can't switch Spaces; that's why
                // rapid ⌘⇥ between Spaces (or Space↔window) used to land on the
                // wrong Space. Fall back to it only for windowless apps.
                if let row = primedAppTargetRow(for: app) {
                    bumpWindowMRUIfPossible(for: row)
                    pendingActivation = { Activator.activate(row, instantSpace: instantSpace) }
                } else {
                    pendingActivation = { Activator.activateApp(app) }
                }
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
        baseRows = []
        baseLabels = []
        windowsOnlyMode = false
        windowsOnlyPid = nil
        windowsOnlyPrimedDelta = 0
        closedTombstones.removeAll()
        resetLetterBuffer()
        resetSearch()
        if pendingActivation != nil { CommitFeedback.play() }
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
        baseRows = []
        baseLabels = []
        windowsOnlyMode = false
        windowsOnlyPid = nil
        windowsOnlyPrimedDelta = 0
        closedTombstones.removeAll()
        resetLetterBuffer()
        resetSearch()
    }

    private func performOnVisibleTarget(_ action: (SwitcherRow) -> Void) {
        guard phase == .visible, rows.indices.contains(index) else { return }
        // System permission/consent windows can't be acted on from the switcher
        // (close/quit/minimize/hide) — the user must enter them and click
        // Deny / Open Settings themselves.
        guard !rows[index].isSystemDialog else { return }
        action(rows[index])
        scheduleVisibleRefresh(after: 0.25)
    }

    /// Move the highlighted window. Horizontal moves go to the adjacent Space
    /// when the experimental toggle is on (following the window there and
    /// closing the switcher); otherwise — and for vertical moves — the window
    /// hops to the adjacent display and the switcher stays open.
    private func performMove(_ direction: MoveDirection) {
        guard phase == .visible, rows.indices.contains(index) else { return }
        let row = rows[index]
        guard !row.isSystemDialog, row.app != nil, row.window != nil else { return }

        let horizontal = (direction == .left || direction == .right)
        if horizontal && Preferences.shared.experimentalMoveToSpace {
            Activator.moveWindowToSpace(row, direction: direction)
            // We followed the window onto its new Space; dismiss the switcher.
            cancel()
        } else {
            Activator.moveWindowToDisplay(row, direction: direction)
            scheduleVisibleRefresh(after: 0.2)
        }
    }

    private func performQuitAction() {
        performOnVisibleTarget { row in
            // Record an app-level entry (no document) so a quit app can be
            // relaunched from recently-closed search. Regular apps only —
            // system dialog hosts shouldn't be reopenable.
            if row.app?.activationPolicy == .regular, let bundleID = row.bundleIdentifier {
                RecentlyClosedStore.shared.record(
                    bundleID: bundleID,
                    appName: row.appName,
                    title: "",
                    documentPath: nil
                )
            }
            Activator.quitApp(row)
        }
    }

    private func performCloseAction() {
        guard phase == .visible, rows.indices.contains(index) else { return }
        let row = rows[index]
        // Permission/consent windows aren't closable from the switcher.
        guard !row.isSystemDialog else { return }
        // Close only applies to a real window of a running app — launchable
        // search rows have nothing to close.
        guard let closedApp = row.app, let closedPid = row.pid else { return }
        // A windowless row has nothing to close. Falling through would pointlessly
        // re-demote the app, flashing its "no window" glyph off (re-inserted
        // suppressed) and back on (the grace reveal) — a visible blink.
        guard row.window != nil else { return }

        // Closing a single window is intentionally NOT recorded for "recently
        // closed": that history is app-level only (an app being quit), captured
        // on termination / ⌘Q — not per window.

        if row.isFullscreen {
            Activator.closeWindow(row)
            cancel()
            return
        }

        recordClosedTombstone(for: row)
        Activator.closeWindow(row)

        // Remove the exact closed window from the canonical set. Match the AX
        // element identity first (CFEqual) so an app with several same-titled
        // (or untitled) windows drops the right row; fall back to the
        // pid+title+hasWindow key only when there's no window ref.
        let removeIdx: Int?
        if let win = row.window {
            removeIdx = baseRows.firstIndex { $0.window.map { CFEqual($0, win) } ?? false }
        } else {
            removeIdx = baseRows.firstIndex { keyMatches($0, (closedPid, row.windowTitle, false)) }
        }
        if let bi = removeIdx {
            baseRows.remove(at: bi)
        }

        // If this was the only window for a regular app, demote the app to a
        // windowless row right now. Otherwise the app visibly vanishes for
        // ~250ms (until the cache refresh + tombstone filter substitute one) —
        // closing the window shouldn't make the app flicker out of the switcher.
        //
        // Insert it at the slot the 250ms cache refresh will ultimately put it
        // in — among the trailing windowless rows, ordered by MRU recency — not
        // at the very end. Appending at the end made a recently-used app jump
        // twice: down to the bottom now, then back up to its MRU slot when the
        // refresh landed.
        if closedApp.activationPolicy == .regular,
           !baseRows.contains(where: { $0.pid == closedPid }) {
            baseRows.insert(
                SwitcherRow(
                    app: closedApp,
                    window: nil,
                    windowTitle: "",
                    isMinimized: false,
                    // Don't claim "no window" yet — the app may be about to hide
                    // itself (Electron apps do). `handleAppHiddenChanged` flips
                    // the row to the hidden glyph the moment it does; otherwise
                    // the next refresh resolves it to a real no-window row.
                    suppressNoWindowGlyph: true
                ),
                at: inactiveInsertionIndex(forPid: closedPid, in: baseRows)
            )
        }

        if baseRows.isEmpty {
            cancel()
            return
        }
        baseLabels = RowLabels.labels(for: baseRows)
        refreshDisplay()

        // Reveal the "no window" glyph on the row we just demoted, after a short
        // grace, so it appears near-instantly instead of waiting on the 250ms
        // refresh below (which rebuilds from the AX cache — a path that lags for
        // the *last*-window close, where the window-destroyed notification often
        // never fires).
        revealNoWindowGlyphAfterGrace(pid: closedPid)
        scheduleVisibleRefresh(after: 0.25)
    }

    /// Flip the suppressed "no window" glyph on after a short, fixed grace. The
    /// optimistic row from `performCloseAction` hides the glyph because the app
    /// might hide itself instead of going windowless (Electron apps do) and we
    /// don't want a no-window→hidden flash. The grace is long enough for such an
    /// app to fire its hide — `isHidden` then goes true and the view paints the
    /// hidden glyph, so we leave the suppression alone — and short enough that
    /// the common case (app simply goes windowless) feels immediate. Purely
    /// time-based: doesn't wait on the AX cache to re-report the window count,
    /// which is the slow path.
    private func revealNoWindowGlyphAfterGrace(pid: pid_t) {
        let gen = revealGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, gen == self.revealGeneration, self.phase == .visible else { return }
            guard let i = self.baseRows.firstIndex(where: {
                $0.pid == pid && $0.window == nil && $0.suppressNoWindowGlyph
            }), let app = self.baseRows[i].app else { return }
            // App hid itself on close — keep suppressing so the hidden glyph
            // (painted live from `isHidden`) shows instead, with no flash.
            if app.isHidden { return }
            self.baseRows[i] = SwitcherRow(
                app: app,
                window: nil,
                windowTitle: "",
                isMinimized: false
            )
            self.refreshDisplay()
        }
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
                // `refreshDisplay` preserves selection by row identity (pid +
                // title + hasWindow). Plain index clamping silently shifts the
                // highlight onto a different window when the fresh snapshot
                // reorders rows (MRU bump after close changing focus is the
                // common trigger), making the next close action hit the wrong
                // window.
                self.baseRows = fresh
                self.baseLabels = RowLabels.labels(for: fresh)
                self.refreshDisplay()
            }
        }
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: apply)
        } else {
            apply()
        }
    }

    /// Index in `rows` at which a freshly-windowless regular app should be
    /// inserted so it matches the catalog's final ordering: after every
    /// windowed/minimized row, and within the trailing "inactive" group
    /// (windowless + hidden, see `statusPriority`) ordered by MRU recency.
    /// Mirrors `AppCatalog`/`AppCatalogCache`'s sort so the row lands where the
    /// next cache refresh will keep it — whether the app settles as windowless
    /// or hidden, both share the bucket — so there's no second jump.
    private func inactiveInsertionIndex(forPid pid: pid_t, in rows: [SwitcherRow]) -> Int {
        let order = mru.order
        let myRank = order.firstIndex(of: pid) ?? Int.max
        for (i, row) in rows.enumerated()
        where ((row.window == nil && !row.isPlaceholder) || row.isHidden) {
            let rank = row.pid.flatMap { order.firstIndex(of: $0) } ?? Int.max
            // First inactive row less recently used than us — sit before it.
            if rank > myRank { return i }
        }
        return rows.count
    }

    private func recordClosedTombstone(for row: SwitcherRow) {
        guard let pid = row.pid else { return }
        let wid = row.window.map { PrivateAPI.cgWindowId(of: $0) } ?? 0
        // Record even when wid == 0 — title fallback still catches it.
        closedTombstones.append(ClosedWindowSignature(
            pid: pid,
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
        // AX window because the destroy hasn't propagated — or, for apps that
        // hide rather than destroy their last window, the *same* window reappears
        // hidden with the same CGWindowID and keeps matching the tombstone), we
        // substitute a windowless row so the app doesn't vanish. `discovery`
        // keeps multiple substitutions in original snapshot order.
        var firstHiddenByPid: [pid_t: (app: NSRunningApplication, discovery: Int)] = [:]
        var discoveryCounter = 0
        for row in snapshot {
            let rowWid = row.window.map { PrivateAPI.cgWindowId(of: $0) } ?? 0
            var suppressed = false
            for (i, sig) in closedTombstones.enumerated() {
                if signatureMatches(sig, row: row, rowWid: rowWid) {
                    // A "closed" window that reappears while its app is now
                    // hidden was hidden by the app, not destroyed (Electron apps
                    // hide on last-window close). Stop suppressing it: keep the
                    // real row so its window title survives and it shows as a
                    // hidden window, and let the tombstone clear (don't mark it
                    // matched) — the close has resolved into a hide.
                    if row.isHidden { break }
                    matchedSigIndices.insert(i)
                    suppressed = true
                    break
                }
            }
            if !suppressed {
                result.append(row)
                if let p = row.pid { keptPids.insert(p) }
            } else if let p = row.pid, let a = row.app, firstHiddenByPid[p] == nil {
                firstHiddenByPid[p] = (app: a, discovery: discoveryCounter)
                discoveryCounter += 1
            }
        }
        let placeholders = firstHiddenByPid
            .filter { !keptPids.contains($0.key) && $0.value.app.activationPolicy == .regular }
            .map { $0.value }
            .sorted { $0.discovery < $1.discovery }
        for placeholder in placeholders {
            // Insert at the app's MRU slot in the inactive group, not at the
            // end. Appending made an app whose closed window reappears hidden
            // (same CGWindowID, so the tombstone keeps matching it) jump to the
            // bottom on the post-close refresh even though it should hold the
            // spot the immediate demotion already gave it.
            let row = SwitcherRow(
                app: placeholder.app,
                window: nil,
                windowTitle: "",
                isMinimized: false
            )
            let idx = inactiveInsertionIndex(forPid: placeholder.app.processIdentifier, in: result)
            result.insert(row, at: idx)
        }
        // Drop tombstones whose windows the cache no longer reports — the
        // close has fully propagated, so no further protection needed.
        closedTombstones = closedTombstones.enumerated()
            .compactMap { matchedSigIndices.contains($0.offset) ? $0.element : nil }
        return result
    }

    private func selectionKey() -> (pid_t, String, Bool)? {
        guard rows.indices.contains(index), let pid = rows[index].pid else { return nil }
        return (pid, rows[index].windowTitle, rows[index].window != nil)
    }

    private func keyMatches(_ row: SwitcherRow, _ key: (pid_t, String, Bool)) -> Bool {
        row.pid == key.0 && row.windowTitle == key.1 && (row.window != nil) == key.2
    }

    /// Recently closed windows/apps to surface for reopening. `forSearchQuery`
    /// non-nil filters by fuzzy match; nil yields the newest entries. Returns
    /// nothing when the feature is off or in window-only mode. App-only entries
    /// (no document) already represented in `alreadyShown` are skipped to avoid
    /// a redundant duplicate row.
    private func recentlyClosedRows(forSearchQuery query: String?, alreadyShown: Set<String>) -> [SwitcherRow] {
        guard Preferences.shared.showRecentlyClosed, !windowsOnlyMode else { return [] }
        let limit = Preferences.shared.recentlyClosedLimit
        let entries: [RecentEntry]
        if let query, !query.isEmpty {
            entries = RecentlyClosedStore.shared.matches(query: query, limit: limit)
        } else {
            entries = RecentlyClosedStore.shared.recent(limit: limit)
        }
        var result: [SwitcherRow] = []
        for entry in entries {
            if entry.documentPath == nil, alreadyShown.contains(entry.bundleID) { continue }
            result.append(SwitcherRow(recentlyClosed: entry))
        }
        return result
    }

    /// Rebuild the folded-string cache for the current `baseRows` if it went
    /// stale. Called at the top of the search-filter path so each row's name and
    /// title are folded once per row-set change, not once per keystroke.
    private func ensureBaseFolded() {
        guard !baseFoldedValid else { return }
        baseFolded = baseRows.map { (FuzzyMatch.fold($0.appName), FuzzyMatch.fold($0.windowTitle)) }
        baseFoldedValid = true
    }

    /// Single funnel that derives the displayed `rows`/`labels` from the
    /// canonical `baseRows`, honoring the active mode: fuzzy-search filter,
    /// letter-prefix reorder, or plain pass-through. Selection is restored by
    /// identity (then `anchorPid`, then clamped), and the result is pushed to
    /// the panel. Replaces the old `applyPrefixReorder`.
    private func refreshDisplay(resetSelectionToTop: Bool = false, anchorPid: pid_t? = nil) {
        guard phase == .visible else { return }
        let key = resetSelectionToTop ? nil : selectionKey()

        if searchActive, !searchQuery.isEmpty {
            ensureBaseFolded()
            let foldedQuery = FuzzyMatch.fold(searchQuery)
            var newRows: [SwitcherRow] = []
            var newLabels: [String] = []
            newRows.reserveCapacity(baseRows.count)
            for i in baseRows.indices
            where FuzzyMatch.matchesFolded(foldedQuery: foldedQuery, foldedAppName: baseFolded[i].app, foldedWindowTitle: baseFolded[i].title) {
                newRows.append(baseRows[i])
                newLabels.append(baseLabels[i])
            }
            // Launcher: append matching apps that aren't running yet so the user
            // can launch them from the same search. Labels are inert in search
            // mode (the view hides them), so empty strings keep the arrays
            // aligned without affecting display.
            if Preferences.shared.searchIncludesLaunchableApps {
                let runningBundleIDs = Set(baseRows.compactMap { $0.bundleIdentifier })
                let launchable = InstalledAppsIndex.shared.matches(
                    query: searchQuery,
                    excludingRunning: runningBundleIDs,
                    limit: 8
                )
                for app in launchable {
                    newRows.append(SwitcherRow(launchable: app))
                    newLabels.append("")
                }
            }
            for row in recentlyClosedRows(forSearchQuery: searchQuery, alreadyShown: Set(newRows.compactMap { $0.bundleIdentifier })) {
                newRows.append(row)
                newLabels.append("")
            }
            rows = newRows
            labels = newLabels
        } else {
            // Non-search: the displayed set is the running rows plus recently
            // closed entries. Labels are computed over the whole set so closed
            // apps get their own type-to-jump letter, exactly like running rows.
            var combined = baseRows
            combined.append(contentsOf: recentlyClosedRows(
                forSearchQuery: nil,
                alreadyShown: Set(baseRows.compactMap { $0.bundleIdentifier })
            ))
            // Reuse `baseLabels` when nothing was appended to keep labels stable.
            let combinedLabels = combined.count == baseRows.count ? baseLabels : RowLabels.labels(for: combined)

            if !letterBuffer.isEmpty {
                let prefix = letterBuffer
                var orderIdx: [Int] = []
                orderIdx.reserveCapacity(combined.count)
                for i in combined.indices where combinedLabels[i].hasPrefix(prefix) { orderIdx.append(i) }
                for i in combined.indices where !combinedLabels[i].hasPrefix(prefix) { orderIdx.append(i) }
                rows = orderIdx.map { combined[$0] }
                labels = orderIdx.map { combinedLabels[$0] }
            } else {
                rows = combined
                labels = combinedLabels
            }
        }

        if resetSelectionToTop {
            index = 0
        } else if let key, let restored = rows.firstIndex(where: { keyMatches($0, key) }) {
            index = restored
        } else if let anchorPid, let match = rows.firstIndex(where: { $0.pid == anchorPid }) {
            index = match
        } else {
            index = rows.isEmpty ? 0 : max(0, min(index, rows.count - 1))
        }

        view.configure(
            rows: rows,
            labels: displayLabels,
            selectedIndex: index,
            metrics: currentMetrics,
            highlightPrefix: searchActive ? "" : letterBuffer,
            searchActive: searchActive,
            searchQuery: searchQuery
        )
        panel.present()
    }

    // MARK: - Fuzzy search

    private func toggleSearch() {
        if searchActive { exitSearch() } else { enterSearch() }
    }

    private func enterSearch() {
        guard phase == .visible, Preferences.shared.fuzzySearchEnabled, !searchActive else { return }
        // Drop any in-flight letter prefix without re-rendering — we re-render
        // immediately below as the search view.
        letterBufferTimer?.invalidate()
        letterBufferTimer = nil
        letterBuffer = ""
        searchActive = true
        searchQuery = ""
        hotkey.setSearchMode(true)
        if Preferences.shared.searchIncludesLaunchableApps {
            InstalledAppsIndex.shared.ensureFresh()
        }
        refreshDisplay()
    }

    private func exitSearch() {
        guard searchActive else { return }
        searchActive = false
        searchQuery = ""
        hotkey.setSearchMode(false)
        refreshDisplay()
    }

    private func handleSearchInput(_ ch: Character) {
        guard searchActive else { return }
        searchQuery.append(ch)
        refreshDisplay(resetSelectionToTop: true)
    }

    private func handleSearchBackspace() {
        guard searchActive else { return }
        if searchQuery.isEmpty {
            exitSearch()
            return
        }
        searchQuery.removeLast()
        refreshDisplay(resetSelectionToTop: true)
    }

    private func resetSearch() {
        searchActive = false
        searchQuery = ""
        stickyOpen = false
        hotkey.setSearchMode(false)
    }

    /// ⌘ (or another hold modifier) was released. Normally that commits the
    /// current selection. In `.stayOpen` search mode the first release instead
    /// detaches the switcher so it persists until Return / mouse selection;
    /// once detached, further modifier releases are ignored.
    private func handleModifierRelease() {
        if stickyOpen { return }
        if searchActive, Preferences.shared.searchDismissMode == .stayOpen {
            stickyOpen = true
            return
        }
        commit()
    }
}
