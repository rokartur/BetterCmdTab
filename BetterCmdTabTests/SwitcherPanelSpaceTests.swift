import AppKit
import Testing
@testable import BetterCmdTab

/// Regression coverage for the WindowServer Space-tag recovery behind
/// #46/#64/#93/#94. The real compositor transition still needs a macOS UI smoke
/// test, but these tests pin the deterministic policy and lifecycle guards.
@MainActor
@Suite("Switcher panel Space recovery")
struct SwitcherPanelSpaceTests {
    @Test("canonical behavior supports Desktops, full-screen Spaces, and other app sets")
    func canonicalBehavior() {
        let behavior = SwitcherPanel.canonicalCollectionBehavior
        #expect(behavior.contains(.canJoinAllSpaces))
        #expect(behavior.contains(.stationary))
        #expect(behavior.contains(.ignoresCycle))
        #expect(behavior.contains(.fullScreenAuxiliary))
        #expect(behavior.contains(.canJoinAllApplications))
        #expect(!behavior.contains(.moveToActiveSpace))
        #expect(!behavior.contains(.primary))
        #expect(!behavior.contains(.auxiliary))
    }

    @Test("new panels install the canonical cross-display behavior")
    func initializerInstallsCanonicalBehavior() {
        let panel = SwitcherPanel()
        #expect(panel.collectionBehavior == SwitcherPanel.canonicalCollectionBehavior)
        #expect(panel.collectionBehavior.contains(.canJoinAllApplications))
    }

    @Test("reassert replaces a damaged mask and is idempotent")
    func reassertRestoresCanonicalBehavior() {
        let panel = SwitcherPanel()
        panel.collectionBehavior = [.moveToActiveSpace]

        panel.reassertAllSpacesTag()
        #expect(panel.collectionBehavior == SwitcherPanel.canonicalCollectionBehavior)

        panel.reassertAllSpacesTag()
        #expect(panel.collectionBehavior == SwitcherPanel.canonicalCollectionBehavior)
    }

    @Test("hidden Space changes restore the tag immediately")
    func hiddenSpaceChangeReassertsTag() {
        let panel = SwitcherPanel()
        #expect(!panel.isVisible)
        panel.collectionBehavior = []

        panel.activeSpaceDidChange()

        #expect(panel.collectionBehavior == SwitcherPanel.canonicalCollectionBehavior)
    }

    @Test("visibility decision needs a settled unhealthy sample before healing")
    func visibilityDecisionMatrix() {
        typealias Decision = SwitcherPanel.SpaceVisibilityDecision
        let decide = SwitcherPanel.spaceVisibilityDecision

        #expect(decide(false, false, false, false) == Decision.none)
        // A healthy first sample can still be the previous presentation's
        // stale state — confirm once instead of trusting it outright.
        #expect(decide(true, true, true, false) == Decision.verify)
        #expect(decide(true, false, false, false) == Decision.retry)
        #expect(decide(true, false, false, true) == Decision.heal)
        #expect(decide(true, true, false, false) == Decision.retry)
        #expect(decide(true, true, false, true) == Decision.heal)
        #expect(decide(true, true, true, true) == Decision.none)
    }

    @Test("visible relayouts do not fork another recovery chain")
    func verificationStartsOnlyOnRevealEdge() {
        #expect(SwitcherPanel.shouldStartSpaceVerification(isAlreadyVisible: false))
        #expect(!SwitcherPanel.shouldStartSpaceVerification(isAlreadyVisible: true))
    }

    @Test("new generations invalidate delayed checks from an older presentation")
    func generationInvalidation() {
        var generation = SwitcherPanel.SpaceCheckGeneration()
        let presentationA = generation.advance()
        #expect(generation.matches(presentationA))

        // Models dismiss(A), then present(B): neither transition may leave A's
        // queued 50 ms callback authorized to touch B.
        generation.advance()
        let presentationB = generation.advance()

        #expect(!generation.matches(presentationA))
        #expect(generation.matches(presentationB))
    }
}
