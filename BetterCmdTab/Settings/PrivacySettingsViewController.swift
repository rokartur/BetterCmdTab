import AppKit
import BetterPermissions
import BetterSettings

@MainActor
final class PrivacySettingsViewController: SettingsTabViewController {

    private let hideFromScreenSharingSwitch = NSSwitch()

    private let permissionIcon = NSImageView()
    private let permissionButton = NSButton(title: "", target: nil, action: nil)
    private let fullDiskIcon = NSImageView()
    private let fullDiskButton = NSButton(title: "", target: nil, action: nil)

    private var observationTasks: [Task<Void, Never>] = []

    deinit {
        // Releasing a Task handle does not cancel the task. This is the final
        // backstop for teardown paths that skip both viewWillDisappear and
        // BetterSettings' prepareForMemoryRelease hook.
        observationTasks.forEach { $0.cancel() }
    }

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

        addRow(
            to: permissions,
            title: String(localized: "Accessibility access"),
            subtitle: String(localized: "Lets BetterCmdTab capture the shortcut and read your open windows. Required to work."),
            accessory: makePermissionAccessory(icon: permissionIcon, button: permissionButton, action: #selector(grantAccess)),
            searchItemID: SearchID.accessibility
        )

        addRow(
            to: permissions,
            title: String(localized: "Full Disk Access"),
            subtitle: String(localized: "Lets BetterCmdTab read Safari's favicon store so Safari tab entries show site icons. Optional — other browsers don't need it."),
            accessory: makePermissionAccessory(icon: fullDiskIcon, button: fullDiskButton, action: #selector(grantFullDiskAccess)),
            searchItemID: SearchID.fullDiskAccess
        )

        // The Recovery section (restore macOS keyboard shortcuts) moved to the
        // General tab — it's troubleshooting, not privacy.
    }

    private func configureSwitch(_ toggle: NSSwitch, action: Selector) {
        toggle.controlSize = .small
        toggle.target = self
        toggle.action = action
    }

    /// Status icon + grant button pair used by every permission row.
    private func makePermissionAccessory(icon: NSImageView, button: NSButton, action: Selector) -> NSStackView {
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
        ])

        button.bezelStyle = .rounded
        button.controlSize = .small
        button.target = self
        button.action = action

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        stack.addArrangedSubview(icon)
        stack.addArrangedSubview(button)
        return stack
    }

    override func viewWillAppear() {
        super.viewWillAppear()

        hideFromScreenSharingSwitch.state = Preferences.shared.hideFromScreenSharing ? .on : .off

        // Reactive accessibility status via BetterPermissions: yields the current value
        // immediately, then every change (TCC notification / app activation / adaptive
        // poll), replacing the hand-rolled 1 Hz timer + didBecomeActive observer. The
        // engine disarms when this task is cancelled on disappear / memory release.
        cancelObservations() // never leak a second armed observation
        observationTasks = [
            Task { @MainActor [weak self] in
                for await snapshot in BetterPermissions.changes(.accessibility) {
                    guard let self else { return }
                    self.refreshPermission(icon: self.permissionIcon, button: self.permissionButton,
                                           isUsable: snapshot.status.isUsable, optional: false)
                }
            },
            Task { @MainActor [weak self] in
                for await snapshot in BetterPermissions.changes(.fullDiskAccess) {
                    guard let self else { return }
                    self.refreshPermission(icon: self.fullDiskIcon, button: self.fullDiskButton,
                                           isUsable: snapshot.status.isUsable, optional: true)
                }
            },
        ]
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        cancelObservations()
    }

    private func cancelObservations() {
        observationTasks.forEach { $0.cancel() }
        observationTasks.removeAll()
    }

    // BetterSettings can tear down the active tab (window close / memory eviction)
    // without a matching viewWillDisappear, which would orphan the observation Task and
    // leave the BetterPermissions accessibility detector armed for the process lifetime.
    override func prepareForMemoryRelease() {
        cancelObservations()
        super.prepareForMemoryRelease()
    }

    @objc private func toggleHideFromScreenSharing(_ sender: NSSwitch) {
        Preferences.shared.hideFromScreenSharing = (sender.state == .on)
    }

    @objc private func grantAccess() {
        Task { @MainActor in
            let outcome = await BetterPermissions.request(.accessibility)
            if outcome.needsSettings { BetterPermissions.openSettings(for: .accessibility) }
        }
    }

    @objc private func grantFullDiskAccess() {
        // FDA has no prompt API — the button always deep-links to the
        // System Settings pane; the observation picks up the grant on return.
        BetterPermissions.openSettings(for: .fullDiskAccess)
    }

    /// Shared status render for a permission row. `optional` picks the
    /// not-granted look: a neutral gray minus for nice-to-have permissions,
    /// an orange warning for required ones.
    private func refreshPermission(icon: NSImageView, button: NSButton, isUsable: Bool, optional: Bool) {
        if isUsable {
            // Granted: show the state only — no actionable button.
            icon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: String(localized: "Granted"))
            icon.contentTintColor = .systemGreen
            button.isHidden = true
        } else {
            icon.image = optional
                ? NSImage(systemSymbolName: "minus.circle.fill", accessibilityDescription: String(localized: "Not granted"))
                : NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: String(localized: "Required"))
            icon.contentTintColor = optional ? .secondaryLabelColor : .systemOrange
            button.isHidden = false
            button.title = String(localized: "Grant Access")
        }
    }
}
