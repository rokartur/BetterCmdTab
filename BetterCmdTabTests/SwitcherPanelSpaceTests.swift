import AppKit
import Testing
@testable import BetterCmdTab

/// Regression coverage for #46: the panel must stay visible on every Space,
/// including other apps' full-screen Spaces, after the Space count changes.
/// `.fullScreenAuxiliary` bound the panel to a full-screen window's Space, so
/// quitting that app rotted its all-Spaces membership — matching AltTab's
/// proven-minimal `.canJoinAllSpaces` config is the fix. The real compositor
/// transition still needs a macOS UI smoke test; this pins the policy.
@MainActor
@Suite("Switcher panel Space behavior")
struct SwitcherPanelSpaceTests {
    @Test("collection behavior joins all Spaces without full-screen-auxiliary binding")
    func collectionBehaviorAvoidsFullScreenBinding() {
        let panel = SwitcherPanel()
        let behavior = panel.collectionBehavior
        #expect(behavior == SwitcherPanel.canonicalCollectionBehavior)
        #expect(behavior.contains(.canJoinAllSpaces))
        #expect(behavior.contains(.stationary))
        #expect(behavior.contains(.ignoresCycle))
        // The #46 guard: these bind the panel to a full-screen window's Space,
        // which rots when that Space is destroyed. They must never come back.
        #expect(!behavior.contains(.fullScreenAuxiliary))
        #expect(!behavior.contains(.canJoinAllApplications))
        #expect(!behavior.contains(.moveToActiveSpace))
    }
}
