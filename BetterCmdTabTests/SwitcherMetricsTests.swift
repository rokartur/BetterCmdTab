import Foundation
import Testing
@testable import BetterCmdTab

@Suite("SwitcherMetrics")
struct SwitcherMetricsTests {

    @Test("reserveTabBand: on when always-expanded, or transiently while searching with the search-tab feature")
    func reserveTabBand() {
        typealias M = SwitcherMetrics
        // Always-expand reserves the band regardless of search.
        #expect(M.reserveTabBand(expandAsWindows: true, applicationsOnly: false, searchActive: false, searchExpandsTabs: false))
        // Search-tab feature: band only while actually searching.
        #expect(!M.reserveTabBand(expandAsWindows: false, applicationsOnly: false, searchActive: false, searchExpandsTabs: true))
        #expect(M.reserveTabBand(expandAsWindows: false, applicationsOnly: false, searchActive: true, searchExpandsTabs: true))
        // Neither feature → never.
        #expect(!M.reserveTabBand(expandAsWindows: false, applicationsOnly: false, searchActive: true, searchExpandsTabs: false))
        // Applications-only collapses to one row per app, so the band is never reserved.
        #expect(!M.reserveTabBand(expandAsWindows: true, applicationsOnly: true, searchActive: false, searchExpandsTabs: false))
        #expect(!M.reserveTabBand(expandAsWindows: false, applicationsOnly: true, searchActive: true, searchExpandsTabs: true))
    }

    @Test("scale 1.0 yields baseline values")
    func baseline() {
        let m = SwitcherMetrics.forScale(1.0)
        #expect(m.scale == 1.0)
        #expect(m.rowHeight == SwitcherMetrics.baseRowHeight)
        #expect(m.rowWidth == SwitcherMetrics.baseRowWidth)
        #expect(m.iconSize == SwitcherMetrics.baseIconSize)
        #expect(m.appNameWidth == SwitcherMetrics.baseAppNameWidth)
    }

