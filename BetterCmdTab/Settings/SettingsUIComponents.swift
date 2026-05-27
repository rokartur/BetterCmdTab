import AppKit
import QuartzCore

// App-specific settings UI helpers that complement the shared `BetterSettings`
// package (which now provides the window, sidebar, search, section cards and
// rows). Kept here: a flipped helper, shared section chrome colors, the radio
// group / labeled block, and the About tab's capsule + quick-link cards.

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

// MARK: - Radio group with title + subtitle per option

/// Vertical group of radio buttons where each option carries an optional
/// secondary explanation under the title. Used in Settings to give choices
/// (e.g. switcher layout) more context than a bare popup.
@MainActor
final class SettingsRadioGroupView: NSView {

    struct Option {
        let identifier: String
        let title: String
        let subtitle: String?

        init(identifier: String, title: String, subtitle: String? = nil) {
            self.identifier = identifier
            self.title = title
            self.subtitle = subtitle
        }
    }

    var onSelectionChange: ((String) -> Void)?

    private let stack: NSStackView = {
        let s = NSStackView()
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 10
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }()

    private var buttonsByIdentifier: [String: NSButton] = [:]

    init(options: [Option], selected: String? = nil, orientation: NSUserInterfaceLayoutOrientation = .vertical) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let horizontal = (orientation == .horizontal)
        stack.orientation = orientation
        if horizontal {
            // Side-by-side options: center them on a single baseline and let the
            // group hug its content at the leading edge. Per-option subtitles are
            // dropped here (they have no room in a row) — context belongs in the
            // surrounding block's description instead.
            stack.alignment = .centerY
            stack.spacing = 18
        }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            horizontal
                ? stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor)
                : stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        for option in options {
            let row = makeOptionRow(option, showsSubtitle: !horizontal, hugsWidth: horizontal)
            stack.addArrangedSubview(row)
            if !horizontal {
                row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
        }

        if let selected {
            select(identifier: selected, notify: false)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func select(identifier: String, notify: Bool = false) {
        for (id, button) in buttonsByIdentifier {
            button.state = (id == identifier) ? .on : .off
        }
        if notify { onSelectionChange?(identifier) }
    }

    var selectedIdentifier: String? {
        buttonsByIdentifier.first(where: { $0.value.state == .on })?.key
    }

    private func makeOptionRow(_ option: Option, showsSubtitle: Bool = true, hugsWidth: Bool = false) -> NSView {
        let button = NSButton(radioButtonWithTitle: option.title, target: self, action: #selector(radioChanged(_:)))
        button.font = .systemFont(ofSize: 13)
        button.identifier = NSUserInterfaceItemIdentifier(option.identifier)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentHuggingPriority(hugsWidth ? .required : .defaultLow, for: .horizontal)
        buttonsByIdentifier[option.identifier] = button

        let normalizedSubtitle = option.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasSubtitle = showsSubtitle && !(normalizedSubtitle?.isEmpty ?? true)

        let container = FlippedView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(button)

        var constraints: [NSLayoutConstraint] = [
            button.topAnchor.constraint(equalTo: container.topAnchor),
            button.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            // When hugging (horizontal row) the container must size to the
            // button, so pin trailing exactly; otherwise leave slack for the
            // full-width vertical rows.
            hugsWidth
                ? button.trailingAnchor.constraint(equalTo: container.trailingAnchor)
                : button.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
        ]

        if hasSubtitle {
            let subtitle = NSTextField(wrappingLabelWithString: normalizedSubtitle ?? "")
            subtitle.font = .systemFont(ofSize: 11)
            subtitle.textColor = .secondaryLabelColor
            subtitle.isSelectable = false
            subtitle.maximumNumberOfLines = 0
            subtitle.translatesAutoresizingMaskIntoConstraints = false
            subtitle.setContentHuggingPriority(.defaultLow, for: .horizontal)
            container.addSubview(subtitle)

            constraints.append(contentsOf: [
                subtitle.topAnchor.constraint(equalTo: button.bottomAnchor, constant: 2),
                subtitle.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 19),
                subtitle.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                subtitle.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        } else {
            constraints.append(button.bottomAnchor.constraint(equalTo: container.bottomAnchor))
        }

        NSLayoutConstraint.activate(constraints)
        return container
    }

    @objc private func radioChanged(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        select(identifier: id, notify: true)
    }
}

// MARK: - Labeled block (inline title + description above arbitrary content)

/// A block inside a settings card that puts a small inline title and an
/// optional description above a content view (e.g. a radio group). Useful
/// when a single setting needs more explanation than a row subtitle can fit.
@MainActor
final class SettingsLabeledBlockView: NSView {

    init(title: String, description: String?, content: NSView) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setupViews(title: title, description: description, content: content)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func setupViews(title: String, description: String?, content: NSView) {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(titleLabel)

        if let description, !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let descLabel = NSTextField(wrappingLabelWithString: description)
            descLabel.font = .systemFont(ofSize: 11)
            descLabel.textColor = .secondaryLabelColor
            descLabel.isSelectable = false
            descLabel.maximumNumberOfLines = 0
            descLabel.translatesAutoresizingMaskIntoConstraints = false
            descLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
            stack.addArrangedSubview(descLabel)
            descLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        content.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(content)
        stack.setCustomSpacing(12, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 2])
        content.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
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
