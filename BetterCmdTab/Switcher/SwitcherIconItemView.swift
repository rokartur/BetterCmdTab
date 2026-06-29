import AppKit

@MainActor
protocol SwitcherItemViewProtocol: NSView {
    var isSelected: Bool { get set }
    /// True while the mouse is directly over this row — drives the hover action
    /// buttons (independent of keyboard selection).
    var isHovered: Bool { get set }
    /// The hover-action this row's button bar exposes at `point` (window coords),
    /// or nil. `SwitcherView` calls this on mouseDown to route clicks (the dots
    /// can't receive events themselves through the glass-hosted subtree).
    func hoverAction(atWindowPoint point: NSPoint) -> RowAction?
    /// Highlight the button under `point` (window coords); nil clears it.
    func setHotDot(atWindowPoint point: NSPoint?)
    func configure(with row: SwitcherRow, label: String, prefixLength: Int, selected: Bool, metrics: SwitcherMetrics, accent: NSColor, effective: EffectiveSettings)
    /// Drop per-tile image retains (app icon, window thumbnail) so the shared
    /// `IconCache` / `WindowThumbnailCache` can evict them, without discarding the
    /// view itself. Called when the panel dismisses so the pooled view stays
    /// allocated for the next reveal (no from-scratch rebuild on the hot path) yet
    /// holds no images while idle. `configure` repopulates them on reuse.
    func prepareForIdle()
}

@MainActor
final class SwitcherIconItemView: NSView, SwitcherItemViewProtocol {
    private let selectionBackdrop = NSView()
    private let imageView = NSImageView()
    private let letterLabel = NSTextField(labelWithString: "")
    private let badgePill = NSView()
    private let badgeLabel = NSTextField(labelWithString: "")
    private let nameLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")

    private var metrics: SwitcherMetrics = .baseline
    private var accent: NSColor = .controlAccentColor
    /// Resolved appearance for the current reveal (#74); set in `configure`, read
    /// by render helpers (`applySelection`) that run outside it.
    private var effective: EffectiveSettings = .defaults
    /// Cheap stable token for the current accent, recomputed only when the
    /// accent changes — used as a memo-cache key instead of re-deriving
    /// `accent.description` on every letter/symbol render.
    private var accentKey: String = NSColor.controlAccentColor.description

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

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.imageFrameStyle = .none
        addSubview(imageView)

        // Jump letter lives in a strip above the icon (never over it), as plain
        // text — no heavy pill — so the tile reads cleanly.
        letterLabel.alignment = .center
        letterLabel.lineBreakMode = .byClipping
        letterLabel.maximumNumberOfLines = 1
        letterLabel.usesSingleLineMode = true
        letterLabel.drawsBackground = false
        letterLabel.isBezeled = false
        letterLabel.isEditable = false
        letterLabel.isSelectable = false
        addSubview(letterLabel)

        badgePill.wantsLayer = true
        badgePill.layer?.cornerCurve = .continuous
        badgePill.layer?.backgroundColor = NSColor.systemRed.cgColor
        // Subtle shadow lifts the badge off the icon like a native Dock badge.
        badgePill.layer?.shadowColor = NSColor.black.cgColor
        badgePill.layer?.shadowOpacity = 0.3
        badgePill.layer?.shadowRadius = 1.5
        badgePill.layer?.shadowOffset = CGSize(width: 0, height: -0.5)
        badgePill.layer?.masksToBounds = false
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

        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1
        nameLabel.usesSingleLineMode = true
        nameLabel.textColor = .labelColor
        nameLabel.drawsBackground = false
        nameLabel.isBezeled = false
        nameLabel.isEditable = false
        nameLabel.isSelectable = false
        addSubview(nameLabel)

        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.usesSingleLineMode = true
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.drawsBackground = false
        titleLabel.isBezeled = false
        titleLabel.isEditable = false
        titleLabel.isSelectable = false
        titleLabel.cell?.usesSingleLineMode = true
        addSubview(titleLabel)

        // Last, so the hover bar floats above the icon and labels.
        addSubview(actionBar)

