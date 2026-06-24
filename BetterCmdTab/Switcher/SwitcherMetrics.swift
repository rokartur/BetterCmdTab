import AppKit

struct SwitcherMetrics: Equatable {
    let layoutMode: SwitcherLayoutMode
    let scale: CGFloat
    let rowHeight: CGFloat
    let rowWidth: CGFloat
    let iconSize: CGFloat
    let appNameWidth: CGFloat
    let interGap: CGFloat
    let horizontalInset: CGFloat
    let fontSize: CGFloat
    let outerPadding: CGFloat
    let cornerRadius: CGFloat
    let highlightCornerRadius: CGFloat
    let highlightInset: CGFloat
    let labelHeight: CGFloat
    let letterColumnWidth: CGFloat
    let letterFontSize: CGFloat

    // Icon-dock layout metrics
    let tileSize: CGFloat
    let tileIconSize: CGFloat
    let tileGap: CGFloat
    let tileLabelArea: CGFloat
    let tileLetterArea: CGFloat
    let tileNameFontSize: CGFloat
    let tileTitleFontSize: CGFloat
    let tileLetterFontSize: CGFloat
    let tileLetterBadgeSize: CGFloat
    let tileStatusIconSize: CGFloat
    let tileSelectionInset: CGFloat
    let tileSelectionCornerRadius: CGFloat

    // Window-preview (alt-tab) layout metrics
    let previewTileWidth: CGFloat
    let previewThumbHeight: CGFloat
    let previewGap: CGFloat
    let previewLabelArea: CGFloat
    let previewLetterArea: CGFloat
    let previewIconSize: CGFloat
    let previewNameFontSize: CGFloat
    let previewThumbCornerRadius: CGFloat
    let previewSelectionInset: CGFloat
    let previewSelectionCornerRadius: CGFloat

    static let baseRowHeight: CGFloat = 28
    static let baseRowWidth: CGFloat = 720
    static let baseIconSize: CGFloat = 18
    static let baseAppNameWidth: CGFloat = 200
    static let baseInterGap: CGFloat = 10
    static let baseHorizontalInset: CGFloat = 14
    static let baseFontSize: CGFloat = 13
    static let baseOuterPadding: CGFloat = 8
    static let baseCornerRadius: CGFloat = 12
    static let baseHighlightCornerRadius: CGFloat = 6
    static let baseHighlightInset: CGFloat = 4
    static let baseLabelHeight: CGFloat = 18
    static let baseLetterColumnWidth: CGFloat = 34
    static let baseLetterFontSize: CGFloat = 11
    static let referenceWidth: CGFloat = 1440

    // Icon-dock base metrics (sized to match macOS-default Cmd+Tab proportions).
    static let baseTileSize: CGFloat = 80
    static let baseTileIconSize: CGFloat = 64
    static let baseTileGap: CGFloat = 10
    static let baseTileLabelArea: CGFloat = 34
    /// Collapsed label area for grid tiles when both the app name and the window
    /// title are hidden — one slim row that still fits status glyphs and
    /// Launch/Reopen cues, dropping the (now empty) name line's height.
    static let baseTileCompactLabelArea: CGFloat = 18
    /// Top strip above each tile's icon that holds the type-to-jump letter, so
    /// the letter never overlaps the icon.
    static let baseTileLetterArea: CGFloat = 16
    static let baseTileNameFontSize: CGFloat = 11
    static let baseTileTitleFontSize: CGFloat = 10
    static let baseTileLetterFontSize: CGFloat = 11
    static let baseTileLetterBadgeSize: CGFloat = 20
    static let baseTileStatusIconSize: CGFloat = 12
    static let baseTileSelectionInset: CGFloat = 4
    static let baseTileSelectionCornerRadius: CGFloat = 16
    static let baseTileOuterPadding: CGFloat = 14
    static let baseTileCornerRadius: CGFloat = 24

