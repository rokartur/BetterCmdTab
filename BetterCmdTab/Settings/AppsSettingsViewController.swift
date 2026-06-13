import AppKit
import BetterSettings
import Combine

/// Settings tab gathering per-app configuration: the "App rules" list (hide /
/// ⌘Tab overrides, one card row per app) and the pinned-apps list. Built from
/// the same `SettingsSectionView` cards + rows as the rest of the app so it
/// matches System Settings rather than looking like a raw table.
@MainActor
final class AppsSettingsViewController: SettingsTabViewController {

    /// Working copy, persisted to `Preferences` on every mutation.
    private var exceptions: [AppException] = Preferences.shared.appExceptions

    /// Short, plain-language popup titles (kept compact for inline rows; the
    /// row summary spells the choice out in full).
    private let showOptions: [(mode: HideWindowsMode, title: String)] = [
        (.dontHide, String(localized: "Always")),
        (.whenNoWindows, String(localized: "With open windows")),
        (.always, String(localized: "Never")),
    ]
    private let shortcutOptions: [(mode: IgnoreShortcutsMode, title: String)] = [
        (.never, String(localized: "Never")),
        (.always, String(localized: "Always")),
        (.whenFullscreen, String(localized: "In full screen")),
    ]

    private let rulesCard = SettingsSectionView()

    private let pinnedButton = NSButton(title: String(localized: "Manage apps"), target: nil, action: nil)
    private var pinnedRow: SettingsRowView!
    private var appsSheet: AppsPickerSheetWindowController?
    private var addSheet: AppsPickerSheetWindowController?

    private var cancellables = Set<AnyCancellable>()

    override func setupContent() {
        // App rules — a titled group (header + description) above a card whose
        // rows are one app each, ending in an "Add App…" row.
        let header = makeGroupHeader(
            title: String(localized: "App rules"),
            description: String(localized: "Choose which apps appear in the switcher, and let some apps keep ⌘Tab for themselves.")
        )
        let block = NSStackView(views: [header, rulesCard])
        block.orientation = .vertical
        block.alignment = .leading
        block.spacing = 10
        block.translatesAutoresizingMaskIntoConstraints = false
        addArrangedSubview(block)
        header.widthAnchor.constraint(equalTo: block.widthAnchor).isActive = true
        rulesCard.widthAnchor.constraint(equalTo: block.widthAnchor).isActive = true
        register(section: block, anchor: SettingsAnchor.appRules)
        register(searchTarget: rulesCard, itemID: SearchID.exceptions)
        rebuildRulesCard()

        // Pinned apps — a lightweight chooser (a picker, not an editor).
        let pinned = addSection(title: String(localized: "Pinned"), anchor: SettingsAnchor.pinned)
        configureManageButton(pinnedButton, action: #selector(managePinned))
        pinnedRow = addRow(to: pinned, title: String(localized: "Pinned apps"),
                           subtitle: Self.pinnedDescription(Preferences.shared.pinnedBundleIDs.count),
                           accessory: pinnedButton, searchItemID: SearchID.pinnedApps)
    }

    private func makeGroupHeader(title: String, description: String) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 14, weight: .bold)
        titleLabel.textColor = .labelColor

        let descLabel = NSTextField(wrappingLabelWithString: description)
        descLabel.font = .systemFont(ofSize: 11)
        descLabel.textColor = .secondaryLabelColor
        descLabel.maximumNumberOfLines = 0

        let stack = NSStackView(views: [titleLabel, descLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        descLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -8).isActive = true
        return stack
    }

    private func configureManageButton(_ button: NSButton, action: Selector) {
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.target = self
        button.action = action
    }

    // MARK: - App rules card

    private func rebuildRulesCard() {
        let stack = rulesCard.contentStack
        for sub in stack.arrangedSubviews {
            stack.removeArrangedSubview(sub)
            sub.removeFromSuperview()
        }

        if exceptions.isEmpty {
            let empty = NSTextField(labelWithString: String(localized: "No apps added yet."))
            empty.font = .systemFont(ofSize: 12)
            empty.textColor = .tertiaryLabelColor
            rulesCard.addContent(empty)
            rulesCard.addDivider()
        } else {
            for exception in exceptions {
                rulesCard.addContent(makeRow(for: exception))
                rulesCard.addDivider()
            }
        }

        let addRow = AddAppRowView()
        addRow.onClick = { [weak self] in self?.presentAddPicker() }
        rulesCard.addContent(addRow)
    }

