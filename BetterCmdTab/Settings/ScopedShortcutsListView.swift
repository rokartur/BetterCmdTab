import AppKit
import BetterShortcuts

/// AltTab-style dynamic list of scoped-switch shortcuts (#74). Replaces the old
/// fixed 3 slots: the user adds rows with "Add shortcut", removes them with the
/// trailing ×, records a unique trigger per row (the recorder rejects a duplicate
/// combo via BetterShortcuts' conflict alert), picks a scope, and opens the
/// per-shortcut Customize sheet. Self-managed — it owns its rows so it doesn't
/// need a row-removal API from the settings framework; added once to a section
/// via `addContent`.
@MainActor
final class ScopedShortcutsListView: NSView {
    /// Called when the user taps Customize on a row; the host presents the sheet.
    var onCustomize: ((SwitchTarget) -> Void)?
    /// Called after add/remove so the host can refresh anything that depends on
    /// the list (none currently, but keeps the host in the loop).
    var onListChanged: (() -> Void)?

    private let entriesStack = NSStackView()
    private let emptyLabel = NSTextField(wrappingLabelWithString:
        String(localized: "No scoped shortcuts yet. Add one to open the switcher on a subset of windows."))
    private let addButton = NSButton()
    private let scopeOptions: [SwitchScope] = SwitchScope.allCases

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setup()
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    private func setup() {
        entriesStack.orientation = .vertical
        entriesStack.alignment = .leading
        entriesStack.spacing = 8
        entriesStack.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = .systemFont(ofSize: 11)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        addButton.title = String(localized: "Add shortcut")
        addButton.bezelStyle = .rounded
        addButton.controlSize = .small
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        addButton.imagePosition = .imageLeading
        addButton.target = self
        addButton.action = #selector(addEntry)
        addButton.translatesAutoresizingMaskIntoConstraints = false

        let outer = NSStackView(views: [emptyLabel, entriesStack, addButton])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 10
        outer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(outer)
        NSLayoutConstraint.activate([
            outer.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            outer.leadingAnchor.constraint(equalTo: leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: trailingAnchor),
            outer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            entriesStack.widthAnchor.constraint(equalTo: outer.widthAnchor),
        ])
    }

    /// Rebuild every row from the current list. Cheap — the list is tiny and this
    /// only runs on settings open / add / remove, never on the hot path.
    func rebuild() {
        for view in entriesStack.arrangedSubviews {
            entriesStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let entries = Preferences.shared.scopedShortcuts
        emptyLabel.isHidden = !entries.isEmpty
        for entry in entries {
            entriesStack.addArrangedSubview(makeRow(for: entry))
        }
    }

    private func makeRow(for entry: ScopedShortcut) -> NSView {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.controlSize = .small
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.setContentHuggingPriority(.required, for: .horizontal)
        popup.addItems(withTitles: scopeOptions.map(\.displayName))
        if let i = scopeOptions.firstIndex(of: entry.scope) { popup.selectItem(at: i) }
        popup.target = self
        popup.action = #selector(scopeChanged(_:))
        popup.tag = entry.id

        let recorder = BetterShortcuts.RecorderCocoa(for: BetterShortcuts.Name(entry.shortcutName))

        let customize = NSButton(title: String(localized: "Customize…"), target: self, action: #selector(customize(_:)))
        customize.bezelStyle = .rounded
        customize.controlSize = .small
        customize.tag = entry.id

        let remove = NSButton(title: "", target: self, action: #selector(removeEntry(_:)))
        remove.bezelStyle = .rounded
        remove.controlSize = .small
        remove.image = NSImage(systemSymbolName: "trash", accessibilityDescription: String(localized: "Remove"))
        remove.tag = entry.id

        let row = NSStackView(views: [popup, recorder, customize, remove])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    // MARK: - Actions

    @objc private func addEntry() {
        let entry = Preferences.shared.appendScopedShortcut()
        ScopedSwitch.installHandler(for: entry)
        rebuild()
        onListChanged?()
    }

    @objc private func removeEntry(_ sender: NSButton) {
        let id = sender.tag
        if let name = Preferences.shared.removeScopedShortcut(id: id) {
            // Clear the recorded trigger so the (already-installed, now-orphaned)
            // Carbon handler can never fire for this removed entry.
            BetterShortcuts.setShortcut(nil, for: BetterShortcuts.Name(name))
        }
        rebuild()
        onListChanged?()
    }

    @objc private func scopeChanged(_ sender: NSPopUpButton) {
        let idx = sender.indexOfSelectedItem
        guard scopeOptions.indices.contains(idx) else { return }
        Preferences.shared.setScope(scopeOptions[idx], forScopedID: sender.tag)
    }

    @objc private func customize(_ sender: NSButton) {
        onCustomize?(.scoped(sender.tag))
    }
}