    // Window-preview base metrics. A uniform tile: jump-letter strip on top, a
    // 16:10 thumbnail area in the middle (the live capture is aspect-fit and
    // letterboxed inside it), and a label row (small app icon + window title)
    // below. Reuses the grid tile's outer padding / panel corner radius.
    static let basePreviewTileWidth: CGFloat = 208
    static let basePreviewThumbHeight: CGFloat = 130
    static let basePreviewGap: CGFloat = 12
    static let basePreviewLabelArea: CGFloat = 24
    static let basePreviewIconSize: CGFloat = 18
    static let basePreviewNameFontSize: CGFloat = 11
    static let basePreviewThumbCornerRadius: CGFloat = 8
    static let basePreviewSelectionInset: CGFloat = 3
    static let basePreviewSelectionCornerRadius: CGFloat = 12

    static let baseline = SwitcherMetrics.forScale(1.0, layoutMode: .list)

    /// Whether the Window Preview label band must be reserved (the
    /// `browserTabsExpanded` input to `forScreen`/`forScale`): always when tabs
    /// are expanded as windows, and transiently while searching with the
    /// search-tab feature — the matched tab rows then need their title (the only
    /// thing distinguishing sibling tabs) shown even when "show window title" is
    /// off. Pure single source of truth shared by the controller and the view's
    /// shrink loop so the two predicates can't drift.
    static func reserveTabBand(expandAsWindows: Bool, applicationsOnly: Bool,
                               searchActive: Bool, searchExpandsTabs: Bool) -> Bool {
        (expandAsWindows || (searchActive && searchExpandsTabs)) && !applicationsOnly
    }

    static func forScreen(_ screen: NSScreen?, layoutMode: SwitcherLayoutMode = .list, userScale: CGFloat = 1.0, letterHints: Bool = true, showAppNames: Bool = true, showWindowTitles: Bool = true, hoverActionCount: Int = 0, browserTabsExpanded: Bool = false) -> SwitcherMetrics {
        let width = screen?.frame.width ?? referenceWidth
        let raw = width / referenceWidth
        // Screen-adaptive clamp first (keep base size on small displays, cap on
        // huge ones), then fold in the user's size preference as a free multiplier
        // so "Small" can shrink below the 1.0 floor.
        let clamped = max(1.0, min(1.8, raw)) * userScale
        return forScale(clamped, layoutMode: layoutMode, letterHints: letterHints, showAppNames: showAppNames, showWindowTitles: showWindowTitles, hoverActionCount: hoverActionCount, browserTabsExpanded: browserTabsExpanded)
    }

