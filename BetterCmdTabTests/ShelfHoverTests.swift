import AppKit
import Testing
@testable import BetterCmdTab

struct ShelfHoverTests {
    @Test func sidewaysScanSelectsAtOnce() {
        #expect(!SwitcherController.pointerHeadsForShelf(from: NSPoint(x: 100, y: 500), to: NSPoint(x: 140, y: 498)))
        #expect(!SwitcherController.pointerHeadsForShelf(from: NSPoint(x: 140, y: 500), to: NSPoint(x: 100, y: 502)))
    }

    @Test func movingDownWaitsForTheGrace() {
        #expect(SwitcherController.pointerHeadsForShelf(from: NSPoint(x: 100, y: 500), to: NSPoint(x: 103, y: 490)))
    }

    @Test func movingUpSelectsAtOnce() {
        #expect(!SwitcherController.pointerHeadsForShelf(from: NSPoint(x: 100, y: 490), to: NSPoint(x: 100, y: 500)))
    }

    @Test func firstHoverSelectsAtOnce() {
        #expect(!SwitcherController.pointerHeadsForShelf(from: nil, to: NSPoint(x: 100, y: 500)))
    }
}
