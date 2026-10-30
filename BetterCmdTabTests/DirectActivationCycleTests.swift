import CoreGraphics
import Testing
@testable import BetterCmdTab

@Suite("Direct activation window cycle (#217)")
struct DirectActivationCycleTests {
    private func target(_ frontToBack: [CGWindowID], onscreen: Set<CGWindowID>, ax: Set<CGWindowID>? = nil) -> CGWindowID? {
        let snapshot = CGWindowSnapshot(
            ids: [7: Set(frontToBack)], zOrder: [7: frontToBack], nonNormalLayer: [:], onscreen: [7: onscreen])
        return Activator.cycleTarget(pid: 7, axWindows: ax ?? Set(frontToBack), in: snapshot)
    }

    @Test("repeat presses visit every window instead of trading the front two")
    func pressesWalkEveryWindow() throws {
        var stack: [CGWindowID] = [1, 2, 3]
        var raised: [CGWindowID] = []
        for _ in 0..<3 {
            let wid = try #require(target(stack, onscreen: Set(stack)))
            raised.append(wid)
            stack.removeAll { $0 == wid }
            stack.insert(wid, at: 0)
        }
        #expect(raised == [3, 2, 1])
    }

    @Test("windows off screen or out of AX reach are skipped, and one window does not cycle")
    func onlyReachableOnScreenWindowsCycle() {
        #expect(target([1, 2, 3], onscreen: [1, 2]) == 2)
        #expect(target([1, 2, 3], onscreen: [1, 2, 3], ax: [1, 2]) == 2)
        #expect(target([1, 2], onscreen: [1]) == nil)
    }
}
