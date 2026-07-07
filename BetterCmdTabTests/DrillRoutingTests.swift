import Testing
@testable import BetterCmdTab

/// Pure-logic coverage for the window drill-down routing (#80): which `↓`
/// presses open the strip instead of navigating, and how strip titles fall
/// back for untitled windows. The eligibility checks that need live state
/// (visible panel, warm catalog cache) are manual-checklist territory.
@Suite("Window drill routing")
struct DrillRoutingTests {
    @Test("down never hijacks the list layout — column wrap stays navigation")
    func downNeverHijacksListLayout() {
        for rpc in [1, 2, 8] {
            #expect(!DrillRouting.downArrowOpensWindowDrill(
                layoutMode: .list, rowsPerColumn: rpc, searchActive: false, tabDrillActive: false))
        }
    }

    @Test("down never hijacks multi-row grids — 2-D neighbor moves stay navigation")
    func downNeverHijacksMultiRowGrid() {
        for mode in [SwitcherLayoutMode.gridView, .windowPreview] {
            #expect(!DrillRouting.downArrowOpensWindowDrill(
                layoutMode: mode, rowsPerColumn: 2, searchActive: false, tabDrillActive: false))
            #expect(!DrillRouting.downArrowOpensWindowDrill(
                layoutMode: mode, rowsPerColumn: 5, searchActive: false, tabDrillActive: false))
        }
    }

    @Test("down drills only where it was a redundant linear wrap (single-row grid/previews)")
    func downFiresOnlyOnSingleRowGridLikeLayouts() {
        for mode in [SwitcherLayoutMode.gridView, .windowPreview] {
            #expect(DrillRouting.downArrowOpensWindowDrill(
                layoutMode: mode, rowsPerColumn: 1, searchActive: false, tabDrillActive: false))
        }
    }

    @Test("search owns the arrows; an open strip keeps them for itself")
    func downSuppressedInSearchAndWhileDrilled() {
        #expect(!DrillRouting.downArrowOpensWindowDrill(
            layoutMode: .windowPreview, rowsPerColumn: 1, searchActive: true, tabDrillActive: false))
        #expect(!DrillRouting.downArrowOpensWindowDrill(
            layoutMode: .windowPreview, rowsPerColumn: 1, searchActive: false, tabDrillActive: true))
    }

    @Test("strip titles pass through, untitled windows fall back to the app name")
    func stripTitleFallsBackToAppName() {
        #expect(DrillRouting.stripTitle(windowTitle: "Report.pdf", appName: "Preview") == "Report.pdf")
        #expect(DrillRouting.stripTitle(windowTitle: "", appName: "Preview") == "Preview")
    }
}
