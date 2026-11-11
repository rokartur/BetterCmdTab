import CoreGraphics
import Testing
@testable import BetterCmdTab

@Suite("Window arrangement frames and the tile width cycle")
struct WindowArrangementTests {
    private let main = CGRect(x: 0, y: 0, width: 1200, height: 800)
    private let secondary = CGRect(x: -1920, y: 300, width: 1920, height: 1000)
    private let anySize = CGSize(width: 10, height: 10)

    private func frame(_ arrangement: WindowArrangement, in visible: CGRect) -> CGRect {
        WindowArrangement.frame(for: arrangement, visibleFrame: visible, windowSize: anySize)
    }

    @Test func tilesOnAFrameAtTheOrigin() {
        #expect(frame(.tileLeftHalf, in: main) == CGRect(x: 0, y: 0, width: 600, height: 800))
        #expect(frame(.tileRightHalf, in: main) == CGRect(x: 600, y: 0, width: 600, height: 800))
        #expect(frame(.tileTopLeft, in: main) == CGRect(x: 0, y: 400, width: 600, height: 400))
        #expect(frame(.tileTopRight, in: main) == CGRect(x: 600, y: 400, width: 600, height: 400))
        #expect(frame(.tileBottomLeft, in: main) == CGRect(x: 0, y: 0, width: 600, height: 400))
        #expect(frame(.tileBottomRight, in: main) == CGRect(x: 600, y: 0, width: 600, height: 400))
    }

    @Test func tilesOnAFrameWithAnOffsetOrigin() {
        #expect(frame(.tileLeftHalf, in: secondary) == CGRect(x: -1920, y: 300, width: 960, height: 1000))
        #expect(frame(.tileRightHalf, in: secondary) == CGRect(x: -960, y: 300, width: 960, height: 1000))
        #expect(frame(.tileTopLeft, in: secondary) == CGRect(x: -1920, y: 800, width: 960, height: 500))
        #expect(frame(.tileTopRight, in: secondary) == CGRect(x: -960, y: 800, width: 960, height: 500))
        #expect(frame(.tileBottomLeft, in: secondary) == CGRect(x: -1920, y: 300, width: 960, height: 500))
        #expect(frame(.tileBottomRight, in: secondary) == CGRect(x: -960, y: 300, width: 960, height: 500))
    }

    @Test func maximizeFillsTheVisibleFrame() {
        #expect(frame(.maximize, in: main) == main)
        #expect(frame(.maximize, in: secondary) == secondary)
    }

    @Test func centerKeepsTheSizeOfASmallerWindow() {
        let size = CGSize(width: 400, height: 300)
        #expect(WindowArrangement.frame(for: .center, visibleFrame: main, windowSize: size)
            == CGRect(x: 400, y: 250, width: 400, height: 300))
        #expect(WindowArrangement.frame(for: .center, visibleFrame: secondary, windowSize: size)
            == CGRect(x: -1160, y: 650, width: 400, height: 300))
    }

    @Test func centerClampsALargerWindowToTheFrame() {
        let size = CGSize(width: 2000, height: 1000)
        #expect(WindowArrangement.frame(for: .center, visibleFrame: main, windowSize: size) == main)
    }

    @Test func rightTileIsFlushToTheRightEdge() {
        let tile = WindowArrangement.tileFrame(side: .right, fraction: 2.0 / 3.0, visibleFrame: secondary)
        #expect(abs(tile.minX - -1280) < 0.001)
        #expect(abs(tile.width - 1280) < 0.001)
        #expect(abs(tile.maxX - 0) < 0.001)
        #expect(tile.minY == 300)
        #expect(tile.height == 1000)
    }

    @Test func leftTileStartsAtTheLeftEdge() {
        let tile = WindowArrangement.tileFrame(side: .left, fraction: 0.5, visibleFrame: secondary)
        #expect(tile == CGRect(x: -1920, y: 300, width: 960, height: 1000))
    }

    @Test func halvesCoverTheFrameWithoutOverlap() {
        for visible in [main, secondary] {
            let left = frame(.tileLeftHalf, in: visible)
            let right = frame(.tileRightHalf, in: visible)
            #expect(left.maxX == right.minX)
            #expect(left.union(right) == visible)
        }
    }

    @Test func topAndBottomHalvesSplitTheFrame() {
        let top = frame(.tileTopHalf, in: secondary)
        let bottom = frame(.tileBottomHalf, in: secondary)
        #expect(top == CGRect(x: -1920, y: 800, width: 1920, height: 500))
        #expect(bottom == CGRect(x: -1920, y: 300, width: 1920, height: 500))
        #expect(top.union(bottom) == secondary)
    }

    @Test func onlyLeftAndRightHalvesCycleWidths() {
        #expect(WindowArrangement.tileLeftHalf.cyclingSide == .left)
        #expect(WindowArrangement.tileRightHalf.cyclingSide == .right)
        let others: [WindowArrangement] = [
            .tileTopHalf, .tileBottomHalf, .tileTopLeft, .tileTopRight, .tileBottomLeft, .tileBottomRight, .maximize, .center,
        ]
        for arrangement in others {
            #expect(arrangement.cyclingSide == nil)
        }
    }

    @MainActor
    @Test func repeatedPressesStepThroughTheWidthCycle() {
        TileCycler.reset()
        let half: CGFloat = 1.0 / 2.0
        let twoThirds: CGFloat = 2.0 / 3.0
        let third: CGFloat = 1.0 / 3.0
        #expect(TileCycler.nextFraction(windowId: 7, side: .left) == half)
        #expect(TileCycler.nextFraction(windowId: 7, side: .left) == twoThirds)
        #expect(TileCycler.nextFraction(windowId: 7, side: .left) == third)
        #expect(TileCycler.nextFraction(windowId: 7, side: .left) == half)

        #expect(TileCycler.nextFraction(windowId: 7, side: .left) == twoThirds)
        #expect(TileCycler.nextFraction(windowId: 7, side: .right) == half)

        #expect(TileCycler.nextFraction(windowId: 7, side: .right) == twoThirds)
        #expect(TileCycler.nextFraction(windowId: 8, side: .right) == half)

        TileCycler.reset()
        #expect(TileCycler.nextFraction(windowId: 0, side: .left) == half)
        #expect(TileCycler.nextFraction(windowId: 0, side: .left) == half)
        TileCycler.reset()
    }
}
