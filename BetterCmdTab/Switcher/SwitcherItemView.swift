import AppKit

@MainActor
final class SwitcherItemView: NSView, SwitcherItemViewProtocol {
    private let letterLabel = NSTextField(labelWithString: "")
    private let appNameLabel = NSTextField(labelWithString: "")
    private let imageView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let highlight = NSView()
    private let hiddenIcon = NSImageView()
    private let minimizedIcon = NSImageView()
    private let noWindowIcon = NSImageView()
    private let fullscreenIcon = NSImageView()
    private let audioIcon = NSImageView()
    private let launchIcon = NSImageView()
    private let reopenIcon = NSImageView()
    private let badgePill = NSView()
    private let badgeLabel = NSTextField(labelWithString: "")

    private var metrics: SwitcherMetrics = .baseline
    private static let statusIconGap: CGFloat = 4

    /// Indicator → image view, in display order. Drives setup, tinting, and
    /// layout uniformly from the shared `SwitcherIndicator` definitions.
    private lazy var indicatorViews: [(SwitcherIndicator, NSImageView)] = [
        (.audio, audioIcon), (.launch, launchIcon), (.reopen, reopenIcon),
        (.hidden, hiddenIcon), (.minimized, minimizedIcon),
        (.noWindow, noWindowIcon), (.fullscreen, fullscreenIcon),
    ]

