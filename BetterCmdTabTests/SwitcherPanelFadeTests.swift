import AppKit
import Testing
@testable import BetterCmdTab

/// Needs a real WindowServer like `SwitcherReflowTests`. A fade length is read when its fade starts, so a case
/// sets it only around that call: suites running beside this one at an `await` must not see or keep it.
@MainActor
@Suite("Switcher panel fade", .serialized)
struct SwitcherPanelFadeTests {
    private func withFade(in fadeIn: Int = 0, out fadeOut: Int = 0, _ start: () -> Void) {
        let prefs = Preferences.shared
        let saved = (prefs.fadeInDurationMs, prefs.fadeOutDurationMs)
        (prefs.fadeInDurationMs, prefs.fadeOutDurationMs) = (fadeIn, fadeOut)
        start()
        (prefs.fadeInDurationMs, prefs.fadeOutDurationMs) = saved
    }

    private func makePanel() -> SwitcherPanel {
        let panel = SwitcherPanel()
        panel.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        return panel
    }

    private func presentedPanel() -> SwitcherPanel {
        let panel = makePanel()
        withFade { panel.present() }
        return panel
    }

    @Test func aFreshPresentFadesIn() async throws {
        let panel = makePanel()
        defer { panel.orderOut(nil) }
        withFade(in: 200) { panel.present() }
        #expect(panel.alphaValue < 1)
        try await Task.sleep(for: .milliseconds(400))
        #expect(panel.alphaValue == 1)
    }

    @Test func aDismissalOrdersOutOnlyOnceTheFadeOutEnds() async throws {
        let panel = presentedPanel()
        defer { panel.orderOut(nil) }
        var released = false
        withFade(out: 100) { panel.dismiss { released = true } }
        #expect(panel.isVisible)
        #expect(!released)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!panel.isVisible)
        #expect(released)
    }

    // Fade-in 0 sets alpha directly, which must also cancel the running fade-out.
    @Test(arguments: [0, 100])
    func aPresentDuringTheFadeOutShowsThePanelAgainAndKeepsTheViews(fadeIn: Int) async throws {
        let panel = presentedPanel()
        defer { panel.orderOut(nil) }
        var released = false
        withFade(in: fadeIn, out: 100) {
            panel.dismiss { released = true }
            panel.present()
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(panel.isVisible)
        #expect(panel.alphaValue == 1)
        #expect(!released)
    }

    @Test func aPanelThatWasNeverShownHidesWithoutAFade() {
        let panel = makePanel()
        defer { panel.orderOut(nil) }
        var released = false
        withFade(out: 200) { panel.dismiss { released = true } }
        #expect(released)
    }

    @Test func aDismissDuringTheVanishFadeEndsWithIt() async throws {
        let panel = presentedPanel()
        defer { panel.orderOut(nil) }
        withFade(out: 400) { panel.vanish() }
        try await Task.sleep(for: .milliseconds(200))
        var releases = 0
        withFade(out: 400) { panel.dismiss { releases += 1 } }
        #expect(panel.isVisible)
        // Past the vanish fade's end, before a fade restarted by the dismiss would end.
        try await Task.sleep(for: .milliseconds(300))
        #expect(!panel.isVisible)
        #expect(releases == 1)
    }

    @Test func aCancelledFadeOutsLateCompletionLeavesTheNextOneRunning() async throws {
        let panel = presentedPanel()
        defer { panel.orderOut(nil) }
        var firstReleased = false
        var secondReleased = false
        withFade(out: 200) {
            panel.dismiss { firstReleased = true }
            panel.present()
            panel.dismiss { secondReleased = true }
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(panel.isVisible)
        #expect(!secondReleased)
        try await Task.sleep(for: .milliseconds(400))
        #expect(!panel.isVisible)
        #expect(secondReleased)
        #expect(!firstReleased)
    }

    @Test func withoutAFadeTheDismissalIsInstant() {
        let panel = presentedPanel()
        defer { panel.orderOut(nil) }
        var released = false
        withFade { panel.dismiss { released = true } }
        #expect(!panel.isVisible)
        #expect(released)
    }
}
