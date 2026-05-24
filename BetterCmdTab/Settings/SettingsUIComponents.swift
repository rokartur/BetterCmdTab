import AppKit
import QuartzCore

// MARK: - Flipped helper (origin at top-left for natural scroll content)

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Section chrome (shared colors)

enum AppKitSectionChrome {
    static let cornerRadius: CGFloat = 14
    static let borderWidth: CGFloat = 0.5

    private static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    static func fillColor(for appearance: NSAppearance) -> NSColor {
        if isDark(appearance) {
            return NSColor.white.withAlphaComponent(0.035)
        }
        return NSColor.black.withAlphaComponent(0.025)
    }

    static func borderColor(for appearance: NSAppearance) -> NSColor {
        if isDark(appearance) {
            return NSColor.white.withAlphaComponent(0.06)
        }
        return NSColor.black.withAlphaComponent(0.05)
    }

    static func dividerColor(for appearance: NSAppearance) -> NSColor {
        if isDark(appearance) {
            return NSColor.white.withAlphaComponent(0.06)
        }
        return NSColor.black.withAlphaComponent(0.06)
    }
}

// MARK: - Section container (rounded card with optional title header)

@MainActor
final class SettingsSectionView: NSView {

    private static let cornerRadius: CGFloat = AppKitSectionChrome.cornerRadius
    private static let contentPadding: CGFloat = 12
    private static let contentSpacing: CGFloat = 10
    private static let headerBottomSpacing: CGFloat = 10

    private let outerStack: NSStackView = {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    private let cardView: NSView = {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.wantsLayer = true
        return v
    }()

    let contentStack: NSStackView = {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = SettingsSectionView.contentSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    private var headerView: NSView?

    init(header: String? = nil) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setupViews(header: header)
    }

    convenience override init(frame: NSRect) {
        self.init(header: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateCardAppearance()
    }

    private func setupViews(header: String?) {
        addSubview(outerStack)
        NSLayoutConstraint.activate([
            outerStack.topAnchor.constraint(equalTo: topAnchor),
            outerStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            outerStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            outerStack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        if let header, !header.isEmpty {
            let headerLabel = NSTextField(labelWithString: header)
            headerLabel.font = .systemFont(ofSize: 13, weight: .semibold)
            headerLabel.textColor = .labelColor
            headerLabel.translatesAutoresizingMaskIntoConstraints = false

            let wrapper = NSView()
            wrapper.translatesAutoresizingMaskIntoConstraints = false
            wrapper.addSubview(headerLabel)
            NSLayoutConstraint.activate([
                headerLabel.topAnchor.constraint(equalTo: wrapper.topAnchor),
                headerLabel.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 6),
                headerLabel.trailingAnchor.constraint(lessThanOrEqualTo: wrapper.trailingAnchor),
                headerLabel.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            ])
            outerStack.addArrangedSubview(wrapper)
            outerStack.setCustomSpacing(Self.headerBottomSpacing, after: wrapper)
            headerView = wrapper

            NSLayoutConstraint.activate([
                wrapper.leadingAnchor.constraint(equalTo: outerStack.leadingAnchor),
                wrapper.trailingAnchor.constraint(equalTo: outerStack.trailingAnchor),
            ])
        }

        outerStack.addArrangedSubview(cardView)

        NSLayoutConstraint.activate([
            cardView.leadingAnchor.constraint(equalTo: outerStack.leadingAnchor),
            cardView.trailingAnchor.constraint(equalTo: outerStack.trailingAnchor),
        ])
        updateCardAppearance()

        cardView.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: cardView.topAnchor, constant: Self.contentPadding),
            contentStack.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: Self.contentPadding),
            contentStack.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -Self.contentPadding),
            contentStack.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -Self.contentPadding),
        ])

        contentStack.setHuggingPriority(.defaultLow, for: .horizontal)
    }

    private func updateCardAppearance() {
        guard let layer = cardView.layer else { return }
        layer.cornerCurve = .continuous
        layer.cornerRadius = Self.cornerRadius
        layer.backgroundColor = AppKitSectionChrome.fillColor(for: effectiveAppearance).cgColor
        layer.borderWidth = AppKitSectionChrome.borderWidth
        layer.borderColor = AppKitSectionChrome.borderColor(for: effectiveAppearance).cgColor
    }

    // MARK: - Public API

    func addRow(_ row: NSView) {
        addContent(row)
    }

    func addContent(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
    }

    func addDivider() {
        let divider = NSBox()
        divider.boxType = .separator
        divider.alphaValue = 0.55
        addContent(divider)
    }
}

