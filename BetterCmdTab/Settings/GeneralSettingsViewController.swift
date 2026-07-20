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
    private let soundPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let betaSwitch = NSSwitch()
    private let intervalPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let exportButton = NSButton(title: String(localized: "Export…"), target: nil, action: nil)
    private let importButton = NSButton(title: String(localized: "Import…"), target: nil, action: nil)
    private let configFileButton = NSButton(title: "", target: nil, action: nil)
    private let restoreShortcutsButton = NSButton(title: "", target: nil, action: nil)

    private var cancellables = Set<AnyCancellable>()
    private lazy var systemSoundNames = CommitFeedback.systemSoundNames()

    private enum SoundItemTag: Int {
        case off
        case system
        case custom
        case chooseCustom
    }

    /// Cadences offered in the update popup. The package's `selectableCadences`
    /// excludes `.manual`; it's appended here so update checks (and their
    /// network traffic) can be turned off entirely — a manual check stays
    /// available from the About pane.
    private let updateCadences: [UpdateCheckInterval] = UpdateCheckInterval.selectableCadences + [.manual]

    override func setupContent() {
        // Startup section
        let startup = addSection(title: String(localized: "Startup"), anchor: SettingsAnchor.startup)
        launchSwitch.controlSize = .small
        launchSwitch.target = self
        launchSwitch.action = #selector(toggleLaunchAtLogin(_:))
        addRow(
            to: startup,
            title: String(localized: "Launch at login"),
            subtitle: String(localized: "Open BetterCmdTab automatically when you log in."),
            accessory: launchSwitch,
            searchItemID: SearchID.launchAtLogin
        )

        configureSwitch(hideMenuBarSwitch, action: #selector(toggleHideMenuBarIcon(_:)))
        addRow(
            to: startup,
            title: String(localized: "Hide menu bar icon"),
            subtitle: String(localized: "Hide the ⌘ icon. Reopen this window from Spotlight."),
            accessory: hideMenuBarSwitch,
            searchItemID: SearchID.hideMenuBar
        )

        // Feedback section — confirmation cues on commit.
        let feedback = addSection(title: String(localized: "Feedback"), anchor: SettingsAnchor.feedback)
        configureSwitch(hapticSwitch, action: #selector(toggleHaptic(_:)))
        addRow(
            to: feedback,
            title: String(localized: "Haptic feedback on switch"),
            subtitle: String(localized: "A tap when you pick an app. Force Touch trackpads only."),
            accessory: hapticSwitch,
            searchItemID: SearchID.haptic
        )
        soundPopup.controlSize = .small
        soundPopup.target = self
        soundPopup.action = #selector(changeSound(_:))
        addRow(
            to: feedback,
            title: String(localized: "Sound on switch"),
            subtitle: String(localized: "Play a sound when you pick an app."),
            accessory: soundPopup,
            searchItemID: SearchID.sound
        )
        soundPopup.cell?.lineBreakMode = .byTruncatingMiddle
        soundPopup.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        soundPopup.widthAnchor.constraint(lessThanOrEqualToConstant: 180).isActive = true
        rebuildSoundMenu()

        // Updates section
        let updates = addSection(title: String(localized: "Updates"), anchor: SettingsAnchor.updates)

        for cadence in updateCadences {
            intervalPopUp.addItem(withTitle: cadence.title)
        }
        intervalPopUp.controlSize = .small
        intervalPopUp.target = self
        intervalPopUp.action = #selector(changeInterval(_:))
        addRow(
            to: updates,
            title: String(localized: "Check for updates"),
            subtitle: String(localized: "How often to check automatically. The beta channel always checks hourly."),
            accessory: intervalPopUp,
            searchItemID: SearchID.updateInterval
        )

        betaSwitch.controlSize = .small
        betaSwitch.target = self
        betaSwitch.action = #selector(toggleBeta(_:))
        addRow(
            to: updates,
            title: String(localized: "Include beta releases"),
            subtitle: String(localized: "Get pre-release builds early. They may be unstable."),
            accessory: betaSwitch,
            searchItemID: SearchID.beta
        )

        // Backup section — export every setting to a file and restore it later
        // or on another Mac. The switcher trigger hotkeys are excluded.
        let backup = addSection(title: String(localized: "Backup"), anchor: SettingsAnchor.backup)
        configureBackupButton(exportButton, action: #selector(exportSettings))
        addRow(
            to: backup,
            title: String(localized: "Export settings"),
            subtitle: String(localized: "Save all your settings to a file you can back up or move to another Mac."),
            accessory: exportButton,
            searchItemID: SearchID.exportSettings
        )
        configureBackupButton(importButton, action: #selector(importSettings))
        addRow(
            to: backup,
            title: String(localized: "Import settings"),
            subtitle: String(localized: "Replace your current settings with those from a previously exported file."),
            accessory: importButton,
            searchItemID: SearchID.importSettings
        )
        configureBackupButton(configFileButton, action: #selector(configFileAction))
        refreshConfigFileButton()
        let configPath = (ConfigFile.url.path as NSString).abbreviatingWithTildeInPath
        addRow(
            to: backup,
            title: String(localized: "Configuration file"),
            subtitle: String(localized: "Keep settings in \(configPath). Edits to the file apply live, and changes made here are written back."),
            accessory: configFileButton,
            searchItemID: SearchID.configFile
        )

        // Recovery section — manual escape hatch if the native ⌘Tab is stuck
        // (moved here from Privacy: it's troubleshooting, not privacy).
        // BetterCmdTab disables the system's ⌘Tab so it can take over under
        // Secure Event Input; that disable lives in the WindowServer and
        // outlives the process, so an unclean exit (crash, Force Quit) can leave
        // macOS's own ⌘Tab dead. This button re-enables every native chord, then
        // the live trigger re-disables only what it currently needs.
        let recovery = addSection(title: String(localized: "Recovery"), anchor: SettingsAnchor.recovery)
        restoreShortcutsButton.bezelStyle = .rounded
        restoreShortcutsButton.controlSize = .small
        restoreShortcutsButton.title = String(localized: "Restore")
        restoreShortcutsButton.target = self
        restoreShortcutsButton.action = #selector(restoreNativeShortcuts)
        addRow(
            to: recovery,
            title: String(localized: "Restore macOS keyboard shortcuts"),
            subtitle: String(localized: "Re-enable the system's ⌘Tab and ⌘` — for example if they got stuck off after a crash. BetterCmdTab hands them back to macOS until you next relaunch it."),
            accessory: restoreShortcutsButton,
            searchItemID: SearchID.restoreShortcuts
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

        refreshConfigFileButton()
        LaunchAtLogin.shared.refresh()
        applyLaunchState(LaunchAtLogin.shared.isEnabled)

        let prefs = Preferences.shared
        hideMenuBarSwitch.state = prefs.hideMenuBarIcon ? .on : .off
        hapticSwitch.state = prefs.hapticOnCommit ? .on : .off
        rebuildSoundMenu()

        let updater = GitHubUpdater.shared
        betaSwitch.state = updater.includePreReleases ? .on : .off

        intervalPopUp.selectItem(at: updateCadences.firstIndex(of: updater.checkInterval) ?? 0)

        LaunchAtLogin.shared.$isEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.applyLaunchState($0) }
            .store(in: &cancellables)

        updater.$includePreReleases
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.betaSwitch.state = $0 ? .on : .off }
            .store(in: &cancellables)

        // Keep the Preferences-backed switches in sync when the values change
        // underneath us — a settings import calls reloadFromDefaults while
        // this pane (which hosts the Import button) is still on screen.
        prefs.$hideMenuBarIcon
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.hideMenuBarSwitch.state = $0 ? .on : .off }
            .store(in: &cancellables)

        prefs.$hapticOnCommit
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.hapticSwitch.state = $0 ? .on : .off }
            .store(in: &cancellables)

        prefs.$soundOnCommit
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuildSoundMenu() }
            .store(in: &cancellables)

        prefs.$commitSoundName
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuildSoundMenu() }
            .store(in: &cancellables)

        prefs.$customCommitSoundFilename
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuildSoundMenu() }
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
        let idx = sender.indexOfSelectedItem
        guard updateCadences.indices.contains(idx) else { return }
        GitHubUpdater.shared.setCheckInterval(updateCadences[idx])
    }

    @objc private func toggleHideMenuBarIcon(_ sender: NSSwitch) {
        Preferences.shared.hideMenuBarIcon = (sender.state == .on)
    }

    @objc private func toggleHaptic(_ sender: NSSwitch) {
        Preferences.shared.hapticOnCommit = (sender.state == .on)
    }

    @objc private func changeSound(_ sender: NSPopUpButton) {
        guard let item = sender.selectedItem,
              let tag = SoundItemTag(rawValue: item.tag) else {
            rebuildSoundMenu()
            return
        }

        let prefs = Preferences.shared
        switch tag {
        case .off:
            prefs.soundOnCommit = false
            CommitFeedback.stop()
        case .system:
            guard let name = item.representedObject as? String else { return }
            CommitFeedback.selectSystemSound(named: name)
            prefs.soundOnCommit = true
            CommitFeedback.preview()
        case .custom:
            prefs.soundOnCommit = true
            CommitFeedback.preview()
        case .chooseCustom:
            chooseCustomSound()
        }
    }

    private func rebuildSoundMenu() {
        let prefs = Preferences.shared
        let menu = NSMenu()

        let offItem = NSMenuItem(title: String(localized: "Off"), action: nil, keyEquivalent: "")
        offItem.tag = SoundItemTag.off.rawValue
        menu.addItem(offItem)
        menu.addItem(.separator())

        var selectedSystemItem: NSMenuItem?
        for name in systemSoundNames {
            let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
            item.tag = SoundItemTag.system.rawValue
            item.representedObject = name
            menu.addItem(item)
            if name == prefs.commitSoundName { selectedSystemItem = item }
        }

        menu.addItem(.separator())
        var customItem: NSMenuItem?
        if let filename = prefs.customCommitSoundFilename {
            let displayName = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
            let item = NSMenuItem(
                title: String(format: String(localized: "Custom: %@"), displayName),
                action: nil,
                keyEquivalent: ""
            )
            item.tag = SoundItemTag.custom.rawValue
            menu.addItem(item)
            customItem = item
        }

        let chooseItem = NSMenuItem(title: String(localized: "Choose Custom Sound…"), action: nil, keyEquivalent: "")
        chooseItem.tag = SoundItemTag.chooseCustom.rawValue
        menu.addItem(chooseItem)

        soundPopup.menu = menu
        if !prefs.soundOnCommit {
            soundPopup.select(offItem)
        } else if let customItem {
            soundPopup.select(customItem)
        } else {
            soundPopup.select(selectedSystemItem ?? menu.item(withTitle: Preferences.defaultCommitSoundName) ?? offItem)
        }
    }

    private func chooseCustomSound() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose Custom Sound…")
        panel.prompt = String(localized: "Choose")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.audio]

        let completion: (NSApplication.ModalResponse) -> Void = { response in
            defer { self.rebuildSoundMenu() }
            guard response == .OK, let url = panel.url else { return }
            do {
                try CommitFeedback.installCustomSound(from: url)
                Preferences.shared.soundOnCommit = true
                CommitFeedback.preview()
            } catch {
                self.presentError(String(localized: "Sound on switch"), error)
            }
        }
        if let window = view.window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }

    @objc private func restoreNativeShortcuts() {
        // Hand off to the live SwitcherController (it owns the symbolic-hotkey
        // state and the Carbon fallback), which re-enables every native chord and
        // then re-syncs the override for the current trigger.
        NotificationCenter.default.post(name: Notification.Name("BetterCmdTab_restoreNativeShortcuts"), object: nil)
    }

    // MARK: - Backup

    @objc private func exportSettings() {
        let panel = NSSavePanel()
        panel.title = String(localized: "Export Settings")
        panel.prompt = String(localized: "Export")
        // Name carries NO extension — the panel appends `.json` from the
        // content type (#117 replaced the .cmdtab envelope with flat JSON;
        // old .cmdtab files still import).
        panel.nameFieldStringValue = Preferences.exportDefaultBaseName
        panel.allowedContentTypes = [.json]
        panel.isExtensionHidden = false
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let data = try Preferences.exportedJSONData()
                try data.write(to: url, options: .atomic)
            } catch {
                self.presentError(String(localized: "Couldn't export settings"), error)
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
        panel.title = String(localized: "Import Settings")
        panel.prompt = String(localized: "Import")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        var types: [UTType] = [.json]
        if let type = UTType(Preferences.exportUTIIdentifier) ?? UTType(filenameExtension: Preferences.exportFileExtension) {
            types.insert(type, at: 0)
        }
        panel.allowedContentTypes = types
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let data = try Data(contentsOf: url)
                try Preferences.shared.importSettings(from: data)
            } catch {
                self.presentError(String(localized: "Couldn't import settings"), error)
            }
        }
        if let window = view.window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }

    private func refreshConfigFileButton() {
        configFileButton.title = ConfigFile.fileExists
            ? String(localized: "Show in Finder")
            : String(localized: "Create…")
    }

    @objc private func configFileAction() {
        if ConfigFile.fileExists {
            NSWorkspace.shared.activateFileViewerSelecting([ConfigFile.url])
        } else {
            do {
                try ConfigFile.shared.createFileAndActivate()
            } catch {
                presentError(String(localized: "Couldn't create the configuration file"), error)
            }
        }
        refreshConfigFileButton()
    }

    private func presentError(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: String(localized: "OK"))
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }
}