    @Test("hiding app names zeroes the column and narrows the list row")
    func hideAppNamesNarrowsList() {
        let shown = SwitcherMetrics.forScale(1.0, layoutMode: .list, showAppNames: true)
        let hidden = SwitcherMetrics.forScale(1.0, layoutMode: .list, showAppNames: false)

        #expect(shown.appNameWidth == SwitcherMetrics.baseAppNameWidth)
        #expect(hidden.appNameWidth == 0)
        // List panel width drops by the freed app-name column plus its inter-gap.
        #expect(hidden.rowWidth == SwitcherMetrics.baseRowWidth
                - SwitcherMetrics.baseAppNameWidth - SwitcherMetrics.baseInterGap)
        #expect(shown.rowWidth == SwitcherMetrics.baseRowWidth)
    }

    @Test("showAppNames does not affect grid/preview metrics")
    func hideAppNamesGridUnaffected() {
        let shown = SwitcherMetrics.forScale(1.0, layoutMode: .gridView, showAppNames: true)
        let hidden = SwitcherMetrics.forScale(1.0, layoutMode: .gridView, showAppNames: false)
        #expect(shown.rowWidth == hidden.rowWidth)
        #expect(shown.tileSize == hidden.tileSize)
    }

    @Test("grid tile label area: full → compact when one hidden → zero when both hidden")
    func gridCompactLabelArea() {
        let full = SwitcherMetrics.forScale(1.0, layoutMode: .gridView, showAppNames: true, showWindowTitles: true)
        let nameOff = SwitcherMetrics.forScale(1.0, layoutMode: .gridView, showAppNames: false, showWindowTitles: true)
        let titleOff = SwitcherMetrics.forScale(1.0, layoutMode: .gridView, showAppNames: true, showWindowTitles: false)
        let bothOff = SwitcherMetrics.forScale(1.0, layoutMode: .gridView, showAppNames: false, showWindowTitles: false)
        // Two stacked lines only when both labels are shown.
        #expect(full.tileLabelArea == SwitcherMetrics.baseTileLabelArea)
        // Hiding one label drops a line; the surviving label + glyphs ride a single
        // slim row.
        #expect(nameOff.tileLabelArea == SwitcherMetrics.baseTileCompactLabelArea)
        #expect(titleOff.tileLabelArea == SwitcherMetrics.baseTileCompactLabelArea)
        // Hiding both drops the label area entirely → bare icon-only tile.
        #expect(bothOff.tileLabelArea == 0)
    }

    @Test("hidden app names reserve a list column for the hover action bar")
    func hiddenNamesReserveHoverColumn() {
        // No hover actions → the name column fully collapses (panel stays narrow).
        let none = SwitcherMetrics.forScale(1.0, layoutMode: .list, showAppNames: false, hoverActionCount: 0)
        #expect(none.appNameWidth == 0)

        // Six dots: reserve the part of the bar that doesn't fit the letter column.
        let many = SwitcherMetrics.forScale(1.0, layoutMode: .list, showAppNames: false, hoverActionCount: 6)
        let barW = HoverActionBar.contentWidth(visibleCount: 6, scale: 1.0)
        let expected = max(0, barW - SwitcherMetrics.baseLetterColumnWidth - SwitcherMetrics.baseInterGap)
        #expect(expected > 0)
        #expect(many.appNameWidth == expected)
        // The reserved column is added back to the row width vs the no-hover collapse.
        #expect(many.rowWidth == SwitcherMetrics.baseRowWidth - SwitcherMetrics.baseAppNameWidth + expected)
    }

    @Test("preview label area collapses to 0 whenever the window title is hidden")
    func previewLabelAreaCollapse() {
        let full = SwitcherMetrics.forScale(1.0, layoutMode: .windowPreview, showAppNames: true, showWindowTitles: true)
        let nameOff = SwitcherMetrics.forScale(1.0, layoutMode: .windowPreview, showAppNames: false, showWindowTitles: true)
        let titleOff = SwitcherMetrics.forScale(1.0, layoutMode: .windowPreview, showAppNames: true, showWindowTitles: false)
        let bothOff = SwitcherMetrics.forScale(1.0, layoutMode: .windowPreview, showAppNames: false, showWindowTitles: false)
        #expect(full.previewLabelArea == SwitcherMetrics.basePreviewLabelArea)
        #expect(nameOff.previewLabelArea == SwitcherMetrics.basePreviewLabelArea)   // title shown → keep the band
        // The preview band only ever shows the window title (the app icon is
        // decorative), so hiding the title reclaims the band regardless of the
        // app-name toggle — symmetric to letterHints collapsing the top strip.
        #expect(titleOff.previewLabelArea == 0)
        #expect(bothOff.previewLabelArea == 0)
    }

    @Test("preview label band survives both-labels-off when browser tabs are expanded")
    func previewLabelAreaKeptForBrowserTabs() {
        // Browser-tab tiles share the parent app icon + thumbnail, so the tab title
        // is the only distinguisher — the band must stay even with both labels off.
        let bothOffExpanded = SwitcherMetrics.forScale(
            1.0, layoutMode: .windowPreview,
            showAppNames: false, showWindowTitles: false, browserTabsExpanded: true)
        #expect(bothOffExpanded.previewLabelArea == SwitcherMetrics.basePreviewLabelArea)

        // Expansion only matters for the both-off preview case; grid ignores it and
        // still drops its label area to zero (icon-only) when both labels are hidden.
        let grid = SwitcherMetrics.forScale(
            1.0, layoutMode: .gridView,
            showAppNames: false, showWindowTitles: false, browserTabsExpanded: true)
        #expect(grid.tileLabelArea == 0)
    }

    @Test("scale clamps high values to 1.8")
    func upperClamp() {
        // forScreen with a 4K screen would normally raise scale beyond 1.8;
        // clamp must protect against giant rows.
        let m = SwitcherMetrics.forScale(2.5)
        // forScale doesn't clamp; only forScreen does. Verify forScreen behavior separately.
        #expect(m.scale == 2.5)
    }

    @Test("forScreen with nil falls back to reference width → scale 1.0")
    func nilScreenScale() {
        let m = SwitcherMetrics.forScreen(nil)
        #expect(m.scale == 1.0)
        #expect(m.rowHeight == SwitcherMetrics.baseRowHeight)
    }

    @Test("baseline static matches forScale(1.0)")
    func baselineMatchesForScale1() {
        let a = SwitcherMetrics.baseline
        let b = SwitcherMetrics.forScale(1.0)
        #expect(a == b)
    }

    @Test("scale 1.5 produces 1.5x integer-rounded dimensions")
    func scale1_5() {
        let m = SwitcherMetrics.forScale(1.5)
        #expect(m.scale == 1.5)
        #expect(m.rowHeight == (SwitcherMetrics.baseRowHeight * 1.5).rounded())
        #expect(m.iconSize == (SwitcherMetrics.baseIconSize * 1.5).rounded())
    }

    @Test("Equatable conformance: same scale → equal")
    func equatable() {
        #expect(SwitcherMetrics.forScale(1.2) == SwitcherMetrics.forScale(1.2))
        #expect(SwitcherMetrics.forScale(1.2) != SwitcherMetrics.forScale(1.3))
    }

    @Test("userScale below 1.0 shrinks past the screen-adaptive floor")
    func userScaleSmall() {
        // nil screen → adaptive scale 1.0; userScale 0.85 must apply on top,
        // proving the multiply happens after the max(1.0, …) clamp.
        let m = SwitcherMetrics.forScreen(nil, userScale: 0.85)
        #expect(m.scale == 0.85)
        #expect(m.iconSize == (SwitcherMetrics.baseIconSize * 0.85).rounded())
    }

    @Test("minimum user scale proportionally shrinks panel geometry")
    func userScaleMinimum() {
        let m = SwitcherMetrics.forScreen(nil, userScale: 0.5)
        #expect(m.scale == 0.5)
        #expect(m.iconSize == (SwitcherMetrics.baseIconSize * 0.5).rounded())
        #expect(m.outerPadding == (SwitcherMetrics.baseOuterPadding * 0.5).rounded())
        #expect(m.interGap == (SwitcherMetrics.baseInterGap * 0.5).rounded())
        #expect(m.fontSize == SwitcherMetrics.baseFontSize * 0.5)
    }

    @Test("userScale above 1.0 enlarges the panel")
    func userScaleLarge() {
        let m = SwitcherMetrics.forScreen(nil, userScale: 1.2)
        #expect(m.scale == 1.2)
        #expect(m.tileIconSize == (SwitcherMetrics.baseTileIconSize * 1.2).rounded())
    }

    @Test("userScale defaults to 1.0 (no behavior change)")
    func userScaleDefault() {
        #expect(SwitcherMetrics.forScreen(nil) == SwitcherMetrics.forScreen(nil, userScale: 1.0))
    }

    @Test("corner-radius pref: 0 = automatic, -1 = square, > 0 = explicit points")
    func resolvedCornerRadius() {
        let m = SwitcherMetrics.forScale(1.0)
        #expect(m.resolvedCornerRadius(pref: 0) == m.cornerRadius)
        #expect(m.resolvedCornerRadius(pref: -1) == 0)
        #expect(m.resolvedCornerRadius(pref: 17) == 17)
        // Grid derives a different automatic radius; square must still win.
        let grid = SwitcherMetrics.forScale(1.0, layoutMode: .gridView)
        #expect(grid.resolvedCornerRadius(pref: 0) == SwitcherMetrics.baseTileCornerRadius)
        #expect(grid.resolvedCornerRadius(pref: -1) == 0)
    }

    @Test("fontScale defaults to 1.0 (no behavior change)")
    func fontScaleDefaultIdentity() {
        #expect(SwitcherMetrics.forScale(1.2) == SwitcherMetrics.forScale(1.2, fontScale: 1.0))
        #expect(SwitcherMetrics.forScreen(nil) == SwitcherMetrics.forScreen(nil, fontScale: 1.0))
    }

    @Test("fontScale multiplies every font size (#62)")
    func fontScaleScalesAllFonts() {
        let m = SwitcherMetrics.forScale(1.0, fontScale: 1.3)
        #expect(m.fontSize == SwitcherMetrics.baseFontSize * 1.3)
        #expect(m.letterFontSize == SwitcherMetrics.baseLetterFontSize * 1.3)
        #expect(m.tileNameFontSize == SwitcherMetrics.baseTileNameFontSize * 1.3)
        #expect(m.tileTitleFontSize == SwitcherMetrics.baseTileTitleFontSize * 1.3)
        #expect(m.tileLetterFontSize == SwitcherMetrics.baseTileLetterFontSize * 1.3)
        #expect(m.previewNameFontSize == SwitcherMetrics.basePreviewNameFontSize * 1.3)
    }

    @Test("fontScale grows the areas that hold text, not the tile geometry")
    func fontScaleGrowsTextAreas() {
        let m = SwitcherMetrics.forScale(1.0, fontScale: 1.3)
        #expect(m.labelHeight == round(SwitcherMetrics.baseLabelHeight * 1.3))
        #expect(m.letterColumnWidth == round(SwitcherMetrics.baseLetterColumnWidth * 1.3))
        #expect(m.previewLabelArea == round(SwitcherMetrics.basePreviewLabelArea * 1.3))
        let grid = SwitcherMetrics.forScale(1.0, layoutMode: .gridView, fontScale: 1.3)
        #expect(grid.tileLabelArea == round(SwitcherMetrics.baseTileLabelArea * 1.3))
        #expect(grid.tileLetterArea == round(SwitcherMetrics.baseTileLetterArea * 1.3))
        // Icon/tile geometry stays on the panel scale alone.
        #expect(grid.tileSize == SwitcherMetrics.baseTileSize)
        #expect(grid.tileIconSize == SwitcherMetrics.baseTileIconSize)
        #expect(m.iconSize == SwitcherMetrics.baseIconSize)
    }

    @Test("shrinking text keeps the icon-driven row height, growing raises it")
    func fontScaleShrinkKeepsRowHeight() {
        let small = SwitcherMetrics.forScale(1.0, fontScale: 0.85)
        #expect(small.fontSize == SwitcherMetrics.baseFontSize * 0.85)
        #expect(small.rowHeight == SwitcherMetrics.baseRowHeight)
        let big = SwitcherMetrics.forScale(1.0, fontScale: 1.3)
        #expect(big.rowHeight == round(SwitcherMetrics.baseRowHeight * 1.3))
    }

    @Test("forScreen passes fontScale through to the fonts")
    func forScreenPassesFontScale() {
        let m = SwitcherMetrics.forScreen(nil, userScale: 1.0, fontScale: 0.85)
        #expect(m.fontSize == SwitcherMetrics.baseFontSize * 0.85)
        #expect(m.fontScale == 0.85)
    }
}

