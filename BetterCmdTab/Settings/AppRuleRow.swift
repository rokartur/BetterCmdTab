import AppKit

/// One app's rules as a compact, single-line card row: app icon, name, and both
/// controls always visible — "Show" (when it appears in the switcher) and
/// "⌘Tab" (whether the app keeps the trigger for itself) — plus a remove button.
/// No disclosure: everything is on screen at once. Owned by
/// `AppsSettingsViewController`, laid out inside a `SettingsSectionView` card.
@MainActor
final class AppRuleRowView: NSView {

    let bundleID: String

    /// Fired after either popup changes, with the row's new modes.
    var onChange: ((HideWindowsMode, IgnoreShortcutsMode) -> Void)?
    /// Fired when the remove button is clicked.
    var onRemove: (() -> Void)?

    private let showOptions: [(mode: HideWindowsMode, title: String)]
    private let shortcutOptions: [(mode: IgnoreShortcutsMode, title: String)]
    private var hide: HideWindowsMode
    private var ignore: IgnoreShortcutsMode

    private let showPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let shortcutPopup = NSPopUpButton(frame: .zero, pullsDown: false)

    init(
        bundleID: String,
        name: String,
        icon: NSImage,
        hide: HideWindowsMode,
        ignore: IgnoreShortcutsMode,
        showOptions: [(mode: HideWindowsMode, title: String)],
        shortcutOptions: [(mode: IgnoreShortcutsMode, title: String)]
    ) {
        self.bundleID = bundleID
        self.hide = hide
        self.ignore = ignore
        self.showOptions = showOptions
        self.shortcutOptions = shortcutOptions
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build(name: name, icon: icon)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    private func build(name: String, icon: NSImage) {
        let iconView = NSImageView()
        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        configure(showPopup, titles: showOptions.map(\.title), selected: showOptions.firstIndex { $0.mode == hide } ?? 0, action: #selector(showChanged))
        showPopup.toolTip = String(localized: "When this app appears in the switcher")

        configure(shortcutPopup, titles: shortcutOptions.map(\.title), selected: shortcutOptions.firstIndex { $0.mode == ignore } ?? 0, action: #selector(shortcutChanged))
        shortcutPopup.toolTip = String(localized: "Pass ⌘Tab through to the app instead of opening the switcher — for apps with their own window switching (virtual machines, remote desktop, some games).")

        let removeButton = NSButton()
        removeButton.isBordered = false
        removeButton.bezelStyle = .accessoryBarAction
        removeButton.imagePosition = .imageOnly
        removeButton.image = NSImage(systemSymbolName: "minus.circle.fill", accessibilityDescription: String(localized: "Remove rule"))?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        removeButton.contentTintColor = .tertiaryLabelColor
        removeButton.toolTip = String(localized: "Remove this rule")
        removeButton.target = self
        removeButton.action = #selector(removeClicked)
        removeButton.translatesAutoresizingMaskIntoConstraints = false
        removeButton.setContentHuggingPriority(.required, for: .horizontal)

        let showGroup = captionedControl(String(localized: "Show"), info: Self.showInfo, showPopup)
        let shortcutGroup = captionedControl("⌘Tab", info: Self.shortcutInfo, shortcutPopup)

        let stack = NSStackView(views: [iconView, nameLabel, NSView(), showGroup, shortcutGroup, removeButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.setCustomSpacing(14, after: showGroup)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 26),
            iconView.heightAnchor.constraint(equalToConstant: 26),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    private func configure(_ popup: NSPopUpButton, titles: [String], selected: Int, action: Selector) {
        popup.controlSize = .small
        popup.font = .systemFont(ofSize: 11)
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.setContentHuggingPriority(.required, for: .horizontal)
        popup.setContentCompressionResistancePriority(.required, for: .horizontal)
        popup.removeAllItems()
        popup.addItems(withTitles: titles)
        popup.selectItem(at: selected)
        popup.target = self
        popup.action = action
    }

    /// A small gray caption + an ⓘ info button immediately left of a control,
    /// kept as a tight group. The info button opens a popover explaining the
    /// control's options.
    private func captionedControl(_ caption: String, info: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: caption)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)

        let infoButton = InfoButton(text: info)

        let group = NSStackView(views: [label, infoButton, control])
        group.orientation = .horizontal
        group.alignment = .centerY
        group.spacing = 6
        group.setCustomSpacing(3, after: label)
        group.setHuggingPriority(.required, for: .horizontal)
        return group
    }

    private static let showInfo =
        String(localized: "Controls whether this app shows up in the switcher.\n\n• Always — always listed.\n• With open windows — listed only while it has at least one open window.\n• Never — never listed (hidden from the switcher).")
    private static let shortcutInfo =
        String(localized: "Lets the app keep ⌘Tab for itself: the chord is passed through to the app instead of opening the switcher. Useful for apps with their own window switching — virtual machines, remote desktop, some games.\n\n• Never — the switcher always opens.\n• Always — the app keeps ⌘Tab whenever it's focused.\n• In full screen — only while the app is in full screen.")

    // MARK: - Actions

    @objc private func showChanged() {
        let idx = showPopup.indexOfSelectedItem
        guard showOptions.indices.contains(idx) else { return }
        hide = showOptions[idx].mode
        onChange?(hide, ignore)
    }

    @objc private func shortcutChanged() {
        let idx = shortcutPopup.indexOfSelectedItem
        guard shortcutOptions.indices.contains(idx) else { return }
        ignore = shortcutOptions[idx].mode
        onChange?(hide, ignore)
    }

    @objc private func removeClicked() {
        onRemove?()
    }
}

/// Full-width "Add App…" affordance shown as the last row of the App rules card.
/// Borderless accent button with a leading plus, matching System Settings'
/// "Add …" rows.
@MainActor
final class AddAppRowView: NSView {
    private let button = NSButton()
    var onClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.imagePosition = .imageLeading
        button.image = NSImage(systemSymbolName: "plus.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        button.contentTintColor = .controlAccentColor
        button.attributedTitle = NSAttributedString(string: String(localized: " Add App…"), attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.controlAccentColor,
        ])
        button.target = self
        button.action = #selector(clicked)
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            button.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            button.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    @objc private func clicked() { onClick?() }
}

/// Small ⓘ button that toggles a transient popover explaining a control's
/// options. Reused next to the "Show" and "⌘Tab" captions.
@MainActor
final class InfoButton: NSButton {
    private let infoText: String
    private let popover = NSPopover()

    init(text: String) {
        self.infoText = text
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .accessoryBarAction
        imagePosition = .imageOnly
        image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: String(localized: "More info"))?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        contentTintColor = .tertiaryLabelColor
        setContentHuggingPriority(.required, for: .horizontal)
        translatesAutoresizingMaskIntoConstraints = false
        target = self
        action = #selector(toggle)
        popover.behavior = .transient
        popover.animates = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    @objc private func toggle() {
        if popover.isShown {
            popover.close()
            return
        }
        popover.contentViewController = InfoPopoverViewController(text: infoText)
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
    }
}

/// Popover body: a padded, wrapping explanation label at a fixed width.
@MainActor
final class InfoPopoverViewController: NSViewController {
    private let text: String
    private static let contentWidth: CGFloat = 240

    init(text: String) {
        self.text = text
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func loadView() {
        let root = NSView()
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11.5)
        label.textColor = .labelColor
        label.isSelectable = false
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = Self.contentWidth
        label.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(label)
        NSLayoutConstraint.activate([
            label.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            label.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            label.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            label.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])
        view = root
    }
}
