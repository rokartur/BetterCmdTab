import AppKit
import ApplicationServices
import os

/// Collapses a burst of Dock AX notifications into a single scheduled action.
/// `arm()` returns true only on the false→true transition — the caller then
/// schedules one debounced pass; further arms during the window are swallowed.
/// `disarm()` resets it when the pass fires. Pure + testable.
struct BadgeRefreshLatch {
    private(set) var scheduled = false
    mutating func arm() -> Bool {
        if scheduled { return false }
        scheduled = true
        return true
    }
    mutating func disarm() { scheduled = false }
}

/// Live-refreshes app Dock badges (unread/notification counts) **while the
/// switcher panel is open**. Without it, badges only snapshot once at reveal, so
/// a count that ticks up while the user holds ⌘Tab open stays stale until the
/// panel is reopened.
///
/// Zero idle cost: it does work only between `start()` (panel shown) and `stop()`
/// (panel closed). There is no dependable "badge changed" AX notification — the
/// Dock does not reliably post one when an `AXStatusLabel` changes — so a pure
/// event-driven approach misses changes. Two mechanisms, both panel-open-only:
///   1. A poll (`pollIntervalSeconds`) that re-reads badges while the panel is
///      visible — the reliable floor that always catches a change within one tick.
///   2. An AX observer on the Dock tree (app element + item `AXList` + each item)
///      as a bonus fast-path: if the Dock *does* post a notification it refreshes
///      instantly; when it stays silent it simply costs nothing.
/// The refresh is change-gated controller-side, so an unchanged poll/notification
/// never repaints rows.
///
/// All state is `@MainActor`; the AX callback's run-loop source is attached to the
/// main run loop, and only the (potentially slow) AX subscription build runs
/// off-main, mirroring `AppCatalogCache`'s observer machinery.
@MainActor
final class DockBadgeObserver {
    /// Called on the main actor when the Dock badges may have changed (debounced).
    /// The owner re-reads `DockBadgeReader.snapshot()` off-main and repaints.
    var onBadgesChanged: (() -> Void)?

    private var observer: AXObserver?
    private var subscriptions: [(element: AXUIElement, name: String)] = []
    private var dockPid: pid_t = 0
    private var isArmed = false
    /// Bumped on every (re)build/teardown so a build that completes off-main after
    /// a `stop()`/rebuild superseded it is discarded instead of attached.
    private var buildGeneration: UInt64 = 0
    private var refreshLatch = BadgeRefreshLatch()
    private var resubscribeLatch = BadgeRefreshLatch()
    private var dockLaunchObserver: NSObjectProtocol?
    /// Bumped on every start/stop so a pending poll tick from a previous arm bails
    /// instead of stacking a second chain.
    private var pollGeneration = 0

    nonisolated private static let dockBundleID = "com.apple.dock"
    /// Panel-open poll cadence. The panel is open only briefly, so this is a
    /// handful of off-main Dock scans per session — never any idle cost.
    private static let pollIntervalSeconds = 0.6
    private let buildQueue = DispatchQueue(label: "pro.bettercmdtab.DockBadgeObserver.build", qos: .utility)

    /// Structural changes (an item appears/disappears or the dock re-lays-out) —
    /// these also mean the per-item subscription set is stale and must be rebuilt.
    nonisolated private static let structuralNotifications: [String] = [
        kAXCreatedNotification as String,
        kAXUIElementDestroyedNotification as String,
        kAXLayoutChangedNotification as String,
    ]
    /// In-place value/title changes — an existing badge ticking "3" → "4".
    nonisolated private static let valueNotifications: [String] = [
        kAXValueChangedNotification as String,
        kAXTitleChangedNotification as String,
    ]

    // MARK: - Lifecycle

