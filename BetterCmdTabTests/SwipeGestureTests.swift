import CoreGraphics
import Dispatch
import Testing
@testable import BetterCmdTab

// One suite: every case drives the process-wide MTGesture state, so they cannot run in parallel.
@Suite("Swipe gesture", .serialized)
struct SwipeGestureTests {
    private typealias CGS = SpaceSwipeSuppressor.CGS

    private func frame(fingers: Int32 = 3, x: Float = 0.5, y: Float = 0.5, device: Int32 = 1, at time: Double) -> MTGesture.Action {
        MTGesture.consume(device: device, contactCount: fingers, position: fingers >= 3 ? (x, y) : nil, timestamp: time)
    }

    private func spaceSwipe(phase: Int64) throws -> CGEvent {
        let event = try #require(CGEvent(source: nil))
        // kCGSEventType (field 55) first: the gesture fields only stick on a dock-control event.
        event.setIntegerValueField(unsafeBitCast(UInt32(55), to: CGEventField.self), value: Int64(CGS.eventDockControl))
        event.setIntegerValueField(unsafeBitCast(CGS.fieldHIDType, to: CGEventField.self), value: CGS.hidDockSwipe)
        event.setIntegerValueField(unsafeBitCast(CGS.fieldSwipeMotion, to: CGEventField.self), value: CGS.motionHorizontal)
        event.setIntegerValueField(unsafeBitCast(CGS.fieldPhase, to: CGEventField.self), value: phase)
        event.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
        return event
    }

    private func startScrubbing(fingers: Int = 3) {
        MTGesture.setOneShot(false)
        MTGesture.setFingerCount(fingers)
        MTGesture.setCommitOnRelease(true)
        MTGesture.setSensitivity(MTGesture.defaultSensitivityLevel)
        MTGesture.reset()
    }

    @Test("an upward slide steps a row up, a downward slide a row down")
    func verticalSlideStepsRows() {
        startScrubbing()
        let step = MTGesture.stepDistance(forLevel: MTGesture.defaultSensitivityLevel)
        _ = frame(at: 0)
        #expect(frame(y: 0.5 + step * 1.1, at: 0.06).rows == -1)
        #expect(frame(y: 0.5 - step * 0.2, at: 0.08).rows == 1)
    }

    @Test("a horizontal slide with vertical drift never banks a row step")
    func horizontalSlideDropsVerticalDrift() {
        startScrubbing()
        let step = MTGesture.stepDistance(forLevel: MTGesture.defaultSensitivityLevel)
        var rows = 0
        var steps = 0
        for i in 0...8 {
            let action = frame(x: 0.1 + Float(i) * step * 0.7, y: 0.5 + Float(i) * step * 0.3, at: Double(i) * 0.02)
            rows += action.rows
            steps += action.steps
        }
        #expect(steps == 5)
        #expect(rows == 0)
    }

    @Test("a fourth finger that lands before any travel rejects the touch (#259)")
    func extraFingerRejectsTheTouch() {
        startScrubbing(fingers: 3)
        let step = MTGesture.stepDistance(forLevel: MTGesture.defaultSensitivityLevel)
        // Fingers land one by one, so a four-finger swipe passes through three.
        var actions = [frame(fingers: 3, x: 0.1, at: 0)]
        for i in 0...10 {
            actions.append(frame(fingers: 4, x: 0.1 + Float(i) * step, at: 0.01 + Double(i) * 0.01))
        }
        actions.append(frame(fingers: 3, x: 0.8, at: 0.2))
        actions.append(frame(fingers: 3, x: 0.8 + step * 1.5, at: 0.21))
        actions.append(frame(fingers: 0, at: 0.22))
        #expect(actions.allSatisfy { $0.steps == 0 && $0.rows == 0 && !$0.commit })
        #expect(!MTGesture.ownsTouch)
    }

    @Test("three fingers that slide a step before the fourth lands never step (#259)")
    func lateFourthFingerNeverSteps() {
        startScrubbing(fingers: 3)
        let step = MTGesture.stepDistance(forLevel: MTGesture.defaultSensitivityLevel)
        let actions = [
            frame(fingers: 3, x: 0.1, at: 0),
            frame(fingers: 3, x: 0.1 + step * 1.5, at: 0.02),
            frame(fingers: 4, x: 0.1 + step * 2, at: 0.04),
            frame(fingers: 0, at: 0.06),
        ]
        #expect(actions.allSatisfy { $0.steps == 0 && $0.rows == 0 && !$0.commit })
    }

