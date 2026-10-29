import CoreGraphics
import Testing
@testable import BetterCmdTab

@Suite("Activator window id resolve")
struct ActivatorWindowIDTests {

    @Test("a cached id never asks the target app")
    func cachedIDSkipsLiveResolve() {
        var askedTarget = false
        let wid = Activator.resolvedWindowID(cached: 42) {
            askedTarget = true
            return 7
        }
        #expect(wid == 42)
        #expect(!askedTarget)
    }

    @Test("no cached id falls back to the live resolve")
    func missingCacheResolvesLive() {
        #expect(Activator.resolvedWindowID(cached: 0) { 7 } == 7)
    }
}
