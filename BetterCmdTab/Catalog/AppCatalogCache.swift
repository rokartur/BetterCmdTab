import AppKit
import ApplicationServices

/// File-scope mirror of the panel-visible state. The AX observer callback is a C
/// function pointer (`AXObserverCallback`) and so cannot reference a type's
/// stored member without "capturing context"; a global it can read freely. Set
/// and read only on the main run loop (where the callback fires), so untorn.
private nonisolated(unsafe) var axCatalogPanelVisible = false

@MainActor
final class AppCatalogCache {
    struct AppCacheEntry {
        let app: NSRunningApplication
        let windows: [WindowInfo]
    }

    /// One pid's result from the off-main snapshot pass: the windows plus the
    /// coverage memo (`expected` CG hint seen, `uncoverable` wids within it) to
    /// fold back into `pidCoverage` on the main completion.
    private struct BumpScan {
        var windows: [WindowInfo] = []
        var expected: Set<CGWindowID> = []
        var uncoverable: Set<CGWindowID> = []
    }

    private(set) var entries: [pid_t: AppCacheEntry] = [:]
    /// True once at least one full off-main scan has landed in `entries`.
    /// Lets the reveal path tell "cache cold, never scanned" apart from
    /// "scanned, and the filters legitimately yield zero rows".
    private(set) var hasCompletedFullScan = false
    /// Whether the switcher panel is on screen. Title-change notifications are
    /// only acted on while this is true. Set via `setPanelVisible`.
    private var panelVisible = false
    private var pendingRefresh = false
    private var pendingBumps: Set<pid_t> = []
    /// Per-pid serialization for `bumpApps`. `snapshotQueue` is concurrent, so
    /// two bumps for the same pid can race — and since later snapshots can
    /// finish *before* earlier ones, the stale completion overwrites fresh
    /// data and the cache gets stuck (e.g. burst of 10 window creates ends
    /// with cache showing 5 because the slow first bump landed last). With
    /// in-flight tracking only one bump per pid runs at a time; any extra
    /// request collapses into a single "pending" slot that re-bumps once the
    /// current one finishes, so we always converge on the latest state.
    private var pidBumpInFlight: Set<pid_t> = []
    private var pidBumpPending: Set<pid_t> = []
    /// Monotonic generation stamped (on main) when a scan is dispatched or an
    /// entry is removed directly; completions only write a pid whose last
    /// write isn't newer. `pidBumpInFlight` serializes bump-vs-bump, but a
    /// full refresh runs concurrently with bumps — without this, a slow full
    /// scan landing late clobbers fresher per-pid bump results (e.g. re-adds
    /// a window a destroy-notification bump just removed while the panel is
    /// open). Stale records are purged in the full-refresh completion.
    private var scanGeneration: UInt64 = 0
    private var pidWriteGeneration: [pid_t: UInt64] = [:]
    /// Per-pid memo of the last brute-scan coverage result: the CG hint set seen
    /// and the wids within it that no AX window could cover. Reused on the next
    /// bump *only while the hint set is unchanged* — a chatty app re-firing AX
    /// notifications without a real window change keeps the same hint, so the
    /// memo lets `WindowEnumerator.needsBruteScan` skip the otherwise-repeated
    /// 256-id sweep. Any real window open/close changes the hint and re-arms a
    /// full sweep. Evicted with the pid's entry and on observer teardown.
    private var pidCoverage: [pid_t: (expected: Set<CGWindowID>, uncoverable: Set<CGWindowID>)] = [:]
    private weak var mru: MRUTracker?
    private var observers: [NSObjectProtocol] = []
    private var axObservers: [pid_t: AXObserver] = [:]
    private var axObserversInstalling: Set<pid_t> = []
    private var pendingOneShotCompletions: [() -> Void] = []
    private let snapshotQueue = DispatchQueue(label: "BetterCmdTab.snapshot", qos: .userInteractive, attributes: .concurrent)
    private let axInstallQueue = DispatchQueue(label: "BetterCmdTab.axInstall", qos: .utility, attributes: .concurrent)

