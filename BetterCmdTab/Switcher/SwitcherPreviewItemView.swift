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
    private let badgePill = NSView()
    private let badgeLabel = NSTextField(labelWithString: "")

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

        // Count badge — sits beside the title (never over the thumbnail).
        badgePill.wantsLayer = true
        badgePill.layer?.cornerCurve = .continuous
        badgePill.layer?.backgroundColor = NSColor.systemRed.cgColor
        badgePill.isHidden = true
        addSubview(badgePill)

        badgeLabel.alignment = .center
        badgeLabel.lineBreakMode = .byClipping
        badgeLabel.maximumNumberOfLines = 1
        badgeLabel.usesSingleLineMode = true
        badgeLabel.textColor = .white
        badgeLabel.drawsBackground = false
        badgeLabel.isBezeled = false
        badgeLabel.isEditable = false
        badgeLabel.isSelectable = false
        badgePill.addSubview(badgeLabel)

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

    /// Horizontal padding a borderless NSTextFieldCell reserves around its text,
    /// beyond the raw glyph bounding box returned by `size(withAttributes:)`. Near
    /// constant (~4–5pt) across font sizes; added to the measured title width so a
    /// title that fits isn't truncated to an ellipsis by the cell's own inset.
    private static let labelCellInset: CGFloat = 5

    func prepareForIdle() {
        // Release the thumbnail and app-icon retains so WindowThumbnailCache /
        // IconCache can evict them; all are re-set by `configure` on reuse.
        // Reset windowID to 0 so a late `setThumbnail` callback can't paint this
        // pooled tile after it's been parked.
        imageView.image = nil
        iconView.image = nil
        placeholderIcon = nil
        windowID = 0
    }

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
        // Browser tabs always show their tab title (the only thing distinguishing
        // sibling tabs). Otherwise the title is gated by "Show window title". When
        // app names are hidden, use windowTitleText so a windowless/launch row
        // never re-surfaces the app name as its title.
        let previewTitle = row.titleSlot(showAppNames: Preferences.shared.showApplicationNames)
        nameLabel.stringValue = (Preferences.shared.showWindowTitleLabel || row.browserTab != nil) ? previewTitle : ""

        // Dock/notification count badge — shown beside the title, never over the
        // thumbnail. Suppressed for placeholder/dialog rows and for browser-tab
        // rows (the count is per-app, so it would repeat identically on every tab).
        let badge = (row.isPlaceholder || isDialog || row.browserTab != nil)
            ? nil
            : DockBadgeReader.shared.badge(forBundleID: row.bundleIdentifier)
        badgeLabel.stringValue = badge ?? ""
        badgePill.isHidden = (badge == nil)

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
        // The selected title brightens to `labelColor`; bolding it is optional so
        // users who dislike the on-select width wobble keep a steady weight (#72).
        let bold = isSelected && Preferences.shared.boldSelectedLabel
        nameLabel.font = NSFont.systemFont(
            ofSize: metrics.previewNameFontSize,
            weight: bold ? .semibold : .medium
        )
    }

    /// Leading edge of the tight icon+title group inside a tile of width
    /// `tileWidth`, for the chosen alignment (#72). Leading hugs the left edge,
    /// trailing the right, centre splits the slack. Clamped to ≥ 0 so an
    /// over-wide group never starts off-tile.
    static func titleGroupOriginX(alignment: PreviewTitleAlignment, groupWidth: CGFloat, tileWidth: CGFloat) -> CGFloat {
        let slack = max(0, tileWidth - groupWidth)
        switch alignment {
        case .leading: return 0
        case .center: return round(slack / 2)
        case .trailing: return slack
        }
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

        // Label row: small app icon + window title (+ optional count badge),
        // centered as a group. When both "show app names" and "show window title"
        // are off, previewLabelArea is 0 and the band is omitted entirely.
        let labelAreaH = m.previewLabelArea
        if labelAreaH == 0 {
            // No label band: thumbnail-only tile. Collapse the icon/title frames
            // and hide the badge pill outright — with no title to sit beside, a
            // stale badgeLabel frame would otherwise leak count digits into the
            // tile corner (badgeLabel is a child of badgePill, so hiding the pill
            // hides it too).
            iconView.frame = .zero
            nameLabel.frame = .zero
            badgePill.frame = .zero
            badgePill.isHidden = true
        } else {
            let iconSize = min(m.previewIconSize, labelAreaH)

            // Count badge sits to the right of the title — a small circle, noticeably
            // smaller than the app icon (a notification badge, not an icon-sized
            // disc). The count font shrinks to fit rather than the badge widening into
            // a pill. Reserve its slot so icon + title + badge stay centered together.
            let badgeVisible = !badgePill.isHidden
            let badgeSize = max(9, round(iconSize * 0.62))
            let badgeGap: CGFloat = badgeVisible ? 4 : 0
            let badgeSlot = badgeVisible ? badgeGap + badgeSize : 0

            // Measure the title width with a string-metrics query rather than
            // `nameLabel.sizeToFit()`, which lays out and resizes the whole
            // NSTextField just to read a width that's immediately clamped below.
            // `nameLabel.frame` is set explicitly at the end of this method, so the
            // skipped sizeToFit mutates nothing used.
            //
            // The glyph bounding box is NOT what the field needs to draw, though:
            // the borderless NSTextFieldCell adds a small fixed horizontal inset
            // (~4–5pt total, independent of font size). Sizing the frame to the bare
            // glyph width left the cell ~4pt short and truncated a fitting title to an
            // ellipsis ("ChatGPT" → "ChatG…"). Add the inset back so titles that fit
            // aren't clipped; the outer `min` still clamps to the tile's free width.
            //
            // Measure the heaviest weight the title can ever take (.semibold), never
            // the current one. A selected tile renders semibold via `applySelection`
            // WITHOUT a relayout, and the bold-on-select pref can flip while the panel
            // is open — so keying the measure off the live weight or pref risks a frame
            // sized for .medium clipping a later semibold render. The bold width fits
            // the medium render too (~1pt slack); the outer `min` still clamps to the
            // tile's free width. Constant weight also keeps this off the pref read path.
            let measureFont = NSFont.systemFont(ofSize: m.previewNameFontSize, weight: .semibold)
            let textW = (nameLabel.stringValue as NSString).size(withAttributes: [.font: measureFont]).width
            let nameW = min(ceil(textW) + Self.labelCellInset, w - iconSize - 6 - badgeSlot)
            let groupW = iconSize + 4 + nameW + badgeSlot
            let startX = Self.titleGroupOriginX(
                alignment: Preferences.shared.previewTitleAlignment,
                groupWidth: groupW,
                tileWidth: w
            )
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
            if badgeVisible {
                // Fit the count inside the icon-sized circle: start proportional to
                // the badge, then step the font down until a 1–3 digit count fits.
                var badgeFont = NSFont.systemFont(ofSize: max(7, round(badgeSize * 0.7)), weight: .semibold)
                let avail = badgeSize - 3
                var tw = (badgeLabel.stringValue as NSString).size(withAttributes: [.font: badgeFont]).width
                while tw > avail && badgeFont.pointSize > 7 {
                    badgeFont = NSFont.systemFont(ofSize: badgeFont.pointSize - 1, weight: .semibold)
                    tw = (badgeLabel.stringValue as NSString).size(withAttributes: [.font: badgeFont]).width
                }
                badgeLabel.font = badgeFont
                let bx = nameLabel.frame.maxX + badgeGap
                let by = round(rowMidY - badgeSize / 2)
                badgePill.frame = NSRect(x: bx, y: by, width: badgeSize, height: badgeSize)
                badgePill.layer?.cornerRadius = badgeSize / 2
                let lineH = ceil(badgeFont.ascender - badgeFont.descender)
                badgeLabel.frame = NSRect(x: 0, y: round((badgeSize - lineH) / 2), width: badgeSize, height: lineH)
            }
        }

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
