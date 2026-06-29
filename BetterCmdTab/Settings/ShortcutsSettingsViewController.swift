import AppKit
import BetterSettings
import BetterShortcuts

@MainActor
final class ShortcutsSettingsViewController: SettingsTabViewController {

    private let appRecorder = BetterShortcuts.RecorderCocoa(for: .switchApps)
    private let windowRecorder = BetterShortcuts.RecorderCocoa(for: .switchWindows)

    // Direct-activation slots: a "choose app" button + shortcut recorder per slot.
    private var directButtons: [NSButton] = []
    private var directSlotSheet: AppsPickerSheetWindowController?

    // Scoped-switch shortcuts: a dynamic, user-managed add/remove list (#74).
    private let scopedListView = ScopedShortcutsListView()

    // Per-shortcut override editor (#74): a "Customize…" button per panel-opening
    // shortcut, the rows whose subtitle reflects whether an override is set, and
    // the live sheet.
    private var switchAppsRow: SettingsRowView?
    private var switchWindowsRow: SettingsRowView?
    private var optionsSheet: ShortcutOptionsSheetWindowController?
    private let switchAppsBaseSubtitle = String(localized: "Hold the modifier (⌘ by default) and tap to move through your open apps.")
    private let switchWindowsBaseSubtitle = String(localized: "Cycle through the windows of the app you're on.")

    // Window-management options.
    private let cycleWidthsSwitch = NSSwitch()

    // "Hide all windows" exclusion list: a row whose subtitle shows the count
    // and a picker sheet to edit which apps stay visible.
    private var excludedHideAppsRow: SettingsRowView?
    private var excludedHideAppsSheet: AppsPickerSheetWindowController?

