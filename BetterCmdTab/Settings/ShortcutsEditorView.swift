import AppKit
import BetterSettings
import BetterShortcuts

/// AltTab-style unified switcher-shortcut editor (#74), built from the app's own
/// settings section cards + rows so it matches the Appearance pane. A segmented
/// tab bar lists every panel-opening shortcut — the two core triggers (Apps,
/// Windows) plus each user-created scoped shortcut — with +/− to add and remove.
/// Selecting a tab shows that shortcut's Trigger card (recorder + scope) and its
/// inline Behavior / Appearance option cards, all live-persisting. Core tabs
/// can't be removed; recording a combo already bound elsewhere is rejected by
/// BetterShortcuts' conflict alert, so every shortcut stays unique.
///
/// Switching is instant: each tab's detail panel is built once and cached, then
/// shown/hidden — no teardown/rebuild on tab change.
@MainActor
final class ShortcutsEditorView: NSView {
    private let header = NSTextField(labelWithString: String(localized: "Switcher shortcuts"))
    private let list = ShortcutsListView()
    /// Holds every built detail panel; only the selected one is unhidden, so the
    /// stack lays out just that panel (detachesHiddenViews is on by default).
    private let detailContainer = NSStackView()

    private let scopeOptions: [SwitchScope] = SwitchScope.allCases

