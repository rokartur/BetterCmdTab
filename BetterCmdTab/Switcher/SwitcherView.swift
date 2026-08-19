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
final class SwitcherView: NSView {

    weak var delegate: SwitcherViewDelegate?

    private let glassBackdrop: NSView
    /// Specular hairline on the panel edge — the same rim the tab strip's
    /// selection capsule wears, at the panel's corner radius.
    private let rim = GlassRimView()
    /// `NSGlassEffectView` outlines itself: a hairline a shade lighter than the panel,
    /// traced right inside its own edge, which reads as a window border rather than as
    /// glass. Nothing turns it off — not `clipsToBounds`, not `masksToBounds` on its
    /// layer, and none of the private knobs (`_variant`, `_contentLensing`, `_scrimState`
    /// and the rest were measured). So the glass is grown past the panel by this much and
    /// the whole view is clipped back to the panel's own rounded rect, which cuts the
    /// outline off along with it. Zero on the pre-26 fallback, which draws no such line.
    private let glassEdgeBleed: CGFloat
    private let allowsWindowCapture: Bool
    private let contentContainer = NSView()
    /// Backdrop pair layered under the content on Liquid Glass: a light frost, then a dim.
    private let haze = NSVisualEffectView()
    private let dim = BackdropDimView()
    private let listContainer = NSView()
    private let searchBar = SwitcherSearchBarView()
    private let tabStrip = TabStripView()
    /// Empty-state glyph + caption, shown centered when there are no rows
    /// (no open windows, or a search/scope that matched nothing — #31). Framed
    /// as a centered icon-over-title group in `layout()` via `emptyLayout()`.
    private let emptyIcon = NSImageView()
    private let emptyTitle = NSTextField(labelWithString: "")
    private var itemViews: [SwitcherItemViewProtocol] = []
    /// Keep the common reveal working set warm, but do not retain an extreme
    /// one-off row count (hundreds of browser tabs/windows) for process life.
    private static let idleItemPoolLimit = 64
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

    override convenience init(frame frameRect: NSRect) {
        self.init(frame: frameRect, allowsWindowCapture: true)
    }

    init(frame frameRect: NSRect, allowsWindowCapture: Bool) {
        self.allowsWindowCapture = allowsWindowCapture
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            // `.regular` is frosted: it blurs the backdrop away into a flat slab, so the
            // panel reads as blur rather than as glass. `.clear` keeps the backdrop
            // legible and lets the material show its refraction, which is the look this
            // panel wants; the legibility that frosting used to provide is restored by
            // the dimming layer behind the content below.
            glass.style = .clear
            glass.cornerRadius = SwitcherMetrics.baseCornerRadius
            glassBackdrop = glass
            glassEdgeBleed = 1
            Log.ui.debug("Glass: NSGlassEffectView")
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
            glassEdgeBleed = 0
            Log.ui.debug("Glass: NSVisualEffectView fallback")
        }
        super.init(frame: frameRect)