    private func makeRow(for exception: AppException) -> AppRuleRowView {
        // Build immediately with a placeholder (the bundle ID + a generic app
        // glyph), then resolve the real name + icon off the main actor — the
        // LaunchServices lookup and disk icon read in `appInfo(for:)` can hitch
        // the UI with many rules or a cold LaunchServices. Mirrors the off-main
        // resolution in `AppsPickerSheetViewController.loadApps`.
        let placeholderIcon = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
        let row = AppRuleRowView(
            bundleID: exception.bundleID,
            name: exception.bundleID,
            icon: placeholderIcon,
            hide: exception.hide,
            ignore: exception.ignore,
            showOptions: showOptions,
            shortcutOptions: shortcutOptions
        )
        let bundleID = exception.bundleID
        row.onChange = { [weak self] hide, ignore in
            self?.updateRule(bundleID: bundleID, hide: hide, ignore: ignore)
        }
        row.onRemove = { [weak self] in
            self?.removeRule(bundleID: bundleID)
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak row] in
            let info = Self.appInfo(for: bundleID)
            DispatchQueue.main.async { [weak row] in
                row?.applyResolved(name: info.name, icon: info.icon)
            }
        }
        return row
    }

    private func updateRule(bundleID: String, hide: HideWindowsMode, ignore: IgnoreShortcutsMode) {
        guard let idx = exceptions.firstIndex(where: { $0.bundleID == bundleID }) else { return }
        exceptions[idx].hide = hide
        exceptions[idx].ignore = ignore
        persist()
    }

    private func removeRule(bundleID: String) {
        exceptions.removeAll { $0.bundleID == bundleID }
        persist()
        rebuildRulesCard()
    }

    private func persist() {
        Preferences.shared.appExceptions = exceptions
    }

    private func presentAddPicker() {
        guard let window = view.window, addSheet == nil else { return }
        let controller = AppsPickerSheetWindowController(
            title: String(localized: "Add App"),
            prompt: String(localized: "Choose an app to set switcher rules for."),
            selectedBundleIDs: [],
            singleSelection: true,
            confirmTitle: String(localized: "Add")
        ) { [weak self] selection in
            guard let self, let bundleID = selection.first else { return }
            if !self.exceptions.contains(where: { $0.bundleID == bundleID }) {
                self.exceptions.append(AppException(bundleID: bundleID))
                self.persist()
                self.rebuildRulesCard()
            }
        }
        controller.onDidDismiss = { [weak self] in self?.addSheet = nil }
        addSheet = controller
        trackForRelease(controller)
        controller.present(asSheetFor: window)
    }

    // MARK: - Pinned

    override func viewWillAppear() {
        super.viewWillAppear()
        // Re-sync the working copy: another pane (e.g. Import settings) can rewrite
        // appExceptions while this cached controller is off screen. Without this,
        // the next add/edit/remove would persist this stale snapshot and silently
        // clobber the imported rules.
        let current = Preferences.shared.appExceptions
        if current != exceptions {
            exceptions = current
            rebuildRulesCard()
        }
        updatePinnedCount()
        Preferences.shared.$pinnedBundleIDs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.pinnedRow?.update(subtitle: Self.pinnedDescription($0.count)) }
            .store(in: &cancellables)
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        cancellables.removeAll()
    }

    @objc private func managePinned() {
        guard let window = view.window, appsSheet == nil else { return }
        let controller = AppsPickerSheetWindowController(
            title: String(localized: "Pinned Apps"),
            prompt: String(localized: "Selected apps are forced to the front of the switcher, before recents."),
            selectedBundleIDs: Set(Preferences.shared.pinnedBundleIDs),
            confirmTitle: String(localized: "Done")
        ) { selection in
            // Preserve existing pin order; append newly-checked apps at the end,
            // sorted by display name — `selection` is a Set, so its iteration
            // order would otherwise persist an arbitrary, user-visible pin order.
            let current = Preferences.shared.pinnedBundleIDs
            var order = current.filter { selection.contains($0) }
            let added = selection.filter { !order.contains($0) }
                .map { (bid: $0, name: AppsSettingsViewController.appName(for: $0)) }
                .sorted {
                    let byName = $0.name.localizedCaseInsensitiveCompare($1.name)
                    return byName == .orderedSame ? $0.bid < $1.bid : byName == .orderedAscending
                }
            order.append(contentsOf: added.map(\.bid))
            Preferences.shared.pinnedBundleIDs = order
        }
        controller.onDidDismiss = { [weak self] in
            self?.appsSheet = nil
            self?.updatePinnedCount()
        }
        appsSheet = controller
        trackForRelease(controller)
        controller.present(asSheetFor: window)
    }

    private func updatePinnedCount() {
        pinnedRow?.update(subtitle: Self.pinnedDescription(Preferences.shared.pinnedBundleIDs.count))
    }

    private static func pinnedDescription(_ count: Int) -> String {
        let prefix = count == 0 ? String(localized: "None") : "\(count) app\(count == 1 ? "" : "s")"
        return "\(prefix)\(String(localized: " — always shown first."))"
    }

    // MARK: - Helpers

    /// Display name + icon for a bundle ID, resolved from the installed app.
    /// `nonisolated` so it can run off the main actor: it only touches
    /// `NSWorkspace.shared`, whose `urlForApplication`/`icon(forFile:)` are
    /// thread-safe, plus an `NSImage` symbol lookup.
    nonisolated private static func appInfo(for bundleID: String) -> (name: String, icon: NSImage) {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return (url.deletingPathExtension().lastPathComponent, NSWorkspace.shared.icon(forFile: url.path))
        }
        let fallback = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
        return (bundleID, fallback)
    }

    /// Display name only — skips the icon disk-decode `appInfo` does, so the
    /// pin-order sort doesn't pay for an `NSImage` it never reads.
    nonisolated private static func appName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return bundleID
        }
        return url.deletingPathExtension().lastPathComponent
    }
}