    /// `SwitchTarget` for each list item, in display order.
    private var targets: [SwitchTarget] = []
    private var selectedIndex = 0
    /// Cached detail panel per item, keyed by `SwitchTarget.storageKey`.
    private var detailCache: [String: NSView] = [:]
    private var visibleKey: String?
    private var shortcutChangeObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setup()
        // The list/panels are built on first `reload()` (always called from the
        // host controller's `viewWillAppear` before the pane shows), so don't
        // build here too — that work would just be torn down and rebuilt.
        // Keep each list row's trigger label live as the user records shortcuts.
        shortcutChangeObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("BetterShortcuts_shortcutByNameDidChange"),
            object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.refreshListItems() } }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    deinit {
        if let shortcutChangeObserver { NotificationCenter.default.removeObserver(shortcutChangeObserver) }
    }

    /// Drop every cached panel and rebuild from the live model — used when the
    /// pane re-appears (another pane, e.g. Import settings, may have rewritten the
    /// list/overrides off-screen). In-session tab switches use the cache instead,
    /// so they stay instant.
    func reload() {
        for (_, view) in detailCache {
            detailContainer.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        detailCache.removeAll()
        visibleKey = nil
        rebuildTabs(select: 0)
    }

    private func setup() {
        header.font = .systemFont(ofSize: 14, weight: .bold)
        header.textColor = .labelColor
        header.translatesAutoresizingMaskIntoConstraints = false

        list.translatesAutoresizingMaskIntoConstraints = false
        list.onSelect = { [weak self] index in
            self?.selectedIndex = index
            self?.showSelected()
        }
        list.onAdd = { [weak self] in self?.addEntry() }
        list.onRemove = { [weak self] in self?.removeEntry() }

        detailContainer.orientation = .vertical
        detailContainer.alignment = .leading
        detailContainer.spacing = 18
        detailContainer.translatesAutoresizingMaskIntoConstraints = false

        let outer = NSStackView(views: [header, list, detailContainer])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 12
        outer.setCustomSpacing(16, after: list)
        outer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(outer)
        NSLayoutConstraint.activate([
            outer.topAnchor.constraint(equalTo: topAnchor),
            outer.leadingAnchor.constraint(equalTo: leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: trailingAnchor),
            outer.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.leadingAnchor.constraint(equalTo: outer.leadingAnchor, constant: 4),
            list.widthAnchor.constraint(equalTo: outer.widthAnchor),
            detailContainer.widthAnchor.constraint(equalTo: outer.widthAnchor),
        ])
    }

    // MARK: - List

    /// Rebuild the shortcut list from the current model and select `select`
    /// (clamped). Called on first load and after add/remove; drops cached panels
    /// for items that no longer exist. Plain selection changes go through
    /// `showSelected` and reuse the cache, so they stay instant.
    func rebuildTabs(select index: Int) {
        targets = [.switchApps, .switchWindows] + Preferences.shared.scopedShortcuts.map { .scoped($0.id) }

        // Drop cached panels whose target is gone (removed scoped shortcut).
        let valid = Set(targets.map(\.storageKey))
        for (key, view) in detailCache where !valid.contains(key) {
            detailContainer.removeArrangedSubview(view)
            view.removeFromSuperview()
            detailCache[key] = nil
            if visibleKey == key { visibleKey = nil }
        }

        selectedIndex = max(0, min(index, targets.count - 1))
        list.reload(items: listItems(), selectedIndex: selectedIndex)
        showSelected()
    }

    /// Rebuild just the list items (keeping the selection) — used when a recorded
    /// trigger changes so each row's trailing glyph stays current.
    private func refreshListItems() {
        guard !targets.isEmpty else { return }
        list.reload(items: listItems(), selectedIndex: selectedIndex)
    }

    private func listItems() -> [ShortcutsListView.Item] {
        targets.enumerated().map { index, target in
            ShortcutsListView.Item(
                icon: icon(for: target),
                title: label(for: target, at: index),
                detail: detail(for: target),
                removable: isScoped(target)
            )
        }
    }

    /// List label: core triggers by name, scoped ones as "Shortcut N" (1-based
    /// position) to match AltTab.
    private func label(for target: SwitchTarget, at index: Int) -> String {
        switch target {
        case .switchApps: return String(localized: "Apps")
        case .switchWindows: return String(localized: "Windows")
        case .scoped: return String(localized: "Shortcut \(index + 1)")
        }
    }

    private func icon(for target: SwitchTarget) -> String {
        switch target {
        case .switchApps: return "command"
        case .switchWindows: return "macwindow"
        case .scoped: return "rectangle.on.rectangle"
        }
    }

    /// Trailing detail: the recorded trigger's glyphs, plus the scope for a scoped
    /// shortcut. Empty when nothing is recorded yet.
    private func detail(for target: SwitchTarget) -> String {
        var parts: [String] = []
        if let shortcut = betterShortcutsName(for: target).shortcut { parts.append("\(shortcut)") }
        if case .scoped(let id) = target,
           let scope = Preferences.shared.scopedShortcuts.first(where: { $0.id == id })?.scope {
            parts.append(scope.displayName)
        }
        return parts.joined(separator: "  ·  ")
    }

    private func currentTarget() -> SwitchTarget? {
        targets.indices.contains(selectedIndex) ? targets[selectedIndex] : nil
    }

    private func isScoped(_ target: SwitchTarget) -> Bool {
        if case .scoped = target { return true }
        return false
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

    // MARK: - Detail panel (cached for instant switching)

    /// Show the selected tab's detail panel, building+caching it on first visit
    /// and just toggling visibility on every later switch.
    private func showSelected() {
        guard let target = currentTarget() else { return }
        let key = target.storageKey
        let panel: NSView
        if let cached = detailCache[key] {
            panel = cached
        } else {
            panel = buildDetail(for: target)
            panel.isHidden = true
            detailCache[key] = panel
            detailContainer.addArrangedSubview(panel)
            panel.widthAnchor.constraint(equalTo: detailContainer.widthAnchor).isActive = true
        }
        if visibleKey != key {
            if let prev = visibleKey, let prevView = detailCache[prev] { prevView.isHidden = true }
            panel.isHidden = false
            visibleKey = key
        }
    }

    private func buildDetail(for target: SwitchTarget) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scoped = isScoped(target)

        // Trigger card.
        let trigger = SettingsSectionView(title: String(localized: "Trigger"))
        // Main switcher triggers (switchApps / switchWindows) DEFINE the reserved
        // chords, so they stay bindable; a scoped-switch trigger is just another
        // global slot that must not shadow them (issue #16).
        var triggerPolicy = BetterShortcuts.recorderPolicy
        triggerPolicy.rejectsReservedShortcuts = scoped
        let recorder = BetterShortcuts.RecorderCocoa(for: betterShortcutsName(for: target), policy: triggerPolicy)
        trigger.addContent(SettingsRowView(
            title: String(localized: "Keyboard shortcut"),
            subtitle: scoped
                ? String(localized: "Opens this shortcut's switcher. Hold the modifier and tap.")
                : String(localized: "Hold the modifier (⌘ by default) and tap to step through."),
            accessory: recorder
        ))
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
            trigger.addContent(SettingsRowView(
                title: String(localized: "Show windows from"),
                subtitle: String(localized: "Which windows this shortcut opens onto."),
                accessory: popup
            ))
        }
        addCard(trigger, to: stack)

        // Behavior + Appearance option cards. Core triggers can override the Space
        // scope (no scope picker); scoped tabs let their scope own it, so the form
        // omits the Space-scope row to avoid double-filtering.
        addCard(ShortcutOptionsFormView(target: target, includeSpaceScope: !scoped), to: stack)
        return stack
    }

    private func addCard(_ card: NSView, to stack: NSStackView) {
        card.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    // MARK: - Actions

    private func addEntry() {
        let entry = Preferences.shared.appendScopedShortcut()
        ScopedSwitch.installHandler(for: entry)
        // The new entry lands at index == the old item count, i.e. the new last row.
        rebuildTabs(select: targets.count)
    }

    private func removeEntry() {
        guard case .scoped(let id)? = currentTarget() else { return }
        if let name = Preferences.shared.removeScopedShortcut(id: id) {
            // Free the Carbon handler closure (else it lingers for the app's
            // lifetime), then clear the recorded trigger so it can't fire / persist.
            ScopedSwitch.removeHandler(for: name)
            BetterShortcuts.setShortcut(nil, for: BetterShortcuts.Name(name))
        }
        // Drop this profile's per-profile in-panel keys (#5) so they don't linger
        // as orphaned UserDefaults entries (the scoped id is never reused).
        BetterShortcuts.reset(BetterShortcuts.Name.profilePanelKeys(for: SwitchTarget.scoped(id).storageKey).map(\.name))
        rebuildTabs(select: selectedIndex - 1)
    }

    @objc private func scopeChanged(_ sender: NSPopUpButton) {
        let idx = sender.indexOfSelectedItem
        guard scopeOptions.indices.contains(idx) else { return }
        Preferences.shared.setScope(scopeOptions[idx], forScopedID: sender.tag)
        // Reflect the new scope in the list row's trailing detail.
        refreshListItems()
    }
}