    override func setupContent() {
        // Switching section — the core ⌘Tab triggers. The trigger must include a
        // hold modifier (⌘/⌥/⌃); Shift is reserved for stepping backwards and is
        // rejected by the recorder.
        let switching = addSection(title: String(localized: "Switching"), anchor: SettingsAnchor.switching)
        let appsCustomize = makeCustomizeButton(action: #selector(customizeSwitchApps))
        switchAppsRow = addRow(
            to: switching,
            title: String(localized: "Switch apps"),
            subtitle: subtitle(switchAppsBaseSubtitle, target: .switchApps),
            accessory: triggerStack(button: appsCustomize, recorder: appRecorder),
            searchItemID: SearchID.switchApps
        )
        let windowsCustomize = makeCustomizeButton(action: #selector(customizeSwitchWindows))
        switchWindowsRow = addRow(
            to: switching,
            title: String(localized: "Switch windows"),
            subtitle: subtitle(switchWindowsBaseSubtitle, target: .switchWindows),
            accessory: triggerStack(button: windowsCustomize, recorder: windowRecorder),
            searchItemID: SearchID.switchWindows
        )

        // Direct activation section — global shortcuts that jump straight to a
        // chosen app, bypassing the switcher.
        let direct = addSection(title: String(localized: "Direct activation"), anchor: SettingsAnchor.directActivation)
        addRow(
            to: direct,
            title: String(localized: "Jump straight to an app"),
            subtitle: String(localized: "Give a shortcut to one app — it focuses that app, opening it first if needed."),
            searchItemID: SearchID.directActivation
        )
        for (index, name) in BetterShortcuts.Name.directActivate.enumerated() {
            let recorder = BetterShortcuts.RecorderCocoa(for: name)
            let button = NSButton(title: String(localized: "Choose…"), target: self, action: #selector(chooseDirectApp(_:)))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.tag = index
            let stack = NSStackView(views: [button, recorder])
            stack.orientation = .horizontal
            stack.spacing = 8
            stack.alignment = .centerY
            addRow(to: direct, title: String(localized: "Slot \(index + 1)"), accessory: stack)
            directButtons.append(button)
        }

        // Scoped shortcuts section — global shortcuts that open the switcher
        // already filtered to a subset of windows.
        let scoped = addSection(title: String(localized: "Scoped shortcuts"), anchor: SettingsAnchor.scopedSwitch)
        addRow(
            to: scoped,
            title: String(localized: "Open the switcher on a subset"),
            subtitle: String(localized: "Give a shortcut its own view — all windows, just this Space, the current app's windows, or only minimized."),
            searchItemID: SearchID.scopedSwitch
        )
        scopedListView.onCustomize = { [weak self] target in
            self?.presentOptions(for: target, title: String(localized: "Customize scoped shortcut"), includeSpaceScope: false)
        }
        scoped.addContent(scopedListView)

        // In-panel keys section — the keys that act on the highlighted window
        // while the switcher is open (close / minimize / hide / quit). Recorded
        // with BetterShortcuts; only the key is used in-panel (⌘ is held the
        // whole time), so e.g. ⌘W reads as W while switching. No global hotkey is
        // registered for these — there's no onKeyDown handler — so binding ⌘W
        // doesn't steal Close in other apps.
        let panelKeys = addSection(title: String(localized: "In-panel keys"), anchor: SettingsAnchor.panelKeys)
        addRow(
            to: panelKeys,
            title: String(localized: "Action keys while switching"),
            subtitle: String(localized: "These act on the highlighted window while the switcher is open. ⌘ is held the whole time, so the modifier you record is ignored in-panel."),
            searchItemID: SearchID.panelKeys
        )
        for (name, title) in BetterShortcuts.Name.panelActionKeys {
            addRow(to: panelKeys, title: title, accessory: BetterShortcuts.RecorderCocoa(for: name))
        }

        // Window management section — tile / maximize / center. These ARE global
        // shortcuts (they work whether the switcher is open or closed); when the
        // they always arrange the frontmost app's focused window, whether or
        // not the switcher is open. Default ⌃⌘ + arrows.
        let windowMgmt = addSection(title: String(localized: "Window management"), anchor: SettingsAnchor.windowMgmt)
        addRow(
            to: windowMgmt,
            title: String(localized: "Arrange the focused window"),
            subtitle: String(localized: "Tile to a half or corner, maximize, or center the frontmost window. Works system-wide."),
            searchItemID: SearchID.windowMgmt
        )
        for (name, title) in BetterShortcuts.Name.windowMgmt {
            addRow(to: windowMgmt, title: title, accessory: BetterShortcuts.RecorderCocoa(for: name))
        }
        addRow(
            to: windowMgmt,
            title: String(localized: "Hide all windows"),
            subtitle: String(localized: "Hide every app to reveal the desktop. Works system-wide."),
            accessory: BetterShortcuts.RecorderCocoa(for: .hideAllWindows)
        )
        addRow(
            to: windowMgmt,
            title: String(localized: "Show all windows"),
            subtitle: String(localized: "Bring every hidden app back."),
            accessory: BetterShortcuts.RecorderCocoa(for: .showAllWindows)
        )
        let excludeButton = NSButton(
            title: String(localized: "Choose…"),
            target: self,
            action: #selector(chooseExcludedHideApps)
        )
        excludeButton.bezelStyle = .rounded
        excludeButton.controlSize = .small
        excludedHideAppsRow = addRow(
            to: windowMgmt,
            title: String(localized: "Keep apps visible"),
            subtitle: Self.excludedHideDescription(Preferences.shared.hideAllExcludedBundleIDs.count),
            accessory: excludeButton
        )
        cycleWidthsSwitch.controlSize = .small
        cycleWidthsSwitch.target = self
        cycleWidthsSwitch.action = #selector(toggleCycleWidths(_:))
        addRow(
            to: windowMgmt,
            title: String(localized: "Cycle tile widths"),
            subtitle: String(localized: "Press Tile left / Tile right again to step the window through ½ → ⅔ → ⅓ of the screen on that side."),
            accessory: cycleWidthsSwitch
        )
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refreshDirectSlots()
        // Another pane (Import settings) can rewrite the scoped list off-screen;
        // rebuild from the live model on appear.
        scopedListView.rebuild()
        refreshCustomizedSubtitles()
        cycleWidthsSwitch.state = Preferences.shared.cycleTileWidths ? .on : .off
        // Another pane (e.g. Import settings) can rewrite the list while this
        // cached controller is off screen — re-sync the subtitle on appear.
        excludedHideAppsRow?.update(
            subtitle: Self.excludedHideDescription(Preferences.shared.hideAllExcludedBundleIDs.count)
        )
    }

    @objc private func toggleCycleWidths(_ sender: NSSwitch) {
        Preferences.shared.cycleTileWidths = (sender.state == .on)
    }

    /// Subtitle for the "Keep apps visible" row: explains the empty state, else
    /// reports how many apps are excluded from Hide all windows.
    private static func excludedHideDescription(_ count: Int) -> String {
        if count == 0 {
            return String(localized: "Hide all windows hides every app, Finder included. Pick apps to keep visible.")
        }
        return String(localized: "Apps kept visible: \(count).")
    }

    /// Open the multi-select app picker seeded with the current exclusions; the
    /// returned set replaces the stored list. The picker itself is the whole
    /// management UI — no per-row remove needed.
    @objc private func chooseExcludedHideApps() {
        guard let window = view.window, excludedHideAppsSheet == nil else { return }
        let current = Set(Preferences.shared.hideAllExcludedBundleIDs)
        let controller = AppsPickerSheetWindowController(
            title: String(localized: "Keep apps visible"),
            prompt: String(localized: "Chosen apps stay visible when you trigger Hide all windows."),
            selectedBundleIDs: current,
            singleSelection: false,
            confirmTitle: String(localized: "Done")
        ) { [weak self] selection in
            guard let self else { return }
            Preferences.shared.hideAllExcludedBundleIDs = selection.sorted()
            self.excludedHideAppsRow?.update(subtitle: Self.excludedHideDescription(selection.count))
        }
        controller.onDidDismiss = { [weak self] in self?.excludedHideAppsSheet = nil }
        excludedHideAppsSheet = controller
        controller.present(asSheetFor: window)
    }

    // MARK: - Direct activation slots

    /// Sync each slot's "choose app" button to its stored bundle ID.
    private func refreshDirectSlots() {
        let bindings = Preferences.shared.directActivationBindings
        for (index, button) in directButtons.enumerated() {
            let bundleID = bindings.indices.contains(index) ? bindings[index] : ""
            if bundleID.isEmpty {
                button.title = String(localized: "Choose…")
                button.image = nil
            } else {
                button.title = Self.appName(forBundleID: bundleID) ?? bundleID
                button.image = Self.appIcon(forBundleID: bundleID)
                button.imagePosition = .imageLeading
            }
        }
    }

    @objc private func chooseDirectApp(_ sender: NSButton) {
        let slot = sender.tag
        guard let window = view.window, directSlotSheet == nil else { return }
        let current = Preferences.shared.directActivationBindings
        let selected: Set<String> = (current.indices.contains(slot) && !current[slot].isEmpty) ? [current[slot]] : []
        let controller = AppsPickerSheetWindowController(
            title: String(localized: "Activate App"),
            prompt: String(localized: "Choose the app this shortcut focuses."),
            selectedBundleIDs: selected,
            singleSelection: true,
            confirmTitle: String(localized: "Choose")
        ) { selection in
            var bindings = Preferences.shared.directActivationBindings
            while bindings.count <= slot { bindings.append("") }
            bindings[slot] = selection.sorted().first ?? ""
            Preferences.shared.directActivationBindings = bindings
        }
        controller.onDidDismiss = { [weak self] in
            self?.directSlotSheet = nil
            self?.refreshDirectSlots()
        }
        directSlotSheet = controller
        controller.present(asSheetFor: window)
    }

    // MARK: - Per-shortcut overrides (#74)

    private func makeCustomizeButton(action: Selector) -> NSButton {
        let button = NSButton(title: String(localized: "Customize…"), target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        return button
    }

    private func triggerStack(button: NSButton, recorder: NSView) -> NSStackView {
        let stack = NSStackView(views: [button, recorder])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        return stack
    }

    /// Append a "(Customized)" marker to a row's base subtitle when the target has
    /// a non-empty override.
    private func subtitle(_ base: String, target: SwitchTarget) -> String {
        guard !Preferences.shared.override(for: target).isEmpty else { return base }
        let marker = String(localized: "Customized")
        return base.isEmpty ? marker : "\(base) · \(marker)"
    }

    private func refreshCustomizedSubtitles() {
        switchAppsRow?.update(subtitle: subtitle(switchAppsBaseSubtitle, target: .switchApps))
        switchWindowsRow?.update(subtitle: subtitle(switchWindowsBaseSubtitle, target: .switchWindows))
    }

    @objc private func customizeSwitchApps() {
        presentOptions(for: .switchApps, title: String(localized: "Customize Switch apps"), includeSpaceScope: true)
    }

    @objc private func customizeSwitchWindows() {
        presentOptions(for: .switchWindows, title: String(localized: "Customize Switch windows"), includeSpaceScope: true)
    }

    private func presentOptions(for target: SwitchTarget, title: String, includeSpaceScope: Bool) {
        guard let window = view.window, optionsSheet == nil else { return }
        let controller = ShortcutOptionsSheetWindowController(
            title: title,
            target: target,
            includeSpaceScope: includeSpaceScope
        ) { override in
            Preferences.shared.setOverride(override, for: target)
        }
        controller.onDidDismiss = { [weak self] in
            self?.optionsSheet = nil
            self?.refreshCustomizedSubtitles()
        }
        optionsSheet = controller
        controller.present(asSheetFor: window)
    }


    private static func appName(forBundleID bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return FileManager.default.displayName(atPath: url.path)
    }

    private static func appIcon(forBundleID bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }
}
