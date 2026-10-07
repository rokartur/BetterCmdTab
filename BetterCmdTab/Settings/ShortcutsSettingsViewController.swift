import AppKit
import BetterSettings
import BetterShortcuts

/// Shortcuts pane — every global trigger that is *not* a switcher shortcut, so
/// there is one place to look for "what does this key do": jump straight to an
/// app, arrange the focused window, hide/show every window, and the trackpad
/// swipe. The shortcuts that open the switcher live under Profiles.
@MainActor
final class ShortcutsSettingsViewController: SettingsTabViewController {

    // Direct-activation slots: a "choose app" button + shortcut recorder per slot
    // (a global hotkey that jumps straight to a chosen app, bypassing the switcher).
    private var directButtons: [NSButton] = []
    private var directSlotSheet: AppsPickerSheetWindowController?

    private let cycleWidthsSwitch = PreferenceSwitch(bind: \.cycleTileWidths)

    // Trackpad swipe (experimental).
    private let swipeSwitch = NSSwitch()
    private let swipeModePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let swipeModes: [SwipeMode] = SwipeMode.allCases
    private let swipeFingersPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let swipeFingerCounts = Array(Preferences.swipeFingerCountRange)
    private let reverseSwitch = PreferenceSwitch(bind: \.swipeReverseDirection)
    private let commitSwitch = PreferenceSwitch(bind: \.swipeCommitOnRelease)
    private let sensitivitySlider = NSSlider()
    private let sensitivityValueLabel = NSTextField(labelWithString: "")

    // "Hide all windows" exclusion list: a row whose subtitle shows the count and
    // a picker sheet to edit which apps stay visible.
    private var excludedHideAppsRow: SettingsRowView?
    private var excludedHideAppsSheet: AppsPickerSheetWindowController?

