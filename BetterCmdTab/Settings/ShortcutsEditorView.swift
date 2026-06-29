import AppKit
import BetterSettings
import BetterShortcuts

/// AltTab-style unified switcher-shortcut editor (#74), built from the app's own
/// settings section cards + rows so it matches the Appearance pane. A segmented
/// tab bar lists every panel-opening shortcut — the two core triggers (Apps,
/// Windows) plus each user-created scoped shortcut — with +/− to add and remove.
/// Selecting a tab shows that shortcut's Trigger card (recorder + scope) and its
/// inline Behavior / Appearance option cards, all live-persisting. Core tabs
/// can't be removed. Recording a combo already bound elsewhere is rejected by
/// BetterShortcuts' conflict alert, so every shortcut stays unique.
@MainActor
final class ShortcutsEditorView: NSView {
    private let tabs = NSSegmentedControl()
    private let addButton = NSButton()
    private let removeButton = NSButton()
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
        tabs.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        configureIconButton(addButton, symbol: "plus", accessibility: String(localized: "Add shortcut"), action: #selector(addEntry))
        configureIconButton(removeButton, symbol: "minus", accessibility: String(localized: "Remove shortcut"), action: #selector(removeEntry))

        let tabRow = NSStackView(views: [tabs, addButton, removeButton])
        tabRow.orientation = .horizontal
        tabRow.spacing = 6
        tabRow.alignment = .centerY
        tabRow.translatesAutoresizingMaskIntoConstraints = false

        detail.orientation = .vertical
        detail.alignment = .leading
        detail.spacing = 18
        detail.translatesAutoresizingMaskIntoConstraints = false

        let outer = NSStackView(views: [tabRow, detail])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 16
        outer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(outer)
        NSLayoutConstraint.activate([
            outer.topAnchor.constraint(equalTo: topAnchor),
            outer.leadingAnchor.constraint(equalTo: leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: trailingAnchor),
            outer.bottomAnchor.constraint(equalTo: bottomAnchor),
            detail.widthAnchor.constraint(equalTo: outer.widthAnchor),
        ])
    }

    private func configureIconButton(_ button: NSButton, symbol: String, accessibility: String, action: Selector) {
        button.bezelStyle = .texturedRounded
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibility)
        button.imagePosition = .imageOnly
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentHuggingPriority(.required, for: .horizontal)
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
        guard let target = currentTarget() else {
            removeButton.isEnabled = false
            return
        }

        var isScoped = false
        if case .scoped = target { isScoped = true }
        removeButton.isEnabled = isScoped

        // Trigger card.
        let trigger = SettingsSectionView(title: String(localized: "Trigger"))
        let recorder = BetterShortcuts.RecorderCocoa(for: betterShortcutsName(for: target))
        addRow(to: trigger, title: String(localized: "Keyboard shortcut"),
               subtitle: isScoped
                   ? String(localized: "Opens this shortcut's switcher. Hold the modifier and tap.")
                   : String(localized: "Hold the modifier (⌘ by default) and tap to step through."),
               accessory: recorder)

        if case .scoped(let id) = target {
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.controlSize = .small
            popup.translatesAutoresizingMaskIntoConstraints = false
            popup.setContentHuggingPriority(.required, for: .horizontal)
            popup.addItems(withTitles: scopeOptions.map(\.displayName))
            if let entry = Preferences.shared.scopedShortcuts.first(where: { $0.id == id }),
               let i = scopeOptions.firstIndex(of: entry.scope) {
                popup.selectItem(at: i)
            }
            popup.target = self
            popup.action = #selector(scopeChanged(_:))
            popup.tag = id
            addRow(to: trigger, title: String(localized: "Show windows from"),
                   subtitle: String(localized: "Which windows this shortcut opens onto."),
                   accessory: popup)
        }
        addCard(trigger)

        // Behavior + Appearance option cards. Core triggers can override the Space
        // scope (they have no scope picker); scoped tabs let their scope own it, so
        // the form omits the Space-scope row to avoid double-filtering.
        addCard(ShortcutOptionsFormView(target: target, includeSpaceScope: !isScoped))
    }

    private func addRow(to section: SettingsSectionView, title: String, subtitle: String?, accessory: NSView) {
        section.addContent(SettingsRowView(title: title, subtitle: subtitle, accessory: accessory))
    }

    private func addCard(_ card: NSView) {
        card.translatesAutoresizingMaskIntoConstraints = false
        detail.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: detail.widthAnchor).isActive = true
    }

    // MARK: - Actions

    @objc private func tabChanged() {
        selectedIndex = tabs.selectedSegment
        rebuildDetail()
    }

    @objc private func addEntry() {
        let entry = Preferences.shared.appendScopedShortcut()
        ScopedSwitch.installHandler(for: entry)
        // The new entry lands at index == the old tab count, i.e. the new last tab.
        rebuildTabs(select: targets.count)
    }

    @objc private func removeEntry() {
        guard case .scoped(let id)? = currentTarget() else { return }
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
