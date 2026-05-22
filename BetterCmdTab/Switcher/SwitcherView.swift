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
    private var itemViews: [SwitcherItemView] = []
    private var rows: [SwitcherRow] = []
    private(set) var labels: [String] = []
    private var selectedIndex: Int = 0
    private var cachedLayout: ListLayout?
    private var trackingArea: NSTrackingArea?

    private var metrics: SwitcherMetrics = .baseline
    let maxScreenHeightFraction: CGFloat = 0.85

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
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    private var highlightPrefix: String = ""

    func configure(rows: [SwitcherRow], labels: [String], selectedIndex: Int, metrics: SwitcherMetrics, highlightPrefix: String = "") {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.rows = rows
        self.labels = labels
        self.highlightPrefix = highlightPrefix
        self.selectedIndex = selectedIndex
        if metrics != self.metrics {
            self.metrics = metrics
            updateBackdropCornerRadius(metrics.cornerRadius)
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

    private func rebuildItemPool() {
        while itemViews.count < rows.count {
            let view = SwitcherItemView(frame: .zero)
            listContainer.addSubview(view)
            itemViews.append(view)
        }
        while itemViews.count > rows.count {
            let v = itemViews.removeLast()
            v.removeFromSuperview()
        }
        for (i, row) in rows.enumerated() {
            let label = i < labels.count ? labels[i] : ""
            let highlightLen = (!highlightPrefix.isEmpty && label.hasPrefix(highlightPrefix)) ? highlightPrefix.count : 0
            itemViews[i].configure(
                with: row,
                label: label,
                prefixLength: highlightLen,
                selected: i == selectedIndex,
                metrics: metrics
            )
            itemViews[i].isHidden = false
        }
    }

    override var intrinsicContentSize: NSSize {
        computeLayout().total
    }

    override func layout() {
        super.layout()
        let info = computeLayout()
        glassBackdrop.frame = bounds

        let contentSize = NSSize(width: bounds.width, height: bounds.height)
        contentContainer.frame = NSRect(origin: .zero, size: contentSize)

        let listOrigin = NSPoint(
            x: (bounds.width - info.listSize.width) / 2,
            y: (bounds.height - info.listSize.height) / 2
        )
        listContainer.frame = NSRect(origin: listOrigin, size: info.listSize)

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

        let rowH = metrics.rowHeight
        let rowW = metrics.rowWidth
        let outerPadding = metrics.outerPadding
        let count = max(rows.count, 1)
        let screenH = NSScreen.main?.visibleFrame.height ?? 900
        let maxListHeight = screenH * maxScreenHeightFraction - outerPadding * 2

        let rowsPerCol = max(1, Int(floor(maxListHeight / rowH)))
        let cols = max(1, Int(ceil(Double(count) / Double(rowsPerCol))))
        let effectiveRowsPerCol = cols == 1 ? count : rowsPerCol

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

        let result = ListLayout(
            frames: frames,
            listSize: NSSize(width: listWidth, height: listHeight),
            total: total,
            rowsPerCol: effectiveRowsPerCol,
            cols: cols
        )
        cachedLayout = result
        return result
    }
}