// MARK: - Settings row (title + optional subtitle + trailing accessory)

@MainActor
final class SettingsRowView: NSView {

    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(wrappingLabelWithString: "")
    private var textColumn: NSStackView!
    private var hStack: NSStackView!
    private var accessoryView: NSView?
    private var iconView: NSImageView?

    /// Creates a settings row.
    /// - Parameters:
    ///   - icon: Optional SF Symbol name (rendered at 13pt) shown leading to the title.
    ///   - title: Primary label text (13pt).
    ///   - subtitle: Optional secondary text (11pt secondary color).
    ///   - accessory: Optional trailing control (button, toggle, picker, ...).
    init(
        icon: String? = nil,
        title: String,
        subtitle: String? = nil,
        accessory: NSView? = nil
    ) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setupViews(icon: icon, title: title, subtitle: subtitle, accessory: accessory)
    }

    // Backwards-compat for legacy callsites using `description:`.
    convenience init(title: String, description: String?, accessory: NSView? = nil) {
        self.init(icon: nil, title: title, subtitle: description, accessory: accessory)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: - Setup

    private func setupViews(icon: String?, title: String, subtitle: String?, accessory: NSView?) {
        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let normalizedSubtitle = subtitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasSubtitle = !(normalizedSubtitle?.isEmpty ?? true)
        subtitleLabel.stringValue = normalizedSubtitle ?? ""
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byWordWrapping
        subtitleLabel.maximumNumberOfLines = 0
        subtitleLabel.preferredMaxLayoutWidth = 350
        subtitleLabel.isHidden = !hasSubtitle
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        textColumn = NSStackView()
        textColumn.orientation = .vertical
        textColumn.alignment = .leading
        textColumn.spacing = 2
        textColumn.translatesAutoresizingMaskIntoConstraints = false
        textColumn.addArrangedSubview(titleLabel)
        textColumn.addArrangedSubview(subtitleLabel)
        textColumn.setHuggingPriority(.defaultLow, for: .horizontal)
        textColumn.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        hStack = NSStackView()
        hStack.orientation = .horizontal
        hStack.alignment = .top
        hStack.spacing = 8
        hStack.translatesAutoresizingMaskIntoConstraints = false

        if let icon, !icon.isEmpty {
            let imageView = NSImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.image = NSImage(systemSymbolName: icon, accessibilityDescription: title)
            imageView.contentTintColor = .labelColor
            imageView.symbolConfiguration = .init(pointSize: 13, weight: .regular)
            imageView.setContentHuggingPriority(.required, for: .horizontal)
            imageView.setContentCompressionResistancePriority(.required, for: .horizontal)
            NSLayoutConstraint.activate([
                imageView.widthAnchor.constraint(equalToConstant: 20),
                imageView.heightAnchor.constraint(greaterThanOrEqualToConstant: 16),
            ])
            hStack.addArrangedSubview(imageView)
            iconView = imageView
        }

        hStack.addArrangedSubview(textColumn)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.fittingSizeCompression, for: .horizontal)
        hStack.addArrangedSubview(spacer)

        if let accessory {
            applyAccessory(accessory)
        }

        addSubview(hStack)
        NSLayoutConstraint.activate([
            hStack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            hStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            hStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            hStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    private func applyAccessory(_ accessory: NSView) {
        accessory.translatesAutoresizingMaskIntoConstraints = false
        accessory.setContentHuggingPriority(.required, for: .horizontal)
        accessory.setContentCompressionResistancePriority(.required, for: .horizontal)
        hStack.addArrangedSubview(accessory)
        accessoryView = accessory
    }

    // MARK: - Public API

    var title: String {
        get { titleLabel.stringValue }
        set { titleLabel.stringValue = newValue }
    }

    var rowDescription: String? {
        didSet {
            let text = rowDescription ?? ""
            subtitleLabel.stringValue = text
            subtitleLabel.isHidden = text.isEmpty
        }
    }

    var attributedRowDescription: NSAttributedString? {
        didSet {
            guard let attr = attributedRowDescription else {
                if (rowDescription ?? "").isEmpty {
                    subtitleLabel.stringValue = ""
                    subtitleLabel.isHidden = true
                }
                return
            }
            subtitleLabel.attributedStringValue = attr
            subtitleLabel.isHidden = attr.length == 0
        }
    }

    func setAccessory(_ view: NSView) {
        if let existing = accessoryView {
            hStack.removeArrangedSubview(existing)
            existing.removeFromSuperview()
            accessoryView = nil
        }
        applyAccessory(view)
    }

    override func layout() {
        super.layout()
        let availableWidth = max(0, textColumn.frame.width)
        if availableWidth > 1, subtitleLabel.preferredMaxLayoutWidth != availableWidth {
            subtitleLabel.preferredMaxLayoutWidth = availableWidth
        }
    }
}

// MARK: - Scrolling tab layout helper

enum SettingsLayout {
    /// Wraps a vertical stack of sections in a scroll view with consistent padding.
    static func makeScrollingTab(sections: [NSView]) -> NSView {
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.verticalScrollElasticity = .allowed
        scroll.horizontalScrollElasticity = .none
        scroll.contentView.drawsBackground = false

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 24
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        for section in sections {
            stack.addArrangedSubview(section)
        }
        document.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor, constant: -24),
        ])

        scroll.documentView = document
        NSLayoutConstraint.activate([
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])

        for section in sections {
            section.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        return scroll
    }
}

