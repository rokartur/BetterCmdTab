import AppKit
import ApplicationServices

@MainActor
final class AppCatalogCache {
    struct AppCacheEntry {
        let app: NSRunningApplication
        let windows: [WindowInfo]
    }

    private(set) var entries: [pid_t: AppCacheEntry] = [:]
    private var pendingRefresh = false
    private var pendingBumps: Set<pid_t> = []
    /// Per-pid serialization for `bumpApp`. `snapshotQueue` is concurrent, so
    /// two bumps for the same pid can race — and since later snapshots can
    /// finish *before* earlier ones, the stale completion overwrites fresh
    /// data and the cache gets stuck (e.g. burst of 10 window creates ends
    /// with cache showing 5 because the slow first bump landed last). With
    /// in-flight tracking only one bump per pid runs at a time; any extra
    /// request collapses into a single "pending" slot that re-bumps once the
    /// current one finishes, so we always converge on the latest state.
    private var pidBumpInFlight: Set<pid_t> = []
    private var pidBumpPending: Set<pid_t> = []
    private weak var mru: MRUTracker?
    private var observers: [NSObjectProtocol] = []
    private var axObservers: [pid_t: AXObserver] = [:]
    private var axObserversInstalling: Set<pid_t> = []
    private var pendingOneShotCompletions: [() -> Void] = []
    private let snapshotQueue = DispatchQueue(label: "BetterCmdTab.snapshot", qos: .userInteractive, attributes: .concurrent)
    private let axInstallQueue = DispatchQueue(label: "BetterCmdTab.axInstall", qos: .utility, attributes: .concurrent)

    /// AX notifications subscribed per running app. Together these cover every
    /// state change that affects the switcher rows: window add/remove,
    /// minimize/restore, title change, focus change, hide/unhide.
    nonisolated private static let axNotifications: [String] = [
        kAXWindowCreatedNotification as String,
        kAXUIElementDestroyedNotification as String,
        kAXWindowMiniaturizedNotification as String,
        kAXWindowDeminiaturizedNotification as String,
        kAXTitleChangedNotification as String,
        kAXFocusedWindowChangedNotification as String,
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
        // Kept for API compatibility. AXObserver model removed the periodic
        // timer entirely — visibility no longer affects refresh cadence.
        _ = visible
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
        for entry in entries.values where !seen.contains(entry.app.processIdentifier) {
            ordered.append(entry)
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
                    result.append(SwitcherRow(
                        app: entry.app,
                        window: window.ref,
                        windowTitle: window.title,
                        isMinimized: window.isMinimized,
                        isFullscreen: window.isFullscreen
                    ))
                }
            }
        }
        let sorted = result.enumerated().sorted { lhs, rhs in
            let pa = Self.statusPriority(lhs.element)
            let pb = Self.statusPriority(rhs.element)
            if pa != pb { return pa < pb }
            return lhs.offset < rhs.offset
        }.map { $0.element }
        return CatalogFilter.filteredRows(sorted, CatalogFilter.config())
    }

    private static func statusPriority(_ row: SwitcherRow) -> Int {
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
        snapshotQueue.async { [weak self] in
            let fresh = Self.computeEntries()
            DispatchQueue.main.async {
                guard let self else { return }
                self.entries = fresh
                self.pendingRefresh = false
                IconCache.prewarm(pids: Array(fresh.keys))
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
                    self?.bumpApp(pid: pid)
                }
            }
            observers.append(obs)
        }
        let terminateObs = nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            Task { @MainActor [weak self] in
                self?.uninstallAXObserver(forPid: pid)
                self?.entries.removeValue(forKey: pid)
                IconCache.evict(pid)
            }
        }
        observers.append(terminateObs)
        let launchObs = nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            Task { @MainActor [weak self] in
                self?.installAXObserver(forPid: pid)
                self?.bumpApp(pid: pid)
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
        let pids = NSWorkspace.shared.runningApplications.map(\.processIdentifier)
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
        let cb: AXObserverCallback = { _, element, _, refcon in
            guard let refcon else { return }
            let cache = Unmanaged<AppCatalogCache>.fromOpaque(refcon).takeUnretainedValue()
            var elemPid: pid_t = 0
            AXUIElementGetPid(element, &elemPid)
            DispatchQueue.main.async {
                cache.scheduleBumpApp(pid: elemPid)
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
        guard let observer = axObservers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    /// Coalesces AX notification storms — bursts of `kAXTitleChanged` or rapid
    /// window creation collapse to a single bumpApp call within the next run
    /// loop tick.
    private func scheduleBumpApp(pid: pid_t) {
        let wasEmpty = pendingBumps.isEmpty
        pendingBumps.insert(pid)
        if wasEmpty {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let toBump = self.pendingBumps
                self.pendingBumps.removeAll()
                for p in toBump { self.bumpApp(pid: p) }
            }
        }
    }

    func bumpApp(pid: pid_t) {
        // Self is no longer force-removed: as an accessory app it only earns a
        // cache entry when it has a window (the Settings window). Showing/hiding
        // the borderless switcher panel yields no standard window, so a self
        // bump just clears the entry again.
        if pidBumpInFlight.contains(pid) {
            pidBumpPending.insert(pid)
            return
        }
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == pid }) else {
            entries.removeValue(forKey: pid)
            return
        }
        let policy = app.activationPolicy
        guard policy == .regular || policy == .accessory else {
            entries.removeValue(forKey: pid)
            return
        }
        let isRegular = policy == .regular
        pidBumpInFlight.insert(pid)
        snapshotQueue.async { [weak self] in
            let cgSnapshot = WindowEnumerator.snapshotCGWindowMap()
            let windows = WindowEnumerator.windows(
                forPid: pid,
                isRegularApp: isRegular,
                expectedCGWindowIDs: cgSnapshot.ids(for: pid),
                cgZOrder: cgSnapshot.zOrder(for: pid)
            )
            DispatchQueue.main.async {
                guard let self else { return }
                self.pidBumpInFlight.remove(pid)
                if policy == .regular {
                    self.entries[pid] = AppCacheEntry(app: app, windows: windows)
                } else if policy == .accessory, !windows.isEmpty {
                    self.entries[pid] = AppCacheEntry(app: app, windows: windows)
                } else {
                    self.entries.removeValue(forKey: pid)
                }
                // Re-bump if another request landed while we were in flight —
                // captures any AX state change that happened between scan and
                // completion (typical during rapid window creation bursts).
                if self.pidBumpPending.remove(pid) != nil {
                    self.bumpApp(pid: pid)
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
