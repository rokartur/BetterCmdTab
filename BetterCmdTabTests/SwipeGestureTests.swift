import Dispatch
import Testing
@testable import BetterCmdTab

/// The production recognizer is one lock-protected process-wide state machine,
/// so serialize these tests and reset its configuration at each boundary.
@Suite("Three-finger swipe recognizer", .serialized)
struct SwipeGestureTests {
    private func reset(
        sensitivity: Int = MTGesture.defaultSensitivityLevel,
        oneShot: Bool = false,
        commitOnRelease: Bool = false
    ) {
        MTGesture.setSensitivity(sensitivity)
        MTGesture.setReverse(false)
        MTGesture.setOneShot(oneShot)
        MTGesture.setCommitOnRelease(commitOnRelease)
        MTGesture.reset()
    }

    @Test("coalesces all whole movement steps and preserves the remainder")
    func coalescesSteps() {
        reset(sensitivity: 10)
        let anchor = MTGesture.consume(device: 1, contactCount: 3, averageX: 0.10, timestamp: 1)
        let moved = MTGesture.consume(device: 1, contactCount: 3, averageX: 0.16, timestamp: 1.01)
        let remainderOnly = MTGesture.consume(device: 1, contactCount: 3, averageX: 0.17, timestamp: 1.02)

        #expect(anchor.steps == 0)
        #expect(moved.steps == 2)
        #expect(remainderOnly.steps == 0)
    }

    @Test("caps a malformed frame and discards its oversized remainder")
    func capsMalformedBurst() {
        reset(sensitivity: 10)
        _ = MTGesture.consume(device: 1, contactCount: 3, averageX: 0, timestamp: 1)
        let burst = MTGesture.consume(device: 1, contactCount: 3, averageX: 100, timestamp: 1.01)
        let settled = MTGesture.consume(device: 1, contactCount: 3, averageX: 100, timestamp: 1.02)

        #expect(burst.steps == 16)
        #expect(settled.steps == 0)
    }

    @Test("one-shot fires once and rearms only after a full lift")
    func oneShotRearmsOnLift() {
        reset(oneShot: true)
        _ = MTGesture.consume(device: 1, contactCount: 3, averageX: 0, timestamp: 1)
        let first = MTGesture.consume(device: 1, contactCount: 3, averageX: 0.09, timestamp: 1.01)
        let held = MTGesture.consume(device: 1, contactCount: 3, averageX: 0.20, timestamp: 1.02)
        _ = MTGesture.consume(device: 1, contactCount: 0, averageX: nil, timestamp: 1.03)
        _ = MTGesture.consume(device: 1, contactCount: 3, averageX: 0.20, timestamp: 2)
        let second = MTGesture.consume(device: 1, contactCount: 3, averageX: 0.10, timestamp: 2.01)

        #expect(first.steps == 1)
        #expect(held.steps == 0)
        #expect(second.steps == -1)
    }

    @Test("commit is emitted once after an active gesture fully lifts")
    func commitsOnceOnFullLift() {
        reset(commitOnRelease: true)
        _ = MTGesture.consume(device: 1, contactCount: 3, averageX: 0.4, timestamp: 1)
        let fingerFlicker = MTGesture.consume(device: 1, contactCount: 2, averageX: nil, timestamp: 1.01)
        let lift = MTGesture.consume(device: 1, contactCount: 0, averageX: nil, timestamp: 1.02)
        let duplicateLift = MTGesture.consume(device: 1, contactCount: 0, averageX: nil, timestamp: 1.03)

        #expect(!fingerFlicker.commit)
        #expect(lift.commit)
        #expect(!duplicateLift.commit)
    }

    @Test("another device cannot steal a live latch until it becomes stale")
    func deviceLatchAndStaleTakeover() {
        reset(sensitivity: 10)
        _ = MTGesture.consume(device: 1, contactCount: 3, averageX: 0.50, timestamp: 10)
        let ignored = MTGesture.consume(device: 2, contactCount: 3, averageX: 0.90, timestamp: 10.1)
        let ownerMove = MTGesture.consume(device: 1, contactCount: 3, averageX: 0.55, timestamp: 10.2)
        let takeoverAnchor = MTGesture.consume(device: 2, contactCount: 3, averageX: 0, timestamp: 10.8)
        let takeoverMove = MTGesture.consume(device: 2, contactCount: 3, averageX: 0.05, timestamp: 10.81)

        #expect(ignored.steps == 0)
        #expect(ownerMove.steps == 2)
        #expect(takeoverAnchor.steps == 0)
        #expect(takeoverMove.steps == 2)
    }

