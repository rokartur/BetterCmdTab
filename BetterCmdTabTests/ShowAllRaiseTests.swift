import Foundation
import Testing
@testable import BetterCmdTab

/// Pure-logic coverage for which app `Activator.showAllApps()` raises back on top
/// (the window the user hid everything from). The AX/activation side effects are
/// manual; the pid/bundleID resolution is isolated here so it stays testable
/// without constructing `NSRunningApplication`s.
@Suite("Show-all raise target")
struct ShowAllRaiseTests {
    typealias App = (pid: pid_t, bundleID: String?, terminated: Bool)

    @Test func nilWhenNothingRemembered() {
        let running: [App] = [(10, "com.a", false)]
        #expect(Activator.showAllRaisePid(remembered: nil, running: running) == nil)
    }

    @Test func matchesByPidSameSession() {
        let running: [App] = [(10, "com.a", false), (20, "com.b", false)]
        #expect(Activator.showAllRaisePid(remembered: (20, "com.b"), running: running) == 20)
    }

    @Test func pidReuseGuardedByBundleID() {
        // Same pid now belongs to a different app (reuse) → must not raise it;
        // fall back to the bundleID match (the relaunched source app).
        let running: [App] = [(20, "com.other", false), (33, "com.b", false)]
        #expect(Activator.showAllRaisePid(remembered: (20, "com.b"), running: running) == 33)
    }

    @Test func fallsBackToBundleIDOnRelaunch() {
        // Original pid gone, app relaunched under a new pid.
        let running: [App] = [(99, "com.b", false)]
        #expect(Activator.showAllRaisePid(remembered: (20, "com.b"), running: running) == 99)
    }

    @Test func nilWhenTargetTerminatedAndNoBundleMatch() {
        let running: [App] = [(20, "com.b", true)]
        #expect(Activator.showAllRaisePid(remembered: (20, "com.b"), running: running) == nil)
    }

    @Test func nilWhenGoneAndNoBundleIDRecorded() {
        let running: [App] = [(10, "com.a", false)]
        #expect(Activator.showAllRaisePid(remembered: (20, nil), running: running) == nil)
    }

    @Test func skipsTerminatedPidMatch() {
        // Pid matches but the process is terminated → skip, then bundleID rescue.
        let running: [App] = [(20, "com.b", true), (50, "com.b", false)]
        #expect(Activator.showAllRaisePid(remembered: (20, "com.b"), running: running) == 50)
    }
}
