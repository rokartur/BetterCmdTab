import AppKit
import BetterSettings
import BetterShortcuts

/// Inline, live-persisting per-shortcut options (#74), laid out as the app's
/// standard settings section cards + rows so it matches the Appearance pane
/// exactly. Every option is a titled row whose accessory is a small popup; its
/// first item, "Use global default", leaves the field unset so the shortcut
/// inherits the global preference. Each change writes straight to
/// `Preferences.shortcutOverrides` — no draft / Done step (AltTab-style).
///
/// The view is a vertical stack of two `SettingsSectionView` cards (Behavior,
/// Appearance); `ShortcutsEditorView` stacks it under the Trigger card.
@MainActor
final class ShortcutOptionsFormView: NSView {
    private let target: SwitchTarget
    private let includeSpaceScope: Bool
    private var override: ShortcutOverride
    private let prefs = Preferences.shared
    private let stack = NSStackView()
    private var actionTargets: [ClosureActionTarget] = []

    private static let useGlobal = String(localized: "Use global default")

    init(target: SwitchTarget, includeSpaceScope: Bool) {
        self.target = target
        self.includeSpaceScope = includeSpaceScope
        self.override = Preferences.shared.override(for: target)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        buildCards()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    private func persist() { prefs.setOverride(override, for: target) }

    private func addCard(_ section: SettingsSectionView) {
        stack.addArrangedSubview(section)
        section.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func buildCards() {
        // MARK: Behavior
        let behavior = SettingsSectionView(title: String(localized: "Behavior"))
        if includeSpaceScope {
            addEnumRow(to: behavior, title: String(localized: "Spaces"),
                       subtitle: String(localized: "Limit this shortcut to the current Space, or show every Space."),
                       options: [.currentSpace, .allSpaces] as [SpaceScopeOverride],
                       display: { $0.displayName },
                       current: override.spaceScope == .inherit ? nil : override.spaceScope) { [weak self] in
                self?.override.spaceScope = $0 ?? .inherit; self?.persist()
            }
        }
        addBoolRow(to: behavior, title: String(localized: "Show minimized windows"), current: override.showMinimized) { [weak self] in self?.override.showMinimized = $0; self?.persist() }
        addBoolRow(to: behavior, title: String(localized: "Show hidden apps"), current: override.showHidden) { [weak self] in self?.override.showHidden = $0; self?.persist() }
        addBoolRow(to: behavior, title: String(localized: "Show apps without windows"), current: override.showWindowless) { [weak self] in self?.override.showWindowless = $0; self?.persist() }
        addEnumRow(to: behavior, title: String(localized: "Sort order"),
                   subtitle: String(localized: "Most recent keeps the classic ⌘Tab order; the others stay put."),
                   options: SwitcherSortOrder.allCases, display: { $0.displayName }, current: override.sortOrder) { [weak self] in self?.override.sortOrder = $0; self?.persist() }
        addBoolRow(to: behavior, title: String(localized: "Applications only"),
                   subtitle: String(localized: "One row per app instead of one per window."),
                   current: override.applicationsOnly) { [weak self] in self?.override.applicationsOnly = $0; self?.persist() }
        addBoolRow(to: behavior, title: String(localized: "Expand browser tabs as windows"), current: override.expandBrowserTabsAsWindows) { [weak self] in self?.override.expandBrowserTabsAsWindows = $0; self?.persist() }
        addCard(behavior)

        // MARK: Appearance
        let appearance = SettingsSectionView(title: String(localized: "Appearance"))
        addEnumRow(to: appearance, title: String(localized: "Layout"), options: [.gridView, .list, .windowPreview] as [SwitcherLayoutMode], display: { $0.displayName }, current: override.layoutMode) { [weak self] in self?.override.layoutMode = $0; self?.persist() }
        addEnumRow(to: appearance, title: String(localized: "Size"), options: PanelSize.allCases, display: { $0.displayName }, current: override.panelSize) { [weak self] in self?.override.panelSize = $0; self?.persist() }
        addIntRow(to: appearance, title: String(localized: "Grid columns"),
                  subtitle: String(localized: "Applies to the Grid and Previews layouts."),
                  values: [0, 2, 3, 4, 5, 6], display: { $0 == 0 ? String(localized: "Automatic") : "\($0)" }, current: override.gridMaxColumns) { [weak self] in self?.override.gridMaxColumns = $0; self?.persist() }
        addEnumRow(to: appearance, title: String(localized: "Accent color"), options: SwitcherAccent.allCases.filter { $0 != .custom }, display: { $0.displayName }, current: override.accentChoice) { [weak self] in self?.override.accentChoice = $0; self?.persist() }
        addEnumRow(to: appearance, title: String(localized: "Backdrop material"), options: BackdropMaterial.allCases, display: { $0.displayName }, current: override.backdropMaterial) { [weak self] in self?.override.backdropMaterial = $0; self?.persist() }
        addEnumRow(to: appearance, title: String(localized: "Title alignment"), options: [.leading, .center, .trailing] as [PreviewTitleAlignment], display: { $0.displayName }, current: override.previewTitleAlignment) { [weak self] in self?.override.previewTitleAlignment = $0; self?.persist() }
        addIntRow(to: appearance, title: String(localized: "Panel opacity"), values: [100, 90, 80, 70, 60, 50, 40, 30], display: { "\($0)%" }, current: override.panelOpacity) { [weak self] in self?.override.panelOpacity = $0; self?.persist() }
        addIntRow(to: appearance, title: String(localized: "Corner radius"), values: [0, 5, 10, 15, 20, 25, 30, 35, 40], display: { $0 == 0 ? String(localized: "Automatic") : "\($0) pt" }, current: override.panelCornerRadius) { [weak self] in self?.override.panelCornerRadius = $0; self?.persist() }
        addBoolRow(to: appearance, title: String(localized: "Show window title"), current: override.showWindowTitleLabel) { [weak self] in self?.override.showWindowTitleLabel = $0; self?.persist() }
        addBoolRow(to: appearance, title: String(localized: "Show application names"), current: override.showApplicationNames) { [weak self] in self?.override.showApplicationNames = $0; self?.persist() }
        addBoolRow(to: appearance, title: String(localized: "Bold selected title"), current: override.boldSelectedLabel) { [weak self] in self?.override.boldSelectedLabel = $0; self?.persist() }
        addBoolRow(to: appearance, title: String(localized: "Show unread badges"), current: override.showUnreadBadges) { [weak self] in self?.override.showUnreadBadges = $0; self?.persist() }
        addBoolRow(to: appearance, title: String(localized: "Show quick-jump letters"), current: override.letterHintsEnabled) { [weak self] in self?.override.letterHintsEnabled = $0; self?.persist() }
        addCard(appearance)

        // MARK: In-panel keys
        // This profile's action keys that act on the highlighted window while its
        // switcher is open (#5). Recorded with BetterShortcuts like the trigger
        // (per-profile names "<base>@<target>"); each defaults to the shipped key,
        // so a recorder shows e.g. ⌘W until changed and its clear button restores
        // that default. Only the keycode is used in-panel (⌘ is held the whole time).
        let panelKeys = SettingsSectionView(title: String(localized: "In-panel keys"))
        panelKeys.addContent(SettingsRowView(
            title: String(localized: "Action keys while switching"),
            subtitle: String(localized: "These act on the highlighted window while the switcher is open. ⌘ is held the whole time, so the modifier you record is ignored in-panel.")
        ))
        // Allow the same chord across profiles (e.g. ⌘W for Close in each) without
        // the cross-name "already used by …" alert — every profile is an independent
        // scope, so a recurring panel key is expected, not a conflict.
        let panelPolicy = BetterShortcuts.RecorderPolicy(allowsDuplicateShortcuts: true, rejectsReservedShortcuts: true)
        for (name, title) in BetterShortcuts.Name.profilePanelKeys(for: target.storageKey) {
            panelKeys.addContent(SettingsRowView(title: title, accessory: BetterShortcuts.RecorderCocoa(for: name, policy: panelPolicy)))
        }
        addCard(panelKeys)
    }

    // MARK: - Row builders

    /// Tri-state bool row: a popup of [Use global default, On, Off].
    private func addBoolRow(to section: SettingsSectionView, title: String, subtitle: String? = nil, current: Bool?, set: @escaping (Bool?) -> Void) {
        addPopupRow(to: section, title: title, subtitle: subtitle,
                    values: [true, false], titles: [String(localized: "On"), String(localized: "Off")],
                    current: current, set: set)
    }

    /// Enum row: a popup of [Use global default, …options].
    private func addEnumRow<T: Equatable>(to section: SettingsSectionView, title: String, subtitle: String? = nil, options: [T], display: (T) -> String, current: T?, set: @escaping (T?) -> Void) {
        addPopupRow(to: section, title: title, subtitle: subtitle,
                    values: options, titles: options.map(display), current: current, set: set)
    }

    /// Int row backed by a discrete value list: a popup of [Use global default, …].
    private func addIntRow(to section: SettingsSectionView, title: String, subtitle: String? = nil, values: [Int], display: (Int) -> String, current: Int?, set: @escaping (Int?) -> Void) {
        addPopupRow(to: section, title: title, subtitle: subtitle,
                    values: values, titles: values.map(display), current: current, set: set)
    }

    /// Core builder: a `SettingsRowView` whose accessory is a popup whose first
    /// item is "Use global default" (→ nil) followed by `titles`/`values`.
    private func addPopupRow<T: Equatable>(to section: SettingsSectionView, title: String, subtitle: String?, values: [T], titles: [String], current: T?, set: @escaping (T?) -> Void) {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.controlSize = .small
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.setContentHuggingPriority(.required, for: .horizontal)
        popup.addItem(withTitle: Self.useGlobal)
        popup.menu?.addItem(.separator())
        for t in titles { popup.addItem(withTitle: t) }
        // Menu index → option index: account for the leading "Use global default"
        // item and the separator (2 leading entries).
        let leading = 2
        if let current, let i = values.firstIndex(of: current) {
            popup.selectItem(at: leading + i)
        } else {
            popup.selectItem(at: 0)
        }
        wire(popup) {
            let menuIndex = popup.indexOfSelectedItem
            let optionIndex = menuIndex - leading
            set(values.indices.contains(optionIndex) ? values[optionIndex] : nil)
        }
        let row = SettingsRowView(title: title, subtitle: subtitle, accessory: popup)
        section.addContent(row)
    }

    private func wire(_ control: NSControl, _ handler: @escaping () -> Void) {
        let target = ClosureActionTarget(handler)
        control.target = target
        control.action = #selector(ClosureActionTarget.fire)
        actionTargets.append(target)
    }
}

/// Small `@objc` target wrapper so controls can fire a Swift closure without a
/// dedicated selector per option. Retained by the owning view.
@MainActor
final class ClosureActionTarget: NSObject {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func fire() { handler() }
}