    /// Arm the observer (no-op if `enabled` is false or already armed). `enabled`
    /// tracks the `showUnreadBadges` preference so a disabled feature does nothing.
    func start(enabled: Bool) {
        guard enabled, !isArmed else { return }
        isArmed = true
        // Re-resolve the Dock relaunch (pid changes) while the panel is open, so a
        // mid-open Dock crash/relaunch re-arms against the new process.
        dockLaunchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == DockBadgeObserver.dockBundleID else { return }
            Task { @MainActor [weak self] in self?.restartForDockRelaunch() }
        }
        installObserver()
        // Reliable floor: the Dock posts no dependable AX notification on a badge
        // change, so poll while the panel is open. The AX observer above only
        // shortens latency when the Dock happens to post something.
        pollGeneration += 1
        schedulePollTick(generation: pollGeneration)
    }

    /// Disarm and fully tear down. Idempotent — safe on every panel-close path,
    /// including ones that never armed (feature off).
    func stop() {
        guard isArmed else { return }
        isArmed = false
        pollGeneration += 1   // invalidate any pending poll tick
        refreshLatch.disarm()
        resubscribeLatch.disarm()
        if let dockLaunchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(dockLaunchObserver)
            self.dockLaunchObserver = nil
        }
        teardownObserver()
    }

    private func restartForDockRelaunch() {
        guard isArmed else { return }
        teardownObserver()
        installObserver()
    }

    // MARK: - Observer build / teardown

    /// Build the AXObserver + subscriptions off-main (the AX adds can stall on a
    /// busy Dock and must not block the reveal/hot path), then attach the run-loop
    /// source on main. A build superseded by a later teardown/rebuild is discarded.
    private func installObserver() {
        buildGeneration &+= 1
        let token = buildGeneration
        guard let pid = NSRunningApplication
            .runningApplications(withBundleIdentifier: Self.dockBundleID)
            .first?.processIdentifier else {
            Log.priv.error("DockBadgeObserver: Dock process not found; live badge refresh off this session")
            return
        }
        dockPid = pid
        let refconBits = UInt(bitPattern: Unmanaged.passUnretained(self).toOpaque())
        buildQueue.async { [weak self] in
            guard let refcon = UnsafeMutableRawPointer(bitPattern: refconBits) else { return }
            let built = DockBadgeObserver.buildObserver(pid: pid, refcon: refcon)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // Stale (a stop()/rebuild ran while we were building) — drop it.
                // The observer was never attached to a run loop, so releasing it
                // tears down every subscription with no leak.
                guard self.isArmed, token == self.buildGeneration, let built else { return }
                CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(built.observer), .defaultMode)
                self.observer = built.observer
                self.subscriptions = built.subscriptions
            }
        }
    }

    private func teardownObserver() {
        // Invalidate any in-flight off-main build so it can't attach after us.
        buildGeneration &+= 1
        if let observer {
            // Drop the AX-server subscriptions before detaching the run-loop
            // source (mirrors the add side); removing only the source leaves the
            // notifications dangling.
            for sub in subscriptions {
                _ = AXObserverRemoveNotification(observer, sub.element, sub.name as CFString)
            }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        subscriptions.removeAll()
        observer = nil
        dockPid = 0
    }

    /// Pure AX-side work, run off-main. Creates the observer and subscribes the
    /// Dock app element, its item list, and each dock item. The returned observer
    /// is not yet bound to a run loop — the caller hops to main to install the
    /// source.
    nonisolated private static func buildObserver(
        pid: pid_t,
        refcon: UnsafeMutableRawPointer
    ) -> (observer: AXObserver, subscriptions: [(element: AXUIElement, name: String)])? {
        var obs: AXObserver?
        guard AXObserverCreate(pid, callback, &obs) == .success, let obs else { return nil }

        let axDock = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axDock, 0.2)

        var subs: [(element: AXUIElement, name: String)] = []
        func add(_ element: AXUIElement, _ names: [String]) {
            for name in names where AXObserverAddNotification(obs, element, name as CFString, refcon) == .success {
                subs.append((element, name))
            }
        }
        // App element + item list: structural changes and (on some macOS versions)
        // app-wide value changes. Each dock item: its in-place value/title change.
        add(axDock, structuralNotifications + valueNotifications)
        if let list = DockBadgeReader.firstAXList(of: axDock) {
            AXUIElementSetMessagingTimeout(list, 0.2)
            add(list, structuralNotifications + valueNotifications)
            for item in DockBadgeReader.children(of: list) {
                AXUIElementSetMessagingTimeout(item, 0.1)
                add(item, valueNotifications)
            }
        }
        return (obs, subs)
    }

    nonisolated private static let callback: AXObserverCallback = { _, _, notification, refcon in
        guard let refcon else { return }
        let observer = Unmanaged<DockBadgeObserver>.fromOpaque(refcon).takeUnretainedValue()
        let structural = CFEqual(notification, kAXCreatedNotification as CFString)
            || CFEqual(notification, kAXUIElementDestroyedNotification as CFString)
            || CFEqual(notification, kAXLayoutChangedNotification as CFString)
        // The source is attached to the main run loop, so the callback fires on
        // main; hop through the main queue (matching AppCatalogCache) to touch
        // @MainActor state.
        DispatchQueue.main.async { observer.notificationFired(structural: structural) }
    }

    // MARK: - Change handling

    private func notificationFired(structural: Bool) {
        guard isArmed else { return }
        // A structural change means new/removed dock items — the per-item
        // subscription set is stale, so rebuild it (debounced).
        if structural { scheduleResubscribe() }
        scheduleBadgeRefresh()
    }

    /// Coalesce a burst of notifications into one signal after a short settle.
    private func scheduleBadgeRefresh() {
        guard refreshLatch.arm() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.refreshLatch.disarm()
            guard self.isArmed else { return }
            self.onBadgesChanged?()
        }
    }

    /// Panel-open poll: re-signal every `pollIntervalSeconds` while armed. The
    /// generation guard drops a tick left over from a previous arm so two chains
    /// never run. The signalled refresh is change-gated downstream, so an
    /// unchanged tick repaints nothing.
    private func schedulePollTick(generation: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pollIntervalSeconds) { [weak self] in
            guard let self, self.isArmed, generation == self.pollGeneration else { return }
            self.onBadgesChanged?()
            self.schedulePollTick(generation: generation)
        }
    }

    private func scheduleResubscribe() {
        guard resubscribeLatch.arm() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.resubscribeLatch.disarm()
            guard self.isArmed else { return }
            self.teardownObserver()
            self.installObserver()
        }
    }

    nonisolated deinit {
        // Backstop — the owner brackets lifetime, so this normally runs already
        // torn down. Mirrors AppCatalogCache.deinit.
        let captured = MainActor.assumeIsolated { (observer, subscriptions, dockLaunchObserver) }
        if let observer = captured.0 {
            for sub in captured.1 {
                _ = AXObserverRemoveNotification(observer, sub.element, sub.name as CFString)
            }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        if let dockLaunchObserver = captured.2 {
            NSWorkspace.shared.notificationCenter.removeObserver(dockLaunchObserver)
        }
    }
}
