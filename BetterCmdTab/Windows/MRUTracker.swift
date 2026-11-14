import AppKit
import os

@MainActor
final class MRUTracker {
    private(set) var order: [pid_t] = []

    func start() {
        guard termObservers.isEmpty else { return }
        seedFromCurrent()
        let termObs = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            MainActor.assumeIsolated { self?.remove(app.pid) }
        }
        termObservers.append(termObs)
        // An app that launches without activating never gets bumped and would
        // list after every app used since launch. Regular apps only: a
        // windowless helper must not become a quick-switch candidate.
        let launchObs = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.activationPolicy == .regular,
                  UserDefaults.standard.bool(forKey: Preferences.Keys.launchedAppsNearTop)
            else { return }
            let pid = app.pid
            MainActor.assumeIsolated { self?.noteLaunch(pid) }
        }
        termObservers.append(launchObs)
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        for observer in termObservers { center.removeObserver(observer) }
        termObservers.removeAll()
    }

    private var termObservers: [NSObjectProtocol] = []

    nonisolated deinit {
        tearDownOnMainActor { stop() }
    }

    private func seedFromCurrent() {
        let selfPid = getpid()
        let candidates = NSWorkspace.shared.runningApplications.filter { app in
            guard app.pid != selfPid else { return false }
            return app.activationPolicy == .regular || app.activationPolicy == .accessory
        }
        order = candidates.map { $0.pid }
        if let front = NSWorkspace.shared.frontmostApplication?.pid, front != selfPid {
            bump(front)
        }
    }

    func syncFrontmost() {
        let selfPid = getpid()
        guard let front = NSWorkspace.shared.frontmostApplication?.pid,
              front != selfPid else { return }
        if order.first != front {
            Log.mru.debug("syncFrontmost drift front=\(front, privacy: .public) was=\(self.order.first ?? -1, privacy: .public)")
            bump(front)
        }
    }

    func bump(_ pid: pid_t) {
        order.removeAll { $0 == pid }
        order.insert(pid, at: 0)
    }

    /// Ranks an app that launched without activating right behind the current
    /// and previous apps, so it lists near the top instead of after every
    /// ranked app. Not at index 1: that is the quick ⌘Tab and swipe target.
    func noteLaunch(_ pid: pid_t) {
        guard !order.contains(pid) else { return }
        order.insert(pid, at: min(2, order.count))
    }

    private func remove(_ pid: pid_t) {
        order.removeAll { $0 == pid }
    }
}
