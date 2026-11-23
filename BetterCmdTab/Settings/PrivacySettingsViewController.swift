import AppKit
import BetterPermissions
import BetterSettings

@MainActor
final class PrivacySettingsViewController: SettingsTabViewController {

    private let hideFromScreenSharingSwitch = PreferenceSwitch(bind: \.hideFromScreenSharing)

    private let permissionIcon = NSImageView()
    private let permissionButton = NSButton(title: "", target: nil, action: nil)
    private let screenRecordingIcon = NSImageView()
    private let screenRecordingButton = NSButton(title: "", target: nil, action: nil)
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
        // Permissions first: everything else in the app is gated on these.
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
            title: String(localized: "Screen Recording"),
            subtitle: String(localized: "Lets the Previews layout show window thumbnails. Without it, tiles show the app icon. Optional."),
            accessory: makePermissionAccessory(icon: screenRecordingIcon, button: screenRecordingButton, action: #selector(grantScreenRecording)),
            searchItemID: SearchID.screenRecording
        )

        addRow(
            to: permissions,
            title: String(localized: "Full Disk Access"),
            subtitle: String(localized: "Lets BetterCmdTab read Safari's favicon store so Safari tab entries show site icons. Optional — other browsers don't need it."),
            accessory: makePermissionAccessory(icon: fullDiskIcon, button: fullDiskButton, action: #selector(grantFullDiskAccess)),
            searchItemID: SearchID.fullDiskAccess
        )

        // Apple Events consent for browser tabs — the third permission the app
        // asks for, so it belongs here rather than beside the Tabs options it
        // unlocks.
        let grantButton = NSButton(title: String(localized: "Check access…"), target: self, action: #selector(grantBrowserPermissions))
        grantButton.bezelStyle = .rounded
        grantButton.controlSize = .small
        addRow(
            to: permissions,
            title: String(localized: "Browser tab access"),
            subtitle: String(localized: "Browsers need Apple Events consent to list their tabs. Click to check each running browser (Safari, Chrome, Arc, Brave, Edge…) — macOS prompts for consent where it's still missing. Must be done with this window open."),
            accessory: grantButton,
            searchItemID: SearchID.tabPermissions
        )

        // Screen-sharing section — hide the switcher panel from screen recording
        // / sharing capture (Zoom, Meet, Teams, QuickTime, ScreenCaptureKit).
        let sharing = addSection(title: String(localized: "Screen sharing"), anchor: SettingsAnchor.screenSharing)
        addRow(
            to: sharing,
            title: String(localized: "Don't look at my windows"),
            subtitle: String(localized: "Hide the switcher from screen recordings and shared screens (Zoom, Meet, Teams). Needs macOS 14.6 or later."),
            accessory: hideFromScreenSharingSwitch,
            searchItemID: SearchID.hideFromScreenSharing
        )

        // The Recovery section (restore macOS keyboard shortcuts) moved to the
        // General tab — it's troubleshooting, not privacy.
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

        hideFromScreenSharingSwitch.sync()

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
                for await snapshot in BetterPermissions.changes(.screenRecording) {
                    guard let self else { return }
                    self.refreshPermission(icon: self.screenRecordingIcon, button: self.screenRecordingButton,
                                           isUsable: snapshot.status.isUsable, optional: true)
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

    @objc private func grantAccess() {
        Task { @MainActor in
            let outcome = await BetterPermissions.request(.accessibility)
            if outcome.needsSettings { BetterPermissions.openSettings(for: .accessibility) }
        }
    }

    // CGRequestScreenCaptureAccess prompts once per install; after a denial only the pane can grant it.
    @objc private func grantScreenRecording() {
        Task { @MainActor in
            let outcome = await BetterPermissions.request(.screenRecording)
            if outcome.needsSettings { BetterPermissions.openSettings(for: .screenRecording) }
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
    @objc private func grantBrowserPermissions() {
        BrowserTabs.requestPermissionForRunningBrowsers { [weak self] granted, denied in
            self?.showBrowserPermissionOutcome(granted: granted, denied: denied)
        }
    }

    /// macOS shows the Apple Events consent prompt only once per browser, so
    /// on every later click the button would do nothing visible (#147). Spell
    /// out what happened instead — and when consent was declined earlier, the
    /// only remedy is the Automation pane (the entry is listed under
    /// "osascript", which sends our tab scripts).
    private func showBrowserPermissionOutcome(granted: [String], denied: [String]) {
        let alert = NSAlert()
        if granted.isEmpty && denied.isEmpty {
            alert.alertStyle = .informational
            alert.messageText = String(localized: "No supported browser is running")
            alert.informativeText = String(localized: "Open a supported browser (Safari, Chrome, Arc, Brave, Edge, Vivaldi, Opera, Dia…) and click the button again.")
            alert.addButton(withTitle: String(localized: "OK"))
        } else if denied.isEmpty {
            alert.alertStyle = .informational
            alert.messageText = String(localized: "Browser tab access is working")
            alert.informativeText = String(localized: "Tabs can be listed for: \(granted.joined(separator: ", ")).")
            alert.addButton(withTitle: String(localized: "OK"))
        } else {
            alert.alertStyle = .warning
            alert.messageText = String(localized: "Automation permission needed")
            alert.informativeText = String(localized: "Tab access failed for: \(denied.joined(separator: ", ")). This usually means Automation consent was declined earlier — macOS asks only once and never prompts again. Check the browsers under \"osascript\" in System Settings → Privacy & Security → Automation.")
            alert.addButton(withTitle: String(localized: "Open System Settings"))
            alert.addButton(withTitle: String(localized: "Cancel"))
        }
        let openSettings = { (response: NSApplication.ModalResponse) in
            guard !denied.isEmpty, response == .alertFirstButtonReturn else { return }
            AccessibilityCheck.openSystemSettings(anchor: "Privacy_Automation")
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: openSettings)
        } else {
            openSettings(alert.runModal())
        }
    }
}