    var isSelected: Bool = false {
        didSet {
            guard oldValue != isSelected else { return }
            applySelection()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        highlight.wantsLayer = true
        highlight.layer?.cornerCurve = .continuous
        highlight.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        highlight.isHidden = true
        addSubview(highlight)

        letterLabel.alignment = .center
        letterLabel.lineBreakMode = .byClipping
        letterLabel.maximumNumberOfLines = 1
        letterLabel.usesSingleLineMode = true
        letterLabel.textColor = .tertiaryLabelColor
        letterLabel.drawsBackground = false
        letterLabel.isBezeled = false
        letterLabel.isEditable = false
        letterLabel.isSelectable = false
        addSubview(letterLabel)

        appNameLabel.alignment = .right
        appNameLabel.lineBreakMode = .byTruncatingHead
        appNameLabel.maximumNumberOfLines = 1
        appNameLabel.usesSingleLineMode = true
        appNameLabel.textColor = .labelColor
        appNameLabel.drawsBackground = false
        appNameLabel.isBezeled = false
        appNameLabel.isEditable = false
        appNameLabel.isSelectable = false
        addSubview(appNameLabel)

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.imageFrameStyle = .none
        addSubview(imageView)

        titleLabel.alignment = .left
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.usesSingleLineMode = true
        titleLabel.textColor = .labelColor
        titleLabel.drawsBackground = false
        titleLabel.isBezeled = false
        titleLabel.isEditable = false
        titleLabel.isSelectable = false
        addSubview(titleLabel)

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

        for (indicator, iv) in indicatorViews {
            iv.imageScaling = .scaleProportionallyUpOrDown
            iv.imageAlignment = .alignCenter
            iv.imageFrameStyle = .none
            iv.isHidden = true
            iv.image = indicator.makeImage()
            iv.contentTintColor = indicator.tint(onAccentFill: false, accent: accent)
            addSubview(iv)
        }

        applyMetrics(metrics)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    private var currentLabel: String = ""
    private var currentPrefixLength: Int = 0
    private var accent: NSColor = .controlAccentColor

    func configure(with row: SwitcherRow, label: String, prefixLength: Int, selected: Bool, metrics: SwitcherMetrics, accent: NSColor) {
        if metrics != self.metrics {
            applyMetrics(metrics)
        }
        if self.accent != accent {
            self.accent = accent
            highlight.layer?.backgroundColor = accent.cgColor
        }
        currentLabel = label
        currentPrefixLength = prefixLength
        renderLetter()
        // System permission/dialog rows (e.g. the Accessibility alert) show just
        // the window title with the System Settings icon — no status icons.
        let isDialog = row.isSystemDialog

        if isDialog {
            appNameLabel.stringValue = row.windowTitle.isEmpty ? row.appName : row.windowTitle
            titleLabel.stringValue = ""
        } else {
            appNameLabel.stringValue = row.appName
            if row.isLaunchable {
                titleLabel.stringValue = "Launch"
            } else if row.isRecentlyClosed {
                titleLabel.stringValue = row.windowTitle.isEmpty ? "Reopen" : row.windowTitle
            } else {
                titleLabel.stringValue = row.displayTitle
            }
        }
        imageView.image = isDialog ? SystemSettingsIcon.image : IconCache.icon(for: row)
        let showHidden = !isDialog && !row.isPlaceholder && row.isHidden
        let showMinimized = !isDialog && !row.isPlaceholder && row.isMinimized && !showHidden
        // No-window applies only to running apps — launch/reopen rows have their
        // own glyph and must not also show the dashed-square.
        let showNoWindow = !isDialog && !row.isPlaceholder && row.app != nil && row.window == nil && !showHidden && !row.suppressNoWindowGlyph
        let showFullscreen = !isDialog && !row.isPlaceholder && row.isFullscreen && !showHidden && !showMinimized && !showNoWindow
        // Audio is per-app and orthogonal to the window-state icons.
        let showAudio = !isDialog && !row.isPlaceholder && (row.pid.map { AudioActivityMonitor.shared.isPlaying($0) } ?? false)
        let showLaunch = !isDialog && row.isLaunchable
        let showReopen = !isDialog && row.isRecentlyClosed
        if audioIcon.isHidden != !showAudio
            || launchIcon.isHidden != !showLaunch
            || reopenIcon.isHidden != !showReopen
            || hiddenIcon.isHidden != !showHidden
            || minimizedIcon.isHidden != !showMinimized
            || noWindowIcon.isHidden != !showNoWindow
            || fullscreenIcon.isHidden != !showFullscreen {
            audioIcon.isHidden = !showAudio
            launchIcon.isHidden = !showLaunch
            reopenIcon.isHidden = !showReopen
            hiddenIcon.isHidden = !showHidden
            minimizedIcon.isHidden = !showMinimized
            noWindowIcon.isHidden = !showNoWindow
            fullscreenIcon.isHidden = !showFullscreen
            needsLayout = true
        }
        // Dock badge (experimental); empty map when the feature is off.
        let badge = (row.isPlaceholder || isDialog) ? nil : DockBadgeReader.shared.badge(forBundleID: row.bundleIdentifier)
        let badgeChanged = badgePill.isHidden == (badge != nil) || badgeLabel.stringValue != (badge ?? "")
        badgeLabel.stringValue = badge ?? ""
        badgePill.isHidden = (badge == nil)
        if badgeChanged { needsLayout = true }
        isSelected = selected
        applySelection()
    }

    private func applyMetrics(_ metrics: SwitcherMetrics) {
        self.metrics = metrics
        let font = NSFont.systemFont(ofSize: metrics.fontSize)
        appNameLabel.font = font
        titleLabel.font = font
        badgeLabel.font = NSFont.systemFont(ofSize: max(9, metrics.fontSize - 2), weight: .bold)
        letterLabel.font = NSFont.monospacedSystemFont(ofSize: metrics.letterFontSize, weight: .semibold)
        highlight.layer?.cornerRadius = metrics.highlightCornerRadius
        let symbolCfg = NSImage.SymbolConfiguration(pointSize: metrics.fontSize, weight: .regular)
        for (_, iv) in indicatorViews {
            iv.symbolConfiguration = symbolCfg
        }
        needsLayout = true
    }

    private func applySelection() {
        highlight.isHidden = !isSelected
        let primary: NSColor = isSelected ? .white : .labelColor
        let secondary: NSColor = isSelected ? NSColor.white.withAlphaComponent(0.9) : .labelColor
        appNameLabel.textColor = primary
        titleLabel.textColor = secondary
        // The selected row paints an accent-colored background, so every glyph
        // turns white; otherwise each keeps its semantic color.
        for (indicator, iv) in indicatorViews {
            iv.contentTintColor = indicator.tint(onAccentFill: isSelected, accent: accent)
        }
        renderLetter()
    }

    private struct LetterCacheKey: Hashable {
        let label: String
        let prefixLen: Int
        let fontSize: CGFloat
        let selected: Bool
        // Distinguishes cache entries per accent so switching the accent color
        // doesn't serve a stale highlight. The color object itself still
        // resolves light/dark at draw time, so dynamic accents stay reactive.
        let accentKey: String
    }

    private static var letterCache: [LetterCacheKey: NSAttributedString] = [:]
    private static var letterCacheOrder: [LetterCacheKey] = []
    private static let letterCacheCap = 256

    private static func memoizedLetter(_ key: LetterCacheKey, accent: NSColor) -> NSAttributedString {
        if let hit = letterCache[key] {
            if let idx = letterCacheOrder.firstIndex(of: key) {
                letterCacheOrder.remove(at: idx)
                letterCacheOrder.append(key)
            }
            return hit
        }
        let font = NSFont.monospacedSystemFont(ofSize: key.fontSize, weight: .semibold)
        let boldFont = NSFont.monospacedSystemFont(ofSize: key.fontSize, weight: .bold)
        let highlightColor: NSColor = key.selected ? .white : accent
        let baseColor: NSColor = key.selected ? .white : .labelColor
        let para = NSMutableParagraphStyle()
        para.alignment = .center

        let attr = NSMutableAttributedString(string: key.label, attributes: [
            .font: font,
            .foregroundColor: baseColor,
            .paragraphStyle: para,
        ])
        let highlightLen = min(key.prefixLen, key.label.count)
        if highlightLen > 0 {
            attr.addAttribute(.foregroundColor, value: highlightColor, range: NSRange(location: 0, length: highlightLen))
            attr.addAttribute(.font, value: boldFont, range: NSRange(location: 0, length: highlightLen))
        }
        letterCache[key] = attr
        letterCacheOrder.append(key)
        if letterCacheOrder.count > letterCacheCap {
            let victim = letterCacheOrder.removeFirst()
            letterCache.removeValue(forKey: victim)
        }
        return attr
    }

    private func renderLetter() {
        let labelStr = currentLabel.uppercased()
        let key = LetterCacheKey(
            label: labelStr,
            prefixLen: currentPrefixLength,
            fontSize: metrics.letterFontSize,
            selected: isSelected,
            accentKey: accent.description
        )
        letterLabel.attributedStringValue = Self.memoizedLetter(key, accent: accent)
    }

    override func layout() {
        super.layout()
        let m = metrics
        let h = bounds.height

        highlight.frame = bounds.insetBy(dx: m.highlightInset, dy: max(1, m.highlightInset / 2))

        let labelH = m.labelHeight
        let labelY = (h - labelH) / 2
        let iconY = (h - m.iconSize) / 2
        let statusSize = m.iconSize
        let statusGap = Self.statusIconGap

        let letterX = m.horizontalInset
        let letterFont = NSFont.monospacedSystemFont(ofSize: m.letterFontSize, weight: .semibold)
        let letterLineHeight = ceil(letterFont.ascender + abs(letterFont.descender))
        let letterY = (h - letterLineHeight) / 2
        letterLabel.frame = NSRect(x: letterX, y: letterY, width: m.letterColumnWidth, height: letterLineHeight)

        let appX = letterX + m.letterColumnWidth + m.interGap
        appNameLabel.frame = NSRect(x: appX, y: labelY, width: m.appNameWidth, height: labelH)

        let iconX = appX + m.appNameWidth + m.interGap
        imageView.frame = NSRect(x: iconX, y: iconY, width: m.iconSize, height: m.iconSize)

        let visibleStatusIcons = indicatorViews.map { $0.1 }.filter { !$0.isHidden }
        var statusRightEdge = bounds.width - m.horizontalInset
        for iv in visibleStatusIcons.reversed() {
            let frame = NSRect(
                x: statusRightEdge - statusSize,
                y: iconY,
                width: statusSize,
                height: statusSize
            )
            iv.frame = frame
            statusRightEdge -= (statusSize + statusGap)
        }

        let titleX = iconX + m.iconSize + m.interGap
        var rightLimit: CGFloat
        if visibleStatusIcons.isEmpty {
            rightLimit = bounds.width - m.horizontalInset
        } else {
            rightLimit = statusRightEdge - m.interGap + statusGap
        }

        if !badgePill.isHidden {
            // Circle for 1–2 digits; widens into a fixed-height pill for 3+.
            // Font stays full-size and the row never clips it.
            let height = min(round(m.fontSize * 1.5), h - 4)
            let font = NSFont.systemFont(ofSize: round(m.fontSize * 0.85), weight: .regular)
            badgeLabel.font = font
            let size = BadgeText.size(for: badgeLabel.stringValue, font: font, height: height)
            let pillX = rightLimit - size.width
            let pillY = (h - height) / 2
            badgePill.frame = NSRect(x: pillX, y: pillY, width: size.width, height: height)
            badgePill.layer?.cornerRadius = height / 2
            badgeLabel.frame = BadgeText.centeredTextFrame(width: size.width, height: height, font: font)
            rightLimit = pillX - m.interGap
        }

        let titleW = max(0, rightLimit - titleX)
        titleLabel.frame = NSRect(x: titleX, y: labelY, width: titleW, height: labelH)
    }
}