        updateSelectionAppearance()
        applyMetrics(metrics)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSelectionAppearance()
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

    private var currentLabel: String = ""
    private var currentPrefixLength: Int = 0

    func prepareForIdle() {
        imageView.image = nil
    }

    func configure(with row: SwitcherRow, label: String, prefixLength: Int, selected: Bool, metrics: SwitcherMetrics, accent: NSColor, effective: EffectiveSettings) {
        self.effective = effective
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

        // System permission/dialog rows (e.g. the Accessibility alert) show
        // just the window title with the System Settings icon — no status
        // glyphs — since their host process name/icon are meaningless.
        let isDialog = row.isSystemDialog
        let showNames = effective.showApplicationNames
        let showTitles = effective.showWindowTitleLabel
        // Both labels hidden → bare icon-only tile: the metrics drop the label area to
        // zero, so the name/title lines and the status glyphs are all dropped.
        let bothHidden = !showNames && !showTitles

        // Status glyphs ride with the secondary text instead of crowding the icon.
        // Audio is orthogonal, so it shows alongside the window-state glyph (e.g. a
        // windowless app playing sound gets both speaker + no-window). Launch/reopen
        // rows return their single cue, never a stacked no-window glyph.
        let indicators = (isDialog || bothHidden) ? [] : Self.indicators(for: row)

        // The label area stacks the app name over a secondary line (glyphs + window
        // title) only when BOTH labels are shown. Hiding one collapses the tile to a
        // single compact line carrying the surviving label + glyphs; hiding both drops
        // the label area entirely. Either way the tile shrinks by the freed height.
        let secondaryLine: String
        if bothHidden {
            // Icon-only: no name, no title, no glyphs.
            nameLabel.stringValue = ""
            nameLabel.isHidden = true
            secondaryLine = ""
        } else if showNames && showTitles {
            // Two lines: app name on top, glyphs + window title below.
            let nameText = isDialog
                ? (row.windowTitle.isEmpty ? row.appName : row.windowTitle)
                : row.appName
            nameLabel.stringValue = nameText
            nameLabel.isHidden = nameText.isEmpty
            secondaryLine = isDialog ? "" : Self.secondaryText(for: row, showTitle: true)
        } else {
            // One compact line: drop the app-name line. The surviving label is the
            // window title when titles are shown, otherwise the app name; dialog rows
            // keep their own title.
            nameLabel.stringValue = ""
            nameLabel.isHidden = true
            if isDialog {
                secondaryLine = row.windowTitle.isEmpty ? row.appName : row.windowTitle
            } else if showTitles {
                // Names hidden, titles shown: ride the window title on the single
                // line. Use `windowTitleText` for ordinary windows so a blank AX
                // title falls back to the app name (matching List/Previews — a
                // blank-title PWA/Electron tile must not render textless), but keep
                // the Launch/Reopen cues for those row kinds.
                secondaryLine = (row.isLaunchable || row.isRecentlyClosed)
                    ? Self.secondaryText(for: row, showTitle: true)
                    : row.windowTitleText
            } else {
                secondaryLine = row.appName
            }
        }

        if indicators.isEmpty, secondaryLine.isEmpty {
            titleLabel.attributedStringValue = NSAttributedString(string: "")
            titleLabel.isHidden = true
        } else {
            titleLabel.attributedStringValue = makeTitle(indicators: indicators, text: secondaryLine)
            titleLabel.isHidden = false
        }

        imageView.image = isDialog ? SystemSettingsIcon.image : IconCache.icon(for: row)

        // Dock badge. Empty map when the feature is off.
        let badge = (row.isPlaceholder || isDialog) ? nil : DockBadgeReader.shared.badge(forBundleID: row.bundleIdentifier)
        if let badge {
            badgeLabel.stringValue = badge
            badgePill.isHidden = false
        } else {
            badgePill.isHidden = true
        }

        // Hover action buttons apply to a real window of a running app.
        actionsAvailable = !isDialog && row.app != nil && row.window != nil
        actionBar.setScale(metrics.scale)
        actionBar.applyEnabledButtons()
        updateHoverBar()

        // Run `applySelection` exactly once: the `isSelected` setter already does
        // so via `didSet` when the value flips, so call it explicitly only when
        // the value is unchanged but other inputs still need re-applying.
        if isSelected == selected {
            applySelection()
        } else {
            isSelected = selected
        }
        needsLayout = true
    }

