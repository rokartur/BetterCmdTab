import AppKit
import BetterSettings
import BetterShortcuts
import BetterUpdater
import Combine

@MainActor
final class GeneralSettingsViewController: SettingsTabViewController {

    private let launchSwitch = NSSwitch()
    private let hideMenuBarSwitch = NSSwitch()
    private let hapticSwitch = NSSwitch()
    private let soundSwitch = NSSwitch()
    private let hideFromScreenSharingSwitch = NSSwitch()
    private let betaSwitch = NSSwitch()
    private let intervalPopUp = NSPopUpButton(frame: .zero, pullsDown: false)

    private let permissionIcon = NSImageView()
    private let permissionButton = NSButton(title: "", target: nil, action: nil)

    private let appRecorder = BetterShortcuts.RecorderCocoa(for: .switchApps)
    private let windowRecorder = BetterShortcuts.RecorderCocoa(for: .switchWindows)

    // Direct-activation slots: a "choose app" button + shortcut recorder per slot.
    private var directButtons: [NSButton] = []
    private var directSlotSheet: AppsPickerSheetWindowController?

    private var cancellables = Set<AnyCancellable>()
    private var axTimer: Timer?

    override func setupContent() {
        // Startup section
        let startup = addSection(title: "Startup", anchor: SettingsAnchor.startup)
        launchSwitch.controlSize = .small
        launchSwitch.target = self
        launchSwitch.action = #selector(toggleLaunchAtLogin(_:))
        addRow(to: startup, title: "Launch at login", accessory: launchSwitch, searchItemID: SearchID.launchAtLogin)

        configureSwitch(hideMenuBarSwitch, action: #selector(toggleHideMenuBarIcon(_:)))
        addRow(
            to: startup,
            title: "Hide menu bar icon",
            subtitle: "Hides the ⌘ icon. Relaunch the app (e.g. from Spotlight) to reopen this window.",
            accessory: hideMenuBarSwitch,
            searchItemID: SearchID.hideMenuBar
        )

        // Shortcuts section — native BetterShortcuts recorders. The trigger must
        // include a hold modifier (Command/Option/Control); Shift is reserved for
        // reverse-direction stepping and is rejected by the recorder.
        let shortcuts = addSection(title: "Shortcuts", anchor: SettingsAnchor.shortcuts)
        addRow(
            to: shortcuts,
            title: "Switch apps",
            subtitle: "Hold the modifier and tap to cycle through your open apps.",
            accessory: appRecorder,
            searchItemID: SearchID.switchApps
        )
        addRow(
            to: shortcuts,
            title: "Switch windows",
            subtitle: "Cycle between the windows of the active app.",
            accessory: windowRecorder,
            searchItemID: SearchID.switchWindows
        )

        // Direct activation section — global shortcuts that jump straight to a
        // chosen app, bypassing the switcher.
        let direct = addSection(title: "Direct activation", anchor: SettingsAnchor.directActivation)
        addRow(
            to: direct,
            title: "Jump straight to an app",
            subtitle: "Assign a shortcut to focus a specific app, launching it if it isn't running.",
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

        // Feedback section — confirmation cues on commit.
        let feedback = addSection(title: "Feedback", anchor: SettingsAnchor.feedback)
        configureSwitch(hapticSwitch, action: #selector(toggleHaptic(_:)))
        addRow(
            to: feedback,
            title: "Haptic feedback on switch",
            subtitle: "A tap when you pick an app. Force Touch trackpads only.",
            accessory: hapticSwitch,
            searchItemID: SearchID.haptic
        )
        configureSwitch(soundSwitch, action: #selector(toggleSound(_:)))
        addRow(
            to: feedback,
            title: "Sound on switch",
            subtitle: "A soft click when you pick an app.",
            accessory: soundSwitch,
            searchItemID: SearchID.sound
        )

        // Privacy section — hide the switcher panel from screen recording /
        // sharing capture (Zoom, Meet, Teams, QuickTime, ScreenCaptureKit).
        let privacy = addSection(title: "Privacy", anchor: SettingsAnchor.privacy)
        configureSwitch(hideFromScreenSharingSwitch, action: #selector(toggleHideFromScreenSharing(_:)))
        addRow(
            to: privacy,
            title: "Don't look at my windows",
            subtitle: "Hide the switcher from screen sharing and recording. Requires macOS 14.6 or later.",
            accessory: hideFromScreenSharingSwitch,
            searchItemID: SearchID.hideFromScreenSharing
        )

        // Permissions section
        let permissions = addSection(title: "Permissions", anchor: SettingsAnchor.permissions)

        permissionIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        permissionIcon.translatesAutoresizingMaskIntoConstraints = false
        permissionIcon.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            permissionIcon.widthAnchor.constraint(equalToConstant: 16),
            permissionIcon.heightAnchor.constraint(equalToConstant: 16),
        ])

        permissionButton.bezelStyle = .rounded
        permissionButton.controlSize = .small
        permissionButton.target = self
        permissionButton.action = #selector(openSystemSettings)

        let permissionAccessory = NSStackView()
        permissionAccessory.orientation = .horizontal
        permissionAccessory.spacing = 8
        permissionAccessory.alignment = .centerY
        permissionAccessory.addArrangedSubview(permissionIcon)
        permissionAccessory.addArrangedSubview(permissionButton)

        addRow(
            to: permissions,
            title: "Accessibility access",
            subtitle: "Needed to capture the shortcut and read your open windows.",
            accessory: permissionAccessory,
            searchItemID: SearchID.accessibility
        )

        // Updates section
        let updates = addSection(title: "Updates", anchor: SettingsAnchor.updates)

        for cadence in UpdateCheckInterval.selectableCadences {
            intervalPopUp.addItem(withTitle: cadence.title)
        }
        intervalPopUp.controlSize = .small
        intervalPopUp.target = self
        intervalPopUp.action = #selector(changeInterval(_:))
        addRow(
            to: updates,
            title: "Check for updates",
            subtitle: "How often to check automatically. The beta channel always checks hourly.",
            accessory: intervalPopUp,
            searchItemID: SearchID.updateInterval
        )

        betaSwitch.controlSize = .small
        betaSwitch.target = self
        betaSwitch.action = #selector(toggleBeta(_:))
        addRow(
            to: updates,
            title: "Include beta releases",
            subtitle: "Beta builds may be unstable.",
            accessory: betaSwitch,
            searchItemID: SearchID.beta
        )
    }

    private func configureSwitch(_ toggle: NSSwitch, action: Selector) {
        toggle.controlSize = .small
        toggle.target = self
        toggle.action = action
    }

    override func viewWillAppear() {
        super.viewWillAppear()

        LaunchAtLogin.shared.refresh()
        applyLaunchState(LaunchAtLogin.shared.isEnabled)
        refreshAccessibilityStatus()

        let prefs = Preferences.shared
        hideMenuBarSwitch.state = prefs.hideMenuBarIcon ? .on : .off
        hapticSwitch.state = prefs.hapticOnCommit ? .on : .off
        soundSwitch.state = prefs.soundOnCommit ? .on : .off
        hideFromScreenSharingSwitch.state = prefs.hideFromScreenSharing ? .on : .off

        refreshDirectSlots()

        let updater = GitHubUpdater.shared
        betaSwitch.state = updater.includePreReleases ? .on : .off

        let cadences = UpdateCheckInterval.selectableCadences
        intervalPopUp.selectItem(at: cadences.firstIndex(of: updater.checkInterval) ?? 0)

        LaunchAtLogin.shared.$isEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.applyLaunchState($0) }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.refreshAccessibilityStatus() }
            .store(in: &cancellables)

        updater.$includePreReleases
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.betaSwitch.state = $0 ? .on : .off }
            .store(in: &cancellables)

        startAccessibilityPolling()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        stopAccessibilityPolling()
        cancellables.removeAll()
    }

