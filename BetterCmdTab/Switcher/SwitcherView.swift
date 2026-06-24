import AppKit
import os

/// A window/app action invoked from a row's hover buttons. Raw values double as
/// `NSButton.tag`s in `HoverActionBar`.
enum RowAction: Int {
    case close
    case minimize
    case maximize
    case hide
    case quit
    case forceQuit
}

@MainActor
protocol SwitcherViewDelegate: AnyObject {
    func switcherViewDidHover(index: Int)
    func switcherViewDidClick(index: Int)
    func switcherViewDidInvokeAction(_ action: RowAction, atIndex index: Int)
    func switcherViewDidSelectTab(_ index: Int)
    func switcherViewDidHoverTab(_ index: Int)
}

@MainActor
final class SwitcherView: NSView, TabStripDelegate {
    func tabStrip(_ strip: TabStripView, didSelectIndex index: Int) {
        delegate?.switcherViewDidSelectTab(index)
    }

    func tabStrip(_ strip: TabStripView, didHoverIndex index: Int) {
        delegate?.switcherViewDidHoverTab(index)
    }

    weak var delegate: SwitcherViewDelegate?

    private let glassBackdrop: NSView
    private let contentContainer = NSView()
    private let listContainer = NSView()
    private let searchBar = SwitcherSearchBarView()
    private let tabStrip = TabStripView()
    /// Empty-state glyph + caption, shown centered when there are no rows
    /// (no open windows, or a search/scope that matched nothing — #31). Framed
    /// as a centered icon-over-title group in `layout()` via `emptyLayout()`.
    private let emptyIcon = NSImageView()
    private let emptyTitle = NSTextField(labelWithString: "")
    private var itemViews: [SwitcherItemViewProtocol] = []
    private var rows: [SwitcherRow] = []
    private(set) var labels: [String] = []
    private var selectedIndex: Int = 0
    /// Last `selectedIndex` value handed to the item views, so `applySelection`
    /// can toggle just the two affected tiles on arrow-spam instead of looping
    /// every item view every keystroke.
    private var appliedSelectedIndex: Int = -1
    /// Row the mouse is directly over (-1 = none). Separate from `selectedIndex`
    /// so hover action buttons appear only under the pointer, not on a
    /// keyboard-selected row.
    private var hoveredIndex: Int = -1
    private var cachedLayout: ListLayout?
    private var trackingArea: NSTrackingArea?

    private var metrics: SwitcherMetrics = .baseline
    let maxScreenHeightFraction: CGFloat = 0.85
    let maxScreenWidthFraction: CGFloat = 0.92

    override init(frame frameRect: NSRect) {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = SwitcherMetrics.baseCornerRadius
            glass.wantsLayer = true
            glass.layer?.masksToBounds = true
            glassBackdrop = glass
            Log.ui.debug("Glass: NSGlassEffectView style=regular")
        } else {
            let fallback = NSVisualEffectView()
            fallback.material = .hudWindow
            fallback.blendingMode = .behindWindow
            fallback.state = .active
            fallback.wantsLayer = true
            fallback.layer?.cornerRadius = SwitcherMetrics.baseCornerRadius
            fallback.layer?.cornerCurve = .continuous
            fallback.layer?.masksToBounds = true
            glassBackdrop = fallback
            Log.ui.debug("Glass: NSVisualEffectView fallback")
        }
        super.init(frame: frameRect)