    /// Status glyphs for a row, in display order. Running rows get an optional
    /// audio glyph (orthogonal) followed by at most one window-state glyph.
    /// Launch/reopen rows return their single cue, so they never stack a
    /// redundant no-window glyph on top.
    private static func indicators(for row: SwitcherRow) -> [SwitcherIndicator] {
        if row.isLaunchable { return [.launch] }
        if row.isRecentlyClosed { return [.reopen] }
        if row.isPlaceholder { return [] }
        var result: [SwitcherIndicator] = []
        if let pid = row.pid, AudioActivityMonitor.shared.isPlaying(pid) { result.append(.audio) }
        if row.isHidden { result.append(.hidden) }
        else if row.isMinimized { result.append(.minimized) }
        else if row.window == nil && !row.suppressNoWindowGlyph { result.append(.noWindow) }
        else if row.isFullscreen { result.append(.fullscreen) }
        return result
    }

    /// `showTitle == false` blanks the window-title text (the "Window title under
    /// icon" preference) while leaving launch/reopen cues — which aren't window
    /// titles — intact so those rows still read clearly.
    private static func secondaryText(for row: SwitcherRow, showTitle: Bool) -> String {
        if row.isLaunchable { return String(localized: "Launch") }
        if row.isRecentlyClosed { return (showTitle && !row.windowTitle.isEmpty) ? row.windowTitle : String(localized: "Reopen") }
        if row.isPlaceholder || row.window == nil { return "" }
        return showTitle ? row.windowTitle : ""
    }

    /// Builds the secondary line: leading status glyphs (each tinted to its
    /// semantic color) followed by the text, centered as one group.
    private func makeTitle(indicators: [SwitcherIndicator], text: String) -> NSAttributedString {
        let key = TitleKey(
            indicators: indicators,
            text: text,
            fontSize: metrics.tileTitleFontSize,
            accentKey: accentKey
        )
        return Self.titleCache.value(for: key) {
            self.buildTitle(indicators: indicators, text: text)
        }
    }