    /// `letterHints == false` collapses the space the jump-letter occupies — the
    /// top strip on tiles and the left column in the list — so the panel reflows
    /// tighter when the user turned letter hints off.
    static func forScale(_ scale: CGFloat, layoutMode: SwitcherLayoutMode = .list, letterHints: Bool = true, showAppNames: Bool = true, showWindowTitles: Bool = true, hoverActionCount: Int = 0, browserTabsExpanded: Bool = false) -> SwitcherMetrics {
        let outerPadding: CGFloat
        let cornerRadius: CGFloat
        switch layoutMode {
        case .list:
            outerPadding = round(baseOuterPadding * scale)
            cornerRadius = round(baseCornerRadius * scale)
        case .gridView, .windowPreview:
            outerPadding = round(baseTileOuterPadding * scale)
            cornerRadius = round(baseTileCornerRadius * scale)
        }

        let letterColumnW = letterHints ? round(baseLetterColumnWidth * scale) : 0

        // Hiding app names removes the List layout's dedicated name column so the
        // panel narrows. But the hover action bar floats over that column; with no
        // column the dots overlap the window title. So when names are hidden we
        // reserve just enough width for the bar's dots that don't already fit in
        // the letter column — scaling with how many hover actions are enabled.
        // Grid/Previews ignore appNameWidth and don't key panel width off rowWidth.
        let fullAppNameW = round(baseAppNameWidth * scale)
        let appNameW: CGFloat
        if showAppNames {
            appNameW = fullAppNameW
        } else if layoutMode == .list, hoverActionCount > 0 {
            let barW = HoverActionBar.contentWidth(visibleCount: hoverActionCount, scale: scale)
            appNameW = max(0, barW - letterColumnW - round(baseInterGap * scale))
        } else {
            appNameW = 0
        }
        // Reclaim whatever the name column gave up (and its trailing inter-gap when
        // the column fully collapses) from the row width.
        let rowW = layoutMode == .list
            ? round(baseRowWidth * scale) - (fullAppNameW - appNameW) - (appNameW == 0 ? round(baseInterGap * scale) : 0)
            : round(baseRowWidth * scale)

        // The grid tile stacks the app name over a secondary line (window title +
        // status glyphs). Two lines are needed only when both labels are shown;
        // hiding one collapses the area to a single slim row (the surviving label
        // rides the secondary line with the glyphs, losing nothing), and hiding both
        // drops the area entirely for a bare icon-only tile — the status glyphs go
        // with it. Either way the tile shrinks by the freed height.
        let tileLabelAreaH: CGFloat
        if layoutMode == .gridView, !showAppNames, !showWindowTitles {
            tileLabelAreaH = 0
        } else if layoutMode == .gridView, !(showAppNames && showWindowTitles) {
            tileLabelAreaH = round(baseTileCompactLabelArea * scale)
        } else {
            tileLabelAreaH = round(baseTileLabelArea * scale)
        }

        // Preview tiles carry a single label row: small app icon + window title.
        // The app-name toggle never adds text here (the icon stands in for the app),
        // so the only thing the band shows is the window title. When the title is
        // hidden, drop the band entirely — symmetric to letterHints collapsing the
        // top letter strip — so the tile is thumbnail-only and shorter, reclaiming
        // the bottom space. Exception: when browser tabs are expanded as windows,
        // every tab tile shares the parent app icon and thumbnail, so the tab title
        // is the *only* sibling distinguisher — keep the band (uniformly, so tile
        // heights stay aligned) even with the title otherwise hidden.
        let previewLabelAreaH = (layoutMode == .windowPreview && !showWindowTitles && !browserTabsExpanded)
            ? 0
            : round(basePreviewLabelArea * scale)

        return SwitcherMetrics(
            layoutMode: layoutMode,
            scale: scale,
            rowHeight: round(baseRowHeight * scale),
            rowWidth: rowW,
            iconSize: round(baseIconSize * scale),
            appNameWidth: appNameW,
            interGap: round(baseInterGap * scale),
            horizontalInset: round(baseHorizontalInset * scale),
            fontSize: baseFontSize * scale,
            outerPadding: outerPadding,
            cornerRadius: cornerRadius,
            highlightCornerRadius: round(baseHighlightCornerRadius * scale),
            highlightInset: round(baseHighlightInset * scale),
            labelHeight: round(baseLabelHeight * scale),
            letterColumnWidth: letterColumnW,
            letterFontSize: baseLetterFontSize * scale,
            tileSize: round(baseTileSize * scale),
            tileIconSize: round(baseTileIconSize * scale),
            tileGap: round(baseTileGap * scale),
            tileLabelArea: tileLabelAreaH,
            tileLetterArea: letterHints ? round(baseTileLetterArea * scale) : 0,
            tileNameFontSize: baseTileNameFontSize * scale,
            tileTitleFontSize: baseTileTitleFontSize * scale,
            tileLetterFontSize: baseTileLetterFontSize * scale,
            tileLetterBadgeSize: round(baseTileLetterBadgeSize * scale),
            tileStatusIconSize: round(baseTileStatusIconSize * scale),
            tileSelectionInset: round(baseTileSelectionInset * scale),
            tileSelectionCornerRadius: round(baseTileSelectionCornerRadius * scale),
            previewTileWidth: round(basePreviewTileWidth * scale),
            previewThumbHeight: round(basePreviewThumbHeight * scale),
            previewGap: round(basePreviewGap * scale),
            previewLabelArea: previewLabelAreaH,
            previewLetterArea: letterHints ? round(baseTileLetterArea * scale) : 0,
            previewIconSize: round(basePreviewIconSize * scale),
            previewNameFontSize: basePreviewNameFontSize * scale,
            previewThumbCornerRadius: round(basePreviewThumbCornerRadius * scale),
            previewSelectionInset: round(basePreviewSelectionInset * scale),
            previewSelectionCornerRadius: round(basePreviewSelectionCornerRadius * scale)
        )
    }
}
