import Testing
@testable import BetterCmdTab

// One suite: every case drives the process-wide MTGesture state, so they cannot run in parallel.
@Suite("Swipe gesture", .serialized)
struct SwipeGestureTests {
    private func frame(_ x: Float, _ y: Float, at time: Double) -> MTGesture.Action {
        MTGesture.consume(device: 1, contactCount: 3, position: (x, y), timestamp: time)
    }

    private func frame(fingers: Int32, x: Float, at time: Double) -> MTGesture.Action {
        MTGesture.consume(device: 1, contactCount: fingers, position: fingers >= 3 ? (x, 0.5) : nil, timestamp: time)
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
        _ = frame(0.5, 0.5, at: 0)
        #expect(frame(0.5, 0.5 + step * 1.1, at: 0.02).rows == -1)
        #expect(frame(0.5, 0.5 - step * 0.2, at: 0.04).rows == 1)
    }

    @Test("a horizontal slide with vertical drift never banks a row step")
    func horizontalSlideDropsVerticalDrift() {
        startScrubbing()
        let step = MTGesture.stepDistance(forLevel: MTGesture.defaultSensitivityLevel)
        var rows = 0
        var steps = 0
        for i in 0...8 {
            let action = frame(0.1 + Float(i) * step * 0.7, 0.5 + Float(i) * step * 0.3, at: Double(i) * 0.02)
            rows += action.rows
            steps += action.steps
        }
        #expect(steps == 5)
        #expect(rows == 0)
    }

    @Test("a four-finger swipe never steps or commits the three-finger gesture (#259)")
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
        actions.append(frame(fingers: 0, x: 0, at: 0.22))
        #expect(actions.allSatisfy { $0.steps == 0 && $0.rows == 0 && !$0.commit })
        #expect(!MTGesture.ownsTouch)
    }

    @Test("the next three-finger touch after a rejected one steps again")
    func rejectionEndsAtLift() {
        startScrubbing(fingers: 3)
        let step = MTGesture.stepDistance(forLevel: MTGesture.defaultSensitivityLevel)
        _ = frame(fingers: 4, x: 0.1, at: 0)
        _ = frame(fingers: 0, x: 0, at: 0.01)
        _ = frame(fingers: 3, x: 0.1, at: 1)
        #expect(frame(fingers: 3, x: 0.1 + step * 1.1, at: 1.01).steps == 1)
        #expect(frame(fingers: 0, x: 0, at: 1.02).commit)
    }

    @Test("the gesture owns its touch past the lift, until another touch lands")
    func ownershipOutlivesTheLift() {
        startScrubbing(fingers: 3)
        _ = frame(fingers: 3, x: 0.1, at: 0)
        _ = frame(fingers: 0, x: 0, at: 0.01)
        #expect(MTGesture.ownsTouch)
        _ = frame(fingers: 1, x: 0, at: 1)
        #expect(!MTGesture.ownsTouch)
    }

    @Test("with four fingers set, a three-finger swipe is not the gesture's")
    func fewerFingersAreNotOwned() {
        startScrubbing(fingers: 4)
        let step = MTGesture.stepDistance(forLevel: MTGesture.defaultSensitivityLevel)
        _ = frame(fingers: 3, x: 0.1, at: 0)
        #expect(frame(fingers: 3, x: 0.1 + step * 1.1, at: 0.01).steps == 0)
        #expect(!MTGesture.ownsTouch)
    }
}
