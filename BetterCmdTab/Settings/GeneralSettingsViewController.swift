import AppKit
import BetterSettings
import BetterUpdater
import Combine
import UniformTypeIdentifiers

@MainActor
final class GeneralSettingsViewController: SettingsTabViewController {

    private let launchSwitch = NSSwitch()
    private let hideMenuBarSwitch = NSSwitch()
    private let hapticSwitch = NSSwitch()
    private let soundSwitch = NSSwitch()
    private let betaSwitch = NSSwitch()
    private let intervalPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let exportButton = NSButton(title: "Export…", target: nil, action: nil)
    private let importButton = NSButton(title: "Import…", target: nil, action: nil)

    private var cancellables = Set<AnyCancellable>()

    override func setupContent() {
        // Startup section
        let startup = addSection(title: "Startup", anchor: SettingsAnchor.startup)
        launchSwitch.controlSize = .small
        launchSwitch.target = self
        launchSwitch.action = #selector(toggleLaunchAtLogin(_:))
        addRow(
            to: startup,
            title: "Launch at login",
            subtitle: "Open BetterCmdTab automatically when you log in.",
            accessory: launchSwitch,
            searchItemID: SearchID.launchAtLogin
        )

        configureSwitch(hideMenuBarSwitch, action: #selector(toggleHideMenuBarIcon(_:)))
        addRow(
            to: startup,
            title: "Hide menu bar icon",
            subtitle: "Hide the ⌘ icon. Reopen this window from Spotlight.",
            accessory: hideMenuBarSwitch,
            searchItemID: SearchID.hideMenuBar
        )

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
            subtitle: "Get pre-release builds early. They may be unstable.",
            accessory: betaSwitch,
            searchItemID: SearchID.beta
        )

        // Backup section — export every setting to a file and restore it later
        // or on another Mac. The switcher trigger hotkeys are excluded.
        let backup = addSection(title: "Backup", anchor: SettingsAnchor.backup)
        configureBackupButton(exportButton, action: #selector(exportSettings))
        addRow(
            to: backup,
            title: "Export settings",
            subtitle: "Save all your settings to a file you can back up or move to another Mac.",
            accessory: exportButton,
            searchItemID: SearchID.exportSettings
        )
        configureBackupButton(importButton, action: #selector(importSettings))
        addRow(
            to: backup,
            title: "Import settings",
            subtitle: "Replace your current settings with those from a previously exported file.",
            accessory: importButton,
            searchItemID: SearchID.importSettings
        )
    }

    private func configureBackupButton(_ button: NSButton, action: Selector) {
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.target = self
        button.action = action
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

        let prefs = Preferences.shared
        hideMenuBarSwitch.state = prefs.hideMenuBarIcon ? .on : .off
        hapticSwitch.state = prefs.hapticOnCommit ? .on : .off
        soundSwitch.state = prefs.soundOnCommit ? .on : .off

        let updater = GitHubUpdater.shared
        betaSwitch.state = updater.includePreReleases ? .on : .off

        let cadences = UpdateCheckInterval.selectableCadences
        intervalPopUp.selectItem(at: cadences.firstIndex(of: updater.checkInterval) ?? 0)

        LaunchAtLogin.shared.$isEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.applyLaunchState($0) }
            .store(in: &cancellables)

        updater.$includePreReleases
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.betaSwitch.state = $0 ? .on : .off }
            .store(in: &cancellables)
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
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

    // MARK: - Backup

    @objc private func exportSettings() {
        let panel = NSSavePanel()
        panel.title = "Export Settings"
        panel.prompt = "Export"
        panel.nameFieldStringValue = "BetterCmdTab Settings.\(Preferences.exportFileExtension)"
        if let type = UTType(filenameExtension: Preferences.exportFileExtension) {
            panel.allowedContentTypes = [type, .json]
        }
        panel.isExtensionHidden = false
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let data = try Preferences.shared.exportedJSONData()
                try data.write(to: url, options: .atomic)
            } catch {
                self.presentBackupError("Couldn't export settings", error)
            }
        }
        if let window = view.window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }

    @objc private func importSettings() {
        let panel = NSOpenPanel()
        panel.title = "Import Settings"
        panel.prompt = "Import"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        var types: [UTType] = [.json]
        if let type = UTType(filenameExtension: Preferences.exportFileExtension) { types.insert(type, at: 0) }
        panel.allowedContentTypes = types
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let data = try Data(contentsOf: url)
                try Preferences.shared.importSettings(from: data)
            } catch {
                self.presentBackupError("Couldn't import settings", error)
            }
        }
        if let window = view.window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }

    private func presentBackupError(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }
}
