import AppKit
import BetterShortcuts

/// AltTab-style unified switcher-shortcut editor (#74): a tab bar listing every
/// panel-opening shortcut — the two core triggers (Apps, Windows) plus each
/// user-created scoped shortcut — and a "+" to add another. Selecting a tab shows
/// that shortcut's trigger recorder, scope (scoped tabs only), and the full set
/// of per-shortcut options inline (live-persisting). Core tabs can't be removed;
/// scoped tabs have a Remove button. Recording a combo already bound elsewhere is
/// rejected by BetterShortcuts' conflict alert, so every shortcut stays unique.
@MainActor
final class ShortcutsEditorView: NSView {
    private let tabs = NSSegmentedControl()
    private let addButton = NSButton()
    private let detail = NSStackView()
    private let scopeOptions: [SwitchScope] = SwitchScope.allCases

    /// `SwitchTarget` for each tab, in display order.
    private var targets: [SwitchTarget] = []
    private var selectedIndex = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setup()
        rebuildTabs(select: 0)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    private func setup() {
        tabs.segmentStyle = .texturedRounded
        tabs.trackingMode = .selectOne
        tabs.target = self
        tabs.action = #selector(tabChanged)
        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabs.setContentHuggingPriority(.defaultLow, for: .horizontal)

        addButton.bezelStyle = .texturedRounded
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: String(localized: "Add shortcut"))
        addButton.target = self
        addButton.action = #selector(addEntry)
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.setContentHuggingPriority(.required, for: .horizontal)

        let tabRow = NSStackView(views: [tabs, addButton])
        tabRow.orientation = .horizontal
        tabRow.spacing = 8
        tabRow.alignment = .centerY
        tabRow.translatesAutoresizingMaskIntoConstraints = false

        detail.orientation = .vertical
        detail.alignment = .leading
        detail.spacing = 12
        detail.translatesAutoresizingMaskIntoConstraints = false

        let outer = NSStackView(views: [tabRow, detail])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 14
        outer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(outer)
        NSLayoutConstraint.activate([
            outer.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            outer.leadingAnchor.constraint(equalTo: leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: trailingAnchor),
            outer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            tabRow.widthAnchor.constraint(lessThanOrEqualTo: outer.widthAnchor),
            detail.widthAnchor.constraint(equalTo: outer.widthAnchor),
        ])
    }

    // MARK: - Tabs

    /// Rebuild the tab list from the current model and select `select` (clamped).
    func rebuildTabs(select index: Int) {
        targets = [.switchApps, .switchWindows] + Preferences.shared.scopedShortcuts.map { .scoped($0.id) }
        tabs.segmentCount = targets.count
        for (i, target) in targets.enumerated() {
            tabs.setLabel(label(for: target, at: i), forSegment: i)
            tabs.setWidth(0, forSegment: i) // auto-size to label
        }
        selectedIndex = max(0, min(index, targets.count - 1))
        tabs.selectedSegment = selectedIndex
        rebuildDetail()
    }

    /// Tab label: core triggers by name, scoped ones as "Shortcut N" (1-based tab
    /// position) to match AltTab.
    private func label(for target: SwitchTarget, at index: Int) -> String {
        switch target {
        case .switchApps: return String(localized: "Apps")
        case .switchWindows: return String(localized: "Windows")
        case .scoped: return String(localized: "Shortcut \(index + 1)")
        }
    }

    private func currentTarget() -> SwitchTarget? {
        targets.indices.contains(selectedIndex) ? targets[selectedIndex] : nil
    }

    private func betterShortcutsName(for target: SwitchTarget) -> BetterShortcuts.Name {
        switch target {
        case .switchApps: return .switchApps
        case .switchWindows: return .switchWindows
        case .scoped(let id):
            let name = Preferences.shared.scopedShortcuts.first(where: { $0.id == id })?.shortcutName ?? "scopedSwitch.\(id)"
            return BetterShortcuts.Name(name)
        }
    }

    // MARK: - Detail panel

    private func rebuildDetail() {
        for view in detail.arrangedSubviews {
            detail.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        guard let target = currentTarget() else { return }

        // Trigger recorder.
        let recorder = BetterShortcuts.RecorderCocoa(for: betterShortcutsName(for: target))
        detail.addArrangedSubview(labeledRow(String(localized: "Trigger"), recorder))

        // Scope picker (scoped tabs only — the core triggers have a fixed window set).
        let isScoped: Bool
        if case .scoped(let id) = target {
            isScoped = true
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.controlSize = .small
            popup.addItems(withTitles: scopeOptions.map(\.displayName))
            if let entry = Preferences.shared.scopedShortcuts.first(where: { $0.id == id }),
               let i = scopeOptions.firstIndex(of: entry.scope) {
                popup.selectItem(at: i)
            }
            popup.target = self
            popup.action = #selector(scopeChanged(_:))
            popup.tag = id
            detail.addArrangedSubview(labeledRow(String(localized: "Show from"), popup))
        } else {
            isScoped = false
        }

        // Inline options form. Core triggers can override the Space scope (they
        // have no scope picker); scoped tabs let their scope own it, so the form
        // omits the Space-scope control to avoid double-filtering.
        let form = ShortcutOptionsFormView(target: target, includeSpaceScope: !isScoped)
        detail.addArrangedSubview(form)

        if case .scoped(let id) = target {
            let remove = NSButton(title: String(localized: "Remove shortcut"), target: self, action: #selector(removeEntry(_:)))
            remove.bezelStyle = .rounded
            remove.controlSize = .small
            remove.contentTintColor = .systemRed
            remove.tag = id
            detail.addArrangedSubview(remove)
        }
    }

    private func labeledRow(_ title: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.widthAnchor.constraint(equalToConstant: 90).isActive = true
        control.translatesAutoresizingMaskIntoConstraints = false
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.spacing = 12
        row.alignment = .centerY
        return row
    }

    // MARK: - Actions

    @objc private func tabChanged() {
        selectedIndex = tabs.selectedSegment
        rebuildDetail()
    }

    @objc private func addEntry() {
        let entry = Preferences.shared.appendScopedShortcut()
        ScopedSwitch.installHandler(for: entry)
        // Select the new tab (last).
        rebuildTabs(select: targets.count) // count grows by one after rebuild
    }

    @objc private func removeEntry(_ sender: NSButton) {
        let id = sender.tag
        if let name = Preferences.shared.removeScopedShortcut(id: id) {
            // Clear the recorded trigger so the orphaned Carbon handler can't fire.
            BetterShortcuts.setShortcut(nil, for: BetterShortcuts.Name(name))
        }
        rebuildTabs(select: selectedIndex - 1)
    }

    @objc private func scopeChanged(_ sender: NSPopUpButton) {
        let idx = sender.indexOfSelectedItem
        guard scopeOptions.indices.contains(idx) else { return }
        Preferences.shared.setScope(scopeOptions[idx], forScopedID: sender.tag)
    }
}
