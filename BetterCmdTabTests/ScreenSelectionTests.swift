import CoreGraphics
import Testing
@testable import BetterCmdTab

@Suite("Pointer warp target")
struct PointerWarpTargetTests {
    static let displays = [
        CGRect(x: 0, y: 0, width: 1440, height: 900),
        CGRect(x: 1440, y: 0, width: 2560, height: 1440),
    ]

    @Test func pointerOnOtherDisplay_movesToCenterOfDisplayHoldingMostOfWindow() {
        let window = CGRect(x: 1000, y: 100, width: 1200, height: 600)
        let target = ScreenSelection.pointerWarpTarget(
            windowBounds: window, pointer: CGPoint(x: 100, y: 800), displayBounds: Self.displays)
        #expect(target == CGPoint(x: 2720, y: 720))
    }

    @Test func pointerAlreadyOnDisplayHoldingMostOfWindow_staysPut() {
        let window = CGRect(x: 1000, y: 100, width: 1200, height: 600)
        let target = ScreenSelection.pointerWarpTarget(
            windowBounds: window, pointer: CGPoint(x: 3000, y: 1000), displayBounds: Self.displays)
        #expect(target == nil)
    }

    @Test func pointerOverWindowOnItsSmallerDisplay_staysPut() {
        let window = CGRect(x: 1000, y: 100, width: 1200, height: 600)
        let target = ScreenSelection.pointerWarpTarget(
            windowBounds: window, pointer: CGPoint(x: 1200, y: 300), displayBounds: Self.displays)
        #expect(target == nil)
    }
}
