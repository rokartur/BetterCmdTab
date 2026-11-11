import ApplicationServices
import Foundation
import Testing
@testable import BetterCmdTab

@Suite("Search slot fitting and Handoff row placement")
struct SwitcherSearchRowsTests {
    private func closedRow(_ title: String) -> SwitcherRow {
        SwitcherRow(recentlyClosed: RecentEntry(
            bundleID: "test.\(title)", appName: title, title: title, documentPath: nil, closedAt: Date(timeIntervalSince1970: 0)
        ))
    }

    private var handoffRow: SwitcherRow {
        SwitcherRow(handoff: HandoffSuggestion(
            appName: "Safari",
            bundleID: "com.apple.Safari",
            appURL: URL(fileURLWithPath: "/Applications/Safari.app"),
            deviceName: "handoff",
            element: AXUIElementCreateSystemWide()
        ))
    }

    private func titles(_ rows: [SwitcherRow]) -> [String] {
        rows.map(\.windowTitle)
    }

    @Test func matchesThatFitAreUnchanged() {
        let fitted = SwitcherController.fitSearchSlots([4, 2, 9], slots: 3) { _ in true }
        #expect(fitted == [4, 2, 9])
    }

    @Test func tabsShareTheSlotsLeftByOtherRows() {
        let tabs: Set = [1, 2, 3, 4]
        let fitted = SwitcherController.fitSearchSlots([0, 1, 2, 3, 4, 5], slots: 4) { tabs.contains($0) }
        #expect(fitted == [0, 1, 2, 5])
    }

    @Test func tabsAloneAreCutToTheSlots() {
        let fitted = SwitcherController.fitSearchSlots([3, 4, 5], slots: 2) { _ in true }
        #expect(fitted == [3, 4])
    }

    @Test func otherRowsAreNeverDropped() {
        let fitted = SwitcherController.fitSearchSlots([0, 1, 2, 9], slots: 2) { $0 == 9 }
        #expect(fitted == [0, 1, 2])
    }

    @Test func noHandoffLeavesRowsAndIndex() {
        let placed = SwitcherController.placingHandoff(nil, in: [closedRow("a"), closedRow("b")], index: 1, placement: .first)
        #expect(titles(placed.rows) == ["a", "b"])
        #expect(placed.index == 1)
    }

    @Test func emptyPanelGetsNoHandoffRow() {
        let placed = SwitcherController.placingHandoff(handoffRow, in: [], index: 0, placement: .first)
        #expect(placed.rows.isEmpty)
        #expect(placed.index == 0)
    }

    @Test func firstPlacementShiftsTheIndex() {
        let placed = SwitcherController.placingHandoff(handoffRow, in: [closedRow("a"), closedRow("b")], index: 1, placement: .first)
        #expect(titles(placed.rows) == ["handoff", "a", "b"])
        #expect(placed.index == 2)
    }

    @Test func lastPlacementKeepsTheIndex() {
        let placed = SwitcherController.placingHandoff(handoffRow, in: [closedRow("a"), closedRow("b")], index: 1, placement: .last)
        #expect(titles(placed.rows) == ["a", "b", "handoff"])
        #expect(placed.index == 1)
    }

    @Test func offPlacementAddsNothing() {
        let placed = SwitcherController.placingHandoff(handoffRow, in: [closedRow("a")], index: 0, placement: .off)
        #expect(titles(placed.rows) == ["a"])
        #expect(placed.index == 0)
    }

    @Test func combinedRowsOrderBaseThenClosedThenHandoff() {
        let combined = SwitcherController.combinedRows(
            base: [closedRow("base")], recentlyClosed: [closedRow("closed")], handoff: handoffRow, placement: .last
        )
        #expect(titles(combined) == ["base", "closed", "handoff"])
    }
}
