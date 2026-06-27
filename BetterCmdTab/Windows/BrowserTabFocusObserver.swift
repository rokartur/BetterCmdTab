import AppKit
import ApplicationServices
import CoreGraphics

/// Always-on AX observation of running browsers' active-tab changes, feeding
/// `BrowserTabMRUTracker` so the experimental browser-tab-MRU mode can return ⌘Tab
/// to the previously used *tab*, not just the previous window (#39).
///
/// A browser tab switch makes the window's AX title flip to the new active tab,
/// but `AppCatalogCache` deliberately DROPS `kAXTitleChangedNotification` while the
/// panel is hidden (title churn is the loudest notification) — so tab switches the
/// user makes between ⌘Tab presses are invisible to it. This observer fills that
/// gap, but ONLY for browser apps and ONLY while the pref is on, so the cost is
/// strictly opt-in. It reads the focused window's AX title (a cheap attribute) on
/// each change — never Apple Events — and bumps the tracker.
///
/// One `AXObserver` per running browser, created off-main (the AX add can block on
/// a slow app) and its run-loop source installed on main. Lifecycle follows
/// NSWorkspace launch/terminate.
@MainActor
final class BrowserTabFocusObserver {
    private unowned let tracker: BrowserTabMRUTracker
    private var observers: [pid_t: AXObserver] = [:]
    /// pids whose observer is being built off-main, so a second launch/scan can't
    /// double-create before the first install lands.
    private var building: Set<pid_t> = []
    /// pids with a focused-window read in flight, coalescing a burst of title
    /// notifications for one app into a single off-main AX read.
    private var inFlight: Set<pid_t> = []
    private var launchObs: NSObjectProtocol?
    private var termObs: NSObjectProtocol?
    private var enabled = false

    nonisolated private static let notifications: [String] = [
        kAXTitleChangedNotification as String,
        kAXFocusedWindowChangedNotification as String,
        kAXMainWindowChangedNotification as String,
    ]

    init(tracker: BrowserTabMRUTracker) { self.tracker = tracker }

    nonisolated deinit {
        MainActor.assumeIsolated {
            if enabled { stop() }
        }
    }

    /// Turn observation on/off. Idempotent. Off tears down every observer and the
    /// workspace hooks, so a disabled feature costs nothing.
    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if on { start() } else { stop() }
    }

    private func start() {
        let nc = NSWorkspace.shared.notificationCenter
        launchObs = nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                   object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.addObserver(for: app) }
        }
        termObs = nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                 object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated {
                self?.removeObserver(pid: pid)
                // The window's tabs are gone with the app — but we don't know its
                // wids here; the tracker's cap + dead-key harmlessness covers it.
            }
        }
        for app in NSWorkspace.shared.runningApplications { addObserver(for: app) }
        // Seed the current tab so the FIRST ⌘Tab after enabling/launch already has
        // it as most-recent (row 0), before any focus change is observed — otherwise
        // an as-yet-unseen current tab sinks to the back and the first step lands
        // wrong until the tracker warms.
        seedFrontmost()
    }

    /// Bump the frontmost browser's active tab to MRU front, once, on enable.
    private func seedFrontmost() {
        guard enabled,
              let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != getpid(),
              BrowserTabs.Family.from(bundleID: front.bundleIdentifier) != nil else { return }
        handleChange(pid: front.processIdentifier)
    }

    private func stop() {
        let nc = NSWorkspace.shared.notificationCenter
        if let o = launchObs { nc.removeObserver(o); launchObs = nil }
        if let o = termObs { nc.removeObserver(o); termObs = nil }
        for pid in Array(observers.keys) { removeObserver(pid: pid) }
        observers.removeAll()
        building.removeAll()
        inFlight.removeAll()
    }

    private func addObserver(for app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard enabled,
              observers[pid] == nil, !building.contains(pid),
              pid != getpid(),
              BrowserTabs.Family.from(bundleID: app.bundleIdentifier) != nil else { return }
        building.insert(pid)
        // Encode the refcon as a bit-pattern integer so it crosses the queue
        // boundary as a Sendable value (mirrors AppCatalogCache).
        let refconBits = UInt(bitPattern: Unmanaged.passUnretained(self).toOpaque())
        DispatchQueue.global(qos: .utility).async {
            guard let refcon = UnsafeMutableRawPointer(bitPattern: refconBits) else { return }
            let observer = Self.buildObserver(pid: pid, refcon: refcon)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.building.remove(pid)
                guard self.enabled, self.observers[pid] == nil, let observer else { return }
                CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
                self.observers[pid] = observer
            }
        }
    }

    private func removeObserver(pid: pid_t) {
        building.remove(pid)
        inFlight.remove(pid)
        guard let observer = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    /// Off-main AX work: create the observer and register the notifications. The
    /// returned observer isn't bound to a run loop yet — the caller installs the
    /// source on main. Mirrors `AppCatalogCache.buildAXObserver`.
    nonisolated private static func buildObserver(pid: pid_t, refcon: UnsafeMutableRawPointer) -> AXObserver? {
        var observer: AXObserver?
        let cb: AXObserverCallback = { _, element, _, refcon in
            guard let refcon else { return }
            let me = Unmanaged<BrowserTabFocusObserver>.fromOpaque(refcon).takeUnretainedValue()
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            // The callback fires on the main run loop (the source is added there).
            MainActor.assumeIsolated { me.handleChange(pid: pid) }
        }
        guard AXObserverCreate(pid, cb, &observer) == .success, let observer else { return nil }
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.2)
        for name in notifications { _ = AXObserverAddNotification(observer, axApp, name as CFString, refcon) }
        return observer
    }

    /// A browser fired a title/focus change — resolve its focused window's active
    /// tab off-main and bump it to MRU front. Coalesced per pid.
    private func handleChange(pid: pid_t) {
        guard enabled, !inFlight.contains(pid) else { return }
        inFlight.insert(pid)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let info = Self.focusedWindowInfo(pid: pid)
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight.remove(pid)
                guard self.enabled, let info, info.wid != 0,
                      !info.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                self.tracker.bump(BrowserTabMRUTracker.tabKey(wid: info.wid, title: info.title))
            }
        }
    }

    /// The pid's focused window's CGWindowID and AX title (its active tab's title
    /// for a browser). `nonisolated` so it runs off the main thread — the AX reads
    /// can stall for the messaging timeout on an unresponsive app.
    nonisolated static func focusedWindowInfo(pid: pid_t) -> (wid: CGWindowID, title: String)? {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.05)
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let focusedVal = focused,
              CFGetTypeID(focusedVal) == AXUIElementGetTypeID() else { return nil }
        let window = focusedVal as! AXUIElement
        let wid = PrivateAPI.cgWindowId(of: window)
        var titleVal: AnyObject?
        let title = (AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleVal) == .success
            ? titleVal as? String : nil) ?? ""
        return (wid, title)
    }
}
