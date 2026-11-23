import AppKit
import Testing
@testable import BetterCmdTab

@Suite("Hover on the way to the window shelf (#211, #308)")
struct ShelfHoverGraceTests {
    @Test func sidewaysScanSelectsAtOnce() {
        #expect(!SwitcherController.pointerHeadsForShelf(
            from: NSPoint(x: 100, y: 500), to: NSPoint(x: 140, y: 498), graceOnThisRow: false))
    }

    @Test func downwardMoveWaits() {
        #expect(SwitcherController.pointerHeadsForShelf(
            from: NSPoint(x: 100, y: 500), to: NSPoint(x: 104, y: 490), graceOnThisRow: false))
    }

    @Test func firstSampleWaits() {
        #expect(SwitcherController.pointerHeadsForShelf(
            from: nil, to: NSPoint(x: 100, y: 500), graceOnThisRow: false))
    }

    @Test func sidewaysJitterInsideATallRowKeepsTheGrace() {
        #expect(SwitcherController.pointerHeadsForShelf(
            from: NSPoint(x: 100, y: 500), to: NSPoint(x: 103, y: 499), graceOnThisRow: true))
    }
}