    @Test("non-finite contact data cannot trap or poison later frames")
    func nonFiniteInputRecovers() {
        reset(sensitivity: 10)
        _ = MTGesture.consume(device: 1, contactCount: 3, averageX: .infinity, timestamp: 1)
        let rejected = MTGesture.consume(device: 1, contactCount: 3, averageX: 0, timestamp: 1.01)
        let recovered = MTGesture.consume(device: 1, contactCount: 3, averageX: 0.05, timestamp: 1.02)

        #expect(rejected.steps == 0)
        #expect(recovered.steps == 2)
    }

    @Test("non-finite contact data cannot poison one-shot mode")
    func nonFiniteOneShotRecovers() {
        reset(oneShot: true)
        _ = MTGesture.consume(device: 1, contactCount: 3, averageX: 0, timestamp: 1)
        _ = MTGesture.consume(device: 1, contactCount: 3, averageX: .nan, timestamp: 1.01)
        let reanchor = MTGesture.consume(device: 1, contactCount: 3, averageX: 0, timestamp: 1.02)
        let recovered = MTGesture.consume(device: 1, contactCount: 3, averageX: 0.09, timestamp: 1.03)

        #expect(reanchor.steps == 0)
        #expect(recovered.steps == 1)
    }

    @Test("reset invalidates actions queued by an older trigger session")
    func resetInvalidatesQueuedAction() {
        reset(oneShot: true)
        _ = MTGesture.consume(device: 1, contactCount: 3, averageX: 0, timestamp: 1)
        let action = MTGesture.consume(device: 1, contactCount: 3, averageX: 0.09, timestamp: 1.01)

        #expect(MTGesture.isCurrent(generation: action.generation))
        MTGesture.reset()
        #expect(!MTGesture.isCurrent(generation: action.generation))
    }

    @Test("non-finite timestamps cannot steal a live device latch")
    func nonFiniteTimestampCannotTakeOver() {
        reset(sensitivity: 10)
        _ = MTGesture.consume(device: 1, contactCount: 3, averageX: 0, timestamp: 10)
        let malformed = MTGesture.consume(device: 2, contactCount: 3, averageX: 0.8, timestamp: .infinity)
        let ownerMove = MTGesture.consume(device: 1, contactCount: 3, averageX: 0.05, timestamp: 10.1)
        let validTakeover = MTGesture.consume(device: 2, contactCount: 3, averageX: 0, timestamp: 10.7)

        #expect(malformed.steps == 0)
        #expect(ownerMove.steps == 2)
        #expect(validTakeover.steps == 0)
    }

    @Test("parallel device callbacks and preference writes remain coherent")
    func concurrentCallbacksAndConfiguration() {
        reset(sensitivity: 10)
        DispatchQueue.concurrentPerform(iterations: 1_000) { i in
            if i.isMultiple(of: 17) { MTGesture.setReverse(i.isMultiple(of: 34)) }
            if i.isMultiple(of: 23) { MTGesture.setSensitivity((i % 10) + 1) }
            if i.isMultiple(of: 31) { MTGesture.setCommitOnRelease(i.isMultiple(of: 62)) }
            _ = MTGesture.consume(
                device: Int32((i % 3) + 1),
                contactCount: i.isMultiple(of: 29) ? 0 : 3,
                averageX: Float(i % 100) / 100,
                timestamp: Double(i) / 120
            )
        }

        // Reset must still produce a deterministic, usable state after the
        // contention burst (TSan also exercises every shared field above).
        reset(sensitivity: 10)
        _ = MTGesture.consume(device: 1, contactCount: 3, averageX: 0, timestamp: 20)
        let action = MTGesture.consume(device: 1, contactCount: 3, averageX: 0.05, timestamp: 20.01)
        #expect(action.steps == 2)
    }
}
