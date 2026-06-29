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
    private let addButton = NSButton()
    private let removeButton = NSButton()
    private var rows: [ShortcutListRow] = []
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

        configureFooterButton(addButton, symbol: "plus", accessibility: String(localized: "Add shortcut"), action: #selector(addTapped))
        configureFooterButton(removeButton, symbol: "minus", accessibility: String(localized: "Remove shortcut"), action: #selector(removeTapped))
        let footer = NSStackView(views: [addButton, removeButton])
        footer.orientation = .horizontal
        footer.spacing = 0
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

    private func configureFooterButton(_ button: NSButton, symbol: String, accessibility: String, action: Selector) {
        button.bezelStyle = .smallSquare
        button.isBordered = true
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibility)
        button.imagePosition = .imageOnly
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        button.heightAnchor.constraint(equalToConstant: 22).isActive = true
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
        self.selectedIndex = max(0, min(selectedIndex, rows.count - 1))
        applySelection()
        removeButton.isEnabled = items.indices.contains(self.selectedIndex) && items[self.selectedIndex].removable
    }

    private func select(_ index: Int, notify: Bool) {
        selectedIndex = index
        applySelection()
        if notify { onSelect?(index) }
    }

    private func applySelection() {
        for (i, row) in rows.enumerated() { row.isSelected = (i == selectedIndex) }
    }

    @objc private func addTapped() { onAdd?() }
    @objc private func removeTapped() { onRemove?() }
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