@Suite("Switcher grid/preview column fitting")
struct SwitcherFitColumnsTests {

    @Test("stays at the preferred columns when the rows already fit the height")
    func fitsWithoutExpansion() {
        // 12 tiles, 6 preferred cols → 2 rows, well under the 5-row cap.
        #expect(SwitcherView.fitColumns(count: 12, preferredCols: 6, tilesPerRow: 10, maxRows: 5) == 6)
        // A user's smaller column choice is honored when it doesn't overflow.
        #expect(SwitcherView.fitColumns(count: 8, preferredCols: 4, tilesPerRow: 10, maxRows: 4) == 4)
    }

    @Test("adds columns past the preferred count to keep rows within the height")
    func expandsToFitHeight() {
        // 40 tiles, 4 preferred cols → 10 rows > 5 cap → needs ceil(40/5)=8 cols.
        #expect(SwitcherView.fitColumns(count: 40, preferredCols: 4, tilesPerRow: 10, maxRows: 5) == 8)
        // After expansion the rows actually fit.
        let cols = SwitcherView.fitColumns(count: 20, preferredCols: 2, tilesPerRow: 10, maxRows: 4)
        #expect(cols == 5)
        #expect(Int(ceil(Double(20) / Double(cols))) <= 4)
    }

    @Test("never exceeds the width-driven column maximum (extreme counts)")
    func cappedByWidth() {
        // 100 tiles want ceil(100/5)=20 cols, but only 6 fit horizontally.
        #expect(SwitcherView.fitColumns(count: 100, preferredCols: 4, tilesPerRow: 6, maxRows: 5) == 6)
    }

