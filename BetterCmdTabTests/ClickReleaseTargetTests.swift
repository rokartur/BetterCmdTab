import Testing
@testable import BetterCmdTab

@Suite("Click on mouse release (#247)")
struct ClickReleaseTargetTests {
    private let windowA = SwitcherRow.Identity.window(100, 1)
    private let windowB = SwitcherRow.Identity.window(100, 2)

    @Test func releaseOffTargetsCancels() {
        #expect(SwitcherController.releaseTarget(pressed: .row(0), released: nil) == nil)
    }

    @Test func releaseOnAnotherRowPicksIt() {
        #expect(SwitcherController.releaseTarget(pressed: .row(0), released: .row(2)) == .row(2))
    }

    @Test func pressOnEmptyGlassThenReleaseOnRowPicksIt() {
        #expect(SwitcherController.releaseTarget(pressed: nil, released: .row(1)) == .row(1))
    }

    @Test func releaseOnTabActs() {
        #expect(SwitcherController.releaseTarget(pressed: .row(0), released: .tab(3)) == .tab(3))
    }

    @Test func actionPressedAndReleasedOnSameButtonActs() {
        let close = SwitcherView.ClickTarget.action(.close, row: 1, window: windowA)
        #expect(SwitcherController.releaseTarget(pressed: close, released: close) == close)
    }

    @Test func actionReleasedOnAnotherButtonCancels() {
        let pressed = SwitcherView.ClickTarget.action(.close, row: 1, window: windowA)
        let released = SwitcherView.ClickTarget.action(.quit, row: 1, window: windowA)
        #expect(SwitcherController.releaseTarget(pressed: pressed, released: released) == nil)
    }

    @Test func actionAfterReflowMovedAnotherWindowUnderPointerCancels() {
        let pressed = SwitcherView.ClickTarget.action(.close, row: 1, window: windowA)
        let released = SwitcherView.ClickTarget.action(.close, row: 1, window: windowB)
        #expect(SwitcherController.releaseTarget(pressed: pressed, released: released) == nil)
    }

    @Test func actionReachedByDragFromRowCancels() {
        let released = SwitcherView.ClickTarget.action(.close, row: 1, window: windowA)
        #expect(SwitcherController.releaseTarget(pressed: .row(1), released: released) == nil)
    }

    @Test func actionPressedThenReleasedOnRowPicksRow() {
        let pressed = SwitcherView.ClickTarget.action(.close, row: 1, window: windowA)
        #expect(SwitcherController.releaseTarget(pressed: pressed, released: .row(1)) == .row(1))
    }
}
