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

    // MARK: - Corner quarters (Cocoa bottom-left origin: "top" sits at midY)

    @Test("corner quarters occupy the right half-square in each corner")
    func corners() {
        let size = CGSize(width: 300, height: 200)
        #expect(WindowArrangement.frame(for: .tileTopLeft, visibleFrame: visible, windowSize: size)
            == CGRect(x: 100, y: 550, width: 800, height: 500))
        #expect(WindowArrangement.frame(for: .tileTopRight, visibleFrame: visible, windowSize: size)
            == CGRect(x: 900, y: 550, width: 800, height: 500))
        #expect(WindowArrangement.frame(for: .tileBottomLeft, visibleFrame: visible, windowSize: size)
            == CGRect(x: 100, y: 50, width: 800, height: 500))
        #expect(WindowArrangement.frame(for: .tileBottomRight, visibleFrame: visible, windowSize: size)
            == CGRect(x: 900, y: 50, width: 800, height: 500))
    }

    @Test("only left/right halves report a cycling side")
    func cyclingSide() {
        #expect(WindowArrangement.tileLeftHalf.cyclingSide == .left)
        #expect(WindowArrangement.tileRightHalf.cyclingSide == .right)
        #expect(WindowArrangement.tileTopLeft.cyclingSide == nil)
        #expect(WindowArrangement.maximize.cyclingSide == nil)
        #expect(WindowArrangement.center.cyclingSide == nil)
    }

    // MARK: - Width cycle (½ → ⅓ → ⅔ → ½)

    // Fractions are floating point (e.g. ⅓ ≈ 0.3333…), so compare with a small
    // tolerance rather than exact bit-equality.
    private func isClose(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 1e-9 }

    @Test("right tile frames stay flush to the right edge")
    func rightTileFrame() {
        let third = WindowArrangement.tileFrame(side: .right, fraction: 1.0 / 3.0, visibleFrame: visible)
        #expect(isClose(third.maxX, visible.maxX))
        #expect(isClose(third.width, visible.width / 3))
        let twoThirds = WindowArrangement.tileFrame(side: .right, fraction: 2.0 / 3.0, visibleFrame: visible)
        #expect(isClose(twoThirds.maxX, visible.maxX))
        #expect(isClose(twoThirds.width, visible.width * 2 / 3))
    }

    @MainActor
    @Test("re-tiling the same window to the same side advances ½ → ⅓ → ⅔ → ½")
    func cyclerAdvances() {
        TileCycler.reset()
        let wid: CGWindowID = 42
        #expect(isClose(TileCycler.nextFraction(windowId: wid, side: .left), 1.0 / 2.0))
        #expect(isClose(TileCycler.nextFraction(windowId: wid, side: .left), 1.0 / 3.0))
        #expect(isClose(TileCycler.nextFraction(windowId: wid, side: .left), 2.0 / 3.0))
        #expect(isClose(TileCycler.nextFraction(windowId: wid, side: .left), 1.0 / 2.0))
    }

    @MainActor
    @Test("switching side restarts the cycle at half")
    func cyclerSideReset() {
        TileCycler.reset()
        _ = TileCycler.nextFraction(windowId: 42, side: .left) // ½
        _ = TileCycler.nextFraction(windowId: 42, side: .left) // ⅓
        #expect(isClose(TileCycler.nextFraction(windowId: 42, side: .right), 1.0 / 2.0))
    }

    @MainActor
    @Test("tiling a different window restarts the cycle at half")
    func cyclerWindowReset() {
        TileCycler.reset()
        _ = TileCycler.nextFraction(windowId: 1, side: .left) // ½
        _ = TileCycler.nextFraction(windowId: 1, side: .left) // ⅓
        #expect(isClose(TileCycler.nextFraction(windowId: 2, side: .left), 1.0 / 2.0))
    }

    @MainActor
    @Test("a non-cycling arrangement interrupts the cycle, so the next tile restarts at half")
    func cyclerInterrupt() {
        TileCycler.reset()
        _ = TileCycler.nextFraction(windowId: 7, side: .left) // ½
        _ = TileCycler.nextFraction(windowId: 7, side: .left) // ⅓
        TileCycler.reset() // applyArrangement does this when maximize/center/a corner intervenes
        #expect(isClose(TileCycler.nextFraction(windowId: 7, side: .left), 1.0 / 2.0))
    }

    @MainActor
    @Test("an unresolved window id (0) never inherits a prior window's cycle position")
    func cyclerZeroId() {
        TileCycler.reset()
        _ = TileCycler.nextFraction(windowId: 0, side: .left) // ½ (id can't be tracked)
        #expect(isClose(TileCycler.nextFraction(windowId: 0, side: .left), 1.0 / 2.0))
    }
}