    override func setupContent() {
        buildDirectActivationSection()
        buildArrangeSection()
        buildAllWindowsSection()
        buildSwipeSection()
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

    /// Trackpad swipe — still experimental, so the section opens with the
    /// warning that used to head the Experimental tab.
    private func buildSwipeSection() {
        let swipe = addSection(title: String(localized: "Trackpad swipe"), anchor: SettingsAnchor.swipe)
        addRow(to: swipe, icon: "flask.fill",
               title: String(localized: "These features are unstable"),
               subtitle: String(localized: "Off by default. They may change or break."))

        configureSwitch(swipeSwitch, action: #selector(toggleSwipe(_:)))
        addRow(to: swipe, title: String(localized: "Swipe gesture"),
               subtitle: String(localized: "Slide three or four fingers horizontally across the trackpad. Reads the trackpad directly, so no system setting is needed."),
               accessory: swipeSwitch, searchItemID: SearchID.swipe)

        configurePopup(swipeFingersPopup, titles: swipeFingerCounts.map(String.init), action: #selector(swipeFingersChanged))
        addRow(to: swipe, title: String(localized: "Fingers"),
               subtitle: String(localized: "Use four to keep three-finger drag for moving windows."),
               accessory: swipeFingersPopup, searchItemID: SearchID.swipeFingers)

        configurePopup(swipeModePopup, titles: swipeModes.map(\.displayName), action: #selector(swipeModeChanged))
        addRow(to: swipe, title: String(localized: "Swipe action"),
               subtitle: String(localized: "Open switcher: scrub through apps (commit with Return/click, Esc to cancel). Switch Spaces: jump to the Space on that side, one per step. Quick switch: flip to your last app, like a quick ⌘Tab tap — swipe again to flip back."),
               accessory: swipeModePopup, searchItemID: SearchID.swipeMode)

        addRow(to: swipe, title: String(localized: "Reverse swipe direction"),
               subtitle: String(localized: "Slide right to move left and left to move right."),
               accessory: reverseSwitch, searchItemID: SearchID.reverseSwipe)
        addRow(to: swipe, title: String(localized: "Switch on release"),
               subtitle: String(localized: "Lift your fingers to switch to the highlighted app. When off, pick with a click or Return."),
               accessory: commitSwitch, searchItemID: SearchID.switchOnRelease)

        addRow(to: swipe, title: String(localized: "Swipe sensitivity"),
               subtitle: String(localized: "How far to slide to move one app. Higher means a shorter slide steps further."),
               accessory: makeSensitivityControl(), searchItemID: SearchID.sensitivity)
    }

    /// Slider (1–10) plus a value label, matching the reveal-delay control.
    private func makeSensitivityControl() -> NSView {
        sensitivitySlider.minValue = Double(Preferences.swipeSensitivityRange.lowerBound)
        sensitivitySlider.maxValue = Double(Preferences.swipeSensitivityRange.upperBound)
        sensitivitySlider.numberOfTickMarks = Preferences.swipeSensitivityRange.count
        sensitivitySlider.allowsTickMarkValuesOnly = true
        sensitivitySlider.isContinuous = true
        sensitivitySlider.controlSize = .small
        sensitivitySlider.target = self
        sensitivitySlider.action = #selector(sensitivityChanged(_:))
        sensitivitySlider.translatesAutoresizingMaskIntoConstraints = false

        sensitivityValueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        sensitivityValueLabel.textColor = .secondaryLabelColor
        sensitivityValueLabel.alignment = .right
        sensitivityValueLabel.translatesAutoresizingMaskIntoConstraints = false
        sensitivityValueLabel.setContentHuggingPriority(.required, for: .horizontal)

        let stack = NSStackView(views: [sensitivitySlider, sensitivityValueLabel])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        NSLayoutConstraint.activate([
            sensitivitySlider.widthAnchor.constraint(equalToConstant: 140),
            sensitivityValueLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 40),
        ])
        return stack
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refreshDirectSlots()
        cycleWidthsSwitch.sync()

        let prefs = Preferences.shared
        swipeSwitch.state = prefs.experimentalSwipeTrigger ? .on : .off
        if let index = swipeModes.firstIndex(of: prefs.swipeMode) { swipeModePopup.selectItem(at: index) }
        if let index = swipeFingerCounts.firstIndex(of: prefs.swipeFingerCount) { swipeFingersPopup.selectItem(at: index) }
        reverseSwitch.sync()
        commitSwitch.sync()
        applySensitivity(prefs.swipeSensitivity)
        setSwipeSubOptionsEnabled(prefs.experimentalSwipeTrigger)
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

    // MARK: - Trackpad swipe

    @objc private func toggleSwipe(_ sender: NSSwitch) {
        let on = (sender.state == .on)
        Preferences.shared.experimentalSwipeTrigger = on
        setSwipeSubOptionsEnabled(on)
    }

    @objc private func swipeModeChanged() {
        let idx = swipeModePopup.indexOfSelectedItem
        guard swipeModes.indices.contains(idx) else { return }
        Preferences.shared.swipeMode = swipeModes[idx]
        setSwipeSubOptionsEnabled(Preferences.shared.experimentalSwipeTrigger)
    }

    @objc private func swipeFingersChanged() {
        let idx = swipeFingersPopup.indexOfSelectedItem
        guard swipeFingerCounts.indices.contains(idx) else { return }
        Preferences.shared.swipeFingerCount = swipeFingerCounts[idx]
    }

    @objc private func sensitivityChanged(_ sender: NSSlider) {
        Preferences.shared.swipeSensitivity = sender.integerValue
        sensitivityValueLabel.stringValue = "\(sender.integerValue)/\(Preferences.swipeSensitivityRange.upperBound)"
    }

    private func applySensitivity(_ level: Int) {
        if sensitivitySlider.integerValue != level { sensitivitySlider.integerValue = level }
        sensitivityValueLabel.stringValue = "\(level)/\(Preferences.swipeSensitivityRange.upperBound)"
    }

    /// The reverse/commit/sensitivity controls only make sense while the swipe
    /// is enabled.
    private func setSwipeSubOptionsEnabled(_ enabled: Bool) {
        // Commit-on-release and sensitivity only apply to the continuous
        // "open switcher" scrub. Direction has no meaning for the quick-switch
        // flip (any swipe just toggles), so reverse is off there too.
        let scrub = Preferences.shared.swipeMode == .openSwitcher
        let directional = Preferences.shared.swipeMode != .quickSwitch
        swipeModePopup.isEnabled = enabled
        swipeFingersPopup.isEnabled = enabled
        reverseSwitch.isEnabled = enabled && directional
        commitSwitch.isEnabled = enabled && scrub
        sensitivitySlider.isEnabled = enabled && scrub
    }
}
