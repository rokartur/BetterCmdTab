import CoreGraphics
import Foundation
import Testing
@testable import BetterCmdTab

/// Pure-geometry tests for the lightweight window arrangements (#7). The AX
/// frame writes themselves need a live window, but the target-frame math is a
/// pure function and is the part worth pinning down.
@Suite("WindowArrangement")
struct WindowArrangementTests {

    // A non-zero-origin visible frame (e.g. a screen below the menu bar with a
    // Dock) so off-by-origin mistakes surface.
    private let visible = CGRect(x: 100, y: 50, width: 1600, height: 1000)

    @Test("left half occupies the left, full height")
    func leftHalf() {
        let f = WindowArrangement.frame(for: .tileLeftHalf, visibleFrame: visible, windowSize: CGSize(width: 800, height: 600))
        #expect(f == CGRect(x: 100, y: 50, width: 800, height: 1000))
    }

    @Test("right half starts at the horizontal midpoint")
    func rightHalf() {
        let f = WindowArrangement.frame(for: .tileRightHalf, visibleFrame: visible, windowSize: CGSize(width: 800, height: 600))
        #expect(f == CGRect(x: 900, y: 50, width: 800, height: 1000))
    }

    @Test("maximize fills the visible frame exactly")
    func maximize() {
        let f = WindowArrangement.frame(for: .maximize, visibleFrame: visible, windowSize: CGSize(width: 300, height: 200))
        #expect(f == visible)
    }

    @Test("center keeps the window size and centers it")
    func center() {
        let f = WindowArrangement.frame(for: .center, visibleFrame: visible, windowSize: CGSize(width: 600, height: 400))
        #expect(f == CGRect(x: 100 + 500, y: 50 + 300, width: 600, height: 400))
    }

    @Test("center clamps an oversized window to the visible frame")
    func centerClamps() {
        let f = WindowArrangement.frame(for: .center, visibleFrame: visible, windowSize: CGSize(width: 9999, height: 9999))
        #expect(f == visible)
    }
}