    @Test("the next three-finger touch after a rejected one steps again")
    func rejectionEndsAtLift() {
        startScrubbing(fingers: 3)
        let step = MTGesture.stepDistance(forLevel: MTGesture.defaultSensitivityLevel)
        _ = frame(fingers: 4, x: 0.1, at: 0)
        _ = frame(fingers: 0, at: 0.01)
        _ = frame(fingers: 3, x: 0.1, at: 1)
        #expect(frame(fingers: 3, x: 0.1 + step * 1.1, at: 1.06).steps == 1)
        #expect(frame(fingers: 0, at: 1.07).commit)
    }

    @Test("another device's lift does not end a rejection")
    func rejectionLatchesTheDevice() {
        startScrubbing(fingers: 3)
        let step = MTGesture.stepDistance(forLevel: MTGesture.defaultSensitivityLevel)
        _ = frame(fingers: 4, x: 0.1, device: 1, at: 0)
        _ = frame(fingers: 0, device: 2, at: 0.01)
        _ = frame(fingers: 3, x: 0.1, device: 1, at: 0.02)
        #expect(frame(fingers: 3, x: 0.1 + step * 1.1, device: 1, at: 0.08).steps == 0)
    }

    @Test("a device that takes over from a stale rejected touch steps")
    func takeoverEndsTheRejection() {
        startScrubbing(fingers: 3)
        let step = MTGesture.stepDistance(forLevel: MTGesture.defaultSensitivityLevel)
        _ = frame(fingers: 4, x: 0.1, device: 1, at: 0)
        _ = frame(fingers: 3, x: 0.1, device: 2, at: 1)
        #expect(frame(fingers: 3, x: 0.1 + step * 1.1, device: 2, at: 1.06).steps == 1)
    }

    @Test("the gesture owns its touch past the lift, until another touch lands")
    func ownershipOutlivesTheLift() {
        startScrubbing(fingers: 3)
        _ = frame(fingers: 3, x: 0.1, at: 0)
        _ = frame(fingers: 0, at: 0.01)
        #expect(MTGesture.ownsTouch)
        _ = frame(fingers: 1, at: 1)
        #expect(!MTGesture.ownsTouch)
    }

    @Test("ownership of a lifted touch expires, so a pad the trigger never saw is not swallowed")
    func ownershipExpiresAfterTheLift() {
        startScrubbing(fingers: 3)
        _ = frame(fingers: 3, x: 0.1, at: 0)
        _ = frame(fingers: 0, at: 0.01)
        let lifted = DispatchTime.now().uptimeNanoseconds
        #expect(MTGesture.ownsTouch(now: lifted))
        #expect(!MTGesture.ownsTouch(now: lifted + 600_000_000))
    }

    @Test("with four fingers set, a three-finger swipe is not the gesture's")
    func fewerFingersAreNotOwned() {
        startScrubbing(fingers: 4)
        let step = MTGesture.stepDistance(forLevel: MTGesture.defaultSensitivityLevel)
        _ = frame(fingers: 4, x: 0.1, at: 0)
        _ = frame(fingers: 0, at: 0.01)
        _ = frame(fingers: 3, x: 0.1, at: 1)
        #expect(frame(fingers: 3, x: 0.1 + step * 1.1, at: 1.06).steps == 0)
        #expect(!MTGesture.ownsTouch)
    }

    @Test("the system Space swipe of an owned touch is swallowed, another touch's passes")
    @MainActor func suppressorSwallowsOnlyOwnedSwipes() throws {
        startScrubbing(fingers: 3)
        let suppressor = SpaceSwipeSuppressor()
        _ = frame(fingers: 3, x: 0.1, at: 0)
        #expect(suppressor.handle(type: .null, event: try spaceSwipe(phase: CGS.phaseBegan)) == nil)
        #expect(suppressor.handle(type: .null, event: try spaceSwipe(phase: CGS.phaseEnded)) == nil)
        _ = frame(fingers: 0, at: 0.01)
        _ = frame(fingers: 4, x: 0.1, at: 1)
        #expect(suppressor.handle(type: .null, event: try spaceSwipe(phase: CGS.phaseBegan)) != nil)
    }

    @Test("a finger that lands mid-swipe does not split the system Space swipe (#259)")
    @MainActor func suppressorKeepsTheBeganVerdict() throws {
        startScrubbing(fingers: 3)
        let suppressor = SpaceSwipeSuppressor()
        _ = frame(fingers: 3, x: 0.1, at: 0)
        #expect(suppressor.handle(type: .null, event: try spaceSwipe(phase: CGS.phaseBegan)) == nil)
        _ = frame(fingers: 4, x: 0.1, at: 0.01)
        #expect(!MTGesture.ownsTouch)
        #expect(suppressor.handle(type: .null, event: try spaceSwipe(phase: CGS.phaseEnded)) == nil)
    }
}