        addSubview(glassBackdrop)
        if #available(macOS 26.0, *), let glass = glassBackdrop as? NSGlassEffectView {
            glass.contentView = contentContainer
        } else {
            glassBackdrop.addSubview(contentContainer)
        }
        contentContainer.addSubview(listContainer)
        searchBar.isHidden = true
        contentContainer.addSubview(searchBar)
        tabStrip.isHidden = true
        tabStrip.delegate = self
        contentContainer.addSubview(tabStrip)
        emptyIcon.isHidden = true
        emptyIcon.imageScaling = .scaleProportionallyUpOrDown
        emptyIcon.contentTintColor = .tertiaryLabelColor
        contentContainer.addSubview(emptyIcon)
        emptyTitle.isHidden = true
        emptyTitle.alignment = .center
        emptyTitle.textColor = .secondaryLabelColor
        emptyTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        contentContainer.addSubview(emptyTitle)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    private var highlightPrefix: String = ""
    private var searchActive: Bool = false
    private var accent: NSColor = .controlAccentColor
    private var tabStripActive: Bool = false

    func configure(rows: [SwitcherRow], labels: [String], selectedIndex: Int, metrics: SwitcherMetrics, highlightPrefix: String = "", searchActive: Bool = false, searchQuery: String = "", tabStripTitles: [String]? = nil, tabStripSelectedIndex: Int = 0) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Item frames depend only on the row count, the metrics, and whether the
        // search strip is showing — not on row content or selection. When none
        // of those changed (a reorder, a glyph flip, an audio/badge repaint, a
        // selection move funnelled through here) the cached layout is still
        // valid, so skip invalidating it and forcing a full relayout + panel
        // resize. The item views still reconfigure below and relayout themselves
        // if their own content changed.
        let stripActiveNew = (tabStripTitles?.isEmpty == false)
        // Shrink grid/preview tiles to fit the screen for large app/window counts
        // so they stay fully visible instead of overflowing top/bottom. Shadows
        // the incoming `metrics` so every downstream sizing path (layout math and
        // the item views, which read the stored metrics) uses the fitted scale.
        let metrics = fittedMetrics(metrics, count: rows.count, searchActive: searchActive, tabActive: stripActiveNew)
        let geometryChanged =
            rows.count != self.rows.count ||
            metrics != self.metrics ||
            searchActive != self.searchActive ||
            stripActiveNew != self.tabStripActive
        self.tabStripActive = stripActiveNew
        self.rows = rows
        self.labels = labels
        self.highlightPrefix = highlightPrefix
        self.searchActive = searchActive
        self.accent = Preferences.shared.resolvedAccent
        self.selectedIndex = selectedIndex
        searchBar.update(query: searchQuery)
        searchBar.isHidden = !searchActive
        if let titles = tabStripTitles, !titles.isEmpty {
            tabStrip.configure(titles: titles, selectedIndex: tabStripSelectedIndex, accent: accent)
            tabStrip.isHidden = false
        } else {
            tabStrip.isHidden = true
        }
        // Empty state (#31): no rows means either nothing is open (filters left
        // the catalog empty) or a live search/scope matched nothing. Present a
        // centered glyph + caption instead of flashing the panel away. The
        // glyph and copy switch on whether the user is searching.
        if rows.isEmpty {
            let symbol = searchActive ? "magnifyingglass" : "macwindow"
            let conf = NSImage.SymbolConfiguration(pointSize: round(34 * metrics.scale), weight: .regular)
            emptyIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(conf)
            emptyTitle.stringValue = searchActive
                ? String(localized: "No matches")
                : String(localized: "No open windows")
            emptyTitle.font = .systemFont(ofSize: round(14 * metrics.scale), weight: .semibold)
        }
        emptyIcon.isHidden = !rows.isEmpty
        emptyTitle.isHidden = !rows.isEmpty
        let layoutModeChanged = metrics.layoutMode != self.metrics.layoutMode
        if metrics != self.metrics {
            self.metrics = metrics
        }
        // Corner radius and blur material are user-tunable theme settings, so
        // apply them on every reveal (a cheap property set) rather than only when
        // the size-derived metrics change.
        updateBackdropCornerRadius(effectiveCornerRadius(metrics))
        applyBackdropMaterial()
        if layoutModeChanged {
            // Different item view class — clear the pool so rebuild picks the right type.
            for v in itemViews { v.removeFromSuperview() }
            itemViews.removeAll()
        }
        rebuildItemPool()
        if geometryChanged {
            cachedLayout = nil
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
        applySelection()
        updatePreviewWiring()
        CATransaction.commit()
    }

    /// In window-preview mode, register the thumbnail-ready hook so a late
    /// capture repaints just its tile, and prompt for Screen Recording the first
    /// time previews are shown. Outside preview mode the hook is cleared so
    /// captures left over from an earlier preview reveal can't fire into list /
    /// grid tiles.
    private func updatePreviewWiring() {
        guard metrics.layoutMode == .windowPreview else {
            WindowThumbnailCache.shared.onReady = nil
            return
        }
        WindowThumbnailCache.shared.ensurePermission()
        WindowThumbnailCache.shared.onReady = { [weak self] wid in
            guard let self else { return }
            for view in self.itemViews {
                guard let preview = view as? SwitcherPreviewItemView, preview.windowID == wid else { continue }
                preview.setThumbnail(WindowThumbnailCache.shared.image(for: wid), for: wid)
            }
        }
    }

    func setSelectedIndex(_ index: Int) {
        guard rows.indices.contains(index) else { return }
        selectedIndex = index
        applySelection()
    }

    /// Move the tab strip's selection without rebuilding the rest of the
    /// panel. Used on every tab arrow press; a full `configure(...)` would
    /// repaint every row's icon/title/badges for no visual change.
    func setTabStripSelectedIndex(_ index: Int) {
        guard tabStripActive else { return }
        tabStrip.setSelectedIndex(index)
    }

    /// Release per-tile `NSImage` retains (app icons, window thumbnails) so the
    /// `IconCache` / `WindowThumbnailCache` can evict images that would otherwise
    /// stay live for the process lifetime — but KEEP the item views pooled
    /// (hidden). Called by `SwitcherController` after `panel.dismiss()`.
    ///
    /// Previously this tore the whole pool down and the next reveal rebuilt it
    /// from scratch (`makeItemView` + `addSubview` per row, then a full autolayout
    /// pass), a cost that scales with the live app/window count and showed up as
    /// intermittent reveal-latency spikes (worst in grid layout). Keeping the
    /// views means the next `configure()` reuses them — only the row-count delta
    /// is ever allocated — while the heavy image retains are still dropped here.
    /// A layout-mode change between opens still rebuilds the pool with the right
    /// view class (handled in `configure`).
    func releaseIdleResources() {
        for v in itemViews {
            v.prepareForIdle()
            v.isHidden = true
        }
        rows = []
        labels = []
        cachedLayout = nil
        appliedSelectedIndex = -1
        hoveredIndex = -1
        tabStripActive = false
        tabStrip.isHidden = true
        searchBar.isHidden = true
        emptyIcon.isHidden = true
        emptyTitle.isHidden = true
        WindowThumbnailCache.shared.onReady = nil
    }

    var selectedRow: SwitcherRow? {
        rows.indices.contains(selectedIndex) ? rows[selectedIndex] : nil
    }

    var rowsPerColumn: Int {
        computeLayout().rowsPerCol
    }

    private func updateBackdropCornerRadius(_ radius: CGFloat) {
        if #available(macOS 26.0, *), let glass = glassBackdrop as? NSGlassEffectView {
            glass.cornerRadius = radius
        } else {
            glassBackdrop.layer?.cornerRadius = radius
        }
    }

    /// User-pinned corner radius when set (> 0), otherwise the size-derived metric.
    private func effectiveCornerRadius(_ metrics: SwitcherMetrics) -> CGFloat {
        let pref = Preferences.shared.panelCornerRadius
        return pref > 0 ? CGFloat(pref) : metrics.cornerRadius
    }

    /// Apply the chosen blur material to the fallback backdrop. The macOS 26
    /// glass backdrop has no material knob, so it's left untouched there.
    private func applyBackdropMaterial() {
        if #available(macOS 26.0, *), glassBackdrop is NSGlassEffectView { return }
        guard let effect = glassBackdrop as? NSVisualEffectView else { return }
        effect.material = Preferences.shared.backdropMaterial.material
        // Pin to `.active` on every reveal: the switcher must always read as
        // active/focused, never follow the (non-activating) panel's key state and
        // dim. Idempotent — cheap to re-assert alongside the material.
        effect.state = .active
    }

    var columnCount: Int {
        computeLayout().cols
    }

    /// Returns the index of the tile in the row above (direction = -1) or
    /// below (direction = +1) `current`, picking the tile whose horizontal
    /// midpoint is closest to the current tile's midX. If `wrap` is true and
    /// we'd go past the top/bottom edge, jumps to the opposite-end row.
    /// Returns nil if there's only one row or layout has no frames.
    func neighboringRowIndex(from current: Int, direction: Int, wrap: Bool = false) -> Int? {
        let info = computeLayout()
        guard info.frames.indices.contains(current) else { return nil }
        let currentFrame = info.frames[current]
        let currentMidX = currentFrame.midX

        // Group frames into rows by Y. Frames are emitted row-by-row from the
        // top, so consecutive frames with the same Y belong to one row.
        let tolerance: CGFloat = 0.5
        var rows: [[(idx: Int, midX: CGFloat)]] = []
        for (i, f) in info.frames.enumerated() {
            if let last = rows.last, let head = last.first, abs(info.frames[head.idx].minY - f.minY) < tolerance {
                rows[rows.count - 1].append((i, f.midX))
            } else {
                rows.append([(i, f.midX)])
            }
        }

        guard rows.count > 1 else { return nil }
        guard let currentRowIdx = rows.firstIndex(where: { row in
            row.contains(where: { $0.idx == current })
        }) else { return nil }

        var targetRowIdx = currentRowIdx + direction
        if !rows.indices.contains(targetRowIdx) {
            guard wrap else { return nil }
            targetRowIdx = ((targetRowIdx % rows.count) + rows.count) % rows.count
        }

        let targetRow = rows[targetRowIdx]
        guard !targetRow.isEmpty else { return nil }

        var best = targetRow[0]
        var bestDist = abs(best.midX - currentMidX)
        for cand in targetRow.dropFirst() {
            let dist = abs(cand.midX - currentMidX)
            if dist < bestDist {
                bestDist = dist
                best = cand
            }
        }
        return best.idx
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return frame.contains(point) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let idx = indexAtWindowPoint(event.locationInWindow)
        setHoveredIndex(idx ?? -1)
        if let idx {
            // Hover-select moves the selection to the row under the pointer; the
            // user can turn it off so the mouse can't change the selection by
            // accident (issue #47). The visual hover + action dots still track
            // the pointer either way.
            if Preferences.shared.mouseHoverSelectionEnabled {
                delegate?.switcherViewDidHover(index: idx)
            }
            // Highlight the hover-action dot under the pointer, if any.
            itemViews[idx].setHotDot(atWindowPoint: event.locationInWindow)
        }
    }

    override func mouseExited(with event: NSEvent) {
        setHoveredIndex(-1)
    }

    /// Track which row the mouse is directly over so only that row shows its
    /// hover action buttons (distinct from the keyboard selection).
    private func setHoveredIndex(_ index: Int) {
        guard index != hoveredIndex else { return }
        hoveredIndex = index
        for (i, view) in itemViews.enumerated() {
            view.isHovered = (i == index)
        }
    }

    override func mouseDown(with event: NSEvent) {
        // The hitTest override pins every mouse event to this view, so clicks
        // over the drill-in tab strip are routed to its cells manually (the
        // same way hover-action dots are hit-tested below).
        if tabStripActive, !tabStrip.isHidden,
           tabStrip.bounds.contains(tabStrip.convert(event.locationInWindow, from: nil)) {
            if let tabIdx = tabStrip.index(atWindowPoint: event.locationInWindow) {
                delegate?.switcherViewDidSelectTab(tabIdx)
            }
            return
        }
        guard let idx = indexAtWindowPoint(event.locationInWindow), itemViews.indices.contains(idx) else { return }
        // A click on a hover-action dot runs that action instead of committing.
        // The dots can't receive events themselves (glass-hosted subtree), so
        // hit-test them here against the hovered row.
        if let action = itemViews[idx].hoverAction(atWindowPoint: event.locationInWindow) {
            delegate?.switcherViewDidInvokeAction(action, atIndex: idx)
            return
        }
        // Click-select commits the row under the pointer; the user can turn it
        // off so a stray click inside the panel can't pick a window (issue #47).
        // Tab-strip and hover-action clicks above stay live regardless.
        if Preferences.shared.mouseClickSelectionEnabled {
            delegate?.switcherViewDidClick(index: idx)
        }
    }

    /// Re-entrancy guard: when the strip's scroll view can't use a wheel event
    /// (e.g. vertical-only deltas) it forwards it up the responder chain, which
    /// lands back here — without the guard that would loop forever.
    private var routingScrollToTabStrip = false

    override func scrollWheel(with event: NSEvent) {
        // hitTest keeps scroll events at the panel level too; hand events over
        // the drill-in tab strip to its scroll view so overflow stays reachable.
        if !routingScrollToTabStrip, tabStripActive, !tabStrip.isHidden,
           tabStrip.bounds.contains(tabStrip.convert(event.locationInWindow, from: nil)) {
            routingScrollToTabStrip = true
            tabStrip.handleScrollWheel(event)
            routingScrollToTabStrip = false
            return
        }
        super.scrollWheel(with: event)
    }

    private func indexAtWindowPoint(_ pointInWindow: NSPoint) -> Int? {
        let local = convert(pointInWindow, from: nil)
        let layoutInfo = computeLayout()
        let listOrigin = listContainer.frame.origin
        let contentOrigin = contentContainer.frame.origin
        let offsetX = contentOrigin.x + listOrigin.x
        let offsetY = contentOrigin.y + listOrigin.y
        for (i, rect) in layoutInfo.frames.enumerated() {
            let translated = rect.offsetBy(dx: offsetX, dy: offsetY)
            if translated.contains(local) { return i }
        }
        return nil
    }

    private func applySelection() {
        // Incremental: deselect the previous tile, select the new one. With
        // dozens of rows that's a 2-write update instead of one per row. The
        // -1 sentinel (or an out-of-bounds index after a configure pass)
        // forces a one-time full pass to sync state.
        let prev = appliedSelectedIndex
        if prev == selectedIndex { return }
        if itemViews.indices.contains(prev) {
            itemViews[prev].isSelected = false
        } else {
            for (i, view) in itemViews.enumerated() where i != selectedIndex {
                view.isSelected = false
            }
        }
        if itemViews.indices.contains(selectedIndex) {
            itemViews[selectedIndex].isSelected = true
        }
        appliedSelectedIndex = selectedIndex
    }

    private func makeItemView() -> SwitcherItemViewProtocol {
        switch metrics.layoutMode {
        case .list:
            return SwitcherItemView(frame: .zero)
        case .gridView:
            return SwitcherIconItemView(frame: .zero)
        case .windowPreview:
            return SwitcherPreviewItemView(frame: .zero)
        }
    }

    private func rebuildItemPool() {
        while itemViews.count < rows.count {
            let view = makeItemView()
            listContainer.addSubview(view)
            itemViews.append(view)
        }
        while itemViews.count > rows.count {
            let v = itemViews.removeLast()
            v.removeFromSuperview()
        }
        // `configure` writes `isSelected` directly below, so the next
        // `applySelection` call should not assume the previous selection is
        // still showing — invalidate it so the incremental path performs a
        // safety sync pass instead of toggling a stale tile.
        appliedSelectedIndex = -1
        for (i, row) in rows.enumerated() {
            // Quick-jump labels are inert in search mode (typing builds the
            // query, not a label jump), so suppress them to avoid confusion.
            let label = searchActive ? "" : (i < labels.count ? labels[i] : "")
            let highlightLen = (!highlightPrefix.isEmpty && label.hasPrefix(highlightPrefix)) ? highlightPrefix.count : 0
            itemViews[i].configure(
                with: row,
                label: label,
                prefixLength: highlightLen,
                selected: i == selectedIndex,
                metrics: metrics,
                accent: accent
            )
            itemViews[i].isHovered = (i == hoveredIndex)
            itemViews[i].isHidden = false
        }
    }

    /// Search-bar height for the current scale (0 when search is inactive).
    private var searchBarHeight: CGFloat { round(30 * metrics.scale) }
    /// Vertical strip reserved above the list for the search bar plus a gap.
    private var reservedSearchHeight: CGFloat {
        searchActive ? searchBarHeight + metrics.outerPadding : 0
    }
    /// Height the tab strip occupies under the list (with a gap).
    private var tabStripHeight: CGFloat { TabStripView.stripHeight }
    private var reservedTabStripHeight: CGFloat {
        tabStripActive ? tabStripHeight + metrics.outerPadding : 0
    }

    override var intrinsicContentSize: NSSize {
        var size = computeLayout().total
        size.height += reservedSearchHeight + reservedTabStripHeight
        return size
    }

    override func layout() {
        super.layout()
        let info = computeLayout()
        glassBackdrop.frame = bounds

        let contentSize = NSSize(width: bounds.width, height: bounds.height)
        contentContainer.frame = NSRect(origin: .zero, size: contentSize)

        let outer = metrics.outerPadding
        if searchActive {
            searchBar.frame = NSRect(
                x: outer,
                y: bounds.height - outer - searchBarHeight,
                width: max(0, bounds.width - outer * 2),
                height: searchBarHeight
            )
        }

        // List occupies the region below the reserved search strip and above
        // the reserved tab strip; center it there so the layout matches the
        // non-search/non-drill case when both are inactive.
        let listAreaHeight = bounds.height - reservedSearchHeight - reservedTabStripHeight
        let listOriginY = reservedTabStripHeight + (listAreaHeight - info.listSize.height) / 2
        let listOrigin = NSPoint(
            x: (bounds.width - info.listSize.width) / 2,
            y: listOriginY
        )
        listContainer.frame = NSRect(origin: listOrigin, size: info.listSize)

        // Empty state: stack the glyph over the caption and center the group in
        // the list area. Sized off the active scale so it tracks panel size.
        if rows.isEmpty {
            let g = emptyStateGeometry()
            let groupH = g.icon + g.spacing + g.title
            let midY = reservedTabStripHeight + listAreaHeight / 2
            let topY = midY + groupH / 2
            emptyIcon.frame = NSRect(
                x: (bounds.width - g.icon) / 2,
                y: topY - g.icon,
                width: g.icon,
                height: g.icon
            )
            emptyTitle.frame = NSRect(
                x: 0,
                y: topY - g.icon - g.spacing - g.title,
                width: bounds.width,
                height: g.title
            )
        }

        if tabStripActive {
            tabStrip.frame = NSRect(
                x: outer,
                y: outer,
                width: max(0, bounds.width - outer * 2),
                height: tabStripHeight
            )
        }

        for (i, rect) in info.frames.enumerated() where i < itemViews.count {
            itemViews[i].frame = rect
        }
    }

    private struct ListLayout {
        let frames: [NSRect]
        let listSize: NSSize
        let total: NSSize
        let rowsPerCol: Int
        let cols: Int
    }

    /// For the grid / window-preview layouts, shrink the tile scale just enough
    /// that `count` tiles fit within the visible height once columns have been
    /// expanded to the width limit — so a large app/window count stays fully on
    /// screen instead of overflowing (or being clipped) top and bottom. Returns
    /// `base` unchanged for the list layout (it bounds itself via columns) and
    /// whenever the content already fits. Floored so tiles never get microscopic;
    /// counts beyond even the floor's capacity fall back to the panel's
    /// visible-frame clamp in `SwitcherPanel.present()`.
    private func fittedMetrics(_ base: SwitcherMetrics, count: Int, searchActive: Bool, tabActive: Bool) -> SwitcherMetrics {
        guard base.layoutMode == .gridView || base.layoutMode == .windowPreview else { return base }
        let frame = layoutScreenFrame()
        let letterHints = base.tileLetterArea > 0
        let userCap = Preferences.shared.gridMaxColumns

        func fits(_ m: SwitcherMetrics) -> Bool {
            let reservedSearch = searchActive ? round(30 * m.scale) + m.outerPadding : 0
            let reservedTab = tabActive ? TabStripView.stripHeight + m.outerPadding : 0
            let maxW = frame.width * maxScreenWidthFraction - m.outerPadding * 2
            let maxH = frame.height * maxScreenHeightFraction - m.outerPadding * 2 - reservedSearch - reservedTab
            let tileW: CGFloat, itemH: CGFloat, gap: CGFloat
            if m.layoutMode == .windowPreview {
                tileW = m.previewTileWidth
                itemH = m.previewLetterArea + m.previewThumbHeight + m.previewLabelArea
                gap = m.previewGap
            } else {
                tileW = m.tileSize
                itemH = m.tileLetterArea + m.tileSize + m.tileLabelArea
                gap = m.tileGap
            }
            let fit = Self.gridFit(count: count, tileW: tileW, itemH: itemH, gap: gap,
                                   maxListWidth: maxW, maxListHeight: maxH, userCap: userCap)
            return fit.listHeight <= maxH
        }

        if fits(base) { return base }
        // Shrink in small steps until it fits or we hit the floor (half the base
        // scale, and never below 0.5) — past that the clamp handles the residual.
        let minScale = max(0.5, base.scale * 0.5)
        var scale = base.scale
        var candidate = base
        while scale > minScale + 0.001 {
            scale = max(minScale, scale - 0.05)
            candidate = SwitcherMetrics.forScale(scale, layoutMode: base.layoutMode, letterHints: letterHints, showAppNames: Preferences.shared.showApplicationNames, showWindowTitles: Preferences.shared.showWindowTitleLabel, hoverActionCount: Preferences.shared.enabledHoverActionCount, browserTabsExpanded: Preferences.shared.expandBrowserTabsAsWindows && !Preferences.shared.applicationsOnly)
            if fits(candidate) { return candidate }
        }
        return candidate
    }

    private func computeLayout() -> ListLayout {
        if let cachedLayout { return cachedLayout }
        let layout: ListLayout
        if rows.isEmpty {
            layout = emptyLayout()
        } else {
            switch metrics.layoutMode {
            case .list:
                layout = computeListLayout()
            case .gridView:
                layout = computeIconDockLayout()
            case .windowPreview:
                layout = computePreviewLayout()
            }
        }
        cachedLayout = layout
        return layout
    }

    /// Pixel sizes of the empty-state group's three parts at the current scale.
    /// Shared by `emptyLayout()` (panel sizing) and `layout()` (positioning) so
    /// the reserved box and the placed views always agree.
    private func emptyStateGeometry() -> (icon: CGFloat, spacing: CGFloat, title: CGFloat) {
        let s = metrics.scale
        return (icon: round(40 * s), spacing: round(12 * s), title: round(22 * s))
    }

    /// A compact, balanced panel for the no-rows case — wide enough for the
    /// caption with margins, tall enough for the glyph-over-title group plus
    /// breathing room — rather than the one-row sliver the list/grid layouts
    /// produce from a zero count.
    private func emptyLayout() -> ListLayout {
        let g = emptyStateGeometry()
        let outer = metrics.outerPadding
        let s = metrics.scale
        let titleW = ceil(emptyTitle.intrinsicContentSize.width)
        let contentW = max(round(260 * s), titleW + round(64 * s))
        let contentH = g.icon + g.spacing + g.title + round(44 * s)
        let listSize = NSSize(width: contentW, height: contentH)
        return ListLayout(
            frames: [],
            listSize: listSize,
            total: NSSize(width: contentW + outer * 2, height: contentH + outer * 2),
            rowsPerCol: 0,
            cols: 1
        )
    }

    /// Returns the visible frame of the screen to size the panel for. Prefers
    /// the controller-resolved session screen (`targetScreen`, set before every
    /// configure and cleared on dismiss): when a visible panel is being moved
    /// to another display, `window?.screen` still reports the OLD one until the
    /// frame actually moves, which would size the layout against the wrong
    /// display. Falls back to the live screen while visible, then
    /// `preferredScreen()`, because `NSWindow.screen` is frame-based and would
    /// otherwise return the screen from the previous open.
    private func layoutScreenFrame() -> NSRect {
        let panelTarget = (window as? SwitcherPanel)?.targetScreen
        let screen = panelTarget
            ?? (window?.isVisible == true ? window?.screen : nil)
            ?? SwitcherPanel.preferredScreen()
        return screen.visibleFrame
    }

    /// Pick a column count that keeps `count` tiles within the visible height
    /// when the width allows it. `preferredCols` is the width-driven or
    /// user-capped starting point; columns are only ADDED past it (never below,
    /// never beyond `tilesPerRow`) when the rows would otherwise overflow
    /// `maxRows`. The grid/preview analogue of the list layout's height-bounded
    /// multi-column wrapping — without it the grid and preview layouts run off
    /// the top and bottom of the screen with many apps/windows.
    nonisolated static func fitColumns(count: Int, preferredCols: Int, tilesPerRow: Int, maxRows: Int) -> Int {
        let base = max(1, min(preferredCols, tilesPerRow))
        let rows = Int(ceil(Double(count) / Double(base)))
        guard rows > maxRows else { return base }
        let neededByHeight = Int(ceil(Double(count) / Double(max(1, maxRows))))
        return max(base, min(tilesPerRow, neededByHeight))
    }

    /// Shared column/row packing for the grid and window-preview layouts: width-
    /// driven (or user-capped) columns, expanded to keep rows within the visible
    /// height when the width allows, plus the resulting content size. When even
    /// the max-width columns can't fit the height (extreme counts) the rows
    /// overflow here, and the configure-time fit-scale shrinks the tiles instead.
    nonisolated static func gridFit(count: Int, tileW: CGFloat, itemH: CGFloat, gap: CGFloat, maxListWidth: CGFloat, maxListHeight: CGFloat, userCap: Int) -> (cols: Int, rowsCount: Int, listWidth: CGFloat, listHeight: CGFloat) {
        let perTileStride = tileW + gap
        let tilesPerRow = max(1, Int(floor((maxListWidth + gap) / perTileStride)))
        let maxRowsByHeight = max(1, Int(floor((maxListHeight + gap) / (itemH + gap))))
        let preferred = userCap > 0 ? min(count, tilesPerRow, userCap) : min(count, tilesPerRow)
        let cols = fitColumns(count: count, preferredCols: preferred, tilesPerRow: tilesPerRow, maxRows: maxRowsByHeight)
        let rowsCount = max(1, Int(ceil(Double(count) / Double(cols))))
        let listWidth = CGFloat(cols) * tileW + CGFloat(max(0, cols - 1)) * gap
        let listHeight = CGFloat(rowsCount) * itemH + CGFloat(max(0, rowsCount - 1)) * gap
        return (cols, rowsCount, listWidth, listHeight)
    }

    private func computeListLayout() -> ListLayout {
        let rowH = metrics.rowHeight
        let baseRowW = metrics.rowWidth
        let outerPadding = metrics.outerPadding
        let count = max(rows.count, 1)
        let screen = layoutScreenFrame()
        // Reserve room for the search bar so an at-cap list + search strip
        // doesn't push the panel past the visible frame (present() centers
        // without clamping).
        let maxListHeight = screen.height * maxScreenHeightFraction - outerPadding * 2 - reservedSearchHeight
        let maxListWidth = screen.width * maxScreenWidthFraction - outerPadding * 2

        let maxRowsByHeight = max(1, Int(floor(maxListHeight / rowH)))

        // Minimum column width: still enough for letter + app name + icon + a
        // bit of title before truncation. Scale with display.
        let minColWidth: CGFloat = round(380 * metrics.scale)
        let maxColsByWidth = max(1, Int(floor(maxListWidth / minColWidth)))

        // Determine how many columns we need to fit `count` without exceeding
        // screen height, then cap by how many narrow columns fit horizontally.
        let neededCols = max(1, Int(ceil(Double(count) / Double(maxRowsByHeight))))
        let cols = min(neededCols, maxColsByWidth)
        let rowsPerCol = max(1, Int(ceil(Double(count) / Double(cols))))
        let effectiveRowsPerCol = cols == 1 ? count : rowsPerCol

        // One column keeps full base width; multiple columns shrink to share
        // the available width evenly, clamped to [minColWidth, baseRowW].
        let rowW: CGFloat
        if cols == 1 {
            rowW = baseRowW
        } else {
            let divided = floor(maxListWidth / CGFloat(cols))
            rowW = max(minColWidth, min(baseRowW, divided))
        }

        let listWidth = CGFloat(cols) * rowW
        let listHeight = CGFloat(effectiveRowsPerCol) * rowH

        var frames: [NSRect] = []
        frames.reserveCapacity(rows.count)

        for i in 0..<rows.count {
            let col = i / effectiveRowsPerCol
            let rowIdx = i % effectiveRowsPerCol
            let x = CGFloat(col) * rowW
            let y = listHeight - CGFloat(rowIdx + 1) * rowH
            frames.append(NSRect(x: x, y: y, width: rowW, height: rowH))
        }

        let total = NSSize(
            width: listWidth + outerPadding * 2,
            height: listHeight + outerPadding * 2
        )

        return ListLayout(
            frames: frames,
            listSize: NSSize(width: listWidth, height: listHeight),
            total: total,
            rowsPerCol: effectiveRowsPerCol,
            cols: cols
        )
    }

    private func computeIconDockLayout() -> ListLayout {
        let tile = metrics.tileSize
        let gap = metrics.tileGap
        let labelArea = metrics.tileLabelArea
        let letterArea = metrics.tileLetterArea
        let outerPadding = metrics.outerPadding
        let count = max(rows.count, 1)

        let screen = layoutScreenFrame()
        let maxListWidth = screen.width * maxScreenWidthFraction - outerPadding * 2
        let maxListHeight = screen.height * maxScreenHeightFraction - outerPadding * 2
            - reservedSearchHeight - reservedTabStripHeight

        // Tile stacks: letter strip (top) + icon + text labels (bottom).
        let itemH = letterArea + tile + labelArea
        let fit = Self.gridFit(count: count, tileW: tile, itemH: itemH, gap: gap,
                               maxListWidth: maxListWidth, maxListHeight: maxListHeight,
                               userCap: Preferences.shared.gridMaxColumns)
        let cols = fit.cols
        let rowsCount = fit.rowsCount
        let listWidth = fit.listWidth
        let listHeight = fit.listHeight

        var frames: [NSRect] = []
        frames.reserveCapacity(rows.count)

        // Center each row's tiles horizontally within the list bounds — when the
        // final row is partially filled it gets centered instead of pinning left.
        for rowIdx in 0..<rowsCount {
            let firstInRow = rowIdx * cols
            let lastInRow = min(firstInRow + cols, rows.count) - 1
            let tilesInRow = lastInRow - firstInRow + 1
            let rowContentWidth = CGFloat(tilesInRow) * tile + CGFloat(max(0, tilesInRow - 1)) * gap
            let rowStartX = (listWidth - rowContentWidth) / 2
            let y = listHeight - CGFloat(rowIdx + 1) * itemH - CGFloat(rowIdx) * gap
            for colIdx in 0..<tilesInRow {
                let x = rowStartX + CGFloat(colIdx) * (tile + gap)
                frames.append(NSRect(x: x, y: y, width: tile, height: itemH))
            }
        }

        let total = NSSize(
            width: listWidth + outerPadding * 2,
            height: listHeight + outerPadding * 2
        )

        return ListLayout(
            frames: frames,
            listSize: NSSize(width: listWidth, height: listHeight),
            total: total,
            rowsPerCol: rowsCount,
            cols: cols
        )
    }

    /// alt-tab–style preview grid: uniform thumbnail tiles wrapping into rows,
    /// width-driven (same packing as the icon-dock grid, just with the larger
    /// preview tile). The user "Grid columns" cap applies here too.
    private func computePreviewLayout() -> ListLayout {
        let tileW = metrics.previewTileWidth
        let itemH = metrics.previewLetterArea + metrics.previewThumbHeight + metrics.previewLabelArea
        let gap = metrics.previewGap
        let outerPadding = metrics.outerPadding
        let count = max(rows.count, 1)

        let screen = layoutScreenFrame()
        let maxListWidth = screen.width * maxScreenWidthFraction - outerPadding * 2
        let maxListHeight = screen.height * maxScreenHeightFraction - outerPadding * 2
            - reservedSearchHeight - reservedTabStripHeight

        // Preview tiles are tall, so width-only wrapping overflows the screen
        // height well before the width. `gridFit` adds columns to keep rows within
        // the visible height; the configure-time fit-scale shrinks the tiles when
        // even max-width columns can't fit (both auto and explicit-column-cap).
        let fit = Self.gridFit(count: count, tileW: tileW, itemH: itemH, gap: gap,
                               maxListWidth: maxListWidth, maxListHeight: maxListHeight,
                               userCap: Preferences.shared.gridMaxColumns)
        let cols = fit.cols
        let rowsCount = fit.rowsCount
        let listWidth = fit.listWidth
        let listHeight = fit.listHeight

        var frames: [NSRect] = []
        frames.reserveCapacity(rows.count)

        // Center each (possibly partial) row's tiles horizontally, matching the
        // icon-dock grid so the final row doesn't pin left.
        for rowIdx in 0..<rowsCount {
            let firstInRow = rowIdx * cols
            let lastInRow = min(firstInRow + cols, rows.count) - 1
            let tilesInRow = lastInRow - firstInRow + 1
            let rowContentWidth = CGFloat(tilesInRow) * tileW + CGFloat(max(0, tilesInRow - 1)) * gap
            let rowStartX = (listWidth - rowContentWidth) / 2
            let y = listHeight - CGFloat(rowIdx + 1) * itemH - CGFloat(rowIdx) * gap
            for colIdx in 0..<tilesInRow {
                let x = rowStartX + CGFloat(colIdx) * (tileW + gap)
                frames.append(NSRect(x: x, y: y, width: tileW, height: itemH))
            }
        }

        let total = NSSize(
            width: listWidth + outerPadding * 2,
            height: listHeight + outerPadding * 2
        )

        return ListLayout(
            frames: frames,
            listSize: NSSize(width: listWidth, height: listHeight),
            total: total,
            rowsPerCol: rowsCount,
            cols: cols
        )
    }
}

