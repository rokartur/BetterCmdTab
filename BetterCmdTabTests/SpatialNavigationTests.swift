import AppKit
import Testing
@testable import BetterCmdTab

@Suite("Spatial switcher navigation")
struct SpatialNavigationTests {
    // Two full rows followed by a centered, shorter row, as in window previews.
    private let frames: [NSRect] = [
        NSRect(x: 0, y: 220, width: 90, height: 90),
        NSRect(x: 110, y: 220, width: 90, height: 90),
        NSRect(x: 220, y: 220, width: 90, height: 90),
        NSRect(x: 0, y: 110, width: 90, height: 90),
        NSRect(x: 110, y: 110, width: 90, height: 90),
        NSRect(x: 220, y: 110, width: 90, height: 90),
        NSRect(x: 55, y: 0, width: 90, height: 90),
        NSRect(x: 165, y: 0, width: 90, height: 90),
    ]

    @Test("horizontal movement stops at each row edge instead of snaking")
    func horizontalEdges() {
        for edge in [2, 5, 7] {
            #expect(SwitcherView.columnNeighborIndex(frames: frames, from: edge, direction: 1) == nil)
        }
        for edge in [0, 3, 6] {
            #expect(SwitcherView.columnNeighborIndex(frames: frames, from: edge, direction: -1) == nil)
        }
        #expect(SwitcherView.columnNeighborIndex(frames: frames, from: 3, direction: 1) == 4)
        #expect(SwitcherView.columnNeighborIndex(frames: frames, from: 5, direction: -1) == 4)
    }

    @Test("turning right then down then left follows the displayed grid")
    func spatialPath() throws {
        let right = try #require(SwitcherView.columnNeighborIndex(frames: frames, from: 0, direction: 1))
        let down = try #require(SwitcherView.rowNeighborIndex(frames: frames, from: right, direction: 1))
        let left = try #require(SwitcherView.columnNeighborIndex(frames: frames, from: down, direction: -1))
        #expect(right == 1 && down == 4 && left == 3)
    }

    @Test("vertical movement aligns with the nearest tile in a shorter row")
    func partialRow() {
        #expect(SwitcherView.rowNeighborIndex(frames: frames, from: 3, direction: 1) == 6)
        #expect(SwitcherView.rowNeighborIndex(frames: frames, from: 5, direction: 1) == 7)
        #expect(SwitcherView.rowNeighborIndex(frames: frames, from: 4, direction: -1) == 1)
        #expect(SwitcherView.rowNeighborIndex(frames: frames, from: 0, direction: -1) == nil)
        #expect(SwitcherView.rowNeighborIndex(frames: frames, from: 7, direction: 1) == nil)
        // Keyboard callers explicitly request wrapping and retain that behavior.
        #expect(SwitcherView.rowNeighborIndex(frames: frames, from: 0, direction: -1, wrap: true) == 6)
    }

    @Test("empty layouts and stale selections cannot navigate")
    func invalidSelection() {
        #expect(SwitcherView.columnNeighborIndex(frames: [], from: 0, direction: 1) == nil)
        #expect(SwitcherView.rowNeighborIndex(frames: [], from: 0, direction: 1) == nil)
        #expect(SwitcherView.columnNeighborIndex(frames: frames, from: 99, direction: 1) == nil)
        #expect(SwitcherView.rowNeighborIndex(frames: frames, from: -1, direction: 1) == nil)
    }
}
