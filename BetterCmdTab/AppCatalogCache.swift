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
    private weak var mru: MRUTracker?
    private var observers: [NSObjectProtocol] = []
    private var axObservers: [pid_t: AXObserver] = [:]
    private var pendingOneShotCompletions: [() -> Void] = []
    private let snapshotQueue = DispatchQueue(label: "BetterCmdTab.snapshot", qos: .userInteractive, attributes: .concurrent)

    /// AX notifications subscribed per running app. Together these cover every
    /// state change that affects the switcher rows: window add/remove,
    /// minimize/restore, title change, focus change, hide/unhide.
    private static let axNotifications: [String] = [
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
        return result.enumerated().sorted { lhs, rhs in
            let pa = Self.statusPriority(lhs.element)
            let pb = Self.statusPriority(rhs.element)
            if pa != pb { return pa < pb }
            return lhs.offset < rhs.offset
        }.map { $0.element }
    }

    private static func statusPriority(_ row: SwitcherRow) -> Int {
        if row.app.isHidden { return 2 }
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

    private static func computeEntries() -> [pid_t: AppCacheEntry] {
        let selfPid = getpid()
        let candidates = NSWorkspace.shared.runningApplications.filter { app in
            guard app.processIdentifier != selfPid else { return false }
            return app.activationPolicy == .regular || app.activationPolicy == .accessory
        }
        let count = candidates.count
        guard count > 0 else { return [:] }

        let cgMap = WindowEnumerator.snapshotCGWindowMap()

        var windowsBuffer: [[WindowInfo]] = Array(repeating: [], count: count)
        windowsBuffer.withUnsafeMutableBufferPointer { buffer in
            DispatchQueue.concurrentPerform(iterations: count) { i in
                let app = candidates[i]
                let pid = app.processIdentifier
                buffer[i] = WindowEnumerator.windows(
                    forPid: pid,
                    isRegularApp: app.activationPolicy == .regular,
                    expectedCGWindowIDs: cgMap[pid] ?? []
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

    private func installAXObserversForAllApps() {
        let selfPid = getpid()
        for app in NSWorkspace.shared.runningApplications where app.processIdentifier != selfPid {
            installAXObserver(forPid: app.processIdentifier)
        }
    }

    private func installAXObserver(forPid pid: pid_t) {
        guard pid != getpid(), axObservers[pid] == nil else { return }
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
        guard result == .success, let observer else {
            // App may not be AX-ready yet — workspace `didLaunchApplication`
            // fires before AX server registers. Skip silently; next bumpApp
            // through workspace events still keeps cache fresh.
            return
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let axApp = AXUIElementCreateApplication(pid)
        for name in Self.axNotifications {
            _ = AXObserverAddNotification(observer, axApp, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        axObservers[pid] = observer
    }

    private func uninstallAXObserver(forPid pid: pid_t) {
        guard let observer = axObservers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    /// Coalesces AX notification storms — bursts of `kAXTitleChanged` or rapid
    /// window creation collapse to a single bumpApp call within the next run
    /// loop tick.
    private func scheduleBumpApp(pid: pid_t) {
        guard pid != getpid() else { return }
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
        guard pid != getpid() else { return }
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
        snapshotQueue.async { [weak self] in
            let cgMap = WindowEnumerator.snapshotCGWindowMap()
            let windows = WindowEnumerator.windows(
                forPid: pid,
                isRegularApp: isRegular,
                expectedCGWindowIDs: cgMap[pid] ?? []
            )
            DispatchQueue.main.async {
                guard let self else { return }
                if policy == .regular {
                    self.entries[pid] = AppCacheEntry(app: app, windows: windows)
                } else if policy == .accessory, !windows.isEmpty {
                    self.entries[pid] = AppCacheEntry(app: app, windows: windows)
                } else {
                    self.entries.removeValue(forKey: pid)
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
