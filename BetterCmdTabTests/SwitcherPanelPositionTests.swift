import AppKit
import Testing
@testable import BetterCmdTab

@MainActor
@Suite("Switcher panel vertical position")
struct SwitcherPanelPositionTests {
    private let visible = NSRect(x: 0, y: 40, width: 1000, height: 1000)

    @Test("middle centers the panel on the visible frame")
    func middleCenters() {
        let origin = SwitcherPanel.origin(of: NSSize(width: 400, height: 300), in: visible, position: .center)
        #expect(origin == NSPoint(x: 300, y: 390))
    }

    @Test("top keeps the top edge still as the panel shrinks")
    func topPinsTopEdge() {
        for height in [600.0, 300.0, 80.0] {
            let origin = SwitcherPanel.origin(of: NSSize(width: 400, height: height), in: visible, position: .top)
            #expect(origin.y + height == 840)
        }
    }

    @Test("top slides a too-tall panel up instead of past the bottom")
    func topClampsToBottom() {
        let origin = SwitcherPanel.origin(of: NSSize(width: 400, height: 950), in: visible, position: .top)
        #expect(origin.y == visible.minY)
    }

    @Test("middle keeps the switcher centered while the shelf hangs below it")
    func middleHangsShelfBelowSwitcher() {
        let alone = SwitcherPanel.origin(of: NSSize(width: 400, height: 300), in: visible, position: .center)
        let withShelf = SwitcherPanel.origin(of: NSSize(width: 400, height: 500), in: visible, position: .center, hanging: 200)
        #expect(withShelf.y + 500 == alone.y + 300)
    }

    @Test("middle slides a shelf that would cross the bottom back up")
    func middleClampsShelfToBottom() {
        let origin = SwitcherPanel.origin(of: NSSize(width: 400, height: 900), in: visible, position: .center, hanging: 600)
        #expect(origin.y == visible.minY)
    }

    @Test("top keeps its top edge whether or not a shelf hangs below")
    func topIgnoresHanging() {
        let alone = SwitcherPanel.origin(of: NSSize(width: 400, height: 300), in: visible, position: .top)
        let withShelf = SwitcherPanel.origin(of: NSSize(width: 400, height: 500), in: visible, position: .top, hanging: 200)
        #expect(withShelf.y + 500 == alone.y + 300)
    }
}
