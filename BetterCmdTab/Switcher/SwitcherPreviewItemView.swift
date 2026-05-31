import AppKit

/// alt-tab–style preview tile: a live window thumbnail with the app icon and
/// window title beneath it, plus the type-to-jump letter strip on top. The
/// thumbnail is captured asynchronously by `WindowThumbnailCache`; until it
/// lands (or when Screen Recording is unavailable) the app icon stands in.
@MainActor
final class SwitcherPreviewItemView: NSView, SwitcherItemViewProtocol {
    private let selectionBackdrop = NSView()
    private let thumbContainer = NSView()
    private let imageView = NSImageView()
    private let letterLabel = NSTextField(labelWithString: "")
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")

    private var metrics: SwitcherMetrics = .baseline
    private var accent: NSColor = .controlAccentColor
    private var accentKey: String = NSColor.controlAccentColor.description

    /// CGWindowID of the row this tile shows, so a late thumbnail capture can be
    /// matched back to the right tile. 0 for rows without a real window.
    private(set) var windowID: CGWindowID = 0
    /// The app icon shown while no thumbnail is available — kept so a thumbnail
    /// arriving via `setThumbnail` can be applied without re-reading the row.
    private var placeholderIcon: NSImage?

    var isSelected: Bool = false {
        didSet {
            guard oldValue != isSelected else { return }
            applySelection()
        }
    }

    private let actionBar = HoverActionBar(frame: .zero)
    private var actionsAvailable = false
    var isHovered: Bool = false {
        didSet {
            guard oldValue != isHovered else { return }
            updateHoverBar()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        actionBar.isHidden = true

        selectionBackdrop.wantsLayer = true
        selectionBackdrop.layer?.cornerCurve = .continuous
        selectionBackdrop.layer?.borderWidth = 1.5
        selectionBackdrop.isHidden = true
        addSubview(selectionBackdrop)

        thumbContainer.wantsLayer = true
        thumbContainer.layer?.cornerCurve = .continuous
        thumbContainer.layer?.masksToBounds = true
        addSubview(thumbContainer)

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.imageFrameStyle = .none
        thumbContainer.addSubview(imageView)

        letterLabel.alignment = .center
        letterLabel.lineBreakMode = .byClipping
        letterLabel.maximumNumberOfLines = 1
        letterLabel.usesSingleLineMode = true
        letterLabel.drawsBackground = false
        letterLabel.isBezeled = false
        letterLabel.isEditable = false
        letterLabel.isSelectable = false
        addSubview(letterLabel)

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.imageFrameStyle = .none
        addSubview(iconView)

        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1
        nameLabel.usesSingleLineMode = true
        nameLabel.textColor = .secondaryLabelColor
        nameLabel.drawsBackground = false
        nameLabel.isBezeled = false
        nameLabel.isEditable = false
        nameLabel.isSelectable = false
        addSubview(nameLabel)

        // Last, so the hover bar floats above the thumbnail.
        addSubview(actionBar)

        updateThumbBackground()
        updateSelectionAppearance()
        applyMetrics(metrics)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSelectionAppearance()
        updateThumbBackground()
    }

    /// Show the hover bar only over a hovered, actionable row when the feature
    /// (and at least one button) is enabled.
    private func updateHoverBar() {
        let show = isHovered
            && Preferences.shared.hoverActionsEnabled
            && actionsAvailable
            && actionBar.hasAnyEnabledButton
        if !show { actionBar.setHotAction(nil) }
        if actionBar.isHidden == !show { return }
        actionBar.isHidden = !show
        needsLayout = true
    }

    func hoverAction(atWindowPoint point: NSPoint) -> RowAction? {
        guard !actionBar.isHidden else { return nil }
        return actionBar.action(atWindowPoint: point)
    }

    func setHotDot(atWindowPoint point: NSPoint?) {
        guard !actionBar.isHidden else { actionBar.setHotAction(nil); return }
        actionBar.setHotAction(point.flatMap { actionBar.action(atWindowPoint: $0) })
    }

    private func updateSelectionAppearance() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let fill: NSColor
        let border: NSColor
        if isDark {
            fill = NSColor.white.withAlphaComponent(0.14)
            border = NSColor.white.withAlphaComponent(0.50)
        } else {
            fill = NSColor.black.withAlphaComponent(0.10)
            border = NSColor.black.withAlphaComponent(0.55)
        }
        selectionBackdrop.layer?.backgroundColor = fill.cgColor
        selectionBackdrop.layer?.borderColor = border.cgColor
    }

