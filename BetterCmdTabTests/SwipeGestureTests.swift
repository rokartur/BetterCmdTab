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
        commitOnRelease: Bool = false,
        navigationEnabled: Bool = false
    ) {
        MTGesture.setSensitivity(sensitivity)
        MTGesture.setReverse(false)
        MTGesture.setOneShot(oneShot)
        MTGesture.setNavigationEnabled(navigationEnabled)
        MTGesture.setCommitOnRelease(commitOnRelease)
        MTGesture.setFingerCount(3)
        MTGesture.reset()
    }

    @Test("coalesces all whole movement steps and preserves the remainder")
    func coalescesSteps() {
        reset(sensitivity: 10, navigationEnabled: true)
        let anchor = MTGesture.consume(device: 1, contactCount: 3, averageX: 0.10, timestamp: 1)
        let moved = MTGesture.consume(device: 1, contactCount: 3, averageX: 0.125, timestamp: 1.10)
        let remainderOnly = MTGesture.consume(device: 1, contactCount: 3, averageX: 0.131, timestamp: 1.20)

        #expect(anchor.steps == 0)
        #expect(moved.steps == 2)
        #expect(remainderOnly.steps == 0)
    }

    @Test("caps a malformed frame and discards its oversized remainder")
    func capsMalformedBurst() {
        reset(sensitivity: 10, navigationEnabled: true)
        _ = MTGesture.consume(device: 1, contactCount: 3, averageX: 0, timestamp: 1)
        let burst = MTGesture.consume(device: 1, contactCount: 3, averageX: 100, timestamp: 1.10)
        let settled = MTGesture.consume(device: 1, contactCount: 3, averageX: 100, timestamp: 1.20)

        #expect(burst.steps == 16)
        #expect(settled.steps == 0)
    }

    @Test("one-shot fires once and rearms only after a full lift")
    func oneShotRearmsOnLift() {
        reset(oneShot: true)
        _ = MTGesture.consume(device: 1, contactCount: 3, averageX: 0, timestamp: 1)
        let first = MTGesture.consume(device: 1, contactCount: 3, averageX: 0.09, timestamp: 1.10)
        let held = MTGesture.consume(device: 1, contactCount: 3, averageX: 0.20, timestamp: 1.20)
        _ = MTGesture.consume(device: 1, contactCount: 0, averageX: nil, timestamp: 1.30)
        _ = MTGesture.consume(device: 1, contactCount: 3, averageX: 0.20, timestamp: 2)
        let second = MTGesture.consume(device: 1, contactCount: 3, averageX: 0.10, timestamp: 2.10)

        #expect(first.steps == 1)
        #expect(held.steps == 0)
        #expect(second.steps == -1)
    }

    @Test("commit is emitted once after an active gesture fully lifts")
    func commitsOnceOnFullLift() {
        reset(commitOnRelease: true)
        _ = MTGesture.consume(device: 1, contactCount: 3, averageX: 0.4, timestamp: 1)
        _ = MTGesture.consume(device: 1, contactCount: 3, averageX: 0.5, timestamp: 1.05)
        let fingerFlicker = MTGesture.consume(device: 1, contactCount: 2, averageX: nil, timestamp: 1.10)
        let lift = MTGesture.consume(device: 1, contactCount: 0, averageX: nil, timestamp: 1.20)
        let duplicateLift = MTGesture.consume(device: 1, contactCount: 0, averageX: nil, timestamp: 1.30)

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
        let takeoverMove = MTGesture.consume(device: 2, contactCount: 3, averageX: 0.05, timestamp: 10.90)

        #expect(ignored.steps == 0)
        #expect(ownerMove.steps == 1)
        #expect(takeoverAnchor.steps == 0)
        #expect(takeoverMove.steps == 1)
    }

    @Test("non-finite contact data cannot trap or poison later frames")
    func nonFiniteInputRecovers() {
        reset(sensitivity: 10)
        _ = MTGesture.consume(device: 1, contactCount: 3, averageX: .infinity, timestamp: 1)
        let rejected = MTGesture.consume(device: 1, contactCount: 3, averageX: 0, timestamp: 1.10)
        let recovered = MTGesture.consume(device: 1, contactCount: 3, averageX: 0.05, timestamp: 1.20)

        #expect(rejected.steps == 0)
        #expect(recovered.steps == 1)
    }

    @Test("non-finite contact data cannot poison one-shot mode")
    func nonFiniteOneShotRecovers() {
        reset(oneShot: true)
        _ = MTGesture.consume(device: 1, contactCount: 3, averageX: 0, timestamp: 1)
        _ = MTGesture.consume(device: 1, contactCount: 3, averageX: .nan, timestamp: 1.10)
        let reanchor = MTGesture.consume(device: 1, contactCount: 3, averageX: 0, timestamp: 1.20)
        let recovered = MTGesture.consume(device: 1, contactCount: 3, averageX: 0.09, timestamp: 1.30)

        #expect(reanchor.steps == 0)
        #expect(recovered.steps == 1)
    }

    @Test("reset invalidates actions queued by an older trigger session")
    func resetInvalidatesQueuedAction() {
        reset(oneShot: true)
        _ = MTGesture.consume(device: 1, contactCount: 3, averageX: 0, timestamp: 1)
        let action = MTGesture.consume(device: 1, contactCount: 3, averageX: 0.09, timestamp: 1.10)

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
        #expect(ownerMove.steps == 1)
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
        let action = MTGesture.consume(device: 1, contactCount: 3, averageX: 0.05, timestamp: 20.10)
        #expect(action.steps == 1)
    }

    @Test("four or more fingers and their three-finger tail never switch", arguments: [4, 5])
    func rejectsExtraFingers(count: Int32) {
        reset(sensitivity: 10, commitOnRelease: true)
        _ = MTGesture.consume(device: 1, contactCount: count, averageX: 0, timestamp: 1)
        let moved = MTGesture.consume(device: 1, contactCount: count, averageX: 0.2, timestamp: 1.1)
        _ = MTGesture.consume(device: 1, contactCount: 3, averageX: 0.2, timestamp: 1.2)
        let tail = MTGesture.consume(device: 1, contactCount: 3, averageX: 0.4, timestamp: 1.3)
        let lift = MTGesture.consume(device: 1, contactCount: 0, averageX: nil, timestamp: 1.4)
        #expect(moved.steps == 0 && tail.steps == 0 && !lift.commit)
        _ = MTGesture.consume(device: 1, contactCount: 3, averageX: 0, timestamp: 2)
        #expect(MTGesture.consume(device: 1, contactCount: 3, averageX: 0.06, timestamp: 2.1).steps == 1)
    }

    @Test("vertical swipe with horizontal drift never switches or commits")
    func rejectsVerticalSwipe() {
        reset(sensitivity: 10, commitOnRelease: true)
        _ = MTGesture.consume(device: 1, contactCount: 3, averageX: 0, averageY: 0, timestamp: 1)
        let vertical = MTGesture.consume(device: 1, contactCount: 3, averageX: 0.03, averageY: 0.1, timestamp: 1.1)
        let drift = MTGesture.consume(device: 1, contactCount: 3, averageX: 0.3, averageY: 0.12, timestamp: 1.2)
        let lift = MTGesture.consume(device: 1, contactCount: 0, averageX: nil, timestamp: 1.3)
        #expect(vertical.steps == 0 && drift.steps == 0 && !lift.commit)
    }

    @Test("a stationary touch must not commit a keyboard-opened switcher")
    func stationaryContactDoesNotCommit() {
        reset(commitOnRelease: true)
        _ = MTGesture.consume(device: 1, contactCount: 3, averageX: 0, timestamp: 1)
        #expect(!MTGesture.consume(device: 1, contactCount: 0, averageX: nil, timestamp: 1.1).commit)
    }

    @Test("a late fourth finger cancels release and cannot rearm through its tail")
    func addedFourthFingerCancelsCommit() {
        reset(sensitivity: 10, commitOnRelease: true)
        _ = MTGesture.consume(device: 1, contactCount: 3, averageX: 0, timestamp: 1)
        #expect(MTGesture.consume(device: 1, contactCount: 3, averageX: 0.06, timestamp: 1.1).steps == 1)
        _ = MTGesture.consume(device: 1, contactCount: 4, averageX: nil, timestamp: 1.2)
        #expect(MTGesture.consume(device: 1, contactCount: 3, averageX: 0.3, timestamp: 1.3).steps == 0)
        #expect(!MTGesture.consume(device: 1, contactCount: 0, averageX: nil, timestamp: 1.4).commit)
    }

    @Test("staggered fourth-finger landing is rejected before the first step")
    func staggeredLanding() {
        reset(sensitivity: 10, commitOnRelease: true)
        _ = MTGesture.consume(device: 1, contactCount: 3, averageX: 0, timestamp: 1)
        #expect(MTGesture.consume(device: 1, contactCount: 3, averageX: 0.1, timestamp: 1.01).steps == 0)
        _ = MTGesture.consume(device: 1, contactCount: 4, averageX: nil, timestamp: 1.02)
        #expect(!MTGesture.consume(device: 1, contactCount: 0, averageX: nil, timestamp: 1.1).commit)
    }

    @Test("horizontal swipes allow modest diagonal drift and reverse direction")
    func horizontalDiagonalAndReverse() {
        reset(sensitivity: 10)
        MTGesture.setReverse(true)
        _ = MTGesture.consume(device: 1, contactCount: 3, averageX: 0, timestamp: 1)
        let moved = MTGesture.consume(device: 1, contactCount: 3, averageX: 0.06, averageY: 0.01, timestamp: 1.1)
        #expect(moved.steps == -1)
        #expect(!MTGesture.consume(device: 1, contactCount: 0, averageX: nil, timestamp: 1.2).commit)
    }

    @Test("contact dropout reanchors without converting a centroid jump to motion")
    func contactDropoutReanchors() {
        reset(sensitivity: 10, navigationEnabled: true)
        _ = MTGesture.consume(device: 1, contactCount: 3, averageX: 0, timestamp: 1)
        _ = MTGesture.consume(device: 1, contactCount: 3, averageX: 0.02, timestamp: 1.1)
        _ = MTGesture.consume(device: 1, contactCount: 2, averageX: nil, timestamp: 1.2)
        #expect(MTGesture.consume(device: 1, contactCount: 3, averageX: 0.8, timestamp: 1.3).steps == 0)
        #expect(MTGesture.consume(device: 1, contactCount: 3, averageX: 0.8, timestamp: 1.4).steps == 0)
    }

    @Test("another device cannot release a four-finger rejection")
    func rejectionBelongsToDevice() {
        reset(sensitivity: 10)
        _ = MTGesture.consume(device: 1, contactCount: 4, averageX: nil, timestamp: 1)
        _ = MTGesture.consume(device: 2, contactCount: 0, averageX: nil, timestamp: 1.1)
        #expect(MTGesture.consume(device: 1, contactCount: 3, averageX: 0.3, timestamp: 1.2).steps == 0)
        _ = MTGesture.consume(device: 2, contactCount: 3, averageX: 0, timestamp: 2)
        #expect(MTGesture.consume(device: 2, contactCount: 3, averageX: 0.06, timestamp: 2.1).steps == 1)
    }

    @Test("invalid Y input recovers without a false step")
    func nonFiniteYRecovers() {
        reset(sensitivity: 10)
        _ = MTGesture.consume(device: 1, contactCount: 3, averageX: 0, averageY: .nan, timestamp: 1)
        #expect(MTGesture.consume(device: 1, contactCount: 3, averageX: 0, timestamp: 1.1).steps == 0)
        #expect(MTGesture.consume(device: 1, contactCount: 3, averageX: 0.06, timestamp: 1.2).steps == 1)
    }

    @Test("a visible switcher follows vertical movement and commits on lift")
    func visibleVerticalNavigation() {
        reset(commitOnRelease: true)
        MTGesture.setNavigationEnabled(true)
        _ = MTGesture.consume(device: 1, contactCount: 3, averageX: 0.5, averageY: 0.5, timestamp: 1)
        let up = MTGesture.consume(device: 1, contactCount: 3, averageX: 0.505, averageY: 0.565, timestamp: 1.1)
        let down = MTGesture.consume(device: 1, contactCount: 3, averageX: 0.505, averageY: 0.435, timestamp: 1.2)
        #expect(up.steps == 0 && up.verticalSteps == -2)
        #expect(down.steps == 0 && down.verticalSteps == 4)
        #expect(MTGesture.consume(device: 1, contactCount: 0, averageX: nil, timestamp: 1.3).commit)
    }

    @Test("one continuous gesture can open horizontally then turn up and left")
    func turnsAfterOpening() {
        reset()
        _ = MTGesture.consume(device: 1, contactCount: 3, averageX: 0.5, averageY: 0.5, timestamp: 1)
        let open = MTGesture.consume(device: 1, contactCount: 3, averageX: 0.56, averageY: 0.51, timestamp: 1.1)
        #expect(open.steps == 1 && open.verticalSteps == 0)
        MTGesture.setNavigationEnabled(true)
        let up = MTGesture.consume(device: 1, contactCount: 3, averageX: 0.56, averageY: 0.575, timestamp: 1.2)
        #expect(up.steps == 0 && up.verticalSteps == -2)
        let left = MTGesture.consume(device: 1, contactCount: 3, averageX: 0.495, averageY: 0.575, timestamp: 1.3)
        #expect(left.steps == -2 && left.verticalSteps == 0)
    }

    @Test("vertical motion is disabled again after the switcher closes")
    func closingDisablesVerticalNavigation() {
        reset(sensitivity: 10)
        MTGesture.setNavigationEnabled(true)
        MTGesture.setNavigationEnabled(false)
        _ = MTGesture.consume(device: 1, contactCount: 3, averageX: 0.5, averageY: 0.5, timestamp: 1)
        let vertical = MTGesture.consume(device: 1, contactCount: 3, averageX: 0.5, averageY: 0.6, timestamp: 1.1)
        #expect(vertical.steps == 0 && vertical.verticalSteps == 0)
    }

    @Test("one-shot modes never emit vertical navigation")
    func oneShotStaysHorizontal() {
        reset(oneShot: true)
        MTGesture.setNavigationEnabled(true)
        _ = MTGesture.consume(device: 1, contactCount: 3, averageX: 0.5, averageY: 0.5, timestamp: 1)
        let vertical = MTGesture.consume(device: 1, contactCount: 3, averageX: 0.5, averageY: 0.7, timestamp: 1.1)
        #expect(vertical.steps == 0 && vertical.verticalSteps == 0)
    }

    @Test("four fingers cancel both axes and release even inside the switcher")
    func fourFingersCancelSpatialNavigation() {
        reset(commitOnRelease: true)
        MTGesture.setNavigationEnabled(true)
        _ = MTGesture.consume(device: 1, contactCount: 3, averageX: 0.5, averageY: 0.5, timestamp: 1)
        #expect(MTGesture.consume(device: 1, contactCount: 3, averageX: 0.5, averageY: 0.565, timestamp: 1.1).verticalSteps == -2)
        _ = MTGesture.consume(device: 1, contactCount: 4, averageX: nil, timestamp: 1.2)
        let tail = MTGesture.consume(device: 1, contactCount: 3, averageX: 0.7, averageY: 0.8, timestamp: 1.3)
        #expect(tail.steps == 0 && tail.verticalSteps == 0)
        #expect(!MTGesture.consume(device: 1, contactCount: 0, averageX: nil, timestamp: 1.4).commit)
    }

    @Test("ordinary scrolling remains separate from three/four-finger sequences", arguments: [3, 4])
    func scrollExclusionThroughLift(count: Int32) {
        reset()
        _ = MTGesture.consume(device: 1, contactCount: 2, averageX: nil, timestamp: 1)
        #expect(MTGesture.scrollRouting == .navigate)
        _ = MTGesture.consume(device: 1, contactCount: count, averageX: 0.5, timestamp: 1.1)
        #expect(MTGesture.scrollRouting == (count == 4 ? .passthrough : .consume))
        _ = MTGesture.consume(device: 1, contactCount: 2, averageX: nil, timestamp: 1.2)
        #expect(MTGesture.scrollRouting == (count == 4 ? .passthrough : .consume))
        _ = MTGesture.consume(device: 1, contactCount: 0, averageX: nil, timestamp: 1.3)
        #expect(MTGesture.scrollRouting == .navigate)
    }

    @Test("a short horizontal swipe opens once before the panel is ready")
    func shortOpeningDoesNotRepeatBeforeReveal() {
        reset()
        _ = MTGesture.consume(device: 1, contactCount: 3, averageX: 0.5, timestamp: 1)
        let opening = MTGesture.consume(device: 1, contactCount: 3, averageX: 0.517, averageY: 0.002, timestamp: 1.05)
        let waiting = MTGesture.consume(device: 1, contactCount: 3, averageX: 0.65, timestamp: 1.1)
        #expect(opening.steps == 1 && opening.verticalSteps == 0)
        #expect(waiting.steps == 0)
    }

    @Test("diagonal navigation preserves progress on both axes")
    func diagonalProgressSurvives() {
        reset(navigationEnabled: true)
        _ = MTGesture.consume(device: 1, contactCount: 3, averageX: 0, averageY: 0, timestamp: 1)
        let below = MTGesture.consume(device: 1, contactCount: 3, averageX: 0.025, averageY: 0.025, timestamp: 1.1)
        let right = MTGesture.consume(device: 1, contactCount: 3, averageX: 0.035, averageY: 0.034, timestamp: 1.2)
        let up = MTGesture.consume(device: 1, contactCount: 3, averageX: 0.035, averageY: 0.035, timestamp: 1.3)
        #expect(below.steps == 0 && below.verticalSteps == 0)
        #expect(right.steps == 1 && right.verticalSteps == 0)
        #expect(up.steps == 0 && up.verticalSteps == -1)
    }

    @Test("default navigation requires three percent of trackpad travel")
    func defaultNavigationDistance() {
        #expect(abs(MTGesture.navigationDistance(forLevel: 5) - 0.03) < 0.00001)
        #expect(MTGesture.openingDistance < MTGesture.navigationDistance(forLevel: 5))
    }
    @Test("explicit four-finger configuration opens and navigates")
    func configuredFourFingers() {
        reset(commitOnRelease: true)
        MTGesture.setFingerCount(4)
        MTGesture.reset()
        defer { MTGesture.setFingerCount(3); MTGesture.reset() }
        _ = MTGesture.consume(device: 1, contactCount: 3, averageX: 0.4, timestamp: 1)
        #expect(MTGesture.scrollRouting == .navigate)
        _ = MTGesture.consume(device: 1, contactCount: 4, averageX: 0.4, timestamp: 1.1)
        let open = MTGesture.consume(device: 1, contactCount: 4, averageX: 0.43, timestamp: 1.2)
        #expect(open.steps == 1)
        #expect(MTGesture.scrollRouting == .consume)
        MTGesture.setNavigationEnabled(true)
        let down = MTGesture.consume(device: 1, contactCount: 4, averageX: 0.43, averageY: -0.06, timestamp: 1.3)
        #expect(down.verticalSteps > 0)
        let lift = MTGesture.consume(device: 1, contactCount: 0, averageX: nil, timestamp: 1.4)
        #expect(lift.commit)
    }

}
