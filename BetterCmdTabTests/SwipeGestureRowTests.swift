import Testing
@testable import BetterCmdTab

@Suite("Swipe gesture rows", .serialized)
struct SwipeGestureRowTests {
    private func frame(_ x: Float, _ y: Float, at time: Double) -> MTGesture.Action {
        MTGesture.consume(device: 1, contactCount: 3, position: (x, y), timestamp: time)
    }

    private func startScrubbing() {
        MTGesture.setOneShot(false)
        MTGesture.setFingerCount(3)
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
}
