import AppKit
import CoreGraphics
import Testing
@testable import BetterCmdTab

@Suite("Spaceless Space filtering")
struct SpacelessSpaceFilterTests {

    private func row(
        _ wid: CGWindowID,
        tabSibling: Bool = false
    ) -> SwitcherRow {
        SwitcherRow(
            app: .current,
            window: nil,
            windowTitle: "",
            isMinimized: false,
            cgWindowID: wid,
            isTabSibling: tabSibling
        )
    }

    @Test("narrowed Space scope drops ordinary spaceless rows but keeps explicit tab siblings")
    func dropsOrdinarySpacelessRows() {
        let active: UInt64 = 100

        let rows: [SwitcherRow] = [
            row(10),
            row(20),
            row(30, tabSibling: true),
        ]

        let spaceByWindow: [CGWindowID: UInt64] = [
            10: active,
        ]

        let spaceless: Set<CGWindowID> = [
            20,
            30,
        ]

        let resolution = CatalogFilter.SpaceResolution(
            spaceByWindow: spaceByWindow,
            confirmedSpaceless: spaceless,
            onScreen: [10],
            allowedSpaces: [active]
        )

        let kept = CatalogFilter.filterToAllowedSpaces(rows, resolution)
        let keptIDs = kept.map { $0.cgWindowID }

        #expect(keptIDs == [10, 30])
    }
}