    /// AX notifications subscribed per running app. These cover the state
    /// changes that affect the switcher's *row set* (and their ordering):
    /// window add/remove, minimize/restore, focus change, hide/unhide.
    ///
    /// `kAXTitleChangedNotification` is the noisiest AX notification (browsers,
    /// terminals, editors fire it constantly), so it is handled specially: its
    /// callback does nothing unless the panel is currently visible (see
    /// `handleAXNotification`). That keeps titles live *while the user is looking
    /// at the switcher* without the idle window-scan churn that made it not worth
    /// subscribing to before — the gate, not the subscription, was the cost.
    nonisolated private static let axNotifications: [String] = [
        kAXWindowCreatedNotification as String,
        kAXUIElementDestroyedNotification as String,
        kAXWindowMiniaturizedNotification as String,
        kAXWindowDeminiaturizedNotification as String,
        kAXFocusedWindowChangedNotification as String,
        // Native window tabs (Finder/Safari/Terminal/…): switching a tab manually
        // makes that tab's window frontmost. Some apps post only main-window-
        // changed (not focused-window-changed) for that, so subscribe both and
        // route them the same — otherwise a manual native-tab switch wouldn't
        // re-order the switcher's window MRU.
        kAXMainWindowChangedNotification as String,
        kAXTitleChangedNotification as String,
        kAXApplicationHiddenNotification as String,
        kAXApplicationShownNotification as String,
    ]

    func start(mru: MRUTracker) {
        self.mru = mru
        installWorkspaceObservers()
        installAXObserversForAllApps()
        scheduleFullRefresh()
    }

    func setPanelVisible(_ visible: Bool) {
        // Gates title-change handling: while the panel is hidden, title churn
        // (browsers/terminals fire it constantly) is ignored, so there is no
        // idle scan cost; while visible, titles are kept live (see
        // `handleAXNotification` / `kAXTitleChangedNotification`).
        panelVisible = visible
        axCatalogPanelVisible = visible
    }

    func rows(orderedBy mru: [pid_t]) -> [SwitcherRow] {
        // Sweep terminated apps that the didTerminate workspace observer
        // hasn't reached yet (race: user hits Cmd+Q on a switcher row → row
        // stays visible with empty icon until the observer fires). Filtering
        // by isTerminated here closes the gap.
        for (pid, entry) in entries where entry.app.isTerminated {
            entries.removeValue(forKey: pid)
            IconCache.evict(pid)
        }

        var ordered: [AppCacheEntry] = []
        ordered.reserveCapacity(entries.count)
        var seen = Set<pid_t>()
        for pid in mru {
            if let entry = entries[pid] {
                ordered.append(entry)
                seen.insert(pid)
            }
        }
        // Apps absent from MRU (launched in the background, never activated):
        // dictionary order is nondeterministic and reshuffles on every cache
        // mutation, so sort by pid — stable and deterministic across refreshes.
        var remainder: [(pid: pid_t, entry: AppCacheEntry)] = []
        for (pid, entry) in entries where !seen.contains(pid) {
            remainder.append((pid, entry))
        }
        remainder.sort { $0.pid < $1.pid }
        for item in remainder {
            ordered.append(item.entry)
        }

        var result: [SwitcherRow] = []
        result.reserveCapacity(ordered.count * 2)
        for entry in ordered {
            if entry.windows.isEmpty {
                if entry.app.activationPolicy == .regular {
                    result.append(SwitcherRow(
                        app: entry.app,
                        window: nil,
                        windowTitle: "",
                        isMinimized: false
                    ))
                }
            } else {
                for window in entry.windows {
                    result.append(SwitcherRow.from(app: entry.app, window: window))
                }
            }
        }
        // Compute each row's status bucket once — `statusPriority` reads the
        // live `app.isHidden` (an ObjC call) — then sort the precomputed keys.
        // The old comparator called it twice per comparison (O(n log n) ObjC
        // queries); decorating up front makes it O(n). Tie-break on the
        // original offset keeps the order byte-identical to before.
        let sorted = result.enumerated()
            .map { (priority: Self.statusPriority($0.element), offset: $0.offset, row: $0.element) }
            .sorted { lhs, rhs in
                if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
                return lhs.offset < rhs.offset
            }
            .map { $0.row }
        return CatalogFilter.filteredRows(sorted, CatalogFilter.config())
    }

