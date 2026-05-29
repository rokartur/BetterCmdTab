import AppKit
import BetterSettings
import Combine

@MainActor
final class PrivacySettingsViewController: SettingsTabViewController {

    private let hideFromScreenSharingSwitch = NSSwitch()

    private let permissionIcon = NSImageView()
    private let permissionButton = NSButton(title: "", target: nil, action: nil)

    private var cancellables = Set<AnyCancellable>()
    private var axTimer: Timer?

    override func setupContent() {
        // Screen-sharing section — hide the switcher panel from screen recording
        // / sharing capture (Zoom, Meet, Teams, QuickTime, ScreenCaptureKit).
        let sharing = addSection(title: String(localized: "Screen sharing"), anchor: SettingsAnchor.screenSharing)
        configureSwitch(hideFromScreenSharingSwitch, action: #selector(toggleHideFromScreenSharing(_:)))
        addRow(
            to: sharing,
            title: String(localized: "Don't look at my windows"),
            subtitle: String(localized: "Hide the switcher from screen recordings and shared screens (Zoom, Meet, Teams). Needs macOS 14.6 or later."),
            accessory: hideFromScreenSharingSwitch,
            searchItemID: SearchID.hideFromScreenSharing
        )

        // Permissions section.
        let permissions = addSection(title: String(localized: "Permissions"), anchor: SettingsAnchor.permissions)

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
            title: String(localized: "Accessibility access"),
            subtitle: String(localized: "Lets BetterCmdTab capture the shortcut and read your open windows. Required to work."),
            accessory: permissionAccessory,
            searchItemID: SearchID.accessibility
        )
    }

    private func configureSwitch(_ toggle: NSSwitch, action: Selector) {
        toggle.controlSize = .small
        toggle.target = self
        toggle.action = action
    }

    override func viewWillAppear() {
        super.viewWillAppear()

        hideFromScreenSharingSwitch.state = Preferences.shared.hideFromScreenSharing ? .on : .off
        refreshAccessibilityStatus()

        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.refreshAccessibilityStatus() }
            .store(in: &cancellables)

        startAccessibilityPolling()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        stopAccessibilityPolling()
        cancellables.removeAll()
    }

    @objc private func toggleHideFromScreenSharing(_ sender: NSSwitch) {
        Preferences.shared.hideFromScreenSharing = (sender.state == .on)
    }

    @objc private func openSystemSettings() {
        AccessibilityCheck.promptIfNeeded()
        AccessibilityCheck.openSystemSettings()
    }

    private func refreshAccessibilityStatus() {
        if AccessibilityCheck.isTrusted {
            permissionIcon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: String(localized: "Granted"))
            permissionIcon.contentTintColor = .systemGreen
            permissionButton.title = String(localized: "Open Settings")
        } else {
            permissionIcon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: String(localized: "Required"))
            permissionIcon.contentTintColor = .systemOrange
            permissionButton.title = String(localized: "Grant Access")
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
