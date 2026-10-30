import CoreGraphics
import Testing
@testable import BetterCmdTab

@Suite("Direct activation window cycle (#217)")
struct DirectActivationCycleTests {
    @Test("repeat presses visit every window instead of trading the front two")
    func pressesWalkEveryWindow() throws {
        var stack: [CGWindowID] = [1, 2, 3]
        var raised: [CGWindowID] = []
        for _ in 0..<3 {
            let wid = try #require(Activator.cycleTarget(frontToBack: stack, axWindows: Set(stack)))
            raised.append(wid)
            stack.removeAll { $0 == wid }
            stack.insert(wid, at: 0)
        }
        #expect(raised == [3, 2, 1])
    }

    @Test("windows out of AX reach are skipped, and one window does not cycle")
    func onlyReachableWindowsCycle() {
        #expect(Activator.cycleTarget(frontToBack: [1, 2, 3], axWindows: [1, 2]) == 2)
        #expect(Activator.cycleTarget(frontToBack: [1, 2], axWindows: [1]) == nil)
    }
}
