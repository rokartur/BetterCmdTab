import Testing
@testable import BetterCmdTab

/// Covers the pure state machine that coordinates native full-screen exit with
/// minimization. Live AX/WindowServer behavior remains an integration concern,
/// but the ordering and timeout policy are deterministic here.
@Suite("Activator full-screen minimization")
struct ActivatorFullscreenMinimizeTests {

    @Test("waits while the window is still full screen")
    func waitsForFullscreenExit() {
        #expect(Activator.fullscreenMinimizeDecision(
            fullscreen: true,
            minimized: false,
            timedOut: false
        ) == .waitForExit)
    }

    @Test("an unavailable full-screen state is retried")
    func retriesUnavailableState() {
        #expect(Activator.fullscreenMinimizeDecision(
            fullscreen: nil,
            minimized: nil,
            timedOut: false
        ) == .waitForExit)
    }

    @Test("requests minimization only after full screen is observably off")
    func minimizesAfterFullscreenExit() {
        #expect(Activator.fullscreenMinimizeDecision(
            fullscreen: false,
            minimized: false,
            timedOut: false
        ) == .requestMinimize)
    }

    @Test("completes only after AX confirms the minimized state")
    func completesWhenMinimized() {
        #expect(Activator.fullscreenMinimizeDecision(
            fullscreen: false,
            minimized: true,
            timedOut: false
        ) == .complete)
    }

    @Test("a confirmed result wins at the timeout boundary")
    func confirmedResultWinsAtTimeout() {
        #expect(Activator.fullscreenMinimizeDecision(
            fullscreen: false,
            minimized: true,
            timedOut: true
        ) == .complete)
    }

    @Test("timeout performs one bounded final attempt")
    func timesOutWithFinalAttempt() {
        #expect(Activator.fullscreenMinimizeDecision(
            fullscreen: true,
            minimized: false,
            timedOut: true
        ) == .finalAttempt)
    }
}
