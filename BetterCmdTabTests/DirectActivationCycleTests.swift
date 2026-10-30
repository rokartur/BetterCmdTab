import CoreGraphics
import Testing
@testable import BetterCmdTab

@Suite("Direct activation window cycle (#217)")
struct DirectActivationCycleTests {
    @Test("repeat presses walk every window in stack order, like ⌘`")
    func pressesWalkEveryWindow() throws {
        var stack: [CGWindowID] = [1, 2, 3, 4]
        var last: Activator.CyclePress?
        var raised: [CGWindowID] = []
        for _ in 0..<6 {
            let press = try #require(Activator.cycleTarget(frontToBack: stack, axWindowIDs: Set(stack), last: last))
            raised.append(press.wid)
            last = press
            stack.removeAll { $0 == press.wid }
            stack.insert(press.wid, at: 0)
        }
        #expect(raised == [2, 3, 4, 1, 2, 3])
    }

    @Test("a press after another window came to front starts a new run at the second window")
    func newRunAfterTheFrontChanges() {
        let stale: Activator.CyclePress = (wid: 3, step: 2)
        #expect(Activator.cycleTarget(frontToBack: [1, 2, 3], axWindowIDs: [1, 2, 3], last: stale)?.wid == 2)
    }

    @Test("only on-screen windows AX can raise take part, and one window does not cycle")
    func onlyReachableWindowsCycle() {
        #expect(Activator.cycleTarget(frontToBack: [1, 2, 3], axWindowIDs: [1, 3], last: nil)?.wid == 3)
        #expect(Activator.cycleTarget(frontToBack: [1, 2], axWindowIDs: [1, 2, 9], last: nil)?.wid == 2)
        #expect(Activator.cycleTarget(frontToBack: [1, 2], axWindowIDs: [1], last: nil) == nil)
        #expect(Activator.cycleTarget(frontToBack: [], axWindowIDs: [1, 2], last: nil) == nil)
    }
}
