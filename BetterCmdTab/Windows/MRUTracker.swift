import AppKit
import os

final class MRUTracker {
    private(set) var order: [pid_t] = []

    func start() {
        seedFromCurrent()
        let termObs = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            self?.remove(app.processIdentifier)
        }
        termObservers.append(termObs)
    }

    private var termObservers: [NSObjectProtocol] = []

    deinit {
        for o in termObservers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
    }

    private func seedFromCurrent() {
        let selfPid = getpid()
        let candidates = NSWorkspace.shared.runningApplications.filter { app in
            guard app.processIdentifier != selfPid else { return false }
            return app.activationPolicy == .regular || app.activationPolicy == .accessory
        }
        order = candidates.map { $0.processIdentifier }
        if let front = NSWorkspace.shared.frontmostApplication?.processIdentifier, front != selfPid {
            bump(front)
        }
    }

    func syncFrontmost() {
        let selfPid = getpid()
        guard let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
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

    private func remove(_ pid: pid_t) {
        order.removeAll { $0 == pid }
    }
}
