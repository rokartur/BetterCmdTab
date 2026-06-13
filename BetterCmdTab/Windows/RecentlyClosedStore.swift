import AppKit

/// A window (or app) the user recently closed, captured so it can be reopened
/// from search. `documentPath` is the file the window was showing, when the AX
/// `AXDocument` attribute exposed one — that's what makes a reliable reopen
/// possible; without it we fall back to relaunching / reactivating the app.
struct RecentEntry: Codable, Hashable, Sendable {
    let bundleID: String
    let appName: String
    let title: String
    let documentPath: String?
    let closedAt: Date

    var documentURL: URL? { documentPath.map { URL(fileURLWithPath: $0) } }
}

/// Persistent, bounded history of recently closed windows/apps. Lives in
/// UserDefaults so it survives relaunches. Newest first.
@MainActor
final class RecentlyClosedStore {
    static let shared = RecentlyClosedStore()

    private(set) var entries: [RecentEntry] = []
    /// Pre-folded (appName, title) per entry, kept in lockstep with `entries`
    /// (rebuilt on every mutation — at most `cap` folds, off the search path)
    /// so each search keystroke folds only the query, not every stored entry.
    private var folded: [(name: String, title: String)] = []
    private let cap = 20
    private let key = "Switcher.recentlyClosed"
    private var observers: [NSObjectProtocol] = []
    /// pid → (bundleID, name) for regular apps, captured while they're alive.
    /// `NSRunningApplication`'s properties (including `activationPolicy`) are
    /// unreliable once the process has terminated, so we can't read them in the
    /// terminate notification — we look them up here instead.
    private var knownRegularApps: [pid_t: (bundleID: String, name: String)] = [:]

    private init() { load() }

    /// Begin recording app quits from anywhere — not just the switcher's own
    /// ⌘Q. We track every regular app's identity while it's running (seed at
    /// start, then launch/activate), and on termination record the tracked
    /// identity. This catches ⌘Q in a focused app, an app quitting itself, etc.
    /// Idempotent.
    func start() {
        guard observers.isEmpty else { return }
        let nc = NSWorkspace.shared.notificationCenter

        // Seed with apps already running when we start.
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            if let bundleID = app.bundleIdentifier, !bundleID.isEmpty {
                knownRegularApps[app.processIdentifier] = (bundleID, app.localizedName ?? bundleID)
            }
        }

        // Keep the map fresh as apps launch and as the user focuses them
        // (activation is when bundleID/name are reliably populated).
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didActivateApplicationNotification] {
            let obs = nc.addObserver(forName: name, object: nil, queue: .main) { note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.activationPolicy == .regular,
                      let bundleID = app.bundleIdentifier, !bundleID.isEmpty else { return }
                let pid = app.processIdentifier
                let appName = app.localizedName ?? bundleID
                Task { @MainActor in
                    RecentlyClosedStore.shared.noteRegularApp(pid: pid, bundleID: bundleID, name: appName)
                }
            }
            observers.append(obs)
        }

        let terminate = nc.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            Task { @MainActor in
                RecentlyClosedStore.shared.handleTermination(pid: pid)
            }
        }
        observers.append(terminate)
    }

    func noteRegularApp(pid: pid_t, bundleID: String, name: String) {
        knownRegularApps[pid] = (bundleID, name)
    }

    /// Record the terminated app using the identity captured while it was alive.
    /// Untracked pids (never seen as a regular app) are ignored, which keeps
    /// background helpers and daemons out of the list.
    func handleTermination(pid: pid_t) {
        guard let info = knownRegularApps.removeValue(forKey: pid) else { return }
        record(bundleID: info.bundleID, appName: info.name, title: "", documentPath: nil)
    }

    /// Record a freshly closed window/app. De-dupes on
    /// (bundleID, documentPath, title) so reopening the same thing repeatedly
    /// just refreshes its position at the front.
    /// Hosts that should never appear in reopen: the system permission/dialog
    /// agents (shared with the switcher's display handling) plus a few more
    /// menu-bar/system processes that aren't meaningful to reopen.
    private static let excludedBundleIDs: Set<String> = SwitcherRow.systemDialogHosts.union([
        "com.apple.systemuiserver",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.dock",
    ])

    func record(bundleID: String, appName: String, title: String, documentPath: String?) {
        guard !bundleID.isEmpty else { return }
        // Never record ourselves — BetterCmdTab shows in the switcher while its
        // Settings window is open, so closing that window must not land us in
        // the recently-closed list.
        guard bundleID != Bundle.main.bundleIdentifier else { return }
        // Keep system permission/dialog hosts out of reopen.
        guard !Self.excludedBundleIDs.contains(bundleID) else { return }
        entries.removeAll { $0.bundleID == bundleID && $0.documentPath == documentPath && $0.title == title }
        entries.insert(
            RecentEntry(bundleID: bundleID, appName: appName, title: title, documentPath: documentPath, closedAt: Date()),
            at: 0
        )
        if entries.count > cap { entries.removeLast(entries.count - cap) }
        refold()
        save()
    }

    /// Newest entries, capped at `limit`.
    func recent(limit: Int) -> [RecentEntry] {
        guard limit > 0 else { return [] }
        return Array(entries.prefix(limit))
    }

    /// Fuzzy-matched recent entries, newest first, capped at `limit`. Empty
    /// query returns nothing (callers fall back to `recent(limit:)`).
    func matches(query: String, limit: Int) -> [RecentEntry] {
        guard !query.isEmpty, limit > 0 else { return [] }
        let foldedQuery = FuzzyMatch.fold(query)
        var result: [RecentEntry] = []
        for i in entries.indices
        where FuzzyMatch.matchesFolded(foldedQuery: foldedQuery, foldedAppName: folded[i].name, foldedWindowTitle: folded[i].title) {
            result.append(entries[i])
            if result.count >= limit { break }
        }
        return result
    }

    func clear() {
        entries = []
        folded = []
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([RecentEntry].self, from: data) else { return }
        entries = decoded
        refold()
    }

    private func refold() {
        folded = entries.map { (FuzzyMatch.fold($0.appName), FuzzyMatch.fold($0.title)) }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