// MARK: - Capsule action view (used by About hero)

@MainActor
final class CapsulePillView: NSView {

    enum Style {
        case subtle
        case prominent(NSColor)
    }

    private enum Animation {
        static let stateDuration: TimeInterval = 0.22
        static let hoverDuration: TimeInterval = 0.12
        static let pressInDuration: TimeInterval = 0.08
        static let pressOutDuration: TimeInterval = 0.16
    }

    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let contentStack: NSStackView = {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    private var topConstraint: NSLayoutConstraint?
    private var leadingConstraint: NSLayoutConstraint?
    private var trailingConstraint: NSLayoutConstraint?
    private var bottomConstraint: NSLayoutConstraint?

    private var trackingArea: NSTrackingArea?
    private var style: Style = .subtle
    private var action: (() -> Void)?
    private var currentIconName: String?
    private var baseHorizontalPadding: CGFloat = 12
    private var baseVerticalPadding: CGFloat = 5

    private var isHovering = false {
        didSet {
            guard oldValue != isHovering else { return }
            if !isHovering { isPressing = false }
            updateAppearance(animated: true, duration: Animation.hoverDuration)
        }
    }
    private var isPressing = false {
        didSet {
            guard oldValue != isPressing else { return }
            updateAppearance(
                animated: true,
                duration: isPressing ? Animation.pressInDuration : Animation.pressOutDuration
            )
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false

        addSubview(contentStack)

        topConstraint = contentStack.topAnchor.constraint(equalTo: topAnchor, constant: baseVerticalPadding)
        leadingConstraint = contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: baseHorizontalPadding)
        trailingConstraint = contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -baseHorizontalPadding)
        bottomConstraint = contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -baseVerticalPadding)
        NSLayoutConstraint.activate([
            topConstraint!,
            leadingConstraint!,
            trailingConstraint!,
            bottomConstraint!,
        ])

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        contentStack.addArrangedSubview(iconView)
        contentStack.addArrangedSubview(label)

