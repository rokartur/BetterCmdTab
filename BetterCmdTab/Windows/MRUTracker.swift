import AppKit
import os

@MainActor
final class MRUTracker {
    private(set) var order: [pid_t] = []

    func start() {
        guard observers.isEmpty else { return }
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
        observers.append(termObs)
        // An app that launches without activating never gets bumped and would
        // list after every app used since launch.
        // Regular apps only: a background helper must not push used apps down.
        let launchObs = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard UserDefaults.standard.bool(forKey: Preferences.Keys.launchedAppsNearTop),
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.activationPolicy == .regular
            else { return }
            MainActor.assumeIsolated {
                self?.noteLaunch(app.pid) { NSRunningApplication(processIdentifier: $0)?.activationPolicy == .regular }
            }
        }
        observers.append(launchObs)
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers { center.removeObserver(observer) }
        observers.removeAll()
    }

    private var observers: [NSObjectProtocol] = []

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
    /// and previous regular apps (the quick-tap list drops the rest), not after
    /// every ranked app. Never ahead of the previous app: the quick ⌘Tab and swipe target.
    func noteLaunch(_ pid: pid_t, isRegular: (pid_t) -> Bool) {
        guard !order.contains(pid) else { return }
        var regularSeen = 0
        for (index, ranked) in order.enumerated() where isRegular(ranked) {
            regularSeen += 1
            if regularSeen == 2 {
                order.insert(pid, at: index + 1)
                return
            }
        }
        order.append(pid)
    }

    private func remove(_ pid: pid_t) {
        order.removeAll { $0 == pid }
    }
}
