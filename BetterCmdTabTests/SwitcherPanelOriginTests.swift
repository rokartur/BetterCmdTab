import AppKit
import Testing
@testable import BetterCmdTab

@Suite("Switcher panel origin")
@MainActor
struct SwitcherPanelOriginTests {
    private let visible = NSRect(x: 0, y: 0, width: 1000, height: 1000)
    private let size = NSSize(width: 400, height: 200)

    @Test func topHangsFromOffset() {
        let origin = SwitcherPanel.origin(of: size, in: visible, position: .top, topOffsetPercent: 10)
        #expect(origin == NSPoint(x: 300, y: 700))
    }

    @Test func zeroOffsetTouchesTop() {
        let origin = SwitcherPanel.origin(of: size, in: visible, position: .top, topOffsetPercent: 0)
        #expect(origin.y + size.height == visible.maxY)
    }

    @Test func tallPanelSlidesUpInsteadOfSpilling() {
        let tall = NSSize(width: 400, height: 900)
        let origin = SwitcherPanel.origin(
            of: tall, in: visible, position: .top, topOffsetPercent: Preferences.topOffsetPercentRange.upperBound)
        #expect(origin.y == visible.minY)
    }

    @Test func centerIgnoresOffset() {
        let origin = SwitcherPanel.origin(
            of: size, in: visible, position: .center, topOffsetPercent: Preferences.topOffsetPercentRange.upperBound)
        #expect(origin == NSPoint(x: 300, y: 400))
    }

    @Test func defaultKeepsHistoricalTwentyPercent() {
        let origin = SwitcherPanel.origin(
            of: size, in: visible, position: .top, topOffsetPercent: Preferences.defaultTopOffsetPercent)
        #expect(origin == NSPoint(x: 300, y: 600))
    }

    @Test func topRoomIsTheHeightBelowTheOffset() {
        #expect(SwitcherPanel.topRoom(in: visible, topOffsetPercent: 40) == 600)
        #expect(SwitcherPanel.topRoom(in: visible, topOffsetPercent: 0) == 1000)
    }

    @Test func offsetMeasuresFromVisibleFrameNotScreenOrigin() {
        let shifted = NSRect(x: 100, y: 50, width: 1000, height: 1000)
        let origin = SwitcherPanel.origin(of: size, in: shifted, position: .top, topOffsetPercent: 10)
        #expect(origin == NSPoint(x: 400, y: 750))
    }
}
