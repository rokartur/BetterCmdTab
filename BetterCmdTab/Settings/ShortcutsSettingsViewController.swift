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

    // Scoped-switch slots: a scope popup + shortcut recorder per slot.
    private var scopePopups: [NSPopUpButton] = []
    private let scopeOptions: [SwitchScope] = SwitchScope.allCases

    // In-panel action keys (#5): one bare-key capture button per action.
    private var panelKeyButtons: [PanelKeyAction: KeyCaptureButton] = [:]

    override func setupContent() {
        // Switching section — the core ⌘Tab triggers. The trigger must include a
        // hold modifier (⌘/⌥/⌃); Shift is reserved for stepping backwards and is
        // rejected by the recorder.
        let switching = addSection(title: "Switching", anchor: SettingsAnchor.switching)
        addRow(
            to: switching,
            title: "Switch apps",
            subtitle: "Hold the modifier (⌘ by default) and tap to move through your open apps.",
            accessory: appRecorder,
            searchItemID: SearchID.switchApps
        )
        addRow(
            to: switching,
            title: "Switch windows",
            subtitle: "Cycle through the windows of the app you're on.",
            accessory: windowRecorder,
            searchItemID: SearchID.switchWindows
        )

        // Direct activation section — global shortcuts that jump straight to a
        // chosen app, bypassing the switcher.
        let direct = addSection(title: "Direct activation", anchor: SettingsAnchor.directActivation)
        addRow(
            to: direct,
            title: "Jump straight to an app",
            subtitle: "Give a shortcut to one app — it focuses that app, opening it first if needed.",
            searchItemID: SearchID.directActivation
        )
        for (index, name) in BetterShortcuts.Name.directActivate.enumerated() {
            let recorder = BetterShortcuts.RecorderCocoa(for: name)
            let button = NSButton(title: "Choose…", target: self, action: #selector(chooseDirectApp(_:)))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.tag = index
            let stack = NSStackView(views: [button, recorder])
            stack.orientation = .horizontal
            stack.spacing = 8
            stack.alignment = .centerY
            addRow(to: direct, title: "Slot \(index + 1)", accessory: stack)
            directButtons.append(button)
        }

        // Scoped shortcuts section — global shortcuts that open the switcher
        // already filtered to a subset of windows.
        let scoped = addSection(title: "Scoped shortcuts", anchor: SettingsAnchor.scopedSwitch)
        addRow(
            to: scoped,
            title: "Open the switcher on a subset",
            subtitle: "Give a shortcut its own view — all windows, just this Space, the current app's windows, or only minimized.",
            searchItemID: SearchID.scopedSwitch
        )
        for (index, name) in BetterShortcuts.Name.scopedSwitch.enumerated() {
            let recorder = BetterShortcuts.RecorderCocoa(for: name)
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.controlSize = .small
            popup.translatesAutoresizingMaskIntoConstraints = false
            popup.setContentHuggingPriority(.required, for: .horizontal)
            popup.addItems(withTitles: scopeOptions.map(\.displayName))
            popup.target = self
            popup.action = #selector(scopeChanged(_:))
            popup.tag = index
            let stack = NSStackView(views: [popup, recorder])
            stack.orientation = .horizontal
            stack.spacing = 8
            stack.alignment = .centerY
            addRow(to: scoped, title: "Slot \(index + 1)", accessory: stack)
            scopePopups.append(popup)
        }

        // In-panel keys section — rebind the action keys used while the switcher
        // is open (close / minimize / hide / quit).
        let panelKeys = addSection(title: "In-panel keys", anchor: SettingsAnchor.panelKeys)
        addRow(
            to: panelKeys,
            title: "Action keys while switching",
            subtitle: "Rebind the keys that act on the highlighted window while the switcher is open. ⌥ with Quit still force-quits.",
            searchItemID: SearchID.panelKeys
        )
        let bindings = Preferences.shared.panelKeyBindings
        for action in PanelKeyAction.allCases {
            let code = bindings[action] ?? action.defaultKeyCode
            let button = KeyCaptureButton(keyCode: code)
            button.onCapture = { [weak self] newCode in self?.setPanelKey(action, newCode) }
            panelKeyButtons[action] = button
            addRow(to: panelKeys, title: action.displayName, accessory: button)
        }
        let resetButton = NSButton(title: "Reset to defaults", target: self, action: #selector(resetPanelKeys))
        resetButton.bezelStyle = .rounded
        resetButton.controlSize = .small
        addRow(to: panelKeys, title: "Defaults", subtitle: "Restore W / M / H / Q.", accessory: resetButton)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refreshDirectSlots()
        refreshScopeSlots()
    }

    // MARK: - Direct activation slots

    /// Sync each slot's "choose app" button to its stored bundle ID.
    private func refreshDirectSlots() {
        let bindings = Preferences.shared.directActivationBindings
        for (index, button) in directButtons.enumerated() {
            let bundleID = bindings.indices.contains(index) ? bindings[index] : ""
            if bundleID.isEmpty {
                button.title = "Choose…"
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
            title: "Activate App",
            prompt: "Choose the app this shortcut focuses.",
            selectedBundleIDs: selected,
            singleSelection: true,
            confirmTitle: "Choose"
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

    // MARK: - Scoped shortcut slots

    /// Sync each slot's scope popup to its stored `SwitchScope`.
    private func refreshScopeSlots() {
        let scopes = Preferences.shared.scopedShortcutScopes
        for (index, popup) in scopePopups.enumerated() {
            let scope = scopes.indices.contains(index) ? scopes[index] : .allAppsAllSpaces
            if let i = scopeOptions.firstIndex(of: scope) { popup.selectItem(at: i) }
        }
    }

    @objc private func scopeChanged(_ sender: NSPopUpButton) {
        let slot = sender.tag
        let idx = sender.indexOfSelectedItem
        guard scopeOptions.indices.contains(idx) else { return }
        var scopes = Preferences.shared.scopedShortcutScopes
        while scopes.count <= slot { scopes.append(.allAppsAllSpaces) }
        scopes[slot] = scopeOptions[idx]
        Preferences.shared.scopedShortcutScopes = scopes
    }

    // MARK: - In-panel keys

    private func setPanelKey(_ action: PanelKeyAction, _ keyCode: Int) {
        var bindings = Preferences.shared.panelKeyBindings
        bindings[action] = keyCode
        Preferences.shared.panelKeyBindings = bindings
    }

    @objc private func resetPanelKeys() {
        var bindings: [PanelKeyAction: Int] = [:]
        for action in PanelKeyAction.allCases {
            bindings[action] = action.defaultKeyCode
            panelKeyButtons[action]?.setKeyCode(action.defaultKeyCode)
        }
        Preferences.shared.panelKeyBindings = bindings
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