    private func updateThumbBackground() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let base = isDark ? NSColor.white : NSColor.black
        thumbContainer.layer?.backgroundColor = base.withAlphaComponent(isDark ? 0.08 : 0.05).cgColor
    }

    private var currentLabel: String = ""
    private var currentPrefixLength: Int = 0

    func configure(with row: SwitcherRow, label: String, prefixLength: Int, selected: Bool, metrics: SwitcherMetrics, accent: NSColor) {
        if metrics != self.metrics {
            applyMetrics(metrics)
        }
        if self.accent != accent {
            self.accent = accent
            accentKey = accent.description
        }
        currentLabel = label
        currentPrefixLength = prefixLength
        renderLetter()

        let isDialog = row.isSystemDialog
        let icon = isDialog ? SystemSettingsIcon.image : IconCache.icon(for: row)
        placeholderIcon = icon
        iconView.image = icon
        // "Window title under icon" preference: when off, keep the app icon but
        // drop the title text so the tile is just the thumbnail + icon. Browser
        // tabs always show their title — it's the only thing distinguishing one
        // tab tile from another (they share the parent window).
        nameLabel.stringValue = (Preferences.shared.showWindowTitleLabel || row.browserTab != nil) ? row.displayTitle : ""

        // Resolve the window id and ask for (or reuse) its live thumbnail. Rows
        // without a real window (windowless apps, launchables, recents) keep the
        // app icon as their preview.
        //
        // Browser tabs aren't separate windows: every tab of a browser window
        // shares the parent window's id, and a window screenshot only ever shows
        // the *active* tab — so requesting it would paint every tab tile with the
        // same, misleading thumbnail. Force the app-icon placeholder (id 0)
        // instead; the distinct tab title under the icon identifies each tab.
        windowID = (row.browserTab == nil) ? (row.window.map { PrivateAPI.cgWindowId(of: $0) } ?? 0) : 0
        if windowID != 0 {
            let scale = window?.backingScaleFactor ?? 2
            WindowThumbnailCache.shared.request(wid: windowID, pixelHeight: metrics.previewThumbHeight * scale)
            imageView.image = WindowThumbnailCache.shared.image(for: windowID) ?? icon
        } else {
            imageView.image = icon
        }
        applyImageScaling()

        // Hover action buttons apply to a real window of a running app.
        actionsAvailable = !isDialog && row.app != nil && row.window != nil
        actionBar.setScale(metrics.scale)
        actionBar.applyEnabledButtons()
        updateHoverBar()

        if isSelected == selected {
            applySelection()
        } else {
            isSelected = selected
        }
        needsLayout = true
    }

    /// Swap in a freshly captured thumbnail (called from the view's `onReady`
    /// hook). Ignores stale callbacks for a tile that has since been reused for
    /// a different window.
    func setThumbnail(_ image: NSImage?, for wid: CGWindowID) {
        guard wid == windowID, wid != 0 else { return }
        imageView.image = image ?? placeholderIcon
        applyImageScaling()
    }

    /// A real capture fills the tile (proportional, letterboxed); the app-icon
    /// placeholder stays small and centered so it doesn't look like a blurry
    /// full-bleed preview.
    private func applyImageScaling() {
        let hasThumb = (windowID != 0) && (WindowThumbnailCache.shared.image(for: windowID) != nil)
        imageView.imageScaling = hasThumb ? .scaleProportionallyUpOrDown : .scaleProportionallyDown
    }

    private func applyMetrics(_ metrics: SwitcherMetrics) {
        self.metrics = metrics
        letterLabel.font = NSFont.monospacedSystemFont(ofSize: metrics.tileLetterFontSize, weight: .bold)
        nameLabel.font = NSFont.systemFont(ofSize: metrics.previewNameFontSize, weight: .medium)
        thumbContainer.layer?.cornerRadius = metrics.previewThumbCornerRadius
        selectionBackdrop.layer?.cornerRadius = metrics.previewSelectionCornerRadius
        needsLayout = true
    }

    private func applySelection() {
        selectionBackdrop.isHidden = !isSelected
        nameLabel.textColor = isSelected ? .labelColor : .secondaryLabelColor
        nameLabel.font = NSFont.systemFont(
            ofSize: metrics.previewNameFontSize,
            weight: isSelected ? .semibold : .medium
        )
    }

    private func renderLetter() {
        let labelStr = currentLabel.uppercased()
        guard !labelStr.isEmpty else {
            letterLabel.attributedStringValue = NSAttributedString(string: "")
            return
        }
        let font = NSFont.monospacedSystemFont(ofSize: metrics.tileLetterFontSize, weight: .bold)
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let attr = NSMutableAttributedString(string: labelStr, attributes: [
            .font: font,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: para,
        ])
        let prefixLen = min(currentPrefixLength, labelStr.count)
        if prefixLen > 0 {
            attr.addAttribute(.foregroundColor, value: accent, range: NSRange(location: 0, length: prefixLen))
        }
        letterLabel.attributedStringValue = attr
    }

    override func layout() {
        super.layout()
        let m = metrics
        let w = bounds.width
        let letterArea = m.previewLetterArea
        let thumbH = m.previewThumbHeight

        // Top→bottom: letter strip, thumbnail, label row.
        let thumbRect = NSRect(x: 0, y: bounds.height - letterArea - thumbH, width: w, height: thumbH)
        thumbContainer.frame = thumbRect
        imageView.frame = thumbContainer.bounds
        selectionBackdrop.frame = thumbRect.insetBy(dx: -m.previewSelectionInset, dy: -m.previewSelectionInset)

        // Letter centered in the top strip.
        if letterArea > 0 {
            letterLabel.sizeToFit()
            let lw = ceil(letterLabel.frame.width)
            let lh = ceil(letterLabel.frame.height)
            letterLabel.frame = NSRect(
                x: round((w - lw) / 2),
                y: round(bounds.height - letterArea / 2 - lh / 2),
                width: lw,
                height: lh
            )
        } else {
            letterLabel.frame = .zero
        }

        // Label row: small app icon + window title, centered as a group.
        let labelAreaH = m.previewLabelArea
        let iconSize = min(m.previewIconSize, labelAreaH)
        // Measure the title width with a string-metrics query rather than
        // `nameLabel.sizeToFit()`, which lays out and resizes the whole
        // NSTextField just to read a width that's immediately clamped below.
        // `nameLabel` is a plain single-line truncating field, so the glyph
        // bounding box is equivalent; `nameLabel.frame` is set explicitly at
        // the end of this method, so the skipped sizeToFit mutates nothing used.
        let measureFont = nameLabel.font ?? NSFont.systemFont(ofSize: m.previewNameFontSize, weight: .medium)
        let textW = (nameLabel.stringValue as NSString).size(withAttributes: [.font: measureFont]).width
        let nameW = min(ceil(textW), w - iconSize - 6)
        let groupW = iconSize + 4 + nameW
        let startX = max(0, round((w - groupW) / 2))
        let rowMidY = labelAreaH / 2
        iconView.frame = NSRect(
            x: startX,
            y: round(rowMidY - iconSize / 2),
            width: iconSize,
            height: iconSize
        )
        let nameH = ceil(nameLabel.font?.pointSize ?? m.previewNameFontSize) + 4
        nameLabel.frame = NSRect(
            x: iconView.frame.maxX + 4,
            y: round(rowMidY - nameH / 2),
            width: max(0, nameW),
            height: nameH
        )

        if !actionBar.isHidden {
            // Top-left corner of the thumbnail, inset slightly. Matches the
            // macOS window-chrome convention (traffic lights live on the
            // left side of every Mac window).
            let size = actionBar.contentSize
            actionBar.frame = NSRect(
                x: round(thumbRect.minX + 4),
                y: round(thumbRect.maxY - size.height - 4),
                width: size.width,
                height: size.height
            )
        }
    }
}
