import AppKit
import Testing
@testable import BetterCmdTab

/// Coverage for the memoized font factory (#62). NSFont resolution works
/// headless, so these run in the plain unit suite — no WindowServer needed.
@Suite("SwitcherFont")
@MainActor
struct SwitcherFontTests {
    @Test("monospaced design yields a fixed-pitch font (the issue's ask)")
    func monospacedIsFixedPitch() {
        let font = SwitcherFont.font(ofSize: 13, weight: .regular, design: .monospaced)
        #expect(font.isFixedPitch)
    }

    @Test("every design preserves the requested point size; .system is the system font")
    func designPreservesPointSizeAndWeight() {
        for face in SwitcherFontFace.allCases {
            let font = SwitcherFont.font(ofSize: 13, weight: .medium, design: face)
            #expect(font.pointSize == 13)
        }
        #expect(SwitcherFont.font(ofSize: 14, weight: .medium, design: .system)
            == NSFont.systemFont(ofSize: 14, weight: .medium))
    }

    @Test("repeat lookups return the same instance (resolve once, not per row)")
    func cacheReturnsIdenticalInstance() {
        // Pinned to a memoized design — .system is the unmemoized fast path.
        let a = SwitcherFont.font(ofSize: 13, weight: .semibold, design: .monospaced)
        let b = SwitcherFont.font(ofSize: 13, weight: .semibold, design: .monospaced)
        #expect(a === b)
    }
}
