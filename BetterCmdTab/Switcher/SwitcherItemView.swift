import AppKit

@MainActor
final class SwitcherItemView: NSView {
    private let letterLabel = NSTextField(labelWithString: "")
    private let appNameLabel = NSTextField(labelWithString: "")
    private let imageView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let highlight = NSView()
    private let hiddenIcon = NSImageView()
    private let minimizedIcon = NSImageView()
    private let noWindowIcon = NSImageView()
    private let fullscreenIcon = NSImageView()

    private var metrics: SwitcherMetrics = .baseline
    private static let statusIconGap: CGFloat = 4

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

        for iv in [hiddenIcon, minimizedIcon, noWindowIcon, fullscreenIcon] {
            iv.imageScaling = .scaleProportionallyUpOrDown
            iv.imageAlignment = .alignCenter
            iv.imageFrameStyle = .none
            iv.isHidden = true
            iv.contentTintColor = .secondaryLabelColor
            addSubview(iv)
        }
        hiddenIcon.image = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: "Hidden app")
        minimizedIcon.image = NSImage(systemSymbolName: "minus.rectangle", accessibilityDescription: "Minimized window")
        noWindowIcon.image = NSImage(systemSymbolName: "square.dashed", accessibilityDescription: "No active window")
        fullscreenIcon.image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: "Fullscreen window")

        applyMetrics(metrics)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    private var currentLabel: String = ""
    private var currentPrefixLength: Int = 0

    func configure(with row: SwitcherRow, label: String, prefixLength: Int, selected: Bool, metrics: SwitcherMetrics) {
        if metrics != self.metrics {
            applyMetrics(metrics)
        }
        currentLabel = label
        currentPrefixLength = prefixLength
        renderLetter()
        appNameLabel.stringValue = row.appName
        titleLabel.stringValue = row.displayTitle
        imageView.image = IconCache.icon(for: row)
        let showHidden = !row.isPlaceholder && row.app.isHidden
        let showMinimized = !row.isPlaceholder && row.isMinimized && !showHidden
        let showNoWindow = !row.isPlaceholder && row.window == nil && !showHidden
        let showFullscreen = !row.isPlaceholder && row.isFullscreen && !showHidden && !showMinimized && !showNoWindow
        if hiddenIcon.isHidden != !showHidden
            || minimizedIcon.isHidden != !showMinimized
            || noWindowIcon.isHidden != !showNoWindow
            || fullscreenIcon.isHidden != !showFullscreen {
            hiddenIcon.isHidden = !showHidden
            minimizedIcon.isHidden = !showMinimized
            noWindowIcon.isHidden = !showNoWindow
            fullscreenIcon.isHidden = !showFullscreen
            needsLayout = true
        }
        isSelected = selected
        applySelection()
    }

    private func applyMetrics(_ metrics: SwitcherMetrics) {
        self.metrics = metrics
        let font = NSFont.systemFont(ofSize: metrics.fontSize)
        appNameLabel.font = font
        titleLabel.font = font
        letterLabel.font = NSFont.monospacedSystemFont(ofSize: metrics.letterFontSize, weight: .semibold)
        highlight.layer?.cornerRadius = metrics.highlightCornerRadius
        let symbolCfg = NSImage.SymbolConfiguration(pointSize: metrics.fontSize, weight: .regular)
        for iv in [hiddenIcon, minimizedIcon, noWindowIcon, fullscreenIcon] {
            iv.symbolConfiguration = symbolCfg
        }
        needsLayout = true
    }

    private func applySelection() {
        highlight.isHidden = !isSelected
        let primary: NSColor = isSelected ? .white : .labelColor
        let secondary: NSColor = isSelected ? NSColor.white.withAlphaComponent(0.9) : .labelColor
        let statusTint: NSColor = isSelected ? NSColor.white.withAlphaComponent(0.85) : .secondaryLabelColor
        appNameLabel.textColor = primary
        titleLabel.textColor = secondary
        for iv in [hiddenIcon, minimizedIcon, noWindowIcon, fullscreenIcon] {
            iv.contentTintColor = statusTint
        }
        renderLetter()
    }

    private struct LetterCacheKey: Hashable {
        let label: String
        let prefixLen: Int
        let fontSize: CGFloat
        let selected: Bool
    }

    private static var letterCache: [LetterCacheKey: NSAttributedString] = [:]
    private static var letterCacheOrder: [LetterCacheKey] = []
    private static let letterCacheCap = 256

    private static func memoizedLetter(_ key: LetterCacheKey) -> NSAttributedString {
        if let hit = letterCache[key] {
            if let idx = letterCacheOrder.firstIndex(of: key) {
                letterCacheOrder.remove(at: idx)
                letterCacheOrder.append(key)
            }
            return hit
        }
        let font = NSFont.monospacedSystemFont(ofSize: key.fontSize, weight: .semibold)
        let boldFont = NSFont.monospacedSystemFont(ofSize: key.fontSize, weight: .bold)
        let highlightColor: NSColor = key.selected ? .white : .controlAccentColor
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
            selected: isSelected
        )
        letterLabel.attributedStringValue = Self.memoizedLetter(key)
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

        let visibleStatusIcons = [hiddenIcon, minimizedIcon, noWindowIcon, fullscreenIcon].filter { !$0.isHidden }
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
        let rightLimit: CGFloat
        if visibleStatusIcons.isEmpty {
            rightLimit = bounds.width - m.horizontalInset
        } else {
            rightLimit = statusRightEdge - m.interGap + statusGap
        }
        let titleW = max(0, rightLimit - titleX)
        titleLabel.frame = NSRect(x: titleX, y: labelY, width: titleW, height: labelH)
    }
}
