import AppKit
import Combine

@MainActor
final class GeneralSettingsViewController: NSViewController {

    private let launchSwitch = NSSwitch()
    private let hideMenuBarSwitch = NSSwitch()
    private let hapticSwitch = NSSwitch()
    private let soundSwitch = NSSwitch()
    private let betaSwitch = NSSwitch()

    private let accessibilityRow = SettingsRowView(
        title: "Accessibility access",
        description: "Needed to capture the shortcut and read your open windows."
    )
    private let permissionIcon = NSImageView()
    private let permissionButton = NSButton(title: "", target: nil, action: nil)

    private let appRecorder = KeyboardShortcuts.RecorderCocoa(for: .switchApps)
    private let windowRecorder = KeyboardShortcuts.RecorderCocoa(for: .switchWindows)

    private var cancellables = Set<AnyCancellable>()
    private var axTimer: Timer?

    override func loadView() {
        // Startup section
        let startup = SettingsSectionView(header: "Startup")
        let launchRow = SettingsRowView(title: "Launch at login", accessory: launchSwitch)
        launchSwitch.controlSize = .small
        launchSwitch.target = self
        launchSwitch.action = #selector(toggleLaunchAtLogin(_:))
        startup.addContent(launchRow)

        configureSwitch(hideMenuBarSwitch, action: #selector(toggleHideMenuBarIcon(_:)))
        startup.addContent(SettingsRowView(
            title: "Hide menu bar icon",
            subtitle: "Hides the ⌘ icon. Relaunch the app (e.g. from Spotlight) to reopen this window.",
            accessory: hideMenuBarSwitch
        ))

        // Shortcuts section — native KeyboardShortcuts recorders. The trigger must
        // include a hold modifier (Command/Option/Control); Shift is reserved for
        // reverse-direction stepping and is rejected by the recorder.
        let shortcuts = SettingsSectionView(header: "Shortcuts")
        shortcuts.addContent(SettingsRowView(
            title: "Switch apps",
            subtitle: "Hold the modifier and tap to cycle through your open apps.",
            accessory: appRecorder
        ))
        shortcuts.addContent(SettingsRowView(
            title: "Switch windows",
            subtitle: "Cycle between the windows of the active app.",
            accessory: windowRecorder
        ))

        // Feedback section — confirmation cues on commit.
        let feedback = SettingsSectionView(header: "Feedback")
        configureSwitch(hapticSwitch, action: #selector(toggleHaptic(_:)))
        feedback.addContent(SettingsRowView(
            title: "Haptic feedback on switch",
            subtitle: "A tap when you pick an app. Force Touch trackpads only.",
            accessory: hapticSwitch
        ))
        configureSwitch(soundSwitch, action: #selector(toggleSound(_:)))
        feedback.addContent(SettingsRowView(
            title: "Sound on switch",
            subtitle: "A soft click when you pick an app.",
            accessory: soundSwitch
        ))

        // Permissions section
        let permissions = SettingsSectionView(header: "Permissions")

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

        accessibilityRow.setAccessory(permissionAccessory)
        permissions.addContent(accessibilityRow)

        // Updates section
        let updates = SettingsSectionView(header: "Updates")
        let betaRow = SettingsRowView(
            title: "Include beta releases",
            description: "Beta builds may be unstable.",
            accessory: betaSwitch
        )
        betaSwitch.controlSize = .small
        betaSwitch.target = self
        betaSwitch.action = #selector(toggleBeta(_:))
        updates.addContent(betaRow)

        view = SettingsLayout.makeScrollingTab(sections: [startup, shortcuts, feedback, permissions, updates])
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

        let updater = GitHubUpdater.shared
        betaSwitch.state = updater.includePreReleases ? .on : .off

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

    @objc private func toggleHideMenuBarIcon(_ sender: NSSwitch) {
        Preferences.shared.hideMenuBarIcon = (sender.state == .on)
    }

    @objc private func toggleHaptic(_ sender: NSSwitch) {
        Preferences.shared.hapticOnCommit = (sender.state == .on)
    }

    @objc private func toggleSound(_ sender: NSSwitch) {
        Preferences.shared.soundOnCommit = (sender.state == .on)
    }

    @objc private func openSystemSettings() {
        AccessibilityCheck.promptIfNeeded()
        AccessibilityCheck.openSystemSettings()
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
