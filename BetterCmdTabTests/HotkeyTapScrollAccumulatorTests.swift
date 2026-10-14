import Testing
@testable import BetterCmdTab

@Suite("Continuous scroll accumulator")
struct HotkeyTapScrollAccumulatorTests {


    @Test func phasedTwoFingerScrollFollowsBothAxes() throws {
        var state = HotkeyTap.ScrollNavigation()
        let downResult = state.consume(x: 0.2, y: -3.5, continuous: true,
            phase: 1, momentum: 0, routing: .navigate, reverse: false, now: 1)
        let down = try #require(downResult)
        #expect(down.count == 1 && !down.horizontal)
        let rightResult = state.consume(x: -3.2, y: 0.1, continuous: true,
            phase: 2, momentum: 0, routing: .navigate, reverse: false, now: 2)
        let right = try #require(rightResult)
        #expect(right.count == 1 && right.horizontal)
        let upResult = state.consume(x: 0, y: 3.2, continuous: true,
            phase: 2, momentum: 0, routing: .navigate, reverse: false, now: 3)
        let up = try #require(upResult)
        #expect(up.count == -1 && !up.horizontal)
    }

    @Test func axisChangeAndNewGestureDiscardOldRemainders() throws {
        var state = HotkeyTap.ScrollNavigation()
        _ = state.consume(x: -2.8, y: 0, continuous: true,
            phase: 1, momentum: 0, routing: .navigate, reverse: false, now: 1)
        let turnResult = state.consume(x: 0, y: -0.5, continuous: true,
            phase: 2, momentum: 0, routing: .navigate, reverse: false, now: 2)
        let turn = try #require(turnResult)
        #expect(turn.count == 0)
        let nextResult = state.consume(x: 0, y: -2.8, continuous: true,
            phase: 1, momentum: 0, routing: .navigate, reverse: false, now: 3)
        let next = try #require(nextResult)
        #expect(next.count == 0)
    }

    @Test func nativeMultiFingerScrollPassesThroughAndMomentumDoesNotNavigate() throws {
        var state = HotkeyTap.ScrollNavigation()
        let native = state.consume(x: 10, y: 0, continuous: true,
            phase: 2, momentum: 0, routing: .passthrough, reverse: false, now: 1)
        #expect(native == nil)
        let inertiaResult = state.consume(x: 0, y: -20, continuous: true,
            phase: 0, momentum: 2, routing: .navigate, reverse: false, now: 2)
        let inertia = try #require(inertiaResult)
        #expect(inertia.count == 0)
    }

    @Test func threeFingerCompanionScrollCannotReachBackgroundOrStepTwice() throws {
        var state = HotkeyTap.ScrollNavigation()
        let result = state.consume(x: 0, y: -15, continuous: true,
            phase: 2, momentum: 0, routing: .consume, reverse: false, now: 1)
        let consumed = try #require(result)
        #expect(consumed.count == 0)
        #expect(state.accumulated == 0)
    }

    @Test func fourthFingerCancelsConsumptionAndClearsScrollProgress() {
        var state = HotkeyTap.ScrollNavigation()
        _ = state.consume(x: 0, y: -2.5, continuous: true,
            phase: 2, momentum: 0, routing: .navigate, reverse: false, now: 1)
        let native = state.consume(x: -15, y: 0, continuous: true,
            phase: 2, momentum: 0, routing: .passthrough, reverse: false, now: 2)
        #expect(native == nil)
        #expect(state.accumulated == 0)
    }

    @Test func wheelAndReverseDirectionUseSpatialSteps() throws {
        var state = HotkeyTap.ScrollNavigation()
        let wheelResult = state.consume(x: 0, y: -1, continuous: false,
            phase: 0, momentum: 0, routing: .navigate, reverse: false, now: 1)
        let wheel = try #require(wheelResult)
        #expect(wheel.count == 1 && !wheel.horizontal)
        let reverseResult = state.consume(x: -3, y: 0, continuous: true,
            phase: 1, momentum: 0, routing: .navigate, reverse: true, now: 2)
        let reverse = try #require(reverseResult)
        #expect(reverse.count == -1 && reverse.horizontal)
    }

}
