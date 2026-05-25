import AppKit
import os

@MainActor
protocol SwitcherViewDelegate: AnyObject {
    func switcherViewDidHover(index: Int)
    func switcherViewDidClick(index: Int)
}

@MainActor
final class SwitcherView: NSView {
    weak var delegate: SwitcherViewDelegate?

    private let glassBackdrop: NSView
    private let contentContainer = NSView()
    private let listContainer = NSView()
    private let searchBar = SwitcherSearchBarView()
    private let noResultsLabel = NSTextField(labelWithString: "No matches")
    private var itemViews: [SwitcherItemViewProtocol] = []
    private var rows: [SwitcherRow] = []
    private(set) var labels: [String] = []
    private var selectedIndex: Int = 0
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
        noResultsLabel.isHidden = true
        noResultsLabel.alignment = .center
        noResultsLabel.textColor = .secondaryLabelColor
        noResultsLabel.font = .systemFont(ofSize: 13, weight: .medium)
        contentContainer.addSubview(noResultsLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    private var highlightPrefix: String = ""
    private var searchActive: Bool = false
    private var accent: NSColor = .controlAccentColor

    func configure(rows: [SwitcherRow], labels: [String], selectedIndex: Int, metrics: SwitcherMetrics, highlightPrefix: String = "", searchActive: Bool = false, searchQuery: String = "") {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.rows = rows
        self.labels = labels
        self.highlightPrefix = highlightPrefix
        self.searchActive = searchActive
        self.accent = Preferences.shared.accentChoice.resolved
        self.selectedIndex = selectedIndex
        searchBar.update(query: searchQuery)
        searchBar.isHidden = !searchActive
        noResultsLabel.isHidden = !(searchActive && rows.isEmpty)
        let layoutModeChanged = metrics.layoutMode != self.metrics.layoutMode
        if metrics != self.metrics {
            self.metrics = metrics
            updateBackdropCornerRadius(metrics.cornerRadius)
        }
        if layoutModeChanged {
            // Different item view class — clear the pool so rebuild picks the right type.
            for v in itemViews { v.removeFromSuperview() }
            itemViews.removeAll()
        }
        rebuildItemPool()
        cachedLayout = nil
        invalidateIntrinsicContentSize()
        needsLayout = true
        applySelection()
        CATransaction.commit()
    }

    func setSelectedIndex(_ index: Int) {
        guard rows.indices.contains(index) else { return }
        selectedIndex = index
        applySelection()
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
        if let idx = indexAtWindowPoint(event.locationInWindow) {
            delegate?.switcherViewDidHover(index: idx)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if let idx = indexAtWindowPoint(event.locationInWindow) {
            delegate?.switcherViewDidClick(index: idx)
        }
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
        for (i, view) in itemViews.enumerated() {
            view.isSelected = (i == selectedIndex)
        }
    }

    private func makeItemView() -> SwitcherItemViewProtocol {
        switch metrics.layoutMode {
        case .list:
            return SwitcherItemView(frame: .zero)
        case .gridView:
            return SwitcherIconItemView(frame: .zero)
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
            itemViews[i].isHidden = false
        }
    }

    /// Search-bar height for the current scale (0 when search is inactive).
    private var searchBarHeight: CGFloat { round(30 * metrics.scale) }
    /// Vertical strip reserved above the list for the search bar plus a gap.
    private var reservedSearchHeight: CGFloat {
        searchActive ? searchBarHeight + metrics.outerPadding : 0
    }

    override var intrinsicContentSize: NSSize {
        var size = computeLayout().total
        size.height += reservedSearchHeight
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

        // List occupies the region below the reserved search strip; center it
        // there so the layout matches the non-search case when inactive.
        let listAreaHeight = bounds.height - reservedSearchHeight
        let listOrigin = NSPoint(
            x: (bounds.width - info.listSize.width) / 2,
            y: (listAreaHeight - info.listSize.height) / 2
        )
        listContainer.frame = NSRect(origin: listOrigin, size: info.listSize)
        noResultsLabel.frame = NSRect(x: 0, y: 0, width: bounds.width, height: listAreaHeight)

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

    private func computeLayout() -> ListLayout {
        if let cachedLayout { return cachedLayout }
        let layout: ListLayout
        switch metrics.layoutMode {
        case .list:
            layout = computeListLayout()
        case .gridView:
            layout = computeIconDockLayout()
        }
        cachedLayout = layout
        return layout
    }

    /// Resolves the screen the switcher should size itself for. `window?.screen`
    /// reflects where the panel was actually placed (set by `SwitcherPanel.present`),
    /// so layout bounds and presentation position stay on the same display when
    /// the panel is shown under the cursor on an external monitor. `NSScreen.main`
    /// would otherwise leak the keyboard-focus monitor into layout math, picking
    /// the wrong DPI / visible area when those don't match.
    private func layoutScreenFrame() -> NSRect {
        let screen = window?.screen ?? SwitcherPanel.preferredScreen()
        return screen.visibleFrame
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

        // Each tile occupies (tile + gap), final tile has no trailing gap.
        let perTileStride = tile + gap
        let tilesPerRow = max(1, Int(floor((maxListWidth + gap) / perTileStride)))
        // User cap (0 = automatic, width-driven).
        let userCap = Preferences.shared.gridMaxColumns
        let cols = userCap > 0 ? min(count, tilesPerRow, userCap) : min(count, tilesPerRow)
        let rowsCount = max(1, Int(ceil(Double(count) / Double(cols))))

        // Tile stacks: letter strip (top) + icon + text labels (bottom).
        let itemH = letterArea + tile + labelArea
        let listWidth = CGFloat(cols) * tile + CGFloat(max(0, cols - 1)) * gap
        let listHeight = CGFloat(rowsCount) * itemH + CGFloat(max(0, rowsCount - 1)) * gap

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
}

/// Display-only search bar shown at the top of the panel in fuzzy-search mode.
/// Keystrokes are captured by the global event tap (not a real text field), so
/// this view only renders the current query text.
@MainActor
private final class SwitcherSearchBarView: NSView {
    private let icon = NSImageView()
    private let field = NSTextField(labelWithString: "")
    private let placeholder = "Type to filter apps & windows…"

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
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            field.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
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
