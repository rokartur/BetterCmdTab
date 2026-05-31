import AppKit
@preconcurrency import ApplicationServices
import BetterShortcuts
import Carbon.HIToolbox
import Combine
import os

@MainActor
final class SwitcherController: SwitcherViewDelegate {
    enum Phase {
        case idle
        case primed
        case visible

        /// The tap suppresses the trigger chord and routes navigation whenever
        /// the switcher is non-idle — both `.primed` and `.visible`.
        var isSwitching: Bool { self != .idle }
        /// The in-panel action keys (close/quit/minimize/hide/fullscreen) and
        /// letter-jump act only against a panel that is actually on screen. They
        /// must NOT fire during the panel-less `.primed` phase — doing so would
        /// silently sink ⌘W/⌘Q/⌘M/⌘H/⌘F (and bare letters) from the focused app
        /// (issue #16). Only `.visible` presents a panel.
        var presentsPanel: Bool { self == .visible }
        /// `.primed` is the only non-idle phase that shows no panel; the liveness
        /// watchdog force-cancels if `phase` is ever stranded here.
        var isPrimed: Bool { self == .primed }
    }

    private let hotkey = HotkeyTap()
    /// Secure-input-immune fallback trigger (see CarbonHotkeyTrigger). Opens and
    /// steps the switcher via a Carbon hot key when the tap is bypassed because
    /// another app holds Secure Event Input (issue #7).
    private let carbonTrigger = CarbonHotkeyTrigger()
    /// Native symbolic hotkeys (⌘Tab etc.) we've currently disabled at the
    /// WindowServer, so teardown / a remap can re-enable exactly those.
    private var disabledSymbolicKeys: [PrivateAPI.SymbolicHotKey] = []
    /// Polls Secure Event Input. The native-shortcut override (symbolic disable +
    /// Carbon registration) is applied ONLY while it is active — outside it the
    /// tap alone suppresses + triggers ⌘Tab, so the native shortcut is never left
    /// disabled across a crash (see `computeNativeOverridePlan`).
    private let secureInputMonitor = SecureInputMonitor()
    private var secureInputActive = false
    /// Polls the hold modifier to detect ⌘-release under Secure Event Input
    /// (where no release event is delivered) and to supply the live hold state
    /// that gates the in-panel Carbon chords. Runs only while the panel is open
    /// under secure input (see `syncNativeHotkeyOverride`).
    private let holdMonitor = HoldModifierMonitor()
    private var holdMonitorRunning = false
    /// Set by the Privacy-pane "Restore macOS keyboard shortcuts" escape hatch.
    /// While set, the native-shortcut override is fully suspended — the system's
    /// ⌘Tab is left enabled and no Carbon chords are registered — so the user gets
    /// their native ⌘Tab back. The tap still opens our switcher under normal
    /// input; only under Secure Event Input does the native switcher win again,
    /// until the next launch (this is in-memory, so a relaunch re-arms the
    /// override). Exists because, always-armed, the override would otherwise
    /// immediately re-disable whatever Restore just re-enabled.
    private var nativeOverrideSuspended = false
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
        didSet {
            baseFoldedValid = false
            // Window AXUIElements churn across reveals; drop the prefetch
            // cache so we don't try to drill into a stale element.
            tabPrefetchCache.removeAll()
            tabPrefetchInFlight.removeAll()
        }
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
    /// The frontmost app's focused window captured at the instant the switcher
    /// opens — before the panel is presented, while the user's real app is still
    /// frontmost. Window-management chords act on THIS ("obecne okno"), not the
    /// highlighted row and not a live `frontmostApplication` read (which returns
    /// BetterCmdTab once our key panel is on screen). Cleared on teardown.
    private var openFocusedWindow: AXUIElement?
    /// The app that was frontmost when the switcher opened. On open we activate
    /// BetterCmdTab so the WindowServer renders the Liquid Glass backdrop as
    /// active (an `.accessory`/non-activating app's in-process `appearsActive`
    /// override can't reach the server-side glass). Restored on `cancel()` so
    /// dismissing without picking anything leaves the user exactly where they
    /// were; `commit()`/`commitTab()` clear it because they activate a target
    /// instead. Nil when the previous app was us (Settings window) or unknown.
    private var previousFrontmostApp: NSRunningApplication?
    private var revealTimer: Timer?
    /// Liveness ceiling on the `.primed` phase. `.primed` is non-idle but shows no
    /// panel; its only exits are `reveal()` (driven by `revealTimer` or an off-main
    /// catalog scan landing), a ⌘-release commit, or Esc/Return — every one a
    /// fragile single async/user event. If one is lost (a dropped reveal under a
    /// starved runloop, a ⌘-up never delivered to a deaf tap under Secure Event
    /// Input), `phase` welds to `.primed`: `switchingFlag` stays set, the next
    /// ⌘Tab can't re-open, and the switcher is wedged. This watchdog force-cancels
    /// back to `.idle` if `.primed` ever outlives a hard ceiling. Armed/disarmed on
    /// the `.primed` edge from the single `phase` chokepoint (issue #16).
    private var primedWatchdog: Timer?
    /// Hard ceiling for the `.primed` phase — comfortably above the configurable
    /// `revealDelay` (clamped to 40…500 ms) and any off-main first-scan, so it
    /// only ever fires on a genuine strand, never on a legitimately slow open.
    private static let primedWatchdogTimeout: TimeInterval = 1.5
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
    /// (The secure-input Carbon chords no longer key off this: they gate on the
    /// live hold modifier + the search/drill mode, re-synced from the poller and
    /// the search/drill transitions, so `stickyOpen` needs no `didSet` here.)
    private var stickyOpen = false
    /// `stickyOpen` snapshotted at drill entry so exiting the drill (e.g. the
    /// `\` toggle while ⌘ is still held) restores the pre-drill detach state
    /// instead of leaving `applyDrill`'s forced `stickyOpen = true` set — which
    /// would strand the panel open because the modifier release no longer commits.
    private var stickyOpenBeforeDrill = false
    /// Browser tab drill-in state. While `tabDrillActive`, nav keys (Cmd+Tab,
    /// Cmd+Left/Right, arrows) step `tabIndex` inside the highlighted row's
    /// `tabs` array instead of changing the app selection. Reset on every row
    /// change, dismiss, and `baseRows` swap.
    private var tabDrillActive: Bool = false
    private var tabIndex: Int = 0
    private var tabTitles: [String] = []
    /// Transient, non-interactive message shown in the tab-strip region (e.g.
    /// "grant Automation access") when a browser drill can't read tabs. Distinct
    /// from `tabDrillActive`: presenting it never enables tab navigation.
    private var tabDrillHint: String?
    /// Tab AX elements located by `WindowEnumerator.tabs(in:)` on drill-in.
    /// Held here (not on `SwitcherRow`) because they're resolved lazily —
    /// browsers nest the tab group too deep for the per-reveal AX scan to
    /// touch them affordably. Empty for browser-family rows since those use
    /// AppleScript-by-index activation.
    private var liveTabElements: [AXUIElement] = []
    /// Source of the current drill-in. `appleScript` → activate by index via
    /// `BrowserTabs.activateTab`. `accessibility` → AX press on
    /// `liveTabElements[tabIndex]`. `windows` → native window tabs: each
    /// `liveTabElements[i]` is a real NSWindow; raising it selects that tab.
    /// Picked once per drill, never crossed.
    private enum TabDrillBackend { case appleScript, accessibility, windows }
    private var tabDrillBackend: TabDrillBackend = .accessibility
    /// The window `applyDrill` built the current tab strip against. `commitTab`
    /// re-validates that the selected row still points at this window before
    /// pairing it with the captured tab elements — a background refresh can move
    /// the selection off the drilled row (the drilled app quits, or a re-sort
    /// reorders rows) while the strip stays open, which would otherwise activate
    /// the wrong window or a different app. Cleared whenever the drill ends.
    private var drillWindow: AXUIElement?
    /// Background prefetch of tab titles keyed by AXUIElement window
    /// identity. Populated when selection lands on a tab-capable row so that
    /// the eventual `\` finds the work already done. Cleared when the panel
    /// dismisses or the base row set changes.
    private struct TabPrefetch {
        let titles: [String]
        let liveTabs: [AXUIElement]
        let backend: TabDrillBackend
    }
    private var tabPrefetchCache: [AXRef: TabPrefetch] = [:]
    private var tabPrefetchInFlight: Set<AXRef> = []
    private var tabPrefetchTimer: Timer?
    /// Inline browser-tab expansion (`expandBrowserTabsAsWindows`). Browser tabs
    /// aren't separate NSWindows, so each browser window's tab titles are fetched
    /// off-main via Apple Events and cached here, keyed by the parent window's AX
    /// element. An empty array is a negative cache (no tabs / fetch failed). The
    /// cache PERSISTS across panel opens (only the in-flight set is cleared on
    /// dismiss) so a re-open expands instantly from cache instead of showing the
    /// collapsed windows and then flickering to tabs after the Apple Events
    /// round-trip; `browserTabsCacheStamp` throttles the background re-scan that
    /// keeps the cache fresh.
    private var browserTabsCache: [AXRef: [String]] = [:]
    private var browserTabsFetchInFlight: Set<AXRef> = []
    /// Monotonic timestamp (systemUptime) of the last successful tab fetch per
    /// window. A window is re-scanned only when its entry is older than
    /// `browserTabsCacheTTL`, bounding osascript spawns across rapid re-opens.
    private var browserTabsCacheStamp: [AXRef: TimeInterval] = [:]
    private static let browserTabsCacheTTL: TimeInterval = 3.0
    /// Monotonic time of the last *forced* (event-driven) browser-tab scan. A
    /// forced scan (a browser-window title change while the panel is open, which
    /// fires when a tab is opened/closed/switched) bypasses the per-window TTL so
    /// the rows sync near-instantly — but page-load title churn can fire many
    /// such events a second, so a forced scan is rate-limited to this interval to
    /// keep osascript spawns (and CPU) bounded.
    private var lastForcedBrowserScanAt: TimeInterval = 0
    private static let forcedBrowserScanMinInterval: TimeInterval = 0.4
    private var windowsOnlyMode: Bool = false
    private var windowsOnlyPid: pid_t? = nil
    private var windowsOnlyPrimedDelta: Int = 0

    /// Active scope for a scoped-shortcut open (#3). Non-nil only between a
    /// scoped open and the next return to idle; while set, every row set
    /// (`reveal`, background `applyFullSnapshot`) is post-filtered to this
    /// subset. nil for normal ⌘Tab opens, so the standard path is unaffected.
    private var activeScope: SwitchScope? = nil
    /// Frontmost app's pid captured when a scoped open started — used by the
    /// `.currentAppWindows` scope (we're an accessory app, so the frontmost at
    /// trigger time is the user's real app, not us).
    private var scopeFrontPid: pid_t? = nil

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
    /// pids of apps the user quit from the switcher. Their rows are dropped
    /// immediately so the app doesn't linger as a windowless row during the gap
    /// between its windows closing and the process terminating; refreshes filter
    /// these out until `handleAppTerminated` (or a safety timeout, for a quit a
    /// save dialog vetoed) clears the pid.
    private var quittingPids: Set<pid_t> = []
    private let quitSuppressTTL: TimeInterval = 2.0

    /// Monotonic token bumped on every `reveal()` and `cancel()`. Background
    /// callbacks capture the value at dispatch time and bail out on return if
    /// the token has changed — prevents rapid Cmd+Tab → Esc → Cmd+Tab from
    /// landing stale rows after a fresh reveal.
    private var revealGeneration: UInt64 = 0

    private var cancellables = Set<AnyCancellable>()

    /// Tap-vs-hold threshold, user-tunable. Read live so a settings change takes
    /// effect on the next chord without restart.
    var revealDelay: TimeInterval { Double(Preferences.shared.revealDelayMs) / 1000.0 }

