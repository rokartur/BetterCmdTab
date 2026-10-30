import AppKit
import BetterSettings
import BetterShortcuts

/// Window Shortcuts pane — every global hotkey that does not open the switcher:
/// jump straight to an app, arrange the focused window, hide/show every window.
/// The shortcuts that open the switcher live under Switcher Shortcuts.
@MainActor
final class ShortcutsSettingsViewController: SettingsTabViewController {

    // Direct-activation slots: a "choose app" button + shortcut recorder per slot
    // (a global hotkey that jumps straight to a chosen app, bypassing the switcher).
    private var directButtons: [NSButton] = []
    private var directSlotSheet: AppsPickerSheetWindowController?

    private let cycleAppWindowsSwitch = PreferenceSwitch(bind: \.directActivationCyclesWindows)
    private let cycleWidthsSwitch = PreferenceSwitch(bind: \.cycleTileWidths)

    // "Hide all windows" exclusion list: a row whose subtitle shows the count and
    // a picker sheet to edit which apps stay visible.
    private var excludedHideAppsRow: SettingsRowView?
    private var excludedHideAppsSheet: AppsPickerSheetWindowController?

    override func setupContent() {
        buildDirectActivationSection()
        buildArrangeSection()
        buildAllWindowsSection()
        addRelatedSection([(String(localized: "Shortcuts that open the switcher"), SettingsTabID.switcherShortcuts)])
    }

    /// Direct activation — global hotkeys that focus (and launch) a chosen app,
    /// bypassing the switcher.
    private func buildDirectActivationSection() {
        let direct = addSection(title: String(localized: "Direct activation"), anchor: SettingsAnchor.directActivation)
        addRow(
            to: direct,
            title: String(localized: "Jump straight to an app"),
            subtitle: String(localized: "Give a shortcut to one app — it focuses that app, opening it first if needed."),
            searchItemID: SearchID.directActivation
        )
        for (index, name) in BetterShortcuts.Name.directActivate.enumerated() {
            let recorder = BetterShortcuts.RecorderCocoa(for: name, policy: .reservedRejecting)
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
        addRow(
            to: direct,
            title: String(localized: "Cycle app windows"),
            subtitle: String(localized: "Press an app's shortcut again while the app is in front to step through its windows."),
            accessory: cycleAppWindowsSwitch,
            searchItemID: SearchID.directActivationCyclesWindows
        )
    }

    private func buildArrangeSection() {
        // Arrange section — global hotkeys that tile / maximize / center the
        // frontmost window (work whether or not the switcher is open). Default ⌃⌘.
        let arrange = addSection(title: String(localized: "Arrange window"), anchor: SettingsAnchor.windowArrange)
        addRow(
            to: arrange,
            title: String(localized: "Arrange the focused window"),
            subtitle: String(localized: "Tile to a half or corner, maximize, or center the frontmost window. Works system-wide."),
            searchItemID: SearchID.windowMgmt
        )
        for (name, title) in BetterShortcuts.Name.windowMgmt {
            addRow(to: arrange, title: title, accessory: BetterShortcuts.RecorderCocoa(for: name, policy: .reservedRejecting))
        }
        addRow(
            to: arrange,
            title: String(localized: "Cycle tile widths"),
            subtitle: String(localized: "Press Tile left / Tile right again to step the window through ½ → ⅔ → ⅓ of the screen on that side."),
            accessory: cycleWidthsSwitch,
            searchItemID: SearchID.cycleTileWidths
        )
    }

    private func buildAllWindowsSection() {
        // All windows section — hide/show every app, and which apps stay visible.
        let allWindows = addSection(title: String(localized: "All windows"), anchor: SettingsAnchor.windowAll)
        addRow(
            to: allWindows,
            title: String(localized: "Hide all windows"),
            subtitle: String(localized: "Hide every app to reveal the desktop. Works system-wide."),
            accessory: BetterShortcuts.RecorderCocoa(for: .hideAllWindows, policy: .reservedRejecting),
            searchItemID: SearchID.hideAllWindows
        )
        addRow(
            to: allWindows,
            title: String(localized: "Show all windows"),
            subtitle: String(localized: "Bring every hidden app back."),
            accessory: BetterShortcuts.RecorderCocoa(for: .showAllWindows, policy: .reservedRejecting),
            searchItemID: SearchID.showAllWindows
        )
        let excludeButton = NSButton(
            title: String(localized: "Choose…"),
            target: self,
            action: #selector(chooseExcludedHideApps)
        )
        excludeButton.bezelStyle = .rounded
        excludeButton.controlSize = .small
        excludedHideAppsRow = addRow(
            to: allWindows,
            title: String(localized: "Keep apps visible"),
            subtitle: Self.excludedHideDescription(Preferences.shared.hideAllExcludedBundleIDs.count),
            accessory: excludeButton,
            searchItemID: SearchID.keepAppsVisible
        )
    }
    override func viewWillAppear() {
        super.viewWillAppear()
        refreshDirectSlots()
        cycleAppWindowsSwitch.sync()
        cycleWidthsSwitch.sync()
        // Another pane (e.g. Import settings) can rewrite the list while this
        // cached controller is off screen — re-sync the subtitle on appear.
        excludedHideAppsRow?.update(
            subtitle: Self.excludedHideDescription(Preferences.shared.hideAllExcludedBundleIDs.count)
        )
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
    /// returned set replaces the stored list.
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
        // Same memory-release tracking the Apps pane gives its picker sheets, so
        // a tab unload can't strand an open sheet.
        trackForRelease(controller)
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
                let info = AppsSettingsViewController.appInfo(for: bundleID)
                button.title = info.name
                info.icon.size = NSSize(width: 16, height: 16)
                button.image = info.icon
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
        trackForRelease(controller)
        controller.present(asSheetFor: window)
    }
}