    /// Internal (not private) so the `.mruWindows` window-recency sort can
    /// re-apply the same bucketing after its global shuffle (hidden/windowless
    /// apps must still sink to the end).
    static func statusPriority(_ row: SwitcherRow) -> Int {
        // Windowless and hidden regular apps share one "inactive" bucket after
        // everything else — they're least immediately actionable. They're
        // pooled together because an app closing its last window can flip
        // between "no window" and "hidden window" across consecutive AX
        // refreshes (Electron apps hide rather than truly go windowless); one
        // bucket keeps that flip from reordering the app. Placeholders keep
        // priority 0 so they don't get demoted while the cache warms up.
        // (Mirror AppCatalog.statusPriority.)
        if row.window == nil, !row.isPlaceholder { return 2 }
        if row.isHidden { return 2 }
        if row.isMinimized { return 1 }
        return 0
    }

    func scheduleFullRefresh(completion: (() -> Void)? = nil) {
        if let completion { pendingOneShotCompletions.append(completion) }
        guard !pendingRefresh else { return }
        pendingRefresh = true
        scanGeneration += 1
        let gen = scanGeneration
        snapshotQueue.async { [weak self] in
            let fresh = Self.computeEntries()
            DispatchQueue.main.async {
                guard let self else { return }
                // Merge per pid instead of replacing wholesale: skip any pid a
                // newer-generation write (a bump dispatched after this scan)
                // already updated or removed — its data is fresher than ours.
                for (pid, entry) in fresh where (self.pidWriteGeneration[pid] ?? 0) <= gen {
                    self.entries[pid] = entry
                    self.pidWriteGeneration[pid] = gen
                }
                for (pid, _) in self.entries
                where fresh[pid] == nil && (self.pidWriteGeneration[pid] ?? 0) <= gen {
                    self.entries.removeValue(forKey: pid)
                }
                self.hasCompletedFullScan = true
                // Drop coverage memos for pids the merged cache no longer lists
                // (terminated apps a missed observer teardown left behind); the
                // memo stays valid across refresh otherwise — it's keyed on the
                // CG hint, which a refresh doesn't change — so live uncoverable
                // pids don't pay a needless re-sweep.
                self.pidCoverage = self.pidCoverage.filter { self.entries.keys.contains($0.key) }
                // Purge generation records nothing in flight can still write:
                // refreshes are serialized by `pendingRefresh`, bumps are
                // tracked in `pidBumpInFlight`, and anything dispatched later
                // gets a higher generation anyway.
                self.pidWriteGeneration = self.pidWriteGeneration.filter {
                    self.entries[$0.key] != nil || self.pidBumpInFlight.contains($0.key)
                }
                self.pendingRefresh = false
                // Warm the most-recently-used app icons off the show path so the
                // first reveal doesn't flatten them synchronously on main (see
                // IconCache.prewarm). MRU order first so the apps most likely to
                // top the panel warm first. Skip while the panel is up: its
                // visible rows are already cached, so this would only flatten
                // off-screen apps and compete with the live session.
                if !self.panelVisible {
                    let mruOrder = self.mru?.order ?? []
                    let inMru = Set(mruOrder)
                    let ordered = mruOrder.filter { fresh.keys.contains($0) }
                        + fresh.keys.filter { !inMru.contains($0) }
                    IconCache.prewarm(pids: ordered)
                }
                let pending = self.pendingOneShotCompletions
                self.pendingOneShotCompletions.removeAll()
                for cb in pending { cb() }
            }
        }
    }