    private func applyLaunchState(_ enabled: Bool) {
        let target: NSControl.StateValue = enabled ? .on : .off
        if launchSwitch.state != target { launchSwitch.state = target }
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSSwitch) {
        LaunchAtLogin.shared.setEnabled(sender.state == .on)
    }

    @objc private func toggleBeta(_ sender: NSSwitch) {
        GitHubUpdater.shared.includePreReleases = (sender.state == .on)
    }

    @objc private func changeInterval(_ sender: NSPopUpButton) {
        let cadences = UpdateCheckInterval.selectableCadences
        let idx = sender.indexOfSelectedItem
        guard cadences.indices.contains(idx) else { return }
        GitHubUpdater.shared.setCheckInterval(cadences[idx])
    }

    @objc private func toggleHideMenuBarIcon(_ sender: NSSwitch) {
        Preferences.shared.hideMenuBarIcon = (sender.state == .on)
    }

    @objc private func toggleHaptic(_ sender: NSSwitch) {
        Preferences.shared.hapticOnCommit = (sender.state == .on)
    }

    @objc private func toggleSound(_ sender: NSSwitch) {
        Preferences.shared.soundOnCommit = (sender.state == .on)
    }

    @objc private func toggleHideFromScreenSharing(_ sender: NSSwitch) {
        Preferences.shared.hideFromScreenSharing = (sender.state == .on)
    }

    @objc private func openSystemSettings() {
        AccessibilityCheck.promptIfNeeded()
        AccessibilityCheck.openSystemSettings()
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
            singleSelection: true
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

    private func refreshAccessibilityStatus() {
        if AccessibilityCheck.isTrusted {
            permissionIcon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Granted")
            permissionIcon.contentTintColor = .systemGreen
            permissionButton.title = "Open Settings"
        } else {
            permissionIcon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Required")
            permissionIcon.contentTintColor = .systemOrange
            permissionButton.title = "Grant Access"
        }
    }

    private func startAccessibilityPolling() {
        axTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshAccessibilityStatus() }
        }
        RunLoop.main.add(timer, forMode: .common)
        axTimer = timer
    }

    private func stopAccessibilityPolling() {
        axTimer?.invalidate()
        axTimer = nil
    }
}