        updateAppearance(animated: false)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance(animated: false)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
            trackingArea = nil
        }
        guard action != nil else { return }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard action != nil else { return }
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guard action != nil else { return }
        isHovering = false
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard action != nil else { return }
        isPressing = true
    }

    override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: event)
        guard action != nil else { return }
        let location = convert(event.locationInWindow, from: nil)
        isPressing = bounds.contains(location)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        guard let action else { return }
        let location = convert(event.locationInWindow, from: nil)
        isPressing = false
        if bounds.contains(location) {
            action()
        }
    }

    func configure(
        text: String,
        iconName: String? = nil,
        iconColor: NSColor = .secondaryLabelColor,
        textColor: NSColor = .secondaryLabelColor,
        textFont: NSFont = .systemFont(ofSize: 11, weight: .medium),
        style: Style = .subtle,
        horizontalPadding: CGFloat = 12,
        verticalPadding: CGFloat = 5,
        action: (() -> Void)? = nil
    ) {
        self.style = style
        self.action = action
        self.baseHorizontalPadding = horizontalPadding
        self.baseVerticalPadding = verticalPadding
        updateTrackingAreas()

        label.stringValue = text
        label.textColor = textColor
        label.font = textFont

        if let iconName {
            let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
            iconView.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
            iconView.contentTintColor = iconColor
            iconView.isHidden = false
            currentIconName = iconName
        } else {
            iconView.image = nil
            iconView.isHidden = true
            currentIconName = nil
        }

        topConstraint?.constant = verticalPadding
        bottomConstraint?.constant = -verticalPadding
        leadingConstraint?.constant = horizontalPadding
        trailingConstraint?.constant = -horizontalPadding

        updateAppearance(animated: false)
        needsLayout = true
        needsDisplay = true
    }

    private func updateAppearance(animated: Bool, duration: TimeInterval = Animation.hoverDuration) {
        let fillColor: NSColor
        let borderColor: NSColor

        switch style {
        case .subtle:
            let baseFill = AppKitSectionChrome.fillColor(for: effectiveAppearance)
            let baseBorder = AppKitSectionChrome.borderColor(for: effectiveAppearance)
            let fillBoost: CGFloat
            let borderBoost: CGFloat
            if isPressing {
                fillBoost = 0.055
                borderBoost = 0.055
            } else if isHovering {
                fillBoost = 0.03
                borderBoost = 0.03
            } else {
                fillBoost = 0
                borderBoost = 0
            }
            fillColor = baseFill.blended(withFraction: fillBoost, of: .labelColor) ?? baseFill
            borderColor = baseBorder.blended(withFraction: borderBoost, of: .labelColor) ?? baseBorder

        case .prominent(let baseColor):
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let alpha: CGFloat
            if isPressing {
                alpha = dark ? 0.28 : 0.20
            } else if isHovering {
                alpha = dark ? 0.20 : 0.14
            } else {
                alpha = dark ? 0.15 : 0.10
            }
            fillColor = baseColor.withAlphaComponent(alpha)
            borderColor = baseColor.withAlphaComponent(isPressing ? 0.38 : 0.30)
        }

        let apply = {
            self.layer?.backgroundColor = fillColor.cgColor
            self.layer?.borderColor = borderColor.cgColor
            self.layer?.borderWidth = AppKitSectionChrome.borderWidth
        }

        guard animated, window != nil else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            apply()
            CATransaction.commit()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            apply()
        }
    }
}

// MARK: - Quick link card (About tab)

@MainActor
final class QuickLinkCardView: NSView {

    private let url: URL
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let arrowView = NSImageView()

    private var trackingArea: NSTrackingArea?
    private var isHovering = false {
        didSet { updateAppearance() }
    }

    init(title: String, iconName: String, url: URL) {
        self.url = url
        super.init(frame: .zero)
        setup(title: title, iconName: iconName)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func setup(title: String, iconName: String) {
        wantsLayer = true
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        if let iconImage = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold)) {
            iconView.image = iconImage
        }
        iconView.contentTintColor = .tertiaryLabelColor
        iconView.translatesAutoresizingMaskIntoConstraints = false

        if let arrowImage = NSImage(systemSymbolName: "arrow.up.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold)) {
            arrowView.image = arrowImage
        }
        arrowView.contentTintColor = .quaternaryLabelColor
        arrowView.translatesAutoresizingMaskIntoConstraints = false
        arrowView.setContentHuggingPriority(.required, for: .horizontal)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [iconView, titleLabel, spacer, arrowView])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
        ])

        updateAppearance()
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
            trackingArea = nil
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovering = false
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        let location = convert(event.locationInWindow, from: nil)
        if bounds.contains(location) {
            NSWorkspace.shared.open(url)
        }
    }

    private func updateAppearance() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let baseAlpha: CGFloat = dark ? (isHovering ? 0.06 : 0.03) : (isHovering ? 0.05 : 0.02)
        let base: NSColor = dark ? .white : .black
        layer?.backgroundColor = base.withAlphaComponent(baseAlpha).cgColor
        layer?.borderWidth = AppKitSectionChrome.borderWidth
        layer?.borderColor = AppKitSectionChrome.borderColor(for: effectiveAppearance).cgColor
    }
}