    nonisolated private static func computeEntries() -> [pid_t: AppCacheEntry] {
        // Self is included so the Settings window shows up in the switcher; the
        // windowless switcher panel is filtered out by WindowEnumerator
        // (non-standard AX subrole) and the accessory rule then drops self when
        // no Settings window is open.
        let candidates = NSWorkspace.shared.runningApplications.filter { app in
            app.activationPolicy == .regular || app.activationPolicy == .accessory
        }
        let count = candidates.count
        guard count > 0 else { return [:] }

        let cgSnapshot = WindowEnumerator.snapshotCGWindowMap()

        var windowsBuffer: [[WindowInfo]] = Array(repeating: [], count: count)
        windowsBuffer.withUnsafeMutableBufferPointer { buffer in
            nonisolated(unsafe) let bufferRef = buffer
            DispatchQueue.concurrentPerform(iterations: count) { i in
                let app = candidates[i]
                let pid = app.processIdentifier
                bufferRef[i] = WindowEnumerator.windows(
                    forPid: pid,
                    isRegularApp: app.activationPolicy == .regular,
                    expectedCGWindowIDs: cgSnapshot.ids(for: pid),
                    cgZOrder: cgSnapshot.zOrder(for: pid)
                )
            }
        }

        var dict: [pid_t: AppCacheEntry] = [:]
        dict.reserveCapacity(count)
        for i in 0..<count {
            let app = candidates[i]
            let windows = windowsBuffer[i]
            if app.activationPolicy == .regular {
                dict[app.processIdentifier] = AppCacheEntry(app: app, windows: windows)
            } else if app.activationPolicy == .accessory, !windows.isEmpty {
                dict[app.processIdentifier] = AppCacheEntry(app: app, windows: windows)
            }
        }
        return dict
    }

