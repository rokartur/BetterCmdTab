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
}