    /// How long a typed letter-jump prefix survives before it expires. Read live
    /// so a settings change takes effect on the next keystroke without restart.
    var letterChainTimeout: TimeInterval { Double(Preferences.shared.letterChainTimeoutMs) / 1000.0 }

    /// Frontmost app's focused window, resolved off-main during the primed phase
    /// (overlapping the reveal delay) so `reveal()` doesn't block its critical
    /// path on the synchronous AX read. Consumed and cleared by `reveal()`.
    private var prefetchedFocusedWindow: AXUIElement?
    /// Token bumped per primed chord so a stale off-main focused-window capture
    /// from an earlier chord can't land on a newer one.
    private var focusedWindowCaptureGen: UInt64 = 0

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
        // Track every app activation live — a Dock click, a click on another
        // app's window, or ⌘Tab from any source — so the app-MRU order is
        // always current. Without this, `mru.order` only self-corrects lazily
        // via `syncFrontmost()` when the switcher opens, which reads
        // `NSWorkspace.frontmostApplication`; that value lags briefly after a
        // Dock switch, so a fast ⌘⇥ right after switching via the Dock reads a
        // stale frontmost and steps from the wrong anchor (wrong target app and
        // window). Bumping here pins `mru.order[0]` to the real frontmost the
        // instant it changes, and refreshes the activated app's focused window
        // in the window-MRU, so the next chord starts from the correct app.
        // Self-activation (our own panel becoming key) is skipped — it must
        // never claim MRU[0]. Also recompute the "Ignore shortcuts" suppression
        // here since the frontmost app just changed.
        let selfPid = getpid()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let pid, pid != selfPid {
                    self.mru.bump(pid)
                    self.handleFocusChange(pid: pid)
                }
                self.updateTriggerSuppression()
            }
        }
        // The active Space flipping (full-screen enter/exit is its own Space)
        // only affects trigger suppression, not the MRU. The flag is read by the
        // tap on the next trigger chord.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateTriggerSuppression() }
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
        // The app is gone — stop suppressing it (no-op if it was a window close,
        // not a quit). Done before the guard so an optimistically-removed quit
        // pid is always cleared.
        quittingPids.remove(pid)
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

    /// UserDefaults key recording which symbolic-hotkey ids we left disabled, so
    /// a launch following an unclean exit can restore them. See `SymbolicHotkeyGuard`.
    private static let persistedDisabledKey = "Switcher.disabledSymbolicHotKeys"

    /// Count of consecutive CGEvent-tap install retries in flight, capped so a
    /// permanently denied tap doesn't spin forever (the Carbon fallback still
    /// drives the trigger meanwhile).
    private var hotkeyTapRetries = 0
    private static let maxHotkeyTapRetries = 5

    func start() {
        // Crash-safety for the WindowServer symbolic-hotkey disable (which
        // outlives the process): install signal/atexit restoration, then
        // self-heal any disable a previous run left behind before we re-derive
        // and re-apply the current config. Covers the uncatchable SIGKILL case.
        SymbolicHotkeyGuard.install()
        healStaleSymbolicHotkeyDisable()

        mru.start()
        windowMRU.start()
        cache.start(mru: mru)
        // Focus changes don't change any app's window set, so the cache routes
        // them here instead of paying a full per-pid AX re-scan: just nudge the
        // per-app window-MRU so the next reveal orders windows correctly.
        cache.onFocusChanged = { [weak self] pid in
            self?.handleFocusChange(pid: pid)
        }
        // A window title changed while the switcher is open — refresh the
        // displayed titles (debounced) so they stay live, e.g. a browser tab
        // finishing load while the user scans rows.
        cache.onVisibleTitleChanged = { [weak self] in
            self?.scheduleVisibleTitleRefresh()
        }
        RecentlyClosedStore.shared.start()
        if !hotkey.install() {
            // A failed tap install (e.g. Accessibility lost in the TOCTOU window
            // between the waiter's trust check and here, or a transient
            // WindowServer hiccup) must NOT abort the rest of `start()`. Bailing
            // skipped the Carbon fallback wiring below — the very trigger that
            // survives Secure Event Input — leaving the app dead with no retry.
            // Wire everything anyway (the tap setters just stage state the tap
            // reads once it comes up) and retry the tap on a short backoff.
            Log.switcher.error("CGEventTap installation failed — Accessibility not trusted? Wiring Carbon fallback and retrying the tap.")
            scheduleHotkeyTapRetry()
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
        // Mirror the tap's reserved-letter set (in-panel action keys + ⌘F,
        // recomputed on every binding/layout change) into RowLabels so hint
        // generation never assigns a letter that's bound to an action.
        hotkey.onReservedLettersChanged = { letters in RowLabels.setReserved(letters) }
        // The Carbon fallback drives the same handler as the tap.
        carbonTrigger.onEvent = { [weak self] event in self?.handle(event) }
        // Scoped-shortcut triggers open the switcher pre-filtered (#3).
        ScopedSwitch.onTrigger = { [weak self] scope in self?.openScoped(scope) }
        // User-invoked recovery from the Privacy pane: re-enable every native
        // symbolic hotkey we may have disabled, in case a prior unclean exit
        // left the system ⌘Tab stuck. Re-syncs the live override afterwards so
        // the current trigger re-disables only what it actually needs.
        NotificationCenter.default.publisher(
            for: Notification.Name("BetterCmdTab_restoreNativeShortcuts")
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in self?.restoreNativeShortcutsThenResync() }
        .store(in: &cancellables)
        // Apply the native-shortcut override only while another app holds Secure
        // Event Input. No notification exists for it, so poll; re-sync on every
        // transition. The synchronous initial read makes "launched while a
        // password field is already focused" correct from boot.
        secureInputMonitor.onChange = { [weak self] active in self?.handleSecureInputChange(active) }
        secureInputMonitor.start()
        secureInputActive = secureInputMonitor.isActive
        // The hold-modifier poller feeds the same release path as the tap's
        // flagsChanged (commit / detach / drill-commit), and re-syncs the
        // registered chord set as the modifier goes up or down.
        holdMonitor.onRelease = { [weak self] in self?.handle(.releaseCmd) }
        // Re-sync the registered chords whenever the hold modifier goes up or down
        // so the in-panel parity set precisely tracks it — in particular, a panel
        // opened without the modifier (gesture/scoped, seeded `assumeHeld`) drops
        // its parity chords on the first poll instead of leaving ⌘-qualified keys
        // registered while the modifier is up. The redundant re-register on a
        // commit (the release also closes the panel) is a cheap rare-path cost.
        holdMonitor.onHoldChange = { [weak self] _ in self?.syncNativeHotkeyOverride() }
        pushHotkeyConfig()
        // In-panel action keys (#5) and window-management chords (#7) are
        // BetterShortcuts names; derive the tap's keycode maps from their stored
        // shortcuts now. The shortcutByNameDidChange subscription below re-runs
        // these whenever any shortcut changes.
        pushPanelKeyBindings()
        pushWindowMgmtBindings()
        // The BetterShortcuts recorders persist the user's trigger choices and
        // post this notification on change — re-derive the tap config and the
        // in-panel (#5) / window-management (#7) keycode maps live.
        NotificationCenter.default.publisher(
            for: Notification.Name("BetterShortcuts_shortcutByNameDidChange")
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            self?.pushHotkeyConfig()
            self?.pushPanelKeyBindings()
            self?.pushWindowMgmtBindings()
        }
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
        // Only "open switcher" scrubs continuously; the other modes fire once
        // per swipe (one Space jump / one app flip).
        swipeTrigger.setOneShot(Preferences.shared.swipeMode != .openSwitcher)
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
            .sink { [weak self] mode in self?.swipeTrigger.setOneShot(mode != .openSwitcher) }
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

        // Click-outside-to-dismiss: the panel publishes its frame (in CGEvent
        // global coordinates) on every present/dismiss; the tap hit-tests an
        // outside click against it and swallows it to dismiss the switcher.
        panel.onFrameDidChange = { [weak self] frame in self?.hotkey.setSwitcherFrame(frame) }
        hotkey.setClickOutsideDismiss(Preferences.shared.clickOutsideToDismiss)
        Preferences.shared.$clickOutsideToDismiss
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in self?.hotkey.setClickOutsideDismiss(enabled) }
            .store(in: &cancellables)

        // "Ignore shortcuts" exceptions: seed the suppression flag for the
        // current frontmost app and re-derive it when the exceptions change.
        updateTriggerSuppression()
        Preferences.shared.$appExceptions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateTriggerSuppression() }
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
        // In "quick switch" mode the swipe never opens the switcher — each swipe
        // flips to the previously-used app like a quick ⌘Tab tap-and-release.
        if Preferences.shared.swipeMode == .quickSwitch {
            quickSwitchToPreviousApp()
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

    /// "Quick switch" swipe mode: one swipe acts like a quick ⌘Tab
    /// tap-and-release — flip to the previously-used app, no panel. Activating
    /// reorders the MRU, so the next swipe flips back: repeated swipes bounce
    /// between the two most recent apps exactly like double-tapping ⌘Tab.
    private func quickSwitchToPreviousApp() {
        mru.syncFrontmost()
        // order[0] is the current frontmost; order[1] is the previous app.
        guard mru.order.count >= 2 else { return }
        let targetPid = mru.order[1]
        // A stale pid (app quit before its terminate notification landed) just
        // no-ops this swipe; the next MRU sync drops it.
        guard let app = NSRunningApplication(processIdentifier: targetPid) else { return }
        Activator.activateApp(app)
        mru.bump(targetPid)
    }

    /// Derive the in-panel action-key map (#5) from the BetterShortcuts
    /// `panelActionKeys` bindings and push it to the tap. Only the *keycode* is
    /// used — the chord's modifier is irrelevant in-panel (⌘ is held the whole
    /// time the switcher is open), so e.g. a stored ⌘W matches the physical W
    /// while switching. Re-derived on launch and on any shortcut change.
    private func pushPanelKeyBindings() {
        var map: [Int64: HotkeyTap.PanelActionKey] = [:]
        let pairs: [(BetterShortcuts.Name, HotkeyTap.PanelActionKey)] = [
            (.panelClose, .close),
            (.panelMinimize, .minimize),
            (.panelHide, .hide),
            (.panelQuit, .quit),
            (.panelFullscreen, .fullscreen),
        ]
        for (name, action) in pairs {
            guard let shortcut = BetterShortcuts.getShortcut(for: name) else { continue }
            map[Int64(shortcut.carbonKeyCode)] = action
        }
        hotkey.setPanelKeyBindings(map)
    }

    /// Derive the window-management chord map (#7) from the BetterShortcuts
    /// `windowMgmt` bindings and push it to the tap. The tap matches these while
    /// the switcher is open (arranging the highlighted window); the same bindings
    /// also fire globally via `WindowManagement` when the switcher is closed.
    /// Command is dropped from the chord bits — the switcher holds ⌘, so a stored
    /// ⌃⌘← reads as ⌃← inside the panel. Re-derived on launch and on any change.
    private func pushWindowMgmtBindings() {
        var map: [Int: HotkeyTap.Event] = [:]
        var fullMap: [Int: HotkeyTap.Event] = [:]
        let pairs: [(BetterShortcuts.Name, HotkeyTap.Event)] = [
            (.windowTileLeft, .tileLeft),
            (.windowTileRight, .tileRight),
            (.windowTileTopLeft, .tileTopLeft),
            (.windowTileTopRight, .tileTopRight),
            (.windowTileBottomLeft, .tileBottomLeft),
            (.windowTileBottomRight, .tileBottomRight),
            (.windowMaximize, .maximizeWindow),
            (.windowCenter, .centerWindow),
            (.windowRestorePrevious, .restoreWindowFrame),
        ]
        for (name, event) in pairs {
            guard let shortcut = BetterShortcuts.getShortcut(for: name) else { continue }
            // `carbonModifiers` is a Carbon bitmask.
            let m = shortcut.carbonModifiers
            let keyCode = Int64(shortcut.carbonKeyCode)
            var bits = 0
            if m & controlKey != 0 { bits |= 1 }
            if m & optionKey != 0 { bits |= 2 }
            if m & shiftKey != 0 { bits |= 4 }
            // In-switcher map: ⌘ excluded (the switcher holds it). A chord that's
            // ⌘-only in-panel (no other modifier) would collide with a bare key.
            if bits != 0 {
                map[HotkeyTap.wmChordKey(keyCode: keyCode, modBits: bits)] = event
            }
            // Global (switcher-closed) map: keep the full chord, ⌘ included.
            var fullBits = bits
            if m & cmdKey != 0 { fullBits |= 8 }
            if fullBits != 0 {
                fullMap[HotkeyTap.wmFullChordKey(keyCode: keyCode, modBits: fullBits)] = event
            }
        }
        // BetterShortcuts is the single source of truth: `getShortcut` resolves
        // the user binding or the declared default (BetterShortcuts ≥ 0.1.2), so
        // these maps are always derived here rather than from any hardcoded
        // chord table in the tap.
        hotkey.setWindowMgmtBindings(map)
        hotkey.setWindowMgmtGlobalBindings(fullMap)
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
        syncNativeHotkeyOverride()
    }

    /// Push the current "Ignore shortcuts" decision for the frontmost app to the
    /// tap. Cheap and only runs on frontmost/Space changes, so the per-keystroke
    /// path stays a single lock read.
    private func updateTriggerSuppression() {
        let front = NSWorkspace.shared.frontmostApplication
        guard let bid = front?.bundleIdentifier else {
            hotkey.setSuppressTrigger(false)
            return
        }
        let suppress: Bool
        switch Preferences.shared.ignoreMode(for: bid) {
        case .never: suppress = false
        case .always: suppress = true
        case .whenFullscreen: suppress = Self.focusedWindowIsFullscreen(pid: front?.processIdentifier ?? -1)
        }
        hotkey.setSuppressTrigger(suppress)
    }

    /// Whether the app's focused window is full screen, via the same AX
    /// `AXFullScreen` attribute the window scan reads. A short messaging timeout
    /// keeps a wedged app from stalling the main thread; any failure (no focused
    /// window, attribute absent, timeout) reads as "not full screen".
    private static func focusedWindowIsFullscreen(pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let windowValue = focused,
              CFGetTypeID(windowValue) == AXUIElementGetTypeID() else { return false }
        let window = windowValue as! AXUIElement
        var fullscreen: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &fullscreen) == .success else { return false }
        return (fullscreen as? Bool) ?? false
    }

    /// React to a Secure Event Input transition surfaced by `secureInputMonitor`:
    /// re-derive and apply the native-shortcut override for the new state.
    private func handleSecureInputChange(_ active: Bool) {
        secureInputActive = active
        syncNativeHotkeyOverride()
    }

    /// Re-derive the secure-input Carbon chords after an in-panel mode change
    /// (search on/off, drill on/off): the letter keys switch between letter-jump
    /// and search input, and the arrows between selection and tab stepping. A
    /// no-op outside secure input or with the panel closed.
    private func resyncSecureInputChords() {
        if secureInputActive && phase != .idle { syncNativeHotkeyOverride() }
    }

    /// Re-derive and apply the native-shortcut override (symbolic-hotkey disable +
    /// Carbon registration). The decision is pure — see `computeNativeOverridePlan`.
    /// Re-run whenever an input changes: trigger remap (`pushHotkeyConfig`),
    /// secure-input transition, or panel open/close while secure input is active.
    private func syncNativeHotkeyOverride() {
        // Restore escape hatch active: keep native ⌘Tab enabled and drop all our
        // Carbon chords until the next launch. The tap still opens our switcher
        // under normal input.
        if nativeOverrideSuspended {
            if holdMonitorRunning {
                holdMonitor.stop()
                holdMonitorRunning = false
            }
            applyOverridePlan(NativeOverridePlan(symbolicKeysToDisable: [], carbonChords: []))
            return
        }
        let app = Self.carbonTrigger(for: .switchApps, defaultKey: 48)
        let window = Self.carbonTrigger(for: .switchWindows, defaultKey: 50)
        let spec = TriggerSpec(
            appKeyCode: app.keyCode,
            appCarbonModifiers: app.carbonModifiers,
            appIsCommandOnly: app.isCommandOnly,
            windowKeyCode: window.keyCode,
            windowCarbonModifiers: window.carbonModifiers,
            windowIsCommandOnly: window.isCommandOnly
        )
        let panelOpen = phase != .idle
        // The hold-modifier poller detects ⌘-release (no event is delivered for
        // it under secure input) and supplies the live hold state that gates the
        // in-panel chords. Needed only while the panel is open under secure input.
        if secureInputActive && panelOpen {
            if !holdMonitorRunning {
                holdMonitor.start(mask: Self.holdMask(for: app.carbonModifiers), assumeHeld: true)
                holdMonitorRunning = true
            }
        } else if holdMonitorRunning {
            holdMonitor.stop()
            holdMonitorRunning = false
        }
        let plan = computeNativeOverridePlan(
            trigger: spec,
            secureInputActive: secureInputActive,
            panelOpen: panelOpen,
            holdModifierDown: holdMonitor.isHeld,
            searchActive: searchActive,
            tabDrillActive: tabDrillActive,
            panelActions: panelActionSpecs()
        )
        applyOverridePlan(plan)
    }

    /// The rebindable in-panel action keys (W/M/H/Q/F), in the pure plan's terms.
    /// Same source as `pushPanelKeyBindings` — only the keycode matters in-panel.
    private func panelActionSpecs() -> [PanelActionSpec] {
        let pairs: [(BetterShortcuts.Name, ChordSpec.Kind)] = [
            (.panelClose, .close),
            (.panelMinimize, .minimize),
            (.panelHide, .hide),
            (.panelQuit, .quit),
            (.panelFullscreen, .fullscreen),
        ]
        var specs: [PanelActionSpec] = []
        for (name, action) in pairs {
            guard let shortcut = BetterShortcuts.getShortcut(for: name) else { continue }
            specs.append(PanelActionSpec(keyCode: UInt32(shortcut.carbonKeyCode), action: action))
        }
        return specs
    }

    /// The `CGEventFlags` mask for the trigger's primary hold modifier, used by
    /// the poller to detect its release.
    private static func holdMask(for carbonModifiers: UInt32) -> CGEventFlags {
        if carbonModifiers & UInt32(cmdKey) != 0 { return .maskCommand }
        if carbonModifiers & UInt32(optionKey) != 0 { return .maskAlternate }
        if carbonModifiers & UInt32(controlKey) != 0 { return .maskControl }
        return .maskCommand
    }

    private func applyOverridePlan(_ plan: NativeOverridePlan) {
        let toDisable = plan.symbolicKeysToDisable.compactMap { PrivateAPI.SymbolicHotKey(rawValue: $0) }
        // Disable the symbolic hotkeys *before* registering: macOS reserves ⌘Tab
        // while its symbolic hotkey is enabled, so RegisterEventHotKey would fail.
        // Re-enable anything we previously disabled that's no longer in the set.
        if toDisable != disabledSymbolicKeys {
            let reEnable = disabledSymbolicKeys.filter { !toDisable.contains($0) }
            PrivateAPI.setNativeCommandTabEnabled(true, reEnable)
            PrivateAPI.setNativeCommandTabEnabled(false, toDisable)
            disabledSymbolicKeys = toDisable
            persistDisabledSymbolicKeys(toDisable)
        }
        carbonTrigger.update(plan.carbonChords.map { spec in
            CarbonHotkeyTrigger.Chord(
                keyCode: spec.keyCode,
                modifiers: spec.modifiers,
                event: Self.event(for: spec.kind, keyCode: spec.keyCode)
            )
        })
    }

    private static func event(for kind: ChordSpec.Kind, keyCode: UInt32) -> HotkeyTap.Event {
        switch kind {
        case .nextApp: return .nextApp
        case .prevApp: return .prevApp
        case .nextWindow: return .nextWindow
        case .prevWindow: return .prevWindow
        case .navUp: return .prevRow
        case .navDown: return .nextRow
        case .navLeft: return .spatialLeft
        case .navRight: return .spatialRight
        case .commit: return .commit
        case .escape: return .escape
        case .toggleSearch: return .toggleSearch
        case .searchBackspace: return .searchBackspace
        case .enterTabDrill: return .enterTabDrill
        case .exitTabDrill: return .exitTabDrill
        case .tabPrev: return .tabPrev
        case .tabNext: return .tabNext
        case .commitTab: return .commitTab
        // The pure plan has no layout context, so it tags alphanumeric chords by
        // keycode; resolve to a character at dispatch (`handle(_:)`).
        case .letterJump: return .letterInputKey(keyCode)
        case .searchChar: return .searchInputKey(keyCode)
        case .close: return .closeWindow
        case .minimize: return .minimizeWindow
        case .hide: return .hideApp
        case .quit: return .quitApp
        case .fullscreen: return .fullscreen
        }
    }

    /// Tear down OS-level state that outlives the process: re-enable the native
    /// symbolic hotkeys we suppressed (the disable persists after quit) and drop
    /// the Carbon hot keys. Call from `applicationWillTerminate`.
    /// Re-arm the CGEvent tap after Accessibility was revoked and re-granted at
    /// runtime. The revoked tap is dead — the system tears it down — so drop it
    /// and create a fresh one. Trigger config, panel keymaps and the Carbon
    /// fallback already live on the instance, so nothing else needs re-pushing.
    func reinstallHotkeyTap() {
        hotkey.uninstall()
        if hotkey.install() {
            hotkeyTapRetries = 0
            Log.switcher.log("CGEventTap re-armed after Accessibility re-grant")
        } else {
            Log.switcher.error("CGEventTap re-arm failed after Accessibility re-grant; retrying")
            scheduleHotkeyTapRetry()
        }
    }

    /// Retry a failed `hotkey.install()` on a short backoff. Only reached after an
    /// install that left the tap uncreated, so a plain `install()` (not a
    /// reinstall) is safe — there is no live tap to leak. Gives up after
    /// `maxHotkeyTapRetries`; the Carbon fallback keeps the trigger working
    /// regardless, and a later Accessibility re-grant re-arms via the waiter.
    private func scheduleHotkeyTapRetry() {
        guard hotkeyTapRetries < Self.maxHotkeyTapRetries else {
            Log.switcher.error("CGEventTap still failing after \(Self.maxHotkeyTapRetries) retries; relying on the Carbon fallback")
            return
        }
        hotkeyTapRetries += 1
        let attempt = hotkeyTapRetries
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            if self.hotkey.install() {
                self.hotkeyTapRetries = 0
                Log.switcher.log("CGEventTap installed on retry \(attempt)")
            } else {
                self.scheduleHotkeyTapRetry()
            }
        }
    }

    func shutdown() {
        secureInputMonitor.stop()
        holdMonitor.stop()
        holdMonitorRunning = false
        carbonTrigger.uninstall()
        if !disabledSymbolicKeys.isEmpty {
            PrivateAPI.setNativeCommandTabEnabled(true, disabledSymbolicKeys)
            disabledSymbolicKeys = []
        }
        persistDisabledSymbolicKeys([])
    }

    /// User-invoked recovery (Privacy pane "Restore macOS keyboard shortcuts").
    /// The native override is always-armed (the symbolic ⌘Tab is disabled the
    /// whole time the app runs, so our switcher wins the instant the tap goes deaf
    /// under Secure Event Input). A re-enable alone would be undone immediately by
    /// the next resync, so this *suspends* the override until the next launch:
    /// force-enable *every* native symbolic hotkey we could have disabled
    /// (regardless of the tracked `disabledSymbolicKeys` set, which can drift if a
    /// prior run exited uncleanly), then resync — which, suspended, drops all our
    /// Carbon chords and leaves the system's ⌘Tab alone. The user's native ⌘Tab
    /// stays back until they relaunch BetterCmdTab (the suspension is in-memory).
    private func restoreNativeShortcutsThenResync() {
        nativeOverrideSuspended = true
        PrivateAPI.setNativeCommandTabEnabled(true, [.commandTab, .commandShiftTab, .commandKeyAboveTab])
        disabledSymbolicKeys = []
        persistDisabledSymbolicKeys([])
        syncNativeHotkeyOverride()
    }

    /// Mirror the disabled symbolic-hotkey set into both the crash-restore guard
    /// (signal/atexit) and UserDefaults (next-launch self-heal).
    private func persistDisabledSymbolicKeys(_ keys: [PrivateAPI.SymbolicHotKey]) {
        let raw = keys.map(\.rawValue)
        SymbolicHotkeyGuard.setDisabled(raw)
        let defaults = UserDefaults.standard
        if raw.isEmpty {
            defaults.removeObject(forKey: Self.persistedDisabledKey)
        } else {
            // Store as `[Int]` — `[Int32]` does not round-trip cleanly through
            // UserDefaults' NSNumber bridging.
            defaults.set(raw.map(Int.init), forKey: Self.persistedDisabledKey)
        }
    }

    /// Re-enable any symbolic hotkeys a previous run disabled but never restored
    /// (crash / SIGKILL / power loss). Runs once at startup before the live
    /// config is applied; the normal `syncNativeHotkeyOverride` then re-disables
    /// whatever the current trigger actually needs.
    private func healStaleSymbolicHotkeyDisable() {
        let defaults = UserDefaults.standard
        guard let raw = defaults.array(forKey: Self.persistedDisabledKey) as? [Int], !raw.isEmpty else { return }
        let keys = raw.compactMap { PrivateAPI.SymbolicHotKey(rawValue: Int32($0)) }
        if !keys.isEmpty {
            PrivateAPI.setNativeCommandTabEnabled(true, keys)
        }
        defaults.removeObject(forKey: Self.persistedDisabledKey)
        SymbolicHotkeyGuard.setDisabled([])
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

    /// Carbon view of a configured trigger, for `RegisterEventHotKey` and native
    /// symbolic-hotkey matching. Mirrors `hotkeyTrigger(for:defaultKey:)` but in
    /// Carbon terms: a Carbon keycode + Carbon modifier mask, plus whether the
    /// hold modifier is exactly Command (used to decide symbolic-hotkey overlap).
    private struct CarbonTrigger {
        let keyCode: UInt32
        let carbonModifiers: UInt32
        let isCommandOnly: Bool
    }

    private static func carbonTrigger(
        for name: BetterShortcuts.Name,
        defaultKey: UInt32
    ) -> CarbonTrigger {
        guard let shortcut = BetterShortcuts.getShortcut(for: name) else {
            return CarbonTrigger(keyCode: defaultKey, carbonModifiers: UInt32(cmdKey), isCommandOnly: true)
        }
        let modifiers = shortcut.modifiers
        var carbon: UInt32 = 0
        if modifiers.contains(.command) { carbon |= UInt32(cmdKey) }
        if modifiers.contains(.option) { carbon |= UInt32(optionKey) }
        if modifiers.contains(.control) { carbon |= UInt32(controlKey) }
        if carbon == 0 { carbon = UInt32(cmdKey) }
        let isCommandOnly = modifiers.contains(.command)
            && !modifiers.contains(.option)
            && !modifiers.contains(.control)
            && !modifiers.contains(.shift)
        return CarbonTrigger(
            keyCode: UInt32(shortcut.carbonKeyCode),
            carbonModifiers: carbon,
            isCommandOnly: isCommandOnly
        )
    }

    private var phase: Phase {
        get { _phase }
        set {
            let wasIdle = _phase == .idle
            _phase = newValue
            hotkey.setSwitching(newValue.isSwitching)
            // Mirror the *visible* edge separately: the tap gates the in-panel
            // action keys + letter-jump on this so a panel-less `.primed` never
            // swallows ⌘W/⌘Q/etc. from the focused app (issue #16).
            hotkey.setPanelPresented(newValue.presentsPanel)
            // Liveness ceiling on `.primed` (see `primedWatchdog`). Arm on entry,
            // tear down on every other edge — `reveal()` → `.visible` and any
            // commit/cancel → `.idle` both pass through here, so the normal fast
            // path disarms it well before it could fire.
            if newValue.isPrimed {
                armPrimedWatchdog()
            } else {
                primedWatchdog?.invalidate()
                primedWatchdog = nil
            }
            // Returning to idle ends any scoped-shortcut open so the next plain
            // ⌘Tab is unfiltered. Single chokepoint — every exit path (commit,
            // cancel, dismiss) flows through here.
            if newValue == .idle {
                activeScope = nil
                scopeFrontPid = nil
            }
            // Under Secure Event Input the in-panel nav chords are registered only
            // while the panel is open, so re-sync on the open⇄close edge. Gated on
            // `secureInputActive` so the common ⌘Tab path stays zero-cost.
            if secureInputActive && wasIdle != (newValue == .idle) {
                syncNativeHotkeyOverride()
            }
        }
    }

    /// Open the switcher already filtered to `scope` (#3). Driven by a user
    /// scoped-shortcut via `ScopedSwitch.onTrigger`. Opens sticky (like a
    /// gesture/stay-open open) so releasing the shortcut's own modifier doesn't
    /// commit — the user steps with Tab/arrows/scroll and commits with Return or
    /// a click, or dismisses with Esc. Ignored if the switcher is already open.
    func openScoped(_ scope: SwitchScope) {
        guard phase == .idle else { return }
        mru.syncFrontmost()
        cache.scheduleFullRefresh()
        let selfPid = getpid()
        // The frontmost app at trigger time (we're accessory, so it's the user's
        // real app) — needed for the current-app scope.
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != selfPid {
            scopeFrontPid = front.processIdentifier
        } else {
            scopeFrontPid = nil
        }
        activeScope = scope
        primedApps = AppCatalog.fastAppList(orderedBy: mru.order)
        primedIndex = 0
        phase = .primed
        reveal()
        // reveal() may cancel back to idle (nothing matched the scope); only
        // stick if it actually presented.
        if phase == .visible { stickyOpen = true }
    }

    /// Filter `rows` to the active scope. Operates on already content-filtered
    /// rows (the user's hide/minimized/space toggles still apply); the scope
    /// narrows further. `.allAppsAllSpaces` only escapes the current-Space
    /// toggle when that toggle is off (the cache already dropped other-Space
    /// windows otherwise — documented edge case).
    private func scopeFiltered(_ rows: [SwitcherRow], scope: SwitchScope) -> [SwitcherRow] {
        let windowed = rows.filter { $0.window != nil }
        let filtered: [SwitcherRow]
        switch scope {
        case .allAppsAllSpaces:
            filtered = windowed
        case .allAppsCurrentSpace:
            filtered = CatalogFilter.filterToCurrentSpace(windowed)
        case .currentAppWindows:
            if let pid = scopeFrontPid {
                filtered = windowed.filter { $0.pid == pid }
            } else {
                filtered = []
            }
        case .minimizedOnly:
            filtered = windowed.filter { $0.isMinimized }
        }
        // Never dead-end: if the scope matched nothing but there are windows to
        // show, fall back to all windows so the shortcut still opens a useful
        // panel instead of a silent no-op (e.g. "Minimized" bound while nothing
        // is minimized, or "Current app" when the front app has no AX windows).
        if filtered.isEmpty && !windowed.isEmpty {
            return windowed
        }
        return filtered
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

    func switcherViewDidSelectTab(_ index: Int) {
        guard tabDrillActive, tabTitles.indices.contains(index) else { return }
        tabIndex = index
        commitTab()
    }

    func switcherViewDidHoverTab(_ index: Int) {
        guard tabDrillActive, tabTitles.indices.contains(index), index != tabIndex else { return }
        tabIndex = index
        view.setTabStripSelectedIndex(tabIndex)
    }

    func switcherViewDidHover(index: Int) {
        guard phase == .visible else { return }
        guard rows.indices.contains(index), index != self.index else { return }
        // Moving the selection off the drilled-in row drops drill mode — the
        // strip belongs to the previous row's tabs.
        if tabDrillActive { exitTabDrill() }
        self.index = index
        view.setSelectedIndex(index)
        schedulePrefetchForCurrentSelection()
    }

    func switcherViewDidClick(index: Int) {
        guard phase == .visible else { return }
        guard rows.indices.contains(index) else { return }
        if tabDrillActive { exitTabDrill() }
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
        case .forceQuit:
            performForceQuitAction()
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
        case .tileLeft:
            arrangeFrontmost(.tileLeftHalf)
        case .tileRight:
            arrangeFrontmost(.tileRightHalf)
        case .tileTopLeft:
            arrangeFrontmost(.tileTopLeft)
        case .tileTopRight:
            arrangeFrontmost(.tileTopRight)
        case .tileBottomLeft:
            arrangeFrontmost(.tileBottomLeft)
        case .tileBottomRight:
            arrangeFrontmost(.tileBottomRight)
        case .maximizeWindow:
            arrangeFrontmost(.maximize)
        case .centerWindow:
            arrangeFrontmost(.center)
        case .restoreWindowFrame:
            performRestoreFrame()
        case .releaseCmd:
            handleModifierRelease()
        case .commit:
            commit()
        case .escape:
            if searchActive { exitSearch() } else { cancel() }
        case .dismiss:
            // Click outside the panel: always fully dismiss, even mid-search or
            // drilled into a tab strip, leaving the current window focused.
            cancel()
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
        case .fullscreen:
            performOnVisibleTarget { Activator.toggleFullscreen($0) }
        case .hideApp:
            performOnVisibleTarget { Activator.hideApp($0) }
        case .quitApp:
            performQuitAction()
        case .forceQuitApp:
            performForceQuitAction()
        case .enterTabDrill:
            enterTabDrill()
        case .exitTabDrill:
            exitTabDrill()
        case .tabPrev:
            advanceTab(by: -1)
        case .tabNext:
            advanceTab(by: 1)
        case .commitTab:
            commitTab()
        case .letterInput(let ch):
            handleLetter(ch)
        case .letterInputKey(let keyCode):
            // Secure-input Carbon path: resolve the keycode for the current
            // layout, matching the tap's plain letter-jump (lowercased).
            if let ch = KeyboardLayout.character(for: UInt16(keyCode)) {
                handleLetter(Character(ch.lowercased()))
            }
        case .searchInputKey(let keyCode):
            if let ch = KeyboardLayout.character(for: UInt16(keyCode)) {
                handleSearchInput(ch)
            }
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
        let timer = Timer(timeInterval: letterChainTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                // Timeout elapsed: drop the prefix AND restore the pre-typing
                // display — `resetLetterBuffer` clears the buffer and refreshes,
                // so the highlight disappears and the rows return to the order
                // they had before the letters were typed.
                self?.resetLetterBuffer()
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
            // Reaching here from the Carbon fallback means the tap was bypassed —
            // strong evidence Secure Event Input is active. Re-check now to shrink
            // the poll-gap window so the in-panel nav chords arm before the reveal.
            secureInputMonitor.refresh()
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
            // before reveal() freezes the snapshot. Catches manual clicks the
            // user made between Cmd+` chords that our own activations did not
            // see. Resolved off-main (the AX query can stall on an unresponsive
            // app — never block the main run loop here): the bump is not consumed
            // synchronously below (the snapshot is sorted later, on the reveal
            // timer), so it can land asynchronously and still order this chord.
            handleFocusChange(pid: front.processIdentifier)
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
            // A Carbon chord opening the switcher means the tap was bypassed —
            // re-check Secure Event Input now (see advanceWindowsOnly).
            secureInputMonitor.refresh()
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
        schedulePrefetchForCurrentSelection()
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

    /// Arm the `.primed` liveness watchdog (see `primedWatchdog`). A classic
    /// run-loop timer in `.common` modes, mirroring `revealTimer`'s scheduling;
    /// the MainActor hop keeps the force-cancel on the main thread. Re-checks
    /// `phase` on fire, so a normal primed→visible/idle transition that already
    /// disarmed it — or a later re-armed `.primed` — makes the stale fire a no-op.
    private func armPrimedWatchdog() {
        primedWatchdog?.invalidate()
        let timer = Timer(timeInterval: Self.primedWatchdogTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.phase.isPrimed else { return }
                Log.switcher.warning("primed phase exceeded watchdog ceiling — forcing idle")
                self.cancel()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        primedWatchdog = timer
    }

    private func schedulePrimedReveal() {
        phase = .primed
        // Resolve the user's current window off-main now, while we wait out the
        // tap-vs-hold delay, so reveal() doesn't stall its critical path on a
        // synchronous AX read (up to 0.25s when the frontmost app is busy).
        prefetchOpenFocusedWindow()
        // Inline browser-tab mode: warm the per-window tab cache during the same
        // hold delay so the first reveal expands straight to tabs instead of
        // showing windows that flicker into tabs after the Apple Events round-trip.
        prewarmBrowserTabs()
        revealTimer?.invalidate()
        let timer = Timer(timeInterval: revealDelay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reveal()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        revealTimer = timer
    }

    /// Resolve the frontmost app's focused window off the main thread during the
    /// primed phase so the work overlaps the reveal delay instead of stalling
    /// `reveal()`. `openFocusedWindow` is what window-management chords act on
    /// for the whole open session; the frontmost pid is captured now (cheap, on
    /// main, while the user's app is still frontmost) and the blocking AX read
    /// runs off-main. `reveal()` consumes the result, or falls back to a
    /// synchronous read if this hasn't landed yet (e.g. an immediate reveal that
    /// skips the primed timer).
    private func prefetchOpenFocusedWindow() {
        prefetchedFocusedWindow = nil
        let selfPid = getpid()
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != selfPid else { return }
        let pid = front.processIdentifier
        focusedWindowCaptureGen &+= 1
        let gen = focusedWindowCaptureGen
        DispatchQueue.global(qos: .userInteractive).async {
            let window = Activator.focusedWindow(pid: pid)
            DispatchQueue.main.async { [weak self] in
                // `.primed` only: reveal() consumes + nils this and flips to
                // `.visible`, so a landing after reveal (or after a cancel to
                // `.idle`) is unwanted and must be dropped — otherwise it would
                // re-arm a stale capture that a later gesture/scoped open (which
                // skip the primed prefetch) would adopt.
                guard let self, gen == self.focusedWindowCaptureGen, self.phase == .primed else { return }
                self.prefetchedFocusedWindow = window
            }
        }
    }

    private func reveal() {
        guard phase == .primed else { return }
        tabDrillHint = nil
        mru.syncFrontmost()
        // Remember who was frontmost so `cancel()` can restore them — captured
        // before `panel.present()` activates us (which it does so the server
        // renders the glass backdrop active). Ignore us as the "previous" app.
        let front = NSWorkspace.shared.frontmostApplication
        previousFrontmostApp = (front?.processIdentifier == getpid()) ? nil : front
        // Capture the user's current window BEFORE `panel.present()` makes our
        // key panel frontmost — a live read afterwards returns BetterCmdTab and
        // window-management chords would no-op. This is the window WM acts on
        // for the whole open session, regardless of which row is highlighted.
        // Prefer the window `prefetchOpenFocusedWindow()` resolved off-main during
        // the primed delay; fall back to a synchronous AX read only when that
        // hasn't landed (e.g. gesture/scoped opens that skip the primed timer).
        // Either way `openFocusedWindow` is assigned fresh on every reveal.
        openFocusedWindow = prefetchedFocusedWindow ?? Activator.frontmostFocusedWindow()
        prefetchedFocusedWindow = nil
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
        // Scoped-shortcut open: narrow the row set to the chosen subset. Only on
        // the warm (real-row) branch — cold placeholder rows have no windows yet,
        // so the background `applyFullSnapshot` below applies the scope once the
        // real scan lands. nil scope (normal ⌘Tab) leaves rows untouched.
        if let scope = activeScope, hadCachedRows {
            baseRows = scopeFiltered(baseRows, scope: scope)
            baseLabels = RowLabels.labels(for: baseRows)
            rows = baseRows
            labels = baseLabels
            index = 0
        }
        // Expand inline browser-tab rows from the persisted per-session cache so a
        // re-open shows tabs immediately instead of windows-then-flicker. The
        // background re-scan re-derives its collapsed source from `baseRows`.
        let expandedAtReveal = expandBrowserTabs(baseRows)
        if expandedAtReveal.count != baseRows.count {
            let selectedPid = rows.indices.contains(index) ? rows[index].pid : targetPid
            baseRows = expandedAtReveal
            baseLabels = RowLabels.labels(for: baseRows)
            rows = baseRows
            labels = baseLabels
            if let pid = selectedPid, let match = rows.firstIndex(where: { $0.pid == pid }) {
                index = match
            } else {
                index = max(0, min(index, rows.count - 1))
            }
        }
        guard !rows.isEmpty else { cancel(); return }

        currentMetrics = SwitcherMetrics.forScreen(SwitcherPanel.preferredScreen(), layoutMode: Preferences.shared.switcherLayoutMode, userScale: Preferences.shared.panelSize.scale, letterHints: Preferences.shared.letterHintsEnabled)
        view.configure(rows: rows, labels: displayLabels, selectedIndex: index, metrics: currentMetrics, highlightPrefix: letterBuffer)
        panel.present()
        phase = .visible
        cache.setPanelVisible(true)
        // Inline browser-tab mode: start scanning the visible browser windows'
        // tabs now so the rows expand as soon as Apple Events answers. Self-
        // guards on the pref; a no-op on the cold (placeholder) branch since
        // those rows carry no windows yet — the post-scan apply kicks it again.
        scheduleBrowserTabExpansion()

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

        // Drop apps being quit so a background refresh doesn't re-add one as a
        // windowless row during its death gap (see `quittingPids`).
        var next = filterQuitting(fresh)
        // Scoped open: narrow the refreshed snapshot the same way the reveal did.
        // If the scope empties it, keep the current rows rather than cancelling —
        // a transient empty refresh shouldn't tear the panel down.
        if let scope = activeScope {
            next = scopeFiltered(next, scope: scope)
            if next.isEmpty { return }
        }

        // `refreshDisplay` preserves the user's current selection by identity so
        // a Tab press landing between reveal-from-cache and this
        // background-refreshed apply isn't reverted to the originally-primed
        // app, falling back to `anchorPid` only if the row is gone.
        // Re-expand inline browser-tab rows from the (warm) per-session cache so a
        // background refresh doesn't visibly collapse them back to one row; then
        // scan any browser window that newly appeared.
        baseRows = expandBrowserTabs(next)
        baseLabels = RowLabels.labels(for: baseRows)
        refreshDisplay(anchorPid: anchorPid)
        scheduleBrowserTabExpansion()
    }

    /// pids with a focused-window resolve in flight, so a burst of focus-change
    /// notifications for the same app collapses to one off-main AX read.
    private var focusSyncInFlight: Set<pid_t> = []

    /// React to a focus change without blocking the main thread: resolve the
    /// pid's focused window off-main (the AX query can stall on an unresponsive
    /// app), then bump the window MRU on main. Coalesced per pid.
    private func handleFocusChange(pid: pid_t) {
        guard !focusSyncInFlight.contains(pid) else { return }
        focusSyncInFlight.insert(pid)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let wid = WindowMRUTracker.focusedWindowID(pid: pid)
            DispatchQueue.main.async {
                guard let self else { return }
                self.focusSyncInFlight.remove(pid)
                if wid != 0 { self.windowMRU.bump(pid: pid, wid: wid) }
            }
        }
    }

    private var visibleTitleRefreshScheduled = false

    /// Coalesce title-change notifications that arrive while the panel is open
    /// into a single refresh after a short settle, so a burst (a page loading,
    /// a terminal scrolling) costs one pass rather than dozens.
    ///
    /// Deliberately does NOT trigger a full catalog re-scan: it only re-reads
    /// the `kAXTitleAttribute` of the windows already on screen (off-main, since
    /// the read can stall), then patches just those rows. A background browser
    /// churning titles can't drag the whole app into repeated full scans.
    private func scheduleVisibleTitleRefresh() {
        guard phase == .visible, !visibleTitleRefreshScheduled else { return }
        visibleTitleRefreshScheduled = true
        let gen = revealGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            self.visibleTitleRefreshScheduled = false
            guard self.phase == .visible, gen == self.revealGeneration else { return }
            // A browser window's title changes when its tabs are opened/closed/
            // switched, so reuse this title-change signal to re-scan its tabs
            // immediately — the event-driven path that keeps the inline tab rows
            // in near-instant sync with the browser without any idle polling.
            // Self-filters to browser windows and is rate-limited, so calling it
            // on every visible title change is cheap.
            self.scheduleBrowserTabExpansion(force: true)
            let windows = self.baseRows.compactMap(\.window)
            guard !windows.isEmpty else { return }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                var titles: [AXRef: String] = [:]
                for w in windows {
                    AXUIElementSetMessagingTimeout(w, 0.05)
                    var v: AnyObject?
                    if AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &v) == .success,
                       let t = v as? String {
                        titles[AXRef(element: w)] = t
                    }
                }
                DispatchQueue.main.async {
                    guard let self, gen == self.revealGeneration, self.phase == .visible else { return }
                    var changed = false
                    let patched = self.baseRows.map { row -> SwitcherRow in
                        // Skip inline browser-tab rows: they all share the parent
                        // browser window, whose AX title is just the *active* tab —
                        // patching here would stamp that one title (e.g. "New Tab")
                        // onto every tab row. Their per-tab titles come from the
                        // AppleScript scan (`browserTabsCache`) instead.
                        guard row.browserTab == nil,
                              let w = row.window,
                              let t = titles[AXRef(element: w)],
                              t != row.windowTitle else { return row }
                        changed = true
                        return row.withWindowTitle(t)
                    }
                    guard changed else { return }
                    self.baseRows = patched
                    self.baseLabels = RowLabels.labels(for: self.baseRows)
                    self.refreshDisplay()
                }
            }
        }
    }

    // MARK: - Inline browser-tab expansion

    /// Replace each browser-family window row with one row per tab, using titles
    /// already resolved in `browserTabsCache`. Rows whose tabs aren't cached yet
    /// (or resolved to <2 tabs) stay collapsed until the background scan lands.
    /// Already-expanded tab rows pass through untouched, so re-applying is
    /// idempotent. No-op (returns the input) when the pref is off — pure, no AX.
    private func expandBrowserTabs(_ source: [SwitcherRow]) -> [SwitcherRow] {
        guard Preferences.shared.expandBrowserTabsAsWindows else { return source }
        var out: [SwitcherRow] = []
        out.reserveCapacity(source.count)
        for row in source {
            guard row.browserTab == nil,
                  let window = row.window,
                  BrowserTabs.Family.from(bundleID: row.bundleIdentifier) != nil,
                  let titles = browserTabsCache[AXRef(element: window)],
                  titles.count > 1 else { out.append(row); continue }
            out.append(contentsOf: row.browserTabRows(tabTitles: titles))
        }
        return out
    }

    /// Kick a background Apple Events scan for every collapsed browser window in
    /// `collapsedBrowserSource()`, then splice the results in. Runs off-main (each
    /// `BrowserTabs.tabTitles` is a blocking osascript round-trip) and uses the
    /// name-match path (no raise) so listing tabs never reorders the browser's
    /// windows. Windows with an empty/ambiguous title are skipped — resolving them
    /// would need a raise, which the user would see as the panel silently
    /// shuffling windows. The persisted cache means a re-open already shows tabs;
    /// this re-scan only refreshes entries older than `browserTabsCacheTTL` (or
    /// never fetched), so opening rapidly doesn't re-spawn osascript every time.
    /// Re-derive the collapsed (one-row-per-window) source from the currently
    /// displayed `baseRows` — the inverse of `expandBrowserTabs`. Computed on
    /// demand so it always reflects direct `baseRows` edits (a window close, an
    /// app quit, a title patch) and can never resurrect a row a parallel array
    /// would have gone stale on.
    private func collapsedBrowserSource() -> [SwitcherRow] {
        guard baseRows.contains(where: { $0.browserTab != nil }) else { return baseRows }
        var out: [SwitcherRow] = []
        out.reserveCapacity(baseRows.count)
        var emitted = Set<AXRef>()
        for row in baseRows {
            guard row.browserTab != nil, let window = row.window else {
                out.append(row); continue
            }
            // One window row per distinct browser window; drop its other tab rows.
            if emitted.insert(AXRef(element: window)).inserted {
                out.append(row.collapsedFromBrowserTab())
            }
        }
        return out
    }

    /// Scan the browser windows in `rows` and refresh `browserTabsCache`, then
    /// re-expand. One batched osascript per browser app (see
    /// `BrowserTabs.allWindowTabs`) instead of one per window. Used for the
    /// reveal-time scan, the pre-roll pre-warm, and event-driven syncs.
    ///
    /// `force` bypasses the per-window TTL (for a title-change event, so a tab
    /// add/close/switch syncs immediately) but is rate-limited by
    /// `forcedBrowserScanMinInterval` so page-load title churn can't spam
    /// osascript. `onDone` runs on the main actor after the cache is updated.
    private func scanBrowserTabs(rows: [SwitcherRow], force: Bool, onDone: (() -> Void)? = nil) {
        guard Preferences.shared.expandBrowserTabsAsWindows else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if force, now - lastForcedBrowserScanAt < Self.forcedBrowserScanMinInterval { return }

        struct Target { let window: AXUIElement; let title: String; let key: AXRef }
        var byApp: [pid_t: (app: NSRunningApplication, wins: [Target])] = [:]
        var liveKeys = Set<AXRef>()
        for row in rows {
            guard row.browserTab == nil,
                  let window = row.window, let app = row.app,
                  BrowserTabs.Family.from(bundleID: app.bundleIdentifier) != nil,
                  !Self.isOwnProcess(app),
                  !row.windowTitle.isEmpty else { continue }
            let key = AXRef(element: window)
            liveKeys.insert(key)
            if browserTabsFetchInFlight.contains(key) { continue }
            // Skip a window whose cache entry is still fresh (unless forced); fall
            // through when it's missing or older than the TTL so tab add/close shows.
            if !force, let stamp = browserTabsCacheStamp[key], now - stamp < Self.browserTabsCacheTTL { continue }
            byApp[app.processIdentifier, default: (app, [])].wins.append(
                Target(window: window, title: row.windowTitle, key: key)
            )
        }
        // The cache persists across opens, so prune entries for browser windows
        // that are no longer present (closed since last seen) — keeps it bounded
        // to the currently-open browser windows over a long session.
        if browserTabsCache.contains(where: { !liveKeys.contains($0.key) }) {
            browserTabsCache = browserTabsCache.filter { liveKeys.contains($0.key) }
            browserTabsCacheStamp = browserTabsCacheStamp.filter { liveKeys.contains($0.key) }
        }
        guard !byApp.isEmpty else { return }
        if force { lastForcedBrowserScanAt = now }
        for (_, entry) in byApp { for t in entry.wins { browserTabsFetchInFlight.insert(t.key) } }
        let apps = Array(byApp.values)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var fetched: [AXRef: [String]] = [:]
            for entry in apps {
                // A browser window's AX kAXTitleAttribute reflects its ACTIVE TAB,
                // not the AppleScript window title (e.g. Arc reports "Arc" as the
                // window title but the AX title is the active tab's title). Match AX
                // titles against each window's active-tab title first, then the
                // window title, then fall back to a direct 1:1 map for a single
                // window. Titles that aren't unique are left collapsed (cached []).
                let perWindow = BrowserTabs.allWindowTabs(for: entry.app)
                var activeCounts: [String: Int] = [:]
                var byActive: [String: [String]] = [:]
                var titleCounts: [String: Int] = [:]
                var byTitle: [String: [String]] = [:]
                for w in perWindow {
                    let a = w.activeTab.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !a.isEmpty { activeCounts[a, default: 0] += 1; byActive[a] = w.tabs }
                    let t = w.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { titleCounts[t, default: 0] += 1; byTitle[t] = w.tabs }
                }
                for t in entry.wins {
                    let k = t.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    if activeCounts[k] == 1 {
                        fetched[t.key] = byActive[k] ?? []
                    } else if titleCounts[k] == 1 {
                        fetched[t.key] = byTitle[k] ?? []
                    } else if perWindow.count == 1 && entry.wins.count == 1 {
                        fetched[t.key] = perWindow[0].tabs
                    } else {
                        // Negative-cache (empty) a missing/ambiguous window so we
                        // don't re-spawn osascript for it every tick this session.
                        fetched[t.key] = []
                    }
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                let stamp = ProcessInfo.processInfo.systemUptime
                for (k, v) in fetched {
                    self.browserTabsFetchInFlight.remove(k)
                    self.browserTabsCache[k] = v
                    self.browserTabsCacheStamp[k] = stamp
                }
                onDone?()
            }
        }
    }

    /// Reveal-time / post-action browser-tab scan over the currently displayed
    /// rows. `force` is set for event-driven syncs (a title change).
    private func scheduleBrowserTabExpansion(force: Bool = false) {
        guard Preferences.shared.expandBrowserTabsAsWindows, phase == .visible else { return }
        scanBrowserTabs(rows: collapsedBrowserSource(), force: force) { [weak self] in
            self?.reExpandBrowserTabs()
        }
    }

    /// Pre-warm the browser-tab cache during the primed phase (while ⌘ is held,
    /// before the panel paints) from the catalog cache's windows, so the first
    /// reveal expands straight to tabs instead of showing windows that flicker
    /// into tabs ~1-2 s later. Throttled by the per-window TTL, so rapid ⌘Tab
    /// cycling doesn't re-spawn osascript. The completion re-expands only if the
    /// panel is already visible by the time it lands (otherwise `reveal()` picks
    /// up the now-warm cache itself).
    private func prewarmBrowserTabs() {
        guard Preferences.shared.expandBrowserTabsAsWindows else { return }
        scanBrowserTabs(rows: cache.rows(orderedBy: mru.order), force: false) { [weak self] in
            self?.reExpandBrowserTabs()
        }
    }

    /// Re-derive the expanded `baseRows` from `collapsedBrowserSource()` after a scan
    /// landed (or after an optimistic cache edit) and re-render. By default skips
    /// the re-render only when nothing visible changed — a tab added/closed
    /// (count) OR any tab's title updated (e.g. "New Tab" → the loaded page title);
    /// `force` re-renders regardless (used after closing a tab).
    private func reExpandBrowserTabs(force: Bool = false) {
        guard phase == .visible else { return }
        let expanded = expandBrowserTabs(collapsedBrowserSource())
        guard force || Self.rowsDifferVisibly(expanded, baseRows) else { return }
        baseRows = expanded
        baseLabels = RowLabels.labels(for: baseRows)
        refreshDisplay()
    }

    /// Whether two row sequences differ in a way the user would see — a different
    /// count, or any row whose displayed title changed. Used so a browser-tab
    /// re-scan that loaded new titles (same tab count) still re-renders.
    private static func rowsDifferVisibly(_ a: [SwitcherRow], _ b: [SwitcherRow]) -> Bool {
        guard a.count == b.count else { return true }
        for (x, y) in zip(a, b) where x.windowTitle != y.windowTitle { return true }
        return false
    }

    /// Called whenever the panel ends. Deliberately KEEPS `browserTabsCache` (and
    /// its staleness stamps) so the next open expands instantly from cache instead
    /// of showing collapsed windows that flicker into tabs after the Apple Events
    /// round-trip; only the in-flight set is cleared so a fetch interrupted by the
    /// dismiss (its result dropped by the `phase == .visible` guard) can re-run.
    /// The cache lives for the process; stale entries are refreshed by the
    /// TTL-gated re-scan and harmless dead-window entries are never read again.
    private func clearBrowserTabExpansion() {
        browserTabsFetchInFlight.removeAll()
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
        // Drilled-in commits go through the tab activation path instead of
        // activating the parent window.
        if tabDrillActive {
            commitTab()
            return
        }
        revealTimer?.invalidate()
        revealTimer = nil
        let currentPhase = phase
        let instantSpace = Preferences.shared.experimentalInstantSpaceSwitch
        var pendingActivation: (() -> Void)? = nil

        switch currentPhase {
        case .visible:
            if rows.indices.contains(index) {
                let row = rows[index]
                if let bt = row.browserTab, let app = row.app, let window = row.window {
                    // Inline browser-tab row: select the tab via Apple Events
                    // (it isn't a real window). Bump the app MRU but not window
                    // MRU — all of a window's tab rows share one cgWindowID.
                    if let pid = row.pid { mru.bump(pid) }
                    let tabIndex = bt.index
                    let parentTitle = bt.parentTitle
                    pendingActivation = {
                        DispatchQueue.global(qos: .userInitiated).async {
                            _ = BrowserTabs.activateTab(at: tabIndex, in: app, window: window, title: parentTitle)
                        }
                    }
                } else {
                    if let pid = row.pid { mru.bump(pid) }
                    bumpWindowMRUIfPossible(for: row)
                    pendingActivation = { Activator.activate(row, instantSpace: instantSpace) }
                }
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
        // Activate BEFORE dismissing the panel: `panel.dismiss()` calls
        // `orderOut(nil)`, surrendering our window/focus to the WindowServer.
        // If that ran first, the synchronous AX focus writes inside the
        // activation could be routed elsewhere and the target window would not
        // end up focused. Running the activation first keeps focus deterministic.
        if pendingActivation != nil { CommitFeedback.play() }
        pendingActivation?()
        panel.dismiss()
        primedApps = []
        rows = []
        baseRows = []
        baseLabels = []
        windowsOnlyMode = false
        windowsOnlyPid = nil
        windowsOnlyPrimedDelta = 0
        closedTombstones.removeAll()
        quittingPids.removeAll()
        clearBrowserTabExpansion()
        // Drop any focused-window prefetch so it can't survive into the next
        // session and be adopted by a gesture/scoped open that skips the primed
        // prefetch (those call reveal() directly).
        prefetchedFocusedWindow = nil
        // We picked a target — `pendingActivation` activates it, so there's
        // nothing to restore. Drop the captured previous app.
        previousFrontmostApp = nil
        resetLetterBuffer()
        resetSearch()
        view.releaseIdleResources()
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
        quittingPids.removeAll()
        tabDrillActive = false
        tabDrillHint = nil
        tabTitles = []
        liveTabElements = []
        tabIndex = 0
        drillWindow = nil
        hotkey.setTabDrillActive(false)
        tabPrefetchCache.removeAll()
        tabPrefetchInFlight.removeAll()
        tabPrefetchTimer?.invalidate()
        tabPrefetchTimer = nil
        clearBrowserTabExpansion()
        resetLetterBuffer()
        resetSearch()
        openFocusedWindow = nil
        prefetchedFocusedWindow = nil
        view.releaseIdleResources()
        // Dismissing without picking: undo the self-activation `present()` did for
        // the glass backdrop and put the user back in the app they came from.
        restorePreviousFrontmostApp()
    }

    /// Re-activate whatever app was frontmost when the switcher opened (captured
    /// in `reveal()`), undoing `present()`'s self-activation. No-op if there was
    /// none or it has since quit.
    private func restorePreviousFrontmostApp() {
        guard let app = previousFrontmostApp, !app.isTerminated else {
            previousFrontmostApp = nil
            return
        }
        previousFrontmostApp = nil
        if #available(macOS 14.0, *) {
            _ = app.activate(from: .current, options: [])
        } else {
            app.activate(options: [.activateIgnoringOtherApps])
        }
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

    /// Window-management chords act on the window that was current when the
    /// switcher opened (`openFocusedWindow`), not the highlighted row. A live
    /// `frontmostApplication` read can't be used here: once our key panel is on
    /// screen the system reports BetterCmdTab as frontmost, so the chord would
    /// no-op. The switcher stays open so chords can be chained.
    private func arrangeFrontmost(_ arrangement: WindowArrangement) {
        if phase == .visible {
            guard let window = openFocusedWindow else { return }
            Activator.arrange(window: window, arrangement)
            scheduleVisibleRefresh(after: 0.25)
        } else {
            // Switcher closed: the global tap chord delivered this. Act on the
            // live frontmost window — no panel is up, so it's the user's app.
            Activator.arrangeFrontmostWindow(arrangement)
        }
    }

    /// Move the current window to the adjacent display in `direction`. While the
    /// switcher is open this targets the window captured at open and the panel
    /// stays open so the move can be repeated; closed, it moves the live
    /// frontmost window.
    private func performMove(_ direction: MoveDirection) {
        if phase == .visible {
            guard let window = openFocusedWindow else { return }
            Activator.moveToDisplay(window: window, direction: direction)
            scheduleVisibleRefresh(after: 0.2)
        } else {
            Activator.moveFrontmostWindowToDisplay(direction: direction)
        }
    }

    /// Restore the current window to the frame captured before its last arrange /
    /// move (⌃⌘⌫ by default). Open: acts on the window captured at open and keeps
    /// the panel up so it can be repeated; closed: the live frontmost window.
    private func performRestoreFrame() {
        if phase == .visible {
            guard let window = openFocusedWindow else { return }
            Activator.restoreFrame(window: window)
            scheduleVisibleRefresh(after: 0.25)
        } else {
            Activator.restoreFrontmostWindowFrame()
        }
    }

    private func performQuitAction() {
        quitVisibleTarget(force: false)
    }

    /// Quit (or force-quit) the highlighted app and drop it from the switcher
    /// immediately. Unlike closing a single window, quitting removes the whole
    /// app, so we must NOT demote it to a windowless row — that's the brief
    /// "no windows" flash the user sees while the app's windows close before the
    /// process actually terminates. `quittingPids` suppresses re-adds from the
    /// refresh until `handleAppTerminated` fires; a safety timeout un-suppresses
    /// the app if the quit was vetoed (e.g. an unsaved-changes dialog).
    private func quitVisibleTarget(force: Bool) {
        guard phase == .visible, rows.indices.contains(index) else { return }
        let row = rows[index]
        guard !row.isSystemDialog else { return }
        guard let pid = row.pid else { return }
        // Record an app-level entry (no document) so a quit app can be relaunched
        // from recently-closed search. Regular apps only — system dialog hosts
        // shouldn't be reopenable.
        if row.app?.activationPolicy == .regular, let bundleID = row.bundleIdentifier {
            RecentlyClosedStore.shared.record(
                bundleID: bundleID,
                appName: row.appName,
                title: "",
                documentPath: nil
            )
        }
        if force {
            Activator.forceQuitApp(row)
        } else {
            Activator.quitApp(row)
        }

        quittingPids.insert(pid)
        baseRows.removeAll { $0.pid == pid }
        if baseRows.isEmpty {
            cancel()
            return
        }
        baseLabels = RowLabels.labels(for: baseRows)
        refreshDisplay()
        scheduleVisibleRefresh(after: 0.25)

        // Safety net: if the app is still alive after the grace (quit vetoed by a
        // save dialog, a modal, etc.), stop suppressing it so it reappears.
        let gen = revealGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + quitSuppressTTL) { [weak self] in
            guard let self, gen == self.revealGeneration else { return }
            guard self.quittingPids.remove(pid) != nil, self.phase == .visible else { return }
            self.scheduleVisibleRefresh()
        }
    }

    // MARK: - Browser tab drill-in

    /// Drill into the highlighted row's tab group. Two backends:
    /// - **AppleScript** for known browser families (Safari, Chrome, Arc,
    ///   Brave, Edge, Vivaldi, Opera, Dia). AX scraping is unreliable across
    ///   browser versions — the scripting dictionaries are stable.
    /// - **Accessibility** as a fallback for AppKit-native tabbed apps
    ///   (Finder, Terminal, iTerm) by recursive AX walk for the first tab
    ///   group.
    /// Both run off-main; the strip appears once titles land. Silently
    /// no-ops if no tabs are found.
    private func enterTabDrill() {
        guard Preferences.shared.tabDrillEnabled else { return }
        guard phase == .visible, rows.indices.contains(index) else { return }
        let row = rows[index]
        // Already an inline browser-tab row — it *is* a tab, so there's nothing
        // further to drill (its window is the parent browser window).
        guard row.browserTab == nil else { return }
        guard let window = row.window, let app = row.app else { return }
        // Native macOS window tabs: the sibling tab windows + titles were already
        // resolved during the scan, so the strip appears instantly with no fetch.
        // Committing a strip entry raises that tab's window (selecting the tab).
        if row.tabWindows.count > 1 {
            applyDrill(
                titles: row.tabWindows.map(\.title),
                liveTabs: row.tabWindows.map(\.ref),
                backend: .windows,
                window: window
            )
            return
        }
        // Never drill our own windows — the AX walk would run in-process off the
        // main thread and crash the layout engine (see `isOwnProcess`).
        guard !Self.isOwnProcess(app) else { return }
        // Cache hit: drill-in is instant — strip appears on the same run
        // loop tick.
        if let cached = tabPrefetchCache[AXRef(element: window)], !cached.titles.isEmpty {
            applyDrill(titles: cached.titles, liveTabs: cached.liveTabs, backend: cached.backend, window: window)
            return
        }
        let isBrowser = (BrowserTabs.Family.from(bundleID: app.bundleIdentifier) != nil)
        // Reuse tab AXUIElements already discovered by the cache snapshot when
        // available — saves a recursive AX walk on every non-browser drill-in
        // (Finder/Terminal/etc.). Browsers ignore this and run AppleScript.
        let prefetchedTabs = isBrowser ? [] : row.tabs
        let title = row.windowTitle
        let gen = revealGeneration
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            let result = Self.fetchTabsBlocking(app: app, window: window, title: title, isBrowser: isBrowser, prefetchedTabs: prefetchedTabs)
            DispatchQueue.main.async {
                guard let self, gen == self.revealGeneration, self.phase == .visible else { return }
                guard self.rows.indices.contains(self.index),
                      let currentWindow = self.rows[self.index].window,
                      CFEqual(currentWindow, window) else { return }
                switch result {
                case .tabs(let titles, let liveTabs, let backend):
                    self.applyDrill(titles: titles, liveTabs: liveTabs, backend: backend, window: window)
                case .failed:
                    self.showTabDrillHint(forApp: app)
                case .none:
                    break
                }
            }
        }
    }

    /// Briefly show a non-interactive hint in the tab-strip region when a browser
    /// tab drill couldn't read the browser's tabs (almost always a missing
    /// Automation permission). Does not enter drill mode, so navigation/commit
    /// are unaffected; auto-dismisses.
    private func showTabDrillHint(forApp app: NSRunningApplication) {
        guard phase == .visible, !tabDrillActive else { return }
        let name = app.localizedName ?? String(localized: "this browser")
        tabDrillHint = String(format: String(localized: "Grant Automation access to %@ in System Settings ▸ Privacy"), name)
        refreshDisplay()
        let gen = revealGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, gen == self.revealGeneration, self.tabDrillHint != nil else { return }
            self.tabDrillHint = nil
            if self.phase == .visible { self.refreshDisplay() }
        }
    }

    /// Apply a fetched/cached tab set to the panel — single sink used by
    /// both the cache-hit and async paths so they can't drift.
    private func applyDrill(titles: [String], liveTabs: [AXUIElement], backend: TabDrillBackend, window: AXUIElement) {
        // Snapshot the detach state on first entry only (a re-drill onto another
        // row must keep the original pre-drill value, not the forced `true`).
        if !tabDrillActive { stickyOpenBeforeDrill = stickyOpen }
        tabTitles = titles
        liveTabElements = liveTabs
        tabDrillBackend = backend
        tabIndex = 0
        tabDrillActive = true
        tabDrillHint = nil
        drillWindow = window
        stickyOpen = true
        hotkey.setTabDrillActive(true)
        refreshDisplay()
        resyncSecureInputChords()
        tabPrefetchCache[AXRef(element: window)] = TabPrefetch(titles: titles, liveTabs: liveTabs, backend: backend)
    }

    /// Blocking tab fetch suitable for a background queue. Returns nil for a
    /// row that has no tab group worth a strip (so the caller can silently
    /// skip without forcing the panel into drill mode on an empty result).
    /// `prefetchedTabs` lets the caller short-circuit the recursive AX walk
    /// when the cache already discovered the tab group during its snapshot.
    /// Outcome of an off-main tab fetch. `failed` is browser-only — the
    /// AppleScript bridge errored (Automation permission/timeout) — and lets the
    /// caller surface a hint instead of silently doing nothing.
    private enum DrillFetch {
        case none
        case failed
        case tabs(titles: [String], liveTabs: [AXUIElement], backend: TabDrillBackend)
    }

    /// AX tab enumeration must never target our own process. Accessibility
    /// requests to a *same-process* element are serviced in-process by AppKit,
    /// and reading `kAXChildrenAttribute` forces a layout pass — illegal off the
    /// main thread, which is exactly where the tab fetch runs (a background
    /// queue, so the recursive AX walk stays off the reveal path). Querying
    /// another app is safe off-main because that work happens in the *other*
    /// process and only serialized data crosses back. Our own windows (Settings,
    /// About) have no drillable tabs anyway, so skip them outright. Without this
    /// guard, having our own window highlighted (e.g. Settings open) crashes with
    /// "Modifications to the layout engine must not be performed from a
    /// background thread."
    private static func isOwnProcess(_ app: NSRunningApplication) -> Bool {
        app.processIdentifier == NSRunningApplication.current.processIdentifier
    }

    nonisolated private static func fetchTabsBlocking(app: NSRunningApplication, window: AXUIElement, title: String, isBrowser: Bool, prefetchedTabs: [AXUIElement] = []) -> DrillFetch {
        if isBrowser {
            switch BrowserTabs.tabTitles(for: app, window: window, title: title) {
            case .failed:
                return .failed
            case .tabs(let titles):
                return titles.count > 1 ? .tabs(titles: titles, liveTabs: [], backend: .appleScript) : .none
            case .notSupported:
                return .none
            }
        }
        let axTabs: [AXUIElement]
        if prefetchedTabs.count > 1 {
            axTabs = prefetchedTabs
        } else {
            axTabs = WindowEnumerator.tabs(in: window)
        }
        guard axTabs.count > 1 else { return .none }
        let titles = WindowEnumerator.tabTitles(for: axTabs)
        return .tabs(titles: titles, liveTabs: axTabs, backend: .accessibility)
    }

    /// Kick a background prefetch for the highlighted row after a short
    /// settle so rapid Tab presses don't spam the AppleScript / AX scan. By
    /// the time the user reaches for `\`, the result is usually already in
    /// `tabPrefetchCache`.
    private func schedulePrefetchForCurrentSelection() {
        tabPrefetchTimer?.invalidate()
        guard Preferences.shared.tabDrillEnabled,
              phase == .visible, rows.indices.contains(index),
              let window = rows[index].window,
              let app = rows[index].app else { return }
        // Skip our own process: the prefetch AX walk runs off-main and would
        // crash the layout engine on a same-process element (see `isOwnProcess`).
        guard !Self.isOwnProcess(app) else { return }
        let key = AXRef(element: window)
        if tabPrefetchCache[key] != nil || tabPrefetchInFlight.contains(key) { return }
        let isBrowser = (BrowserTabs.Family.from(bundleID: app.bundleIdentifier) != nil)
        // Browsers reach their tabs through an AppleScript that must first
        // `AXRaise` the row's window so `window 1` resolves to it — and that
        // raise reorders the browser's windows, which the user perceives as
        // the switcher silently switching windows on mere hover. Hover must
        // never switch; only Space / Return / a click / releasing ⌘ commits.
        // So don't prefetch browsers here; the drill strip is fetched
        // on-demand when the user actually presses `\` (a deliberate gesture),
        // and the raise's side effect there is expected. The AX path used by
        // non-browser tabbed apps (Finder/Terminal/…) only reads attributes —
        // no raise — so it stays eligible for the instant-drill prefetch.
        if isBrowser { return }
        let prefetchedTabs = rows[index].tabs
        let timer = Timer(timeInterval: 0.18, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.tabPrefetchCache[key] == nil,
                      !self.tabPrefetchInFlight.contains(key) else { return }
                self.tabPrefetchInFlight.insert(key)
                let gen = self.revealGeneration
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    // Browsers are excluded above, so this path is AX-only and
                    // ignores `title`.
                    let result = Self.fetchTabsBlocking(app: app, window: window, title: "", isBrowser: isBrowser, prefetchedTabs: prefetchedTabs)
                    DispatchQueue.main.async {
                        guard let self, gen == self.revealGeneration else { return }
                        self.tabPrefetchInFlight.remove(key)
                        guard case .tabs(let titles, let liveTabs, let backend) = result, !titles.isEmpty else { return }
                        self.tabPrefetchCache[key] = TabPrefetch(titles: titles, liveTabs: liveTabs, backend: backend)
                    }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        tabPrefetchTimer = timer
    }

    private func exitTabDrill() {
        guard tabDrillActive else { return }
        tabDrillActive = false
        tabDrillHint = nil
        tabTitles = []
        liveTabElements = []
        tabIndex = 0
        drillWindow = nil
        // Restore the pre-drill detach state so a `\`-toggle exit while ⌘ is held
        // re-arms commit-on-release; mouse-park / stay-open-search keep their sticky.
        stickyOpen = stickyOpenBeforeDrill
        hotkey.setTabDrillActive(false)
        refreshDisplay()
        resyncSecureInputChords()
    }

    private func advanceTab(by delta: Int) {
        guard tabDrillActive, !tabTitles.isEmpty else { return }
        let count = tabTitles.count
        tabIndex = ((tabIndex + delta) % count + count) % count
        view.setTabStripSelectedIndex(tabIndex)
    }

    private func commitTab() {
        guard tabDrillActive, !tabTitles.isEmpty,
              rows.indices.contains(index),
              let app = rows[index].app,
              let window = rows[index].window,
              // The selection must still be the row the strip was built against.
              // A background refresh can drift `index` onto a different row while
              // the strip stays open (the drilled app quit, or a re-sort moved
              // rows); the captured tab elements then no longer belong to
              // rows[index]. Fall back to a plain commit rather than activating a
              // mismatched window/app.
              let dw = drillWindow, CFEqual(window, dw) else {
            exitTabDrill()
            commit()
            return
        }
        let row = rows[index]
        let chosen = tabIndex
        let backend = tabDrillBackend
        // For AX/native-window backends the target element is `liveTabElements[chosen]`
        // (an AXTab control, or a real tab window respectively). Bail to a plain
        // commit if it's somehow missing.
        let targetElement: AXUIElement? = (backend != .appleScript && liveTabElements.indices.contains(chosen))
            ? liveTabElements[chosen] : nil
        if backend != .appleScript && targetElement == nil {
            exitTabDrill()
            commit()
            return
        }
        let instantSpace = Preferences.shared.experimentalInstantSpaceSwitch
        if let pid = row.pid { mru.bump(pid) }
        bumpWindowMRUIfPossible(for: row)

        revealGeneration &+= 1
        phase = .idle
        cache.setPanelVisible(false)
        CommitFeedback.play()
        // Activate BEFORE dismissing the panel (same reason as commit()):
        // panel.dismiss() surrenders our key window, so a synchronous activate
        // afterwards can lose focus back to the WindowServer.
        switch backend {
        case .appleScript:
            let title = row.windowTitle
            DispatchQueue.global(qos: .userInitiated).async {
                _ = BrowserTabs.activateTab(at: chosen, in: app, window: window, title: title)
            }
        case .accessibility:
            if let tab = targetElement {
                Activator.activateTab(in: app, window: window, tab: tab, instantSpace: instantSpace)
            }
        case .windows:
            // The chosen tab is a real NSWindow — raising it selects that tab.
            if let tabWindow = targetElement {
                let tabRow = SwitcherRow(app: app, window: tabWindow, windowTitle: row.windowTitle, isMinimized: false)
                Activator.activate(tabRow, instantSpace: instantSpace)
            }
        }
        panel.dismiss()
        // Activating the chosen tab's app above; nothing to restore.
        previousFrontmostApp = nil
        tabDrillActive = false
        tabTitles = []
        liveTabElements = []
        tabIndex = 0
        drillWindow = nil
        hotkey.setTabDrillActive(false)
        primedApps = []
        rows = []
        baseRows = []
        baseLabels = []
        closedTombstones.removeAll()
        quittingPids.removeAll()
        clearBrowserTabExpansion()
        resetLetterBuffer()
        resetSearch()
        view.releaseIdleResources()
    }

    /// SIGKILL the highlighted app — bypasses the AppleEvent terminate() that
    /// hung apps ignore. Recorded in `RecentlyClosedStore` like a normal quit so
    /// the app can be relaunched from there.
    private func performForceQuitAction() {
        quitVisibleTarget(force: true)
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

        // Inline browser-tab row: close just that tab, not its parent window.
        // `Activator.closeWindow` presses the window's AX close button / posts ⌘W,
        // which would close the whole browser window. Browser tabs aren't AX
        // windows, so drive the close through Apple Events, mirroring the activate
        // path used on commit.
        if let bt = row.browserTab, let app = row.app, let window = row.window {
            let tabIndex = bt.index
            let parentTitle = bt.parentTitle
            DispatchQueue.global(qos: .userInitiated).async {
                _ = BrowserTabs.closeTab(at: tabIndex, in: app, window: window, title: parentTitle)
            }
            // Optimistically drop the closed tab from the per-window cache and
            // re-expand so the row vanishes immediately; later tabs' indices shift
            // down naturally because `browserTabRows` re-enumerates the array. The
            // throttled background re-scan reconciles if the close didn't take.
            let key = AXRef(element: window)
            if var titles = browserTabsCache[key], titles.indices.contains(tabIndex) {
                titles.remove(at: tabIndex)
                browserTabsCache[key] = titles
                browserTabsCacheStamp[key] = nil   // force a refresh on next scan
            }
            reExpandBrowserTabs(force: true)
            if baseRows.isEmpty { cancel(); return }
            scheduleVisibleRefresh(after: 0.25)
            return
        }

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

        // Windows-only mode (⌘`): the panel lists ONE app's windows, so a close
        // must not demote the app to a windowless row or reveal a "no window"
        // glyph — those are multi-app-list concepts. Just drop the closed window
        // and re-refresh scoped to this app (the refresh stays filtered to
        // `windowsOnlyPid`); the last window closing cancels via the refresh.
        if windowsOnlyMode {
            if baseRows.isEmpty {
                cancel()
                return
            }
            baseLabels = RowLabels.labels(for: baseRows)
            refreshDisplay()
            scheduleVisibleRefresh(after: 0.25)
            return
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
        //
        // Skip the demotion when the user's filter would hide the app once it's
        // windowless — a per-app "hide when no windows" exception, or the global
        // show-windowless toggle off. For those, vanishing the instant the last
        // window closes is the *correct* behavior; the optimistic row bypasses
        // `CatalogFilter` (it's set on `baseRows` directly, not via
        // `cache.rows()`), so without this gate it would flash on screen until
        // the 250ms refresh re-applied the filter and dropped it.
        if closedApp.activationPolicy == .regular,
           !baseRows.contains(where: { $0.pid == closedPid }),
           CatalogFilter.includes(
               bundleID: closedApp.bundleIdentifier,
               isPlaceholder: false,
               isMinimized: false,
               appHidden: closedApp.isHidden,
               hasWindow: false,
               CatalogFilter.config()
           ) {
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
        @MainActor func apply() {
            guard gen == revealGeneration, phase == .visible else { return }
            cache.scheduleFullRefresh { [weak self] in
                guard let self, gen == self.revealGeneration, self.phase == .visible else { return }
                let fresh = self.filterQuitting(self.filterClosedTombstones(self.cache.rows(orderedBy: self.mru.order)))
                // Windows-only mode (⌘`) is scoped to a single app's windows. A
                // post-action refresh must stay filtered to `windowsOnlyPid` —
                // otherwise it rebuilds from the full multi-app catalog and the
                // panel suddenly shows every app's windows (e.g. after closing a
                // window). `applyWindowsOnlySnapshot` re-sorts and cancels if the
                // app has no windows left.
                if self.windowsOnlyMode {
                    let scoped = self.windowsOnlyPid.map { pid in fresh.filter { $0.pid == pid } } ?? fresh
                    self.applyWindowsOnlySnapshot(scoped)
                    return
                }
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
                //
                // Re-expand inline browser-tab rows from the warm cache (like
                // `applyFullSnapshot`) — otherwise this refresh would collapse a
                // browser window's tabs back to one row (e.g. after closing a tab,
                // the panel would show just the window until the user re-opened).
                // Then rescan so a tab added/closed since the cache stamp shows.
                self.baseRows = self.expandBrowserTabs(fresh)
                self.baseLabels = RowLabels.labels(for: self.baseRows)
                self.refreshDisplay()
                self.scheduleBrowserTabExpansion()
            }
        }
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                Task { @MainActor in apply() }
            }
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
    /// Drop rows for apps the user just quit (see `quittingPids`) so a refresh
    /// landing during the quit's death gap doesn't re-add the app as a windowless
    /// row. Cleared per-pid on terminate or the safety timeout.
    private func filterQuitting(_ snapshot: [SwitcherRow]) -> [SwitcherRow] {
        if quittingPids.isEmpty { return snapshot }
        return snapshot.filter { row in
            guard let pid = row.pid else { return true }
            return !quittingPids.contains(pid)
        }
    }

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
            searchQuery: searchQuery,
            tabStripTitles: tabDrillActive ? tabTitles : tabDrillHint.map { [$0] },
            tabStripSelectedIndex: tabIndex
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
        resyncSecureInputChords()
    }

    private func exitSearch() {
        guard searchActive else { return }
        searchActive = false
        searchQuery = ""
        hotkey.setSearchMode(false)
        refreshDisplay()
        resyncSecureInputChords()
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
        // Drill-in commits on release: the user picks the highlighted tab the
        // same way releasing ⌘ commits the highlighted app. Bypass the
        // stickyOpen guard that enterTabDrill set for safety against stray
        // commits during the drill.
        if tabDrillActive {
            commitTab()
            return
        }
        if stickyOpen { return }
        if searchActive, Preferences.shared.searchDismissMode == .stayOpen {
            stickyOpen = true
            return
        }
        commit()
    }
}