    private func installWorkspaceObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        let perAppNames: [NSNotification.Name] = [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didDeactivateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
        ]
        for name in perAppNames {
            let obs = nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                let pid = app.processIdentifier
                Task { @MainActor [weak self] in
                    self?.scheduleBumpApp(pid: pid)
                }
            }
            observers.append(obs)
        }
        let terminateObs = nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.uninstallAXObserver(forPid: pid)
                self.entries.removeValue(forKey: pid)
                // Stamp the removal so an in-flight scan that saw the app
                // alive can't resurrect its entry when it lands.
                self.scanGeneration += 1
                self.pidWriteGeneration[pid] = self.scanGeneration
                IconCache.evict(pid)
            }
        }
        observers.append(terminateObs)
        let launchObs = nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            let canHaveWindows = app.activationPolicy == .regular || app.activationPolicy == .accessory
            Task { @MainActor [weak self] in
                if canHaveWindows {
                    self?.installAXObserver(forPid: pid)
                }
                self?.scheduleBumpApp(pid: pid)
            }
        }
        observers.append(launchObs)
    }

    /// Install AX observers for every running app. The blocking AX calls
    /// (`AXObserverCreate` + 8× `AXObserverAddNotification`, each up to 0.2s
    /// when the target app is slow) run on a concurrent background queue so
    /// they never starve the main run loop. Without this, every hotkey event
    /// dispatched to main from the input thread had to wait behind the
    /// pending install backlog — turning the very first Cmd+Tab after launch
    /// into a 3–4s lag spike.
    private func installAXObserversForAllApps() {
        let pids = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular || $0.activationPolicy == .accessory }
            .map(\.processIdentifier)
        for pid in pids {
            installAXObserver(forPid: pid)
        }
    }

    private func installAXObserver(forPid pid: pid_t) {
        guard axObservers[pid] == nil, !axObserversInstalling.contains(pid) else { return }
        axObserversInstalling.insert(pid)
        // Encode the refcon as a bit-pattern integer so it can cross the
        // sendable boundary without forcing an unchecked wrapper. The
        // pointer is stable for `self`'s lifetime and the observer callback
        // is always invoked while `self` is alive (uninstall stops it).
        let refconBits = UInt(bitPattern: Unmanaged.passUnretained(self).toOpaque())
        axInstallQueue.async { [weak self] in
            guard let refcon = UnsafeMutableRawPointer(bitPattern: refconBits) else { return }
            let observer = Self.buildAXObserver(pid: pid, refcon: refcon)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.axObserversInstalling.remove(pid)
                guard let observer else {
                    // App may not be AX-ready yet — workspace
                    // `didLaunchApplication` fires before AX server registers.
                    // Skip silently; next bumpApp through workspace events
                    // still keeps cache fresh.
                    return
                }
                guard self.axObservers[pid] == nil else { return }
                // The app can terminate while the build was in flight on the
                // background queue — didTerminate's uninstall runs first and
                // finds nothing to remove. Installing anyway would retain the
                // observer + run-loop source for process lifetime and block a
                // future install if the OS recycles the pid. Dropping the
                // observer here is the cleanup: no source was added, and the
                // AX-server subscriptions died with the target process.
                guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return }
                CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
                self.axObservers[pid] = observer
            }
        }
    }

    /// Pure AX-side work. Runs off-main so per-notification timeouts cannot
    /// stall the main run loop. The returned observer is not yet bound to
    /// any run loop — the caller hops to main to install the source.
    nonisolated private static func buildAXObserver(pid: pid_t, refcon: UnsafeMutableRawPointer) -> AXObserver? {
        var observer: AXObserver?
        let cb: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let cache = Unmanaged<AppCatalogCache>.fromOpaque(refcon).takeUnretainedValue()
            var elemPid: pid_t = 0
            AXUIElementGetPid(element, &elemPid)
            // A pure focus change reorders windows but never changes the window
            // *set* — route it to a cheap MRU nudge instead of a full per-pid
            // re-enumeration. Every set-changing notification (create/destroy/
            // miniaturize/hide/...) still triggers the full scan.
            let kind: AXNoteKind
            if CFEqual(notification, kAXFocusedWindowChangedNotification as CFString)
                || CFEqual(notification, kAXMainWindowChangedNotification as CFString) {
                // Both just reorder existing windows (a native-tab switch makes a
                // different window frontmost) — a cheap MRU nudge, not a re-scan.
                kind = .focus
            } else if CFEqual(notification, kAXTitleChangedNotification as CFString) {
                // Title churn is by far the loudest notification; while the panel
                // is hidden it changes nothing on screen, so drop it here before
                // even a main-queue hop. (Read on the main run loop, where this
                // callback fires, so the flag is never torn.)
                if !axCatalogPanelVisible { return }
                kind = .title
            } else {
                kind = .set
            }
            DispatchQueue.main.async {
                cache.handleAXNotification(pid: elemPid, kind: kind)
            }
        }
        let result = AXObserverCreate(pid, cb, &observer)
        guard result == .success, let observer else { return nil }
        let axApp = AXUIElementCreateApplication(pid)
        // Clamp per-call blocking when the target app is slow. Without this
        // `AXObserverAddNotification` can stall its thread indefinitely.
        AXUIElementSetMessagingTimeout(axApp, 0.2)
        for name in axNotifications {
            _ = AXObserverAddNotification(observer, axApp, name as CFString, refcon)
        }
        return observer
    }

    private func uninstallAXObserver(forPid pid: pid_t) {
        // Tearing down tracking for this pid (app terminated) — drop its coverage
        // memo too, before the observer guard so it clears even if no observer
        // was installed.
        pidCoverage.removeValue(forKey: pid)
        guard let observer = axObservers.removeValue(forKey: pid) else { return }
        // Drop the AX-server subscriptions before detaching the run-loop source,
        // mirroring the add side in `buildAXObserver` (same names, same element).
        // Removing only the source leaves the notifications dangling.
        let axApp = AXUIElementCreateApplication(pid)
        for name in Self.axNotifications {
            _ = AXObserverRemoveNotification(observer, axApp, name as CFString)
        }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    /// Classification of an AX notification by its effect on the switcher.
    enum AXNoteKind {
        case focus  // reorders windows only
        case title  // changes a window's title only
        case set    // adds/removes/min/hides a window — needs a re-scan
    }

    /// Set by `SwitcherController` to handle focus-change notifications without a
    /// window re-scan (a focus change only reorders existing windows). Receives
    /// the pid whose focused window changed.
    var onFocusChanged: ((pid_t) -> Void)?

    /// Set by `SwitcherController`: a window title changed while the panel is
    /// visible. Only fires when visible (titles don't matter when hidden), so the
    /// switcher can refresh displayed titles without paying any idle cost.
    var onVisibleTitleChanged: (() -> Void)?

    /// Dispatch an AX notification by kind: focus → cheap MRU nudge; title →
    /// notify the panel only while visible; everything else → full re-scan.
    func handleAXNotification(pid: pid_t, kind: AXNoteKind) {
        switch kind {
        case .focus:
            onFocusChanged?(pid)
        case .title:
            if panelVisible { onVisibleTitleChanged?() }
        case .set:
            scheduleBumpApp(pid: pid)
        }
    }

    /// Coalesces bump requests — an app-switch (deactivate + activate), an AX
    /// notification storm (bursts of window create/destroy), and workspace
    /// hide/unhide/launch events that all land in the same run-loop tick fold
    /// into a single `bumpApps` call. That call takes exactly one shared
    /// `CGWindowListCopyWindowInfo` snapshot for the whole batch instead of one
    /// per pid, so a 5-app storm costs one full-system window-list copy, not 5.
    private func scheduleBumpApp(pid: pid_t) {
        let wasEmpty = pendingBumps.isEmpty
        pendingBumps.insert(pid)
        if wasEmpty {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let toBump = self.pendingBumps
                self.pendingBumps.removeAll()
                self.bumpApps(pids: toBump)
            }
        }
    }

    /// Refresh the cached window inventory for a set of pids off one shared CG
    /// snapshot. Self is no longer force-removed: as an accessory app it only
    /// earns a cache entry when it has a window (the Settings window). Showing/
    /// hiding the borderless switcher panel yields no standard window, so a
    /// self bump just clears the entry again.
    func bumpApps(pids: Set<pid_t>) {
        guard !pids.isEmpty else { return }
        scanGeneration += 1
        let gen = scanGeneration
        // Resolve policy and reserve in-flight slots on main. Pids already in
        // flight collapse into the pending set and re-run when the current scan
        // lands. Value-type `plan` crosses to the snapshot queue; the
        // `apps`/`accessoryPids` lookups stay main-only (read in the completion).
        // Each plan item carries the pid's prior coverage memo so the off-main
        // pass can decide (against the fresh CG hint) whether the brute scan can
        // be skipped — read here on main, where `pidCoverage` lives.
        var plan: [(pid: pid_t, isRegular: Bool, priorCoverage: (expected: Set<CGWindowID>, uncoverable: Set<CGWindowID>)?)] = []
        plan.reserveCapacity(pids.count)
        var apps: [pid_t: NSRunningApplication] = [:]
        var accessoryPids = Set<pid_t>()
        for pid in pids {
            if pidBumpInFlight.contains(pid) {
                pidBumpPending.insert(pid)
                continue
            }
            // Direct pid lookup instead of scanning the whole running-app list;
            // `NSRunningApplication(processIdentifier:)` is O(1) and always
            // reflects the current process table.
            guard let app = NSRunningApplication(processIdentifier: pid) else {
                entries.removeValue(forKey: pid)
                pidCoverage.removeValue(forKey: pid)
                pidWriteGeneration[pid] = gen
                continue
            }
            let policy = app.activationPolicy
            guard policy == .regular || policy == .accessory else {
                entries.removeValue(forKey: pid)
                pidCoverage.removeValue(forKey: pid)
                pidWriteGeneration[pid] = gen
                continue
            }
            pidBumpInFlight.insert(pid)
            apps[pid] = app
            if policy == .accessory { accessoryPids.insert(pid) }
            plan.append((pid, policy == .regular, pidCoverage[pid]))
        }
        guard !plan.isEmpty else { return }

        snapshotQueue.async { [weak self] in
            let cgSnapshot = WindowEnumerator.snapshotCGWindowMap()
            let count = plan.count
            // Reuse the memoized uncoverable wids only while the CG hint is
            // unchanged from the bump that produced them; any hint change (a real
            // window opened/closed) drops back to a full sweep that re-memoizes.
            func scan(_ item: (pid: pid_t, isRegular: Bool, priorCoverage: (expected: Set<CGWindowID>, uncoverable: Set<CGWindowID>)?)) -> BumpScan {
                let expected = cgSnapshot.ids(for: item.pid)
                let known = (item.priorCoverage?.expected == expected) ? (item.priorCoverage?.uncoverable ?? []) : []
                let result = WindowEnumerator.enumerate(
                    forPid: item.pid,
                    isRegularApp: item.isRegular,
                    expectedCGWindowIDs: expected,
                    cgZOrder: cgSnapshot.zOrder(for: item.pid),
                    knownUncoverable: known
                )
                return BumpScan(windows: result.windows, expected: expected, uncoverable: result.uncoverable)
            }
            var scanBuffer = [BumpScan](repeating: BumpScan(), count: count)
            if count == 1 {
                scanBuffer[0] = scan(plan[0])
            } else {
                // Parallelize the per-pid AX scans (each blocks on AX timeouts)
                // while still sharing the single CG snapshot above.
                scanBuffer.withUnsafeMutableBufferPointer { buffer in
                    nonisolated(unsafe) let bufferRef = buffer
                    DispatchQueue.concurrentPerform(iterations: count) { i in
                        bufferRef[i] = scan(plan[i])
                    }
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                var rebump = Set<pid_t>()
                for i in 0..<count {
                    let pid = plan[i].pid
                    let scan = scanBuffer[i]
                    self.pidBumpInFlight.remove(pid)
                    if let app = apps[pid], (self.pidWriteGeneration[pid] ?? 0) <= gen {
                        self.pidWriteGeneration[pid] = gen
                        if plan[i].isRegular {
                            self.entries[pid] = AppCacheEntry(app: app, windows: scan.windows)
                            self.pidCoverage[pid] = (scan.expected, scan.uncoverable)
                        } else if accessoryPids.contains(pid), !scan.windows.isEmpty {
                            self.entries[pid] = AppCacheEntry(app: app, windows: scan.windows)
                            self.pidCoverage[pid] = (scan.expected, scan.uncoverable)
                        } else {
                            self.entries.removeValue(forKey: pid)
                            self.pidCoverage.removeValue(forKey: pid)
                        }
                    }
                    // Re-bump if another request landed while in flight —
                    // captures AX state that changed between scan and
                    // completion (typical during rapid window-creation bursts).
                    if self.pidBumpPending.remove(pid) != nil {
                        rebump.insert(pid)
                    }
                }
                if !rebump.isEmpty {
                    self.bumpApps(pids: rebump)
                }
            }
        }
    }

    nonisolated deinit {
        let nc = NSWorkspace.shared.notificationCenter
        let snapshot = MainActor.assumeIsolated { (observers, axObservers) }
        for o in snapshot.0 {
            nc.removeObserver(o)
        }
        for (_, observer) in snapshot.1 {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
    }
}
