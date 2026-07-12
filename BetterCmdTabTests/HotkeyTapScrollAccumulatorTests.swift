import Testing
@testable import BetterCmdTab

/// Pure-logic coverage for the continuous-scroll step accumulator behind
/// scroll-to-switch (issue #68). Driver-smoothed mouse wheels (Logitech
/// Options, many Bluetooth mice) report *continuous* line-fraction deltas
/// instead of discrete ±1 notches; the accumulator has to turn a burst of
/// fractions into whole selection steps, carry remainders across events,
/// and drop the remainder on a direction flip.
@Suite("Continuous scroll accumulator")
struct HotkeyTapScrollAccumulatorTests {

    private let threshold = 3.0

    @Test func fractionsBelowThresholdEmitNoStep() {
        let r = HotkeyTap.accumulateContinuousScroll(
            accumulated: 0, delta: -1.5, threshold: threshold)
        #expect(r.steps == 0)
        #expect(r.remainder == -1.5)
    }

    @Test func accumulatedFractionsCrossThresholdOnce() {
        // One smooth notch arrives as a burst of small same-sign deltas: the
        // burst has to produce exactly one step, not zero and not one per event.
        var acc = 0.0
        var total = 0
        for _ in 0..<4 {
            let r = HotkeyTap.accumulateContinuousScroll(
                accumulated: acc, delta: -1.0, threshold: threshold)
            acc = r.remainder
            total += r.steps
        }
        #expect(total == -1)
        #expect(acc == -1.0)
    }

    @Test func bigFlickEmitsMultipleSteps() {
        let r = HotkeyTap.accumulateContinuousScroll(
            accumulated: 0, delta: 7.0, threshold: threshold)
        #expect(r.steps == 2)
        #expect(abs(r.remainder - 1.0) < 0.0001)
    }

    @Test func directionFlipDropsOppositeRemainder() {
        // -2.5 accumulated (almost a downward step), then the user reverses:
        // the stale downward remainder must not swallow the upward motion.
        let r = HotkeyTap.accumulateContinuousScroll(
            accumulated: -2.5, delta: 3.5, threshold: threshold)
        #expect(r.steps == 1)
        #expect(abs(r.remainder - 0.5) < 0.0001)
    }

    @Test func remainderCarriesAcrossSameDirectionEvents() {
        let first = HotkeyTap.accumulateContinuousScroll(
            accumulated: 0, delta: 2.0, threshold: threshold)
        #expect(first.steps == 0)
        let second = HotkeyTap.accumulateContinuousScroll(
            accumulated: first.remainder, delta: 2.0, threshold: threshold)
        #expect(second.steps == 1)
        #expect(abs(second.remainder - 1.0) < 0.0001)
    }

    @Test func signConventionMatchesDiscreteWheel() {
        // Natural scrolling: wheel down = negative delta = forward step, so
        // steps must keep the delta's sign for the caller's direction check.
        let down = HotkeyTap.accumulateContinuousScroll(
            accumulated: 0, delta: -3.0, threshold: threshold)
        #expect(down.steps == -1)
        let up = HotkeyTap.accumulateContinuousScroll(
            accumulated: 0, delta: 3.0, threshold: threshold)
        #expect(up.steps == 1)
    }
}