    private func buildTitle(indicators: [SwitcherIndicator], text: String) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: metrics.tileTitleFontSize, weight: .regular)
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byTruncatingTail

        let result = NSMutableAttributedString()
        for (i, indicator) in indicators.enumerated() {
            if i > 0 { result.append(NSAttributedString(string: "\u{2009}")) } // thin space between glyphs
            if let image = tintedSymbol(indicator, pointSize: font.pointSize) {
                let attachment = NSTextAttachment()
                attachment.image = image
                attachment.bounds = CGRect(
                    x: 0,
                    y: (font.capHeight - image.size.height) / 2,
                    width: image.size.width,
                    height: image.size.height
                )
                result.append(NSAttributedString(attachment: attachment))
            }
        }
        if !text.isEmpty {
            if !indicators.isEmpty { result.append(NSAttributedString(string: " ")) }
            result.append(NSAttributedString(string: text))
        }
        result.addAttributes(
            [.font: font, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: para],
            range: NSRange(location: 0, length: result.length)
        )
        return result
    }

    private func applyMetrics(_ metrics: SwitcherMetrics) {
        self.metrics = metrics
        letterLabel.font = NSFont.monospacedSystemFont(ofSize: metrics.tileLetterFontSize, weight: .bold)
        badgeLabel.font = NSFont.systemFont(ofSize: metrics.tileLetterFontSize, weight: .bold)
        nameLabel.font = NSFont.systemFont(ofSize: metrics.tileNameFontSize, weight: .medium)
        titleLabel.font = NSFont.systemFont(ofSize: metrics.tileTitleFontSize, weight: .regular)
        selectionBackdrop.layer?.cornerRadius = metrics.tileSelectionCornerRadius
        needsLayout = true
    }

    private func applySelection() {
        selectionBackdrop.isHidden = !isSelected
        nameLabel.textColor = isSelected ? .labelColor : .secondaryLabelColor
        // Bolding the selected name is optional (#72) — off keeps a steady weight
        // so the label doesn't grow/shrink as selection moves; it still brightens.
        let bold = isSelected && effective.boldSelectedLabel
        nameLabel.font = NSFont.systemFont(
            ofSize: metrics.tileNameFontSize,
            weight: bold ? .semibold : .medium
        )
        // The jump letter doesn't depend on selection, so it is rendered once in
        // `configure` rather than re-built on every selection move.
    }

    // MARK: - Memo caches

    private struct LetterKey: Hashable {
        let label: String
        let prefixLen: Int
        let fontSize: CGFloat
        let accentKey: String
    }
    private static var letterCache = MemoCache<LetterKey, NSAttributedString>(capacity: 256)

    private struct SymbolKey: Hashable {
        let indicator: SwitcherIndicator
        let pointSize: CGFloat
        let accentKey: String
    }
    private static var symbolCache = MemoCache<SymbolKey, NSImage?>(capacity: 128)

    private struct TitleKey: Hashable {
        let indicators: [SwitcherIndicator]
        let text: String
        let fontSize: CGFloat
        let accentKey: String
    }
    /// The fully assembled secondary line (tinted glyph attachments + text) is
    /// the same immutable string for any tile with the same inputs, so memoize
    /// it like `letterCache`/`symbolCache`. Otherwise `configure` rebuilds an
    /// NSMutableAttributedString + one NSTextAttachment per glyph for every tile
    /// on every reveal / reorder / search keystroke / badge repaint.
    private static var titleCache = MemoCache<TitleKey, NSAttributedString>(capacity: 256)

    /// Tinted status-glyph image for the secondary line, memoized: otherwise
    /// `withSymbolConfiguration` re-renders the SF Symbol on every `configure`,
    /// for every glyph on every tile.
    private func tintedSymbol(_ indicator: SwitcherIndicator, pointSize: CGFloat) -> NSImage? {
        let key = SymbolKey(indicator: indicator, pointSize: pointSize, accentKey: accentKey)
        let accentColor = accent
        return Self.symbolCache.value(for: key) {
            let color = indicator.tint(onAccentFill: false, accent: accentColor)
            let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
                .applying(.init(paletteColors: [color]))
            return indicator.makeImage()?.withSymbolConfiguration(cfg)
        }
    }

    private func renderLetter() {
        let labelStr = currentLabel.uppercased()
        guard !labelStr.isEmpty else {
            letterLabel.attributedStringValue = NSAttributedString(string: "")
            return
        }
        let key = LetterKey(
            label: labelStr,
            prefixLen: min(currentPrefixLength, labelStr.count),
            fontSize: metrics.tileLetterFontSize,
            accentKey: accentKey
        )
        let accentColor = accent
        letterLabel.attributedStringValue = Self.letterCache.value(for: key) {
            let font = NSFont.monospacedSystemFont(ofSize: key.fontSize, weight: .bold)
            let para = NSMutableParagraphStyle()
            para.alignment = .center
            let attr = NSMutableAttributedString(string: key.label, attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: para,
            ])
            if key.prefixLen > 0 {
                attr.addAttribute(.foregroundColor, value: accentColor, range: NSRange(location: 0, length: key.prefixLen))
            }
            return attr
        }
    }

    override func layout() {
        super.layout()
        let m = metrics
        let w = bounds.width
        let letterArea = m.tileLetterArea
        let tile = m.tileSize

        // Top→bottom: letter strip, icon, text labels.
        let iconArea = NSRect(x: (w - tile) / 2, y: bounds.height - letterArea - tile, width: tile, height: tile)
        selectionBackdrop.frame = iconArea.insetBy(dx: m.tileSelectionInset, dy: m.tileSelectionInset)

        let iconRect = NSRect(
            x: iconArea.midX - m.tileIconSize / 2,
            y: iconArea.midY - m.tileIconSize / 2,
            width: m.tileIconSize,
            height: m.tileIconSize
        )
        imageView.frame = iconRect

        // Letter centered in the top strip, above the icon.
        letterLabel.sizeToFit()
        let lw = ceil(letterLabel.frame.width)
        let lh = ceil(letterLabel.frame.height)
        letterLabel.frame = NSRect(
            x: round((w - lw) / 2),
            y: round(bounds.height - letterArea / 2 - lh / 2),
            width: lw,
            height: lh
        )
        // Hide the letter hint while the hover bar is showing — they share
        // the top strip and otherwise overlap.
        letterLabel.isHidden = !actionBar.isHidden

        // Dock badge: hug the icon's top-right corner with a hair of outward
        // float, like a native badge. The icon is inset within the tile so this
        // never clips.
        if !badgePill.isHidden {
            // Circle for 1–2 digits; widens into a fixed-height pill for 3+,
            // matching native Dock badges. Font is full-size (not shrunk).
            let height = m.tileLetterBadgeSize
            let font = NSFont.systemFont(ofSize: round(m.tileLetterFontSize * 0.9), weight: .regular)
            badgeLabel.font = font
            let size = BadgeText.size(for: badgeLabel.stringValue, font: font, height: height)
            let overflow = round(height * 0.1)
            badgePill.frame = NSRect(
                x: iconRect.maxX + overflow - size.width,
                y: iconRect.maxY + overflow - height,
                width: size.width,
                height: height
            )
            badgePill.layer?.cornerRadius = height / 2
            badgeLabel.frame = BadgeText.centeredTextFrame(width: size.width, height: height, font: font)
        }

        // Name + title in the bottom label area.
        let labelAreaH = m.tileLabelArea
        let nameH = ceil(nameLabel.font?.pointSize ?? m.tileNameFontSize) + 4
        let titleH = ceil(titleLabel.font?.pointSize ?? m.tileTitleFontSize) + 2
        if nameLabel.isHidden {
            // No app name (names hidden): the secondary line takes the top slot
            // so there's no empty gap between the icon and the text.
            titleLabel.frame = NSRect(x: 0, y: labelAreaH - titleH, width: w, height: titleH)
        } else {
            nameLabel.frame = NSRect(x: 0, y: labelAreaH - nameH, width: w, height: nameH)
            titleLabel.frame = NSRect(x: 0, y: labelAreaH - nameH - titleH, width: w, height: titleH)
        }

        if !actionBar.isHidden {
            // Constrain the bar to the tile width minus a small inset before
            // measuring — with every button enabled, the natural six-dot run
            // is wider than narrow grid tiles, which pushed the outer dots
            // past the hit-test bounds and made them unclickable.
            actionBar.fitWidth(tile - 8)
            let size = actionBar.contentSize
            // Center the bar on the letter strip, but clamp it inside the tile:
            // with letter hints off the strip is zero-height, and a centered bar
            // would straddle the tile's top edge — drawing over the row above
            // and losing clicks (SwitcherView only routes points inside a tile).
            let barY = min(
                round(bounds.height - letterArea / 2 - size.height / 2),
                bounds.height - size.height
            )
            actionBar.frame = NSRect(
                x: round((w - size.width) / 2),
                y: barY,
                width: size.width,
                height: size.height
            )
        }
    }
}

/// Tiny capped LRU backing the grid tile's render memo caches (attributed
/// letters and tinted status symbols), mirroring the list view's inline cache.
private struct MemoCache<Key: Hashable, Value> {
    private var storage: [Key: Value] = [:]
    private var order: [Key] = []
    private let capacity: Int

    init(capacity: Int) { self.capacity = capacity }

    mutating func value(for key: Key, build: () -> Value) -> Value {
        if let hit = storage[key] {
            if let i = order.firstIndex(of: key) {
                order.remove(at: i)
                order.append(key)
            }
            return hit
        }
        let made = build()
        storage[key] = made
        order.append(key)
        if order.count > capacity {
            storage.removeValue(forKey: order.removeFirst())
        }
        return made
    }
}