/// Display-only search bar shown at the top of the panel in fuzzy-search mode.
/// Keystrokes are captured by the global event tap (not a real text field), so
/// this view only renders the current query text.
@MainActor
private final class SwitcherSearchBarView: NSView {
    private let icon = NSImageView()
    private let field = NSTextField(labelWithString: "")
    private let placeholder = String(localized: "Type to filter apps & windows…")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerCurve = .continuous

        icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        field.font = .systemFont(ofSize: 14, weight: .medium)
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false

        addSubview(icon)
        addSubview(field)
        // The bar itself is positioned by manual frame layout (see SwitcherView.layout),
        // so its autoresizing mask yields a `width == 0` constraint while it is hidden /
        // before first sizing. Keep the trailing inset non-required so it breaks cleanly
        // at that transient zero width instead of logging an unsatisfiable-constraint error.
        let fieldTrailing = field.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12)
        fieldTrailing.priority = .defaultHigh
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            fieldTrailing,
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        update(query: "")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        updateAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    func update(query: String) {
        if query.isEmpty {
            field.stringValue = placeholder
            field.textColor = .tertiaryLabelColor
        } else {
            field.stringValue = query
            field.textColor = .labelColor
        }
    }

    private func updateAppearance() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let base = dark ? NSColor.white : NSColor.black
        layer?.backgroundColor = base.withAlphaComponent(dark ? 0.10 : 0.06).cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = base.withAlphaComponent(dark ? 0.12 : 0.08).cgColor
    }
}
