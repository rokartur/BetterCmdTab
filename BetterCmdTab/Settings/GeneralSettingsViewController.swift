import AppKit
import Combine

@MainActor
final class GeneralSettingsViewController: NSViewController {

    private let launchSwitch = NSSwitch()
    private let accessibilityRow = SettingsRowView(title: "Accessibility access")
    private let permissionIcon = NSImageView()
    private let permissionButton = NSButton(title: "", target: nil, action: nil)

    private let betaSwitch = NSSwitch()

    private var cancellables = Set<AnyCancellable>()
    private var axTimer: Timer?

    override func loadView() {
        // Behavior section
        let behavior = SettingsSectionView(header: "Behavior")
        let launchRow = SettingsRowView(
            title: "Launch at login",
            subtitle: "Start \(AppInfo.displayName) automatically when you sign in.",
            accessory: launchSwitch
        )
        launchSwitch.controlSize = .small
        launchSwitch.target = self
        launchSwitch.action = #selector(toggleLaunchAtLogin(_:))
        behavior.addContent(launchRow)

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

        // Update Channel section
        let updates = SettingsSectionView(header: "Update Channel")
        let betaRow = SettingsRowView(
            title: "Include beta releases",
            subtitle: "Receive pre-release versions when checking for updates.",
            accessory: betaSwitch
        )
        betaSwitch.controlSize = .small
        betaSwitch.target = self
        betaSwitch.action = #selector(toggleBeta(_:))
        updates.addContent(betaRow)

        view = SettingsLayout.makeScrollingTab(sections: [behavior, permissions, updates])
    }

    override func viewWillAppear() {
        super.viewWillAppear()

        LaunchAtLogin.shared.refresh()
        applyLaunchState(LaunchAtLogin.shared.isEnabled)
        refreshAccessibilityStatus()

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

    @objc private func openSystemSettings() {
        AccessibilityCheck.promptIfNeeded()
        AccessibilityCheck.openSystemSettings()
    }

    private func refreshAccessibilityStatus() {
        if AccessibilityCheck.isTrusted {
            permissionIcon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Granted")
            permissionIcon.contentTintColor = .systemGreen
            accessibilityRow.rowDescription = "Granted — \(AppInfo.displayName) can observe window focus changes."
            permissionButton.title = "Open Settings"
        } else {
            permissionIcon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Required")
            permissionIcon.contentTintColor = .systemOrange
            accessibilityRow.rowDescription = "Required to detect window focus changes. Without it, \(AppInfo.displayName) cannot switch between windows."
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
