import AppKit
import Testing
@testable import BetterCmdTab

/// Needs a real WindowServer like `SwitcherReflowTests`; serialized because every case writes the fade preferences.
@MainActor
@Suite("Switcher panel fade", .serialized)
struct SwitcherPanelFadeTests {
    private func presentedPanel(fadeIn: Int, fadeOut: Int, _ body: (SwitcherPanel) async throws -> Void) async throws {
        let prefs = Preferences.shared
        let saved = (prefs.fadeInDurationMs, prefs.fadeOutDurationMs)
        defer { (prefs.fadeInDurationMs, prefs.fadeOutDurationMs) = saved }
        prefs.fadeInDurationMs = fadeIn
        prefs.fadeOutDurationMs = fadeOut
        let panel = SwitcherPanel()
        defer { panel.orderOut(nil) }
        panel.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        panel.present()
        try await body(panel)
    }

    @Test func aFreshPresentFadesIn() async throws {
        try await presentedPanel(fadeIn: 200, fadeOut: 0) { panel in
            #expect(panel.alphaValue < 1)
            try await Task.sleep(for: .milliseconds(400))
            #expect(panel.alphaValue == 1)
        }
    }

    @Test func aDismissalOrdersOutOnlyOnceTheFadeOutEnds() async throws {
        try await presentedPanel(fadeIn: 0, fadeOut: 100) { panel in
            var released = false
            panel.dismiss { released = true }
            #expect(panel.isVisible)
            #expect(!released)
            try await Task.sleep(for: .milliseconds(300))
            #expect(!panel.isVisible)
            #expect(released)
        }
    }

    @Test func aPresentDuringTheFadeOutFadesBackInAndKeepsTheViews() async throws {
        try await presentedPanel(fadeIn: 0, fadeOut: 100) { panel in
            var released = false
            panel.dismiss { released = true }
            Preferences.shared.fadeInDurationMs = 100
            panel.present()
            try await Task.sleep(for: .milliseconds(300))
            #expect(panel.isVisible)
            #expect(panel.alphaValue == 1)
            #expect(!released)
        }
    }

    @Test func aDismissDuringTheVanishFadeEndsWithIt() async throws {
        try await presentedPanel(fadeIn: 0, fadeOut: 400) { panel in
            panel.vanish()
            try await Task.sleep(for: .milliseconds(200))
            var releases = 0
            panel.dismiss { releases += 1 }
            #expect(panel.isVisible)
            // Past the vanish fade's end, before a fade restarted by the dismiss would end.
            try await Task.sleep(for: .milliseconds(300))
            #expect(!panel.isVisible)
            #expect(releases == 1)
        }
    }

    @Test func aCancelledFadeOutsLateCompletionLeavesTheNextOneRunning() async throws {
        try await presentedPanel(fadeIn: 0, fadeOut: 200) { panel in
            var firstReleased = false
            var secondReleased = false
            panel.dismiss { firstReleased = true }
            panel.present()
            panel.dismiss { secondReleased = true }
            try await Task.sleep(for: .milliseconds(50))
            #expect(panel.isVisible)
            #expect(!secondReleased)
            try await Task.sleep(for: .milliseconds(400))
            #expect(!panel.isVisible)
            #expect(secondReleased)
            #expect(!firstReleased)
        }
    }

    @Test func withoutAFadeTheDismissalIsInstant() async throws {
        try await presentedPanel(fadeIn: 0, fadeOut: 0) { panel in
            var released = false
            panel.dismiss { released = true }
            #expect(!panel.isVisible)
            #expect(released)
        }
    }
}
