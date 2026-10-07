import AppKit
import Testing
@testable import BetterCmdTab

@Suite("NSRunningApplication pid recovery")
struct RunningApplicationPidTests {

    @Test("finds a process by the executable and launch date LaunchServices reports")
    func findsProcessFromLaunchServicesFacts() throws {
        let host = NSRunningApplication.current
        let path = try #require(host.executableURL?.path)
        let launchDate = try #require(host.launchDate)
        #expect(NSRunningApplication.pidOfProcess(executablePath: path, startedNear: launchDate) == getpid())
    }

    @Test("no process runs the executable")
    func unknownExecutable() {
        #expect(NSRunningApplication.pidOfProcess(executablePath: "/nonexistent/Emacs-arm64-11", startedNear: .now) == nil)
    }

    @Test("a later relaunch of the same executable is not the process LaunchServices meant")
    func relaunchIsNotAMatch() throws {
        let host = NSRunningApplication.current
        let path = try #require(host.executableURL?.path)
        let launchDate = try #require(host.launchDate)
        #expect(NSRunningApplication.pidOfProcess(executablePath: path, startedNear: launchDate.addingTimeInterval(-60)) == nil)
    }
}
