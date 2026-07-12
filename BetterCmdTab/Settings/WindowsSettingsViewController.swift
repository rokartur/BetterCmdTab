import AppKit
import BetterSettings
import BetterShortcuts

/// Windows pane — system-wide window management, moved out of the Shortcuts pane
/// (which now focuses on the switcher triggers). Holds the arrange-the-focused-
/// window hotkeys (tile / maximize / center / restore) and their cycle-widths
/// option, plus the hide-all / show-all hotkeys and their keep-visible list.
@MainActor
final class WindowsSettingsViewController: SettingsTabViewController {

    private let cycleWidthsSwitch = NSSwitch()

    // "Hide all windows" exclusion list: a row whose subtitle shows the count and
    // a picker sheet to edit which apps stay visible.
    private var excludedHideAppsRow: SettingsRowView?
    private var excludedHideAppsSheet: AppsPickerSheetWindowController?

    override func setupContent() {
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
        cycleWidthsSwitch.controlSize = .small
        cycleWidthsSwitch.target = self
        cycleWidthsSwitch.action = #selector(toggleCycleWidths(_:))
        addRow(
            to: arrange,
            title: String(localized: "Cycle tile widths"),
            subtitle: String(localized: "Press Tile left / Tile right again to step the window through ½ → ⅔ → ⅓ of the screen on that side."),
            accessory: cycleWidthsSwitch
        )

        // All windows section — hide/show every app, and which apps stay visible.
        let allWindows = addSection(title: String(localized: "All windows"), anchor: SettingsAnchor.windowAll)
        addRow(
            to: allWindows,
            title: String(localized: "Hide all windows"),
            subtitle: String(localized: "Hide every app to reveal the desktop. Works system-wide."),
            accessory: BetterShortcuts.RecorderCocoa(for: .hideAllWindows, policy: .reservedRejecting)
        )
        addRow(
            to: allWindows,
            title: String(localized: "Show all windows"),
            subtitle: String(localized: "Bring every hidden app back."),
            accessory: BetterShortcuts.RecorderCocoa(for: .showAllWindows, policy: .reservedRejecting)
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
            accessory: excludeButton
        )
    }

    override func viewWillAppear() {
        super.viewWillAppear()
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
}