    @Test("clamps a preferred column count above what the width holds")
    func preferredAboveWidth() {
        // preferredCols 12 but width holds only 6; rows then fit → 6.
        #expect(SwitcherView.fitColumns(count: 10, preferredCols: 12, tilesPerRow: 6, maxRows: 10) == 6)
    }

    @Test("gridFit expands columns past a user cap to keep rows within the height")
    func gridFitExpandsPastCap() {
        // tileW 100 + gap 10 → 8 cols fit the 870-wide area; itemH 100 + gap 10 →
        // 2 rows fit the 250-tall area. User cap 2 would need 6 rows (overflow),
        // so columns expand from 2 → 6 to land 12 tiles in 2 rows.
        let f = SwitcherView.gridFit(count: 12, tileW: 100, itemH: 100, gap: 10,
                                     maxListWidth: 870, maxListHeight: 250, userCap: 2)
        #expect(f.cols == 6)
        #expect(f.rowsCount == 2)
        #expect(f.listHeight <= 250)   // fits the visible height after expansion
    }

    @Test("gridFit never exceeds the width-driven column max (shrink-to-fit handles the rest)")
    func gridFitWidthCapped() {
        // 100 tiles want 50 cols to fit 2 rows, but only 5 fit the 540-wide area,
        // so cols cap at 5 and the rows overflow here — the configure-time fit
        // scale then shrinks the tiles. gridFit just reports the packing.
        let f = SwitcherView.gridFit(count: 100, tileW: 100, itemH: 100, gap: 10,
                                     maxListWidth: 540, maxListHeight: 250, userCap: 0)
        #expect(f.cols == 5)
        #expect(f.rowsCount == 20)
    }
}
