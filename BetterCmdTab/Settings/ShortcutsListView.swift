import AppKit

/// Selectable list of switcher shortcuts (#74) — the master half of the
/// shortcut editor's master/detail. A rounded card of rows (one per shortcut)
/// with an accent selection highlight, plus a +/− footer to add/remove scoped
/// shortcuts. Replaces the old segmented control: a list is the native macOS
/// pattern for picking from a managed collection.
@MainActor
final class ShortcutsListView: NSView {
    struct Item {
        let icon: String
        let title: String
        let detail: String
        let removable: Bool
    }

    /// A row was clicked (index into the last `reload` items).
    var onSelect: ((Int) -> Void)?
    var onAdd: (() -> Void)?
    /// Remove the currently-selected row.
    var onRemove: (() -> Void)?

    private let card = PickerCardView()
    private let rowsStack = NSStackView()
    private let addButton = ListActionButton(symbol: "plus")
    private let removeButton = ListActionButton(symbol: "minus")
    private var rows: [ShortcutListRow] = []
    /// `removable` flag per row, in display order — kept so a row-click selection
    /// can recompute the −button's enabled state without a full `reload`.
    private var removable: [Bool] = []
    private var selectedIndex = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    private func setup() {
        card.translatesAutoresizingMaskIntoConstraints = false
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 2
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(rowsStack)
        NSLayoutConstraint.activate([
            rowsStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 6),
            rowsStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 6),
            rowsStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -6),
            rowsStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -6),
        ])

        addButton.setAccessibilityLabel(String(localized: "Add shortcut"))
        removeButton.setAccessibilityLabel(String(localized: "Remove shortcut"))
        addButton.onClick = { [weak self] in self?.onAdd?() }
        removeButton.onClick = { [weak self] in self?.onRemove?() }
        let footer = NSStackView(views: [addButton, removeButton])
        footer.orientation = .horizontal
        footer.spacing = 6
        footer.translatesAutoresizingMaskIntoConstraints = false

        let outer = NSStackView(views: [card, footer])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 6
        outer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(outer)
        NSLayoutConstraint.activate([
            outer.topAnchor.constraint(equalTo: topAnchor),
            outer.leadingAnchor.constraint(equalTo: leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: trailingAnchor),
            outer.bottomAnchor.constraint(equalTo: bottomAnchor),
            card.widthAnchor.constraint(equalTo: outer.widthAnchor),
        ])
    }

    /// Rebuild the rows and apply the selection.
    func reload(items: [Item], selectedIndex: Int) {
        for row in rows { rowsStack.removeArrangedSubview(row); row.removeFromSuperview() }
        rows = items.enumerated().map { index, item in
            let row = ShortcutListRow(icon: item.icon, title: item.title, detail: item.detail)
            row.onClick = { [weak self] in self?.select(index, notify: true) }
            rowsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
            return row
        }
        removable = items.map(\.removable)
        self.selectedIndex = max(0, min(selectedIndex, rows.count - 1))
        applySelection()
        updateRemoveEnabled()
        addButton.isEnabled = true
    }

    private func select(_ index: Int, notify: Bool) {
        selectedIndex = index
        applySelection()
        updateRemoveEnabled()
        if notify { onSelect?(index) }
    }

    /// Enable − only when the selected row is removable, so a row-click selection
    /// keeps the footer in sync (not just `reload`).
    private func updateRemoveEnabled() {
        removeButton.isEnabled = removable.indices.contains(selectedIndex) && removable[selectedIndex]
    }

    private func applySelection() {
        for (i, row) in rows.enumerated() { row.isSelected = (i == selectedIndex) }
    }
}

/// Compact, modern icon button for the list footer (+/−). A rounded square with
/// the app's subtle section-chrome fill that brightens on hover and press —
/// native-feeling and consistent with the rest of the app, instead of the dated
/// gradient `.smallSquare` push button. Supports a disabled state.
@MainActor
final class ListActionButton: NSView {
    var onClick: (() -> Void)?
    var isEnabled = true { didSet { if oldValue != isEnabled { updateAppearance() } } }

    private let iconView = NSImageView()
    private var trackingArea: NSTrackingArea?
    private var isHovering = false { didSet { if oldValue != isHovering { updateAppearance() } } }
    private var isPressing = false { didSet { if oldValue != isPressing { updateAppearance() } } }

    init(symbol: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        layer?.borderWidth = AppKitSectionChrome.borderWidth

        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        iconView.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 28),
            heightAnchor.constraint(equalToConstant: 24),
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { guard isEnabled else { return }; isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false; isPressing = false }
    override func mouseDown(with event: NSEvent) { guard isEnabled else { return }; isPressing = true }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled else { return }
        let wasPressing = isPressing
        isPressing = false
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        if wasPressing && inside { onClick?() }
    }

    private func updateAppearance() {
        let base = AppKitSectionChrome.fillColor(for: effectiveAppearance)
        let border = AppKitSectionChrome.borderColor(for: effectiveAppearance)
        let boost: CGFloat = isPressing ? 0.08 : (isHovering ? 0.04 : 0)
        layer?.backgroundColor = (base.blended(withFraction: boost, of: .labelColor) ?? base).cgColor
        layer?.borderColor = border.cgColor
        iconView.contentTintColor = .secondaryLabelColor
        alphaValue = isEnabled ? 1 : 0.35
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }
}

/// One selectable shortcut row: leading SF Symbol, title, trailing detail (the
/// recorded trigger / scope). Highlights with the system selection accent when
/// selected and a faint fill on hover, matching the settings sidebar.
@MainActor
final class ShortcutListRow: NSView {
    var onClick: (() -> Void)?

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?
    private var isHovering = false { didSet { if oldValue != isHovering { updateAppearance() } } }

    var isSelected = false { didSet { if oldValue != isSelected { updateAppearance() } } }

    init(icon: String, title: String, detail: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous

        iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        iconView.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        detailLabel.stringValue = detail
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .right
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.setContentHuggingPriority(.required, for: .horizontal)

        let stack = NSStackView(views: [iconView, titleLabel, NSView(), detailLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 18),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 30),
        ])
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }
    override func mouseDown(with event: NSEvent) { onClick?() }

    private func updateAppearance() {
        let bg: NSColor
        if isSelected {
            bg = .selectedContentBackgroundColor
        } else if isHovering {
            bg = NSColor.labelColor.withAlphaComponent(0.06)
        } else {
            bg = .clear
        }
        layer?.backgroundColor = bg.cgColor
        let onAccent = isSelected
        titleLabel.textColor = onAccent ? .white : .labelColor
        detailLabel.textColor = onAccent ? NSColor.white.withAlphaComponent(0.8) : .secondaryLabelColor
        iconView.contentTintColor = onAccent ? .white : .secondaryLabelColor
    }
}
