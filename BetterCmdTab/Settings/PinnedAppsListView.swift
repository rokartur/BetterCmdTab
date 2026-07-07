import AppKit

/// Pure array-move for the pinned-apps drag reorder. Extracted from the view so
/// the drop-index math is unit-testable without a live `NSTableView`.
enum PinnedReorder {
    /// Move the element at `from` to the `.above` drop slot `to`.
    ///
    /// `NSTableView` reports `to` in the *pre-removal* index space (the slot the
    /// dragged row would land in front of), so a downward move has to shift the
    /// destination left by one once the row is pulled out. Out-of-range `from`
    /// is a no-op.
    static func apply(_ ids: [String], movingRowAt from: Int, to row: Int) -> [String] {
        guard ids.indices.contains(from) else { return ids }
        var result = ids
        let item = result.remove(at: from)
        let dest = from < row ? row - 1 : row
        result.insert(item, at: min(max(dest, 0), result.count))
        return result
    }
}

/// A reorderable list of pinned apps, rendered as a content-sized, header-less
/// `NSTableView` so it can sit inside a settings card and let the pane's own
/// scroll view handle overflow. Dragging a row changes the pin order; each row
/// carries a remove button. Ordering is the app's contract — the array index is
/// the switcher pin rank (see `CatalogFilter.pinnedToFront`).
@MainActor
final class PinnedAppsListView: NSView {

    /// Fired with the full new order after a drag reorder.
    var onReorder: (([String]) -> Void)?
    /// Fired with the bundle ID when its remove button is clicked.
    var onRemove: ((String) -> Void)?

    private var bundleIDs: [String] = []
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private var heightConstraint: NSLayoutConstraint!

    private static let rowHeight: CGFloat = 36
    private static let cellID = NSUserInterfaceItemIdentifier("PinnedAppRowCell")
    private static let dragType = NSPasteboard.PasteboardType("pro.bettercmdtab.pinnedapp.row")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    /// Replace the list contents and resize to fit (no inner scrolling).
    func reload(_ ids: [String]) {
        bundleIDs = ids
        tableView.reloadData()
        updateHeight()
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = Self.rowHeight
        tableView.backgroundColor = .clear
        tableView.gridStyleMask = []
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.selectionHighlightStyle = .none
        tableView.style = .plain
        tableView.usesAutomaticRowHeights = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.registerForDraggedTypes([Self.dragType])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.verticalScrollElasticity = .none
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        heightConstraint = scrollView.heightAnchor.constraint(equalToConstant: Self.rowHeight)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightConstraint,
        ])
    }

    private func updateHeight() {
        // N rows = N*rowHeight + (N-1) gaps; no trailing gap after the last row.
        let rows = max(bundleIDs.count, 1)
        let spacing = tableView.intercellSpacing.height
        heightConstraint.constant = CGFloat(rows) * Self.rowHeight + CGFloat(rows - 1) * spacing
    }
}

extension PinnedAppsListView: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { bundleIDs.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard bundleIDs.indices.contains(row) else { return nil }
        let bundleID = bundleIDs[row]
        let cell: PinnedAppRowCellView
        if let reused = tableView.makeView(withIdentifier: Self.cellID, owner: self) as? PinnedAppRowCellView {
            cell = reused
        } else {
            cell = PinnedAppRowCellView(frame: .zero)
            cell.identifier = Self.cellID
        }
        cell.configure(bundleID: bundleID)
        cell.onRemove = { [weak self] in self?.onRemove?(bundleID) }
        return cell
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.dragType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        dropOperation == .above ? .move : []
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                   row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let item = info.draggingPasteboard.pasteboardItems?.first,
              let raw = item.string(forType: Self.dragType),
              let from = Int(raw), bundleIDs.indices.contains(from) else { return false }
        let reordered = PinnedReorder.apply(bundleIDs, movingRowAt: from, to: row)
        guard reordered != bundleIDs else { return false }
        bundleIDs = reordered
        let dest = from < row ? row - 1 : row
        tableView.beginUpdates()
        tableView.moveRow(at: from, to: dest)
        tableView.endUpdates()
        onReorder?(bundleIDs)
        return true
    }
}

/// One pinned-app row: a drag-handle affordance, the app icon and name, and a
/// trailing remove button. Name and icon are resolved off the main actor and
/// spliced in — a cold LaunchServices lookup can hitch the UI (mirrors
/// `AppRuleRowView` / `AppsSettingsViewController.makeRow`).
@MainActor
final class PinnedAppRowCellView: NSTableCellView {

    /// Fired when the remove button is clicked.
    var onRemove: (() -> Void)?

    private let handle = NSImageView()
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let removeButton = NSButton()
    private var bundleID = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    func configure(bundleID: String) {
        self.bundleID = bundleID
        // Placeholder now; resolve the real name + icon off the main actor.
        iconView.image = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
        nameLabel.stringValue = bundleID
        DispatchQueue.global(qos: .userInitiated).async {
            let info = AppsSettingsViewController.appInfo(for: bundleID)
            DispatchQueue.main.async { [weak self] in
                // Cell reuse: only splice if this cell still represents the same app.
                guard let self, self.bundleID == bundleID else { return }
                info.icon.size = NSSize(width: 22, height: 22)
                self.iconView.image = info.icon
                self.nameLabel.stringValue = info.name
            }
        }
    }

    private func setup() {
        handle.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: String(localized: "Drag to reorder"))?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        handle.contentTintColor = .tertiaryLabelColor
        handle.toolTip = String(localized: "Drag to reorder")
        handle.setContentHuggingPriority(.required, for: .horizontal)

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        removeButton.isBordered = false
        removeButton.bezelStyle = .accessoryBarAction
        removeButton.imagePosition = .imageOnly
        removeButton.image = NSImage(systemSymbolName: "minus.circle.fill", accessibilityDescription: String(localized: "Remove from pinned"))?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        removeButton.contentTintColor = .tertiaryLabelColor
        removeButton.toolTip = String(localized: "Remove from pinned")
        removeButton.target = self
        removeButton.action = #selector(removeClicked)
        removeButton.setContentHuggingPriority(.required, for: .horizontal)

        let stack = NSStackView(views: [handle, iconView, nameLabel, NSView(), removeButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 22),
            iconView.heightAnchor.constraint(equalToConstant: 22),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
        ])
    }

    @objc private func removeClicked() { onRemove?() }
}
