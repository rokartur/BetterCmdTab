import AppKit

@MainActor
protocol SwitcherItemViewProtocol: NSView {
    var isSelected: Bool { get set }
    func configure(with row: SwitcherRow, label: String, prefixLength: Int, selected: Bool, metrics: SwitcherMetrics, accent: NSColor)
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

    var isSelected: Bool = false {
        didSet {
            guard oldValue != isSelected else { return }
            applySelection()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

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

        updateSelectionAppearance()
        applyMetrics(metrics)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSelectionAppearance()
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

    func configure(with row: SwitcherRow, label: String, prefixLength: Int, selected: Bool, metrics: SwitcherMetrics, accent: NSColor) {
        if metrics != self.metrics {
            applyMetrics(metrics)
        }
        self.accent = accent
        currentLabel = label
        currentPrefixLength = prefixLength
        renderLetter()

        // System permission/dialog rows (e.g. the Accessibility alert) show
        // just the window title with the System Settings icon — no status
        // glyphs — since their host process name/icon are meaningless.
        let isDialog = row.isSystemDialog

        nameLabel.stringValue = isDialog
            ? (row.windowTitle.isEmpty ? row.appName : row.windowTitle)
            : row.appName

        // Status glyphs ride with the secondary text instead of crowding the
        // icon. Audio is orthogonal, so it shows alongside the window-state
        // glyph (e.g. a windowless app playing sound gets both speaker + no-
        // window). Launch/reopen rows return their single cue, never a stacked
        // no-window glyph.
        let indicators = isDialog ? [] : Self.indicators(for: row)
        let secondary = isDialog ? "" : Self.secondaryText(for: row)
        if indicators.isEmpty, secondary.isEmpty {
            titleLabel.attributedStringValue = NSAttributedString(string: "")
            titleLabel.isHidden = true
        } else {
            titleLabel.attributedStringValue = makeTitle(indicators: indicators, text: secondary)
            titleLabel.isHidden = false
        }

        imageView.image = isDialog ? SystemSettingsIcon.image : IconCache.icon(for: row)

        // Dock badge (experimental). Empty map when the feature is off.
        let badge = (row.isPlaceholder || isDialog) ? nil : DockBadgeReader.shared.badge(forBundleID: row.bundleIdentifier)
        if let badge {
            badgeLabel.stringValue = badge
            badgePill.isHidden = false
        } else {
            badgePill.isHidden = true
        }

        isSelected = selected
        applySelection()
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

    private static func secondaryText(for row: SwitcherRow) -> String {
        if row.isLaunchable { return "Launch" }
        if row.isRecentlyClosed { return row.windowTitle.isEmpty ? "Reopen" : row.windowTitle }
        if row.isPlaceholder || row.window == nil { return "" }
        return row.windowTitle
    }

    /// Builds the secondary line: leading status glyphs (each tinted to its
    /// semantic color) followed by the text, centered as one group.
    private func makeTitle(indicators: [SwitcherIndicator], text: String) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: metrics.tileTitleFontSize, weight: .regular)
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byTruncatingTail

        let result = NSMutableAttributedString()
        for (i, indicator) in indicators.enumerated() {
            if i > 0 { result.append(NSAttributedString(string: "\u{2009}")) } // thin space between glyphs
            let color = indicator.tint(onAccentFill: false, accent: accent)
            let cfg = NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .semibold)
                .applying(.init(paletteColors: [color]))
            if let image = indicator.makeImage()?.withSymbolConfiguration(cfg) {
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
        nameLabel.font = NSFont.systemFont(
            ofSize: metrics.tileNameFontSize,
            weight: isSelected ? .semibold : .medium
        )
        renderLetter()
    }

    private func renderLetter() {
        let labelStr = currentLabel.uppercased()
        guard !labelStr.isEmpty else {
            letterLabel.attributedStringValue = NSAttributedString(string: "")
            return
        }
        let highlightLen = min(currentPrefixLength, labelStr.count)
        let font = NSFont.monospacedSystemFont(ofSize: metrics.tileLetterFontSize, weight: .bold)
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let attr = NSMutableAttributedString(string: labelStr, attributes: [
            .font: font,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: para,
        ])
        if highlightLen > 0 {
            attr.addAttribute(.foregroundColor, value: accent, range: NSRange(location: 0, length: highlightLen))
        }
        letterLabel.attributedStringValue = attr
        needsLayout = true
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
        nameLabel.frame = NSRect(x: 0, y: labelAreaH - nameH, width: w, height: nameH)
        titleLabel.frame = NSRect(x: 0, y: labelAreaH - nameH - titleH, width: w, height: titleH)
    }
}