        addSubview(glassBackdrop)
        if #available(macOS 26.0, *), let glass = glassBackdrop as? NSGlassEffectView {
            glass.contentView = contentContainer
            wantsLayer = true   // clips the glass back to the panel; see `glassEdgeBleed`
            layer?.cornerCurve = .continuous
            layer?.masksToBounds = true
            // Clear glass leaves the backdrop sharp, so a frosted layer at low alpha
            // softens it back to a light blur, and the dim above it restores the
            // legibility that frosting used to provide (Apple pairs clear glass with a
            // dimming layer for the same reason). Order matters: both sit below every
            // row and label, so the dim darkens the backdrop rather than the text.
            //
            // Costs ~5 ms to stand up, which lands on `SwitcherController.init` — this
            // view is built once and reused for every reveal, so no reveal pays it.
            // The second `.behindWindow` sampler does keep compositing while the panel
            // is open, so it was measured (GPU device utilization, panel held open,
            // macOS 26.6, MacBook Pro 16-inch / MacBookPro18,4, Apple M1 Max):
            // idle 6 %, glass alone 25 %, glass + haze 29 %. Clear glass is
            // itself ~3 points cheaper than the frosted style it replaced (27 %), so the
            // pair lands ~2 points above what shipped — for as long as the panel shows.
            haze.material = .hudWindow
            haze.blendingMode = .behindWindow
            haze.state = .active   // the panel never becomes key, so don't dim with focus
            haze.alphaValue = 0.85
            for backdrop in [haze, dim] {
                backdrop.frame = contentContainer.bounds
                backdrop.autoresizingMask = [.width, .height]
                backdrop.wantsLayer = true
                backdrop.layer?.cornerCurve = .continuous
                backdrop.layer?.cornerRadius = SwitcherMetrics.baseCornerRadius
                backdrop.layer?.masksToBounds = true
                contentContainer.addSubview(backdrop)
            }
        } else {
            glassBackdrop.addSubview(contentContainer)
        }
        // The row block is slid by its layer on every reflow, so it owns one
        // outright instead of relying on the glass backdrop above it to make
        // the subtree layer-backed — without a layer the glide silently no-ops.
        listContainer.wantsLayer = true
        contentContainer.addSubview(listContainer)
        searchBar.isHidden = true
        contentContainer.addSubview(searchBar)
        tabStrip.isHidden = true
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
        // Last, so the panel edge stays lit above every row and label.
        rim.frame = contentContainer.bounds
        rim.autoresizingMask = [.width, .height]
        contentContainer.addSubview(rim)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    private static let livePreviewInterval: TimeInterval = 0.1
    private var livePreviewTimer: Timer?

    nonisolated deinit {
        tearDownOnMainActor { stopLivePreviewTimer() }
    }

    private var highlightPrefix: String = ""
    private var searchActive: Bool = false
    private var accent: NSColor = .controlAccentColor
    private var tabStripActive: Bool = false
    /// Visible frame the cached layout was fitted to. Metrics no longer vary by
    /// display, so without this a move to a same-metrics screen would keep a
    /// layout wrapped and clamped against the previous screen's bounds.
    private var layoutScreenFrameUsed: NSRect = .zero
    private var appliedPanelAppearance: PanelAppearance = .system
    /// Resolved appearance for the current reveal (#74). Set at the top of
    /// `configure` so the layout helpers below (and on standalone relayouts) read
    /// the firing shortcut's overrides instead of the global preferences.
    private var effective: EffectiveSettings = .defaults

    func configure(rows: [SwitcherRow], labels: [String], selectedIndex: Int, metrics: SwitcherMetrics, effective: EffectiveSettings, highlightPrefix: String = "", searchActive: Bool = false, searchQuery: String = "", tabStripItems: [TabStripItem]? = nil, tabStripSelectedIndex: Int = 0) {
        applyPanelAppearance(effective.panelAppearance)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Set before `fittedMetrics`/layout below read it (see ivar note).
        self.effective = effective
        // Item frames depend only on the row count, the metrics, and whether the
        // search strip is showing — not on row content or selection. When none
        // of those changed (a reorder, a glyph flip, an audio/badge repaint, a
        // selection move funnelled through here) the cached layout is still
        // valid, so skip invalidating it and forcing a full relayout + panel
        // resize. The item views still reconfigure below and relayout themselves
        // if their own content changed.
        let stripActiveNew = (tabStripItems?.isEmpty == false)
        // Shrink the panel to fit the screen for large app/window counts so it
        // stays fully visible instead of overflowing top/bottom. Shadows
        // the incoming `metrics` so every downstream sizing path (layout math and
        // the item views, which read the stored metrics) uses the fitted scale.
        let metrics = fittedMetrics(metrics, count: rows.count, searchActive: searchActive, tabActive: stripActiveNew)
        let screenFrame = layoutScreenFrame()
        let geometryChanged =
            rows.count != self.rows.count ||
            metrics != self.metrics ||
            searchActive != self.searchActive ||
            stripActiveNew != self.tabStripActive ||
            screenFrame != layoutScreenFrameUsed
        self.layoutScreenFrameUsed = screenFrame
        self.tabStripActive = stripActiveNew
        armReflow(incoming: rows, geometryChanged: geometryChanged)
        self.rows = rows
        self.labels = labels
        self.highlightPrefix = highlightPrefix
        self.searchActive = searchActive
        // Selection highlight / jump-letter color (#185) — the macOS accent by
        // default, re-read per reveal so both a settings change and a system
        // accent change land on the next open without any observer.
        self.accent = effective.selectionColor
        self.selectedIndex = selectedIndex
        // Only when it's on screen: this runs on every reveal, and the common
        // ⌘Tab has no search bar to configure.
        if searchActive {
            searchBar.update(query: searchQuery)
            searchBar.apply(metrics: metrics, face: effective.fontFace)
        }
        searchBar.isHidden = !searchActive
        if let items = tabStripItems, !items.isEmpty {
            tabStrip.configure(items: items, selectedIndex: tabStripSelectedIndex)
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
            emptyTitle.font = SwitcherFont.font(ofSize: round(14 * metrics.scale * metrics.fontScale), weight: .semibold, design: effective.fontFace)
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
        updatePreviewWiring()
        rebuildItemPool()
        if geometryChanged {
            cachedLayout = nil
            invalidateIntrinsicContentSize()
            needsLayout = true
        } else if reflowAnimates {
            // Rows only swapped places: the slots are unchanged, but the tiles
            // have to glide between them, and that needs a layout pass.
            needsLayout = true
        }
        applySelection()
        CATransaction.commit()
    }

    /// In window-preview mode, register the thumbnail-ready hook so a late
    /// capture repaints just its tile, and prompt for Screen Recording the first
    /// time previews are shown. Outside preview mode the hook is cleared so
    /// captures left over from an earlier preview reveal can't fire into list /
    /// grid tiles.
    private func updatePreviewWiring() {
        guard allowsWindowCapture else {
            stopLivePreviewTimer()
            return
        }
        guard metrics.layoutMode == .windowPreview else {
            WindowThumbnailCache.shared.onReady = nil
            stopLivePreviewTimer()
            return
        }
        WindowThumbnailCache.shared.ensurePermission()
        WindowThumbnailCache.shared.onReady = { [weak self] key in
            guard let self else { return }
            for view in self.itemViews {
                guard let preview = view as? SwitcherPreviewItemView, preview.thumbnailKey == key else { continue }
                preview.setThumbnail(WindowThumbnailCache.shared.image(for: key), for: key)
            }
        }
        syncLivePreviewTimer()
    }

    /// Live previews use short, tile-sized SCScreenshotManager captures rather
    /// than persistent SCStreams. Persistent per-window streams are smoother,
    /// but macOS marks every captured window with sharing UI; one-shot captures
    /// avoid that intrusive system overlay. 10 Hz is a practical middle ground
    /// between the old 2 fps behavior and the cost of continuously recapturing
    /// every visible window.
    private func syncLivePreviewTimer() {
        guard #available(macOS 14.0, *), Preferences.shared.livePreviews else {
            stopLivePreviewTimer()
            return
        }
        guard livePreviewTimer == nil else { return }
        let timer = Timer(timeInterval: Self.livePreviewInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.livePreviewTick() }
        }
        timer.tolerance = Self.livePreviewInterval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        livePreviewTimer = timer
    }

    private func stopLivePreviewTimer() {
        livePreviewTimer?.invalidate()
        livePreviewTimer = nil
    }

    private func livePreviewTick() {
        guard window?.isVisible == true, metrics.layoutMode == .windowPreview else {
            stopLivePreviewTimer()
            return
        }
        let scale = window?.backingScaleFactor ?? 2
        let pixelHeight = metrics.previewThumbHeight * scale
        for view in itemViews {
            guard let preview = view as? SwitcherPreviewItemView,
                  !preview.isHidden,
                  let key = preview.thumbnailKey else { continue }
            WindowThumbnailCache.shared.requestLiveFrame(wid: key, pixelHeight: pixelHeight)
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
        stopLivePreviewTimer()
        for v in itemViews {
            v.prepareForIdle()
            v.isHidden = true
        }
        while itemViews.count > Self.idleItemPoolLimit {
            let view = itemViews.removeLast()
            view.removeFromSuperview()
        }
        rows = []
        labels = []
        cachedLayout = nil
        appliedSelectedIndex = -1
        hoveredIndex = -1
        tabStripActive = false
        tabStrip.isHidden = true
        tabStrip.releaseIdleResources()
        searchBar.isHidden = true
        emptyIcon.isHidden = true
        emptyTitle.isHidden = true
        if allowsWindowCapture {
            WindowThumbnailCache.shared.onReady = nil
            WindowThumbnailCache.shared.releaseCaptureMetadata()
        }
    }

    var selectedRow: SwitcherRow? {
        rows.indices.contains(selectedIndex) ? rows[selectedIndex] : nil
    }

    var rowsPerColumn: Int {
        computeLayout().rowsPerCol
    }

    private func updateBackdropCornerRadius(_ radius: CGFloat) {
        rim.cornerRadius = radius
        if #available(macOS 26.0, *), let glass = glassBackdrop as? NSGlassEffectView {
            layer?.cornerRadius = radius
            glass.cornerRadius = radius + glassEdgeBleed
            haze.layer?.cornerRadius = radius
            dim.layer?.cornerRadius = radius
        } else {
            glassBackdrop.layer?.cornerRadius = radius
        }
    }

    /// Set a forced Aqua/Dark Aqua only when the preference changes. Leaving the
    /// override nil preserves AppKit's live system-appearance inheritance.
    private func applyPanelAppearance(_ value: PanelAppearance) {
        guard value != appliedPanelAppearance || (value == .system && appearance != nil) else { return }
        appliedPanelAppearance = value
        switch value {
        case .system: appearance = nil
        case .light: appearance = NSAppearance(named: .aqua)
        case .dark: appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// User-pinned corner radius when set (`-1` = square, `> 0` = explicit
    /// points), otherwise the size-derived metric.
    private func effectiveCornerRadius(_ metrics: SwitcherMetrics) -> CGFloat {
        metrics.resolvedCornerRadius(pref: effective.panelCornerRadius)
    }

    /// Apply the chosen blur material to the fallback backdrop. The macOS 26 glass
    /// path is left untouched: the glass itself takes no material, and the `haze`
    /// behind it is deliberately pinned to `.hudWindow` — it exists to put a light
    /// blur under clear glass, not to expose a second material control, and letting
    /// the preference drive it would change what Liquid Glass looks like rather than
    /// what the fallback blurs with.
    private func applyBackdropMaterial() {
        if #available(macOS 26.0, *), glassBackdrop is NSGlassEffectView { return }
        guard let effect = glassBackdrop as? NSVisualEffectView else { return }
        effect.material = effective.backdropMaterial.material
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
        // Same manual routing as `handleClick`: the hitTest override pins mouse
        // events to this view, so the strip is asked what is under the pointer
        // rather than each cell tracking it.
        if tabStripActive, !tabStrip.isHidden,
           let tabIdx = tabStrip.index(atWindowPoint: event.locationInWindow) {
            setHoveredIndex(-1)
            delegate?.switcherViewDidHoverTab(tabIdx)
            return
        }
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
        handleClick(atWindowPoint: event.locationInWindow)
    }

    /// Route a click at a window-local point to the tab strip, hover-action
    /// dots, or row selection. Split from `mouseDown` because clicks inside
    /// the panel are swallowed by the tap (#36) and arrive from the controller
    /// as a bare point — they never exist as deliverable NSEvents.
    func handleClick(atWindowPoint point: NSPoint) {
        // The hitTest override pins every mouse event to this view, so clicks
        // over the drill-in tab strip are routed to its cells manually (the
        // same way hover-action dots are hit-tested below).
        if tabStripActive, !tabStrip.isHidden,
           tabStrip.bounds.contains(tabStrip.convert(point, from: nil)) {
            if let tabIdx = tabStrip.index(atWindowPoint: point) {
                delegate?.switcherViewDidSelectTab(tabIdx)
            }
            return
        }
        guard let idx = indexAtWindowPoint(point), itemViews.indices.contains(idx) else { return }
        // A click on a hover-action dot runs that action instead of committing.
        // The dots can't receive events themselves (glass-hosted subtree), so
        // hit-test them here against the hovered row.
        if let action = itemViews[idx].hoverAction(atWindowPoint: point) {
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
    /// Armed by `configure` for one layout pass. See `armReflow`.
    private var reflowAnimates = false
    /// New row index → the frame that row's tile currently occupies, for the
    /// rows that changed places. See `applyItemFrames`.
    private var reflowOrigins: [Int: NSRect]?

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

    /// Row under a window-space point. The frames come out of `computeLayout()` in
    /// `listContainer`'s space — the same rects the item views get — so the point is
    /// converted there rather than summed along the parent chain, which silently goes
    /// wrong whenever an ancestor's origin moves (`glassEdgeBleed` did exactly that).
    private func indexAtWindowPoint(_ pointInWindow: NSPoint) -> Int? {
        let local = listContainer.convert(pointInWindow, from: nil)
        return computeLayout().frames.firstIndex { $0.contains(local) }
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
        // Park surplus views instead of destroying them: a search keystroke
        // shrinks and regrows the row count within one session, and destroying
        // views per keystroke defeats the idle pool. `prepareForIdle` drops
        // their image retains and thumbnail key so a late thumbnail callback
        // can't paint a parked tile; the hard trim stays in `releaseIdleResources`,
        // which bounds the pool at dismiss.
        while itemViews.count > max(rows.count, Self.idleItemPoolLimit) {
            let v = itemViews.removeLast()
            v.removeFromSuperview()
        }
        for i in rows.count..<itemViews.count {
            itemViews[i].prepareForIdle()
            itemViews[i].isHidden = true
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
                accent: accent,
                effective: effective
            )
            itemViews[i].isHovered = (i == hoveredIndex)
            itemViews[i].isHidden = false
        }
    }

    /// Vertical strip reserved above the list for the search bar plus a gap.
    private var reservedSearchHeight: CGFloat {
        metrics.reservedSearchHeight(active: searchActive)
    }
    /// Height the tab strip occupies under the list (with a gap).
    private var tabStripHeight: CGFloat { TabStripView.stripHeight }
    private var reservedTabStripHeight: CGFloat {
        tabStripActive ? tabStripHeight + metrics.outerPadding : 0
    }

    override var intrinsicContentSize: NSSize {
        var size = computeLayout().total
        size.height += reservedSearchHeight + reservedTabStripHeight
        // Grid/preview size the panel to their results, so a specific query used
        // to shrink it to a single tile. Floor it while search is open (the floor
        // depends only on `searchActive`, never on the query, so typing resizes
        // the panel no more often than it already did).
        if searchActive { size.width = max(size.width, metrics.searchMinPanelWidth) }
        return size
    }

    override func layout() {
        super.layout()
        let info = computeLayout()
        glassBackdrop.frame = bounds.insetBy(dx: -glassEdgeBleed, dy: -glassEdgeBleed)

        let contentSize = NSSize(width: bounds.width, height: bounds.height)
        // Offset by the bleed so the content stays put while the glass around it grows.
        contentContainer.frame = NSRect(
            origin: NSPoint(x: glassEdgeBleed, y: glassEdgeBleed),
            size: contentSize
        )

        let outer = metrics.outerPadding
        if searchActive {
            searchBar.frame = NSRect(
                x: outer,
                y: bounds.height - outer - metrics.searchBarHeight,
                width: max(0, bounds.width - outer * 2),
                height: metrics.searchBarHeight
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
        let previousListOrigin = listContainer.frame.origin
        listContainer.frame = NSRect(origin: listOrigin, size: info.listSize)
        if reflowAnimates { glideListContainer(from: previousListOrigin) }

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
            // The strip spans the same width as the row highlights above it,
            // which sit `highlightInset` inside their row.
            let stripInset = outer + metrics.highlightInset
            tabStrip.frame = NSRect(
                x: stripInset,
                y: outer,
                width: max(0, bounds.width - stripInset * 2),
                height: tabStripHeight
            )
        }

        applyItemFrames(info.frames)
    }

    /// Slides the whole row block from where it was drawn a moment ago to where
    /// this layout puts it. The panel resizes around its own center, so a strip
    /// claiming height at the bottom lifts every row on screen — and because the
    /// measuring layout pass runs before the panel's frame animation starts, the
    /// rows would otherwise land in their final screen position in a single
    /// frame and just sit there while the glass grows around them.
    /// Translating the layer rather than animating the frame is what keeps this
    /// stable: the panel's resize re-runs this layout on every step, so the model
    /// frame has to stay at the layout's answer while only the presentation lags.
    private func glideListContainer(from previous: NSPoint) {
        let current = listContainer.frame.origin
        let offset = NSPoint(x: previous.x - current.x, y: previous.y - current.y)
        guard offset.x != 0 || offset.y != 0, let layer = listContainer.layer else { return }
        let slide = CABasicAnimation(keyPath: "transform")
        slide.fromValue = NSValue(caTransform3D: CATransform3DMakeTranslation(offset.x, offset.y, 0))
        slide.duration = SwitcherMotion.duration
        slide.timingFunction = SwitcherMotion.timing
        layer.add(slide, forKey: "reflowGlide")
    }

    /// Decides whether the next layout pass glides its tiles into place, and
    /// from where. Two things move tiles: the grid re-flowing (the search strip
    /// or the tab strip claiming height, a wider panel fitting another column)
    /// and rows swapping places. Either way a tile is followed by identity, so
    /// it glides to wherever its own icon ended up instead of having content
    /// swapped underneath it while it stays put. A row that wasn't on screen a
    /// moment ago gets no entry and simply appears in its slot.
    /// Stays a hard cut when the panel isn't showing this content yet (a reveal
    /// has to land in one frame) or the user turned animations off.
    private func armReflow(incoming: [SwitcherRow], geometryChanged: Bool) {
        reflowOrigins = nil
        reflowAnimates = false
        // The panel exists from launch on, so its mere presence proves nothing:
        // the reveal reconfigures rows over a layout that has never run, and
        // gliding from that would fly the grid in from the window corner.
        guard window?.isVisible == true, !isHidden, !rows.isEmpty, !incoming.isEmpty,
              SwitcherMotion.isEnabled else { return }
        // Cheap first: every cycle step reconfigures the same rows at the same
        // size, and that path stays a handful of integer comparisons with
        // nothing allocated.
        guard geometryChanged
            || rows.count != incoming.count
            || zip(rows, incoming).contains(where: { $0.identity != $1.identity }) else { return }
        reflowAnimates = true
        var current: [SwitcherRow.Identity: NSRect] = [:]
        current.reserveCapacity(rows.count)
        for (index, row) in rows.enumerated() where index < itemViews.count {
            current[row.identity] = itemViews[index].frame
        }
        var origins: [Int: NSRect] = [:]
        for (index, row) in incoming.enumerated() {
            if let from = current[row.identity] { origins[index] = from }
        }
        reflowOrigins = origins.isEmpty ? nil : origins
    }

    /// Parks every tile where its row was last drawn, then lets it glide to the
    /// slot the layout just computed. Straight assignment otherwise — including
    /// the relayout passes that a resizing panel fires, which must not disturb a
    /// glide already in flight: `animator()` writes the target frame through
    /// immediately, so the equality check below leaves those tiles alone.
    private func applyItemFrames(_ frames: [NSRect]) {
        let origins = reflowOrigins
        let animates = reflowAnimates
        reflowOrigins = nil
        reflowAnimates = false
        guard animates else {
            for (index, rect) in frames.enumerated()
            where index < itemViews.count && itemViews[index].frame != rect {
                itemViews[index].frame = rect
            }
            return
        }
        // A tile with no origin is showing a row that wasn't on screen a moment
        // ago — nothing to glide from, so it lands in its slot directly.
        for (index, rect) in frames.enumerated() where index < itemViews.count {
            itemViews[index].frame = origins?[index] ?? rect
        }
        // `SwitcherPanel.present()` measures the panel by laying this view out
        // inside a transaction with actions disabled, and that is exactly the
        // pass a reflow lands in. Re-enable actions for the glide alone — without
        // this the tiles cut straight to their new slots.
        CATransaction.begin()
        CATransaction.setDisableActions(false)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = SwitcherMotion.duration
            context.timingFunction = SwitcherMotion.timing
            for (index, rect) in frames.enumerated()
            where index < itemViews.count && itemViews[index].frame != rect {
                itemViews[index].animator().frame = rect
            }
        }
        CATransaction.commit()
    }

    private struct ListLayout {
        let frames: [NSRect]
        let listSize: NSSize
        let total: NSSize
        let rowsPerCol: Int
        let cols: Int
    }

    /// Shrink the scale just enough that `count` items fit within the visible
    /// area once columns have been expanded to the width limit — so a large
    /// app/window count stays fully on screen instead of overflowing (or being
    /// clipped) top and bottom. Returns `base` whenever the content already fits.
    /// Floored so items never get microscopic; counts beyond even the floor's
    /// capacity fall back to the panel's visible-frame clamp in
    /// `SwitcherPanel.present()`.
    private func fittedMetrics(_ base: SwitcherMetrics, count: Int, searchActive: Bool, tabActive: Bool) -> SwitcherMetrics {
        let frame = layoutScreenFrame()
        let letterHints = base.tileLetterArea > 0
        let userCap = effective.gridMaxColumns

        /// `allowWrap: false` also rejects a grid that needs a second row, so the
        /// shrink loop can look for a scale that keeps everything on one.
        func fits(_ m: SwitcherMetrics, allowWrap: Bool = true) -> Bool {
            let reservedSearch = m.reservedSearchHeight(active: searchActive)
            let reservedTab = tabActive ? TabStripView.stripHeight + m.outerPadding : 0
            let maxW = frame.width * maxScreenWidthFraction - m.outerPadding * 2
            let maxH = frame.height * maxScreenHeightFraction - m.outerPadding * 2 - reservedSearch - reservedTab
            if m.layoutMode == .list {
                // The list wraps into columns on its own, but a wide base row or a
                // tall row height can still outrun the screen once the columns are
                // capped by width (#170).
                let fit = Self.listFit(count: count, rowH: m.rowHeight,
                                       baseRowW: m.resolvedRowWidth(percent: effective.listWidthPercent),
                                       scale: m.scale, maxListWidth: maxW, maxListHeight: maxH)
                // Width needs no test: `listFit` already clamps it to `maxListWidth`,
                // so overflow can only show up as height.
                return fit.listHeight <= maxH
            }
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
            if !allowWrap && fit.rowsCount > 1 { return false }
            return fit.listHeight <= maxH
        }

        // The macOS switcher never opens a second row: past a screenful of apps
        // it shrinks the icons until they all fit on one. The grid does the same
        // while a single row is still reachable above the scale floor. A user
        // column cap asks for rows, and the list and preview layouts wrap by
        // design, so both keep wrapping.
        let noWrap = effective.gridSingleRow && base.layoutMode == .gridView && userCap == 0

        if fits(base, allowWrap: !noWrap) { return base }
        // Shrink in small steps until it fits or we hit the floor (half the base
        // scale, and never below 0.5) — past that the clamp handles the residual.
        let minScale = max(0.5, base.scale * 0.5)
        var scale = base.scale
        var candidate = base
        // Biggest scale that fits only by wrapping. Kept so a count that can't be
        // squeezed onto one row even at the floor falls back to the largest tiles
        // that fit rather than to the smallest ones the loop tried.
        var wrapping: SwitcherMetrics? = noWrap && fits(base) ? base : nil
        while scale > minScale + 0.001 {
            scale = max(minScale, scale - 0.05)
            // Preserve a tab-only preview label band already present in `base`.
            // The view doesn't know whether the controller is in windows-only
            // mode, so re-deriving this from raw preferences can drop tab titles.
            let reserveBand = base.previewLabelArea > 0
                && !effective.showWindowTitleLabel
            candidate = SwitcherMetrics.forScale(scale, layoutMode: base.layoutMode, fontScale: effective.fontScale.multiplier, letterHints: letterHints, showAppNames: effective.showApplicationNames, showWindowTitles: effective.showWindowTitleLabel, hoverActionCount: Preferences.shared.enabledHoverActionCount, browserTabsExpanded: reserveBand)
            if fits(candidate, allowWrap: !noWrap) { return candidate }
            if noWrap, wrapping == nil, fits(candidate) { wrapping = candidate }
        }
        return wrapping ?? candidate
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

    /// Shared column/row packing for the list layout: as many rows per column as
    /// the visible height allows, wrapping into more columns while the width
    /// permits. The list analogue of `gridFit`, extracted so the configure-time
    /// fit-shrink can ask "would this scale fit?" without laying anything out.
    /// `listWidth` is always clamped to `maxListWidth` (one column takes the min, more
    /// columns are bounded by `maxColsByWidth`); only `listHeight` can still exceed its
    /// maximum at extreme counts — that is the signal for the caller to shrink the scale.
    nonisolated static func listFit(count: Int, rowH: CGFloat, baseRowW: CGFloat, scale: CGFloat, maxListWidth: CGFloat, maxListHeight: CGFloat) -> (cols: Int, rowsPerCol: Int, rowW: CGFloat, listWidth: CGFloat, listHeight: CGFloat) {
        let maxRowsByHeight = max(1, Int(floor(maxListHeight / rowH)))

        // Minimum column width: still enough for letter + app name + icon + a
        // bit of title before truncation. Scale with display, but never past a
        // user width cap (#124) — the cap wins over the readability floor.
        let minColWidth = min(round(380 * scale), baseRowW)
        let maxColsByWidth = max(1, Int(floor(maxListWidth / minColWidth)))

        // Determine how many columns we need to fit `count` without exceeding
        // screen height, then cap by how many narrow columns fit horizontally.
        let neededCols = max(1, Int(ceil(Double(count) / Double(maxRowsByHeight))))
        let cols = min(neededCols, maxColsByWidth)
        let rowsPerCol = max(1, Int(ceil(Double(count) / Double(cols))))

        // One column keeps full base width but never wider than the screen allows
        // (#170: a high panel scale can make the base row wider than the display,
        // and a single column has no divide step to rein it back in); multiple
        // columns shrink to share the available width evenly.
        let rowW: CGFloat
        if cols == 1 {
            rowW = min(baseRowW, maxListWidth)
        } else {
            let divided = floor(maxListWidth / CGFloat(cols))
            rowW = max(minColWidth, min(baseRowW, divided))
        }
        return (cols, rowsPerCol, rowW, CGFloat(cols) * rowW, CGFloat(rowsPerCol) * rowH)
    }

    private func computeListLayout() -> ListLayout {
        let rowH = metrics.rowHeight
        let baseRowW = metrics.resolvedRowWidth(percent: effective.listWidthPercent)
        let outerPadding = metrics.outerPadding
        let count = max(rows.count, 1)
        let screen = layoutScreenFrame()
        // Reserve room for the search bar and the tab strip so an at-cap list plus
        // either strip doesn't push the panel past the visible frame (present()
        // centers without clamping). Both are subtracted by the grid and preview
        // paths, added back by `intrinsicContentSize`, and subtracted by the list
        // branch of `fits()` — omitting one here made the fit check and the layout
        // disagree by exactly the strip's height.
        let maxListHeight = screen.height * maxScreenHeightFraction - outerPadding * 2
            - reservedSearchHeight - reservedTabStripHeight
        let maxListWidth = screen.width * maxScreenWidthFraction - outerPadding * 2

        let fit = Self.listFit(count: count, rowH: rowH, baseRowW: baseRowW, scale: metrics.scale,
                               maxListWidth: maxListWidth, maxListHeight: maxListHeight)
        let effectiveRowsPerCol = fit.rowsPerCol
        let rowW = fit.rowW
        let listWidth = fit.listWidth
        let listHeight = fit.listHeight

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
            cols: fit.cols
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
                               userCap: effective.gridMaxColumns)
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
                               userCap: effective.gridMaxColumns)
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

/// Veil under the clear glass, dark on dark and light on light. A fixed black would
/// darken the backdrop behind the near-black labels of a light panel and cost the
/// contrast it is there to buy — and a `CGColor` set once never re-resolves when the
/// system theme (or the panel-appearance preference) flips under a live view.
private final class BackdropDimView: NSView {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateAppearance()
    }

    private func updateAppearance() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.backgroundColor = (dark ? NSColor.black : NSColor.white).withAlphaComponent(0.2).cgColor
    }
}

/// Display-only search bar shown at the top of the panel in fuzzy-search mode.
/// Keystrokes are captured by the global event tap (not a real text field), so
/// this view only renders the current query text.
///
/// The view spans the panel width but draws only a chip sized to the query and
/// centered over the list: a full-width slab left a long empty trough above a
/// short result set, and read as pre-glass chrome sitting on top of the panel
/// rather than as part of it. The chip grows with the query up to the width of
/// the strip, but never shrinks below `chipMinWidth`.
@MainActor
private final class SwitcherSearchBarView: NSView {
    private let chip = NSView()
    private let icon = NSImageView()
    private let field = NSTextField(labelWithString: "")
    private var lastQuery: String?
    // A sentence-long hint stretched the empty chip wider than any query ever makes it;
    // the magnifier already says what the field does. Reuses a string the catalog
    // already carries, so no translation is lost.
    private let placeholder = String(localized: "Search")

    /// Chip geometry, refreshed per reveal from the live panel metrics. Every
    /// other element scales with the Size slider; the chip's insets and glyph
    /// used to be pinned to fixed points, which read a third too small at the
    /// default scale next to a 16.5pt app name. Starts at 0 so the first reveal
    /// always takes the apply path, whatever scale it comes in at.
    private var scale: CGFloat = 0
    private var iconSize: CGFloat = 0

    private var chipPadding: CGFloat { round(11 * scale) }
    private var chipSpacing: CGFloat { round(6 * scale) }
    /// Floor on the chip's width. Sized to the query alone, a one or two letter
    /// filter collapsed the chip to a glyph and a stub — too small to read as the
    /// panel's search field, and it twitched wider on every keystroke.
    private var chipMinWidth: CGFloat { round(150 * scale) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        chip.wantsLayer = true
        chip.layer?.cornerCurve = .continuous

        icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor

        field.lineBreakMode = .byTruncatingTail
        // Size/face come from `apply(metrics:face:)` per reveal (#62) — the bar is
        // created once, so the init font is only the pre-first-reveal default.
        field.font = .systemFont(ofSize: 14, weight: .medium)

        chip.addSubview(icon)
        chip.addSubview(field)
        addSubview(chip)
        update(query: "")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func layout() {
        super.layout()
        let height = bounds.height   // the pill fills the strip, so the bar height is the pill height
        let pad = chipPadding
        let gap = chipSpacing
        let leading = pad + iconSize + gap
        let text = field.intrinsicContentSize   // measured once: this runs per keystroke
        let width = min(max(leading + ceil(text.width) + pad, chipMinWidth), bounds.width)

        chip.frame = NSRect(x: round((bounds.width - width) / 2), y: 0,
                            width: width, height: height)
        chip.layer?.cornerRadius = height / 2
        icon.frame = NSRect(x: pad, y: round((height - iconSize) / 2),
                            width: iconSize, height: iconSize)
        let textHeight = ceil(text.height)
        field.frame = NSRect(x: leading, y: round((height - textHeight) / 2),
                             width: max(0, width - leading - pad), height: textHeight)
        updateAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    /// Guarded so the reveals that don't change the query (a selection move, a
    /// badge repaint) don't dirty the text field or the chip's width. The guard
    /// compares the query and not what's rendered, or a query that happens to
    /// equal the placeholder would be drawn in placeholder gray.
    func update(query: String) {
        guard lastQuery != query else { return }
        lastQuery = query
        field.stringValue = query.isEmpty ? placeholder : query
        field.textColor = query.isEmpty ? .tertiaryLabelColor : .labelColor
        needsLayout = true
    }

    /// Chip size/face, applied per reveal — the bar is created once and pooled,
    /// so a metrics or font change has to reach the live views. Guarded:
    /// `SwitcherFont` memoizes, so the common no-change path is one dictionary
    /// hit + pointer compare.
    func apply(metrics: SwitcherMetrics, face: SwitcherFontFace) {
        // Match the label the current layout draws for each item, so the query reads as
        // part of the panel's type scale instead of the largest text on screen: a fixed
        // 13pt sat two points above the names in grid and preview.
        let pointSize: CGFloat
        switch metrics.layoutMode {
        case .list: pointSize = metrics.fontSize
        case .gridView: pointSize = metrics.tileNameFontSize
        case .windowPreview: pointSize = metrics.previewNameFontSize
        }
        let font = SwitcherFont.font(ofSize: pointSize, weight: .medium, design: face)
        if field.font != font {
            field.font = font
            needsLayout = true
        }
        guard metrics.scale != scale else { return }
        scale = metrics.scale
        // Box a little larger than the glyph, so a symbol whose bounds exceed its
        // point size still has room to draw.
        iconSize = round(16 * metrics.scale)
        icon.symbolConfiguration = .init(pointSize: round(iconSize * 0.8), weight: .semibold)
        needsLayout = true
    }

    private func updateAppearance() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let base = dark ? NSColor.white : NSColor.black
        chip.layer?.backgroundColor = base.withAlphaComponent(dark ? 0.10 : 0.06).cgColor
    }
}
