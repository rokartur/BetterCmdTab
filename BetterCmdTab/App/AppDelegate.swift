import AppKit
import BetterShortcuts
import BetterUpdater
import Combine
import os

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: SwitcherController?
    private var statusItem: NSStatusItem?
    private var axWaiter: AccessibilityWaiter?
    private var secureInputMonitor: SecureInputMonitor?
    private var cancellables = Set<AnyCancellable>()

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        BetterShortcuts.installDisplayNames()
        DirectActivation.installHandlers()
        #if DEBUG
        // In Debug builds always show the menu bar icon, regardless of the
        // saved preference — otherwise a hidden icon leaves no way to reach
        // Settings when running from Xcode.
        if Preferences.shared.hideMenuBarIcon {
            Preferences.shared.hideMenuBarIcon = false
        }
        #endif

        updateStatusItem()
        Preferences.shared.$hideMenuBarIcon
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateStatusItem() }
            .store(in: &cancellables)

        // With the menu bar icon hidden there's no in-menu way to reach
        // Settings, so a manual launch (Spotlight/Finder) surfaces it. Skip
        // the automatic login launch, which would otherwise pop Settings on
        // every login; that case is handled by `applicationShouldHandleReopen`
        // when the user launches the already-running app again.
        LaunchAtLogin.shared.refresh()
        if Preferences.shared.hideMenuBarIcon && !LaunchAtLogin.shared.isEnabled {
            SettingsWindowPresenter.shared.show()
        }

        let missing = PrivateAPI.selfCheck()
        if !missing.isEmpty {
            Log.priv.warning("Missing private symbols: \(missing.joined(separator: ", "), privacy: .public)")
        }

        // Configure the updater before any BetterUpdater type is touched.
        // The pinned Ed25519 public key is the trust anchor for the signed
        // repo-identity manifest (see BetterUpdater README).
        BetterUpdater.bootstrap(configuration: .init(
            owner: "rokartur",
            repo: "BetterCmdTab",
            displayName: AppInfo.displayName,
            bundleIdentifier: "pro.bettercmdtab.BetterCmdTab",
            pinnedPublicKeyBase64: "EdGQwfRFT04hggloIRmN2twIC/UIlM6yoAAzZ97jgcI=",
            userAgentProduct: "BetterCmdTab-Updater",
            manifestRequired: true
        ))

        // Refuse to start the switcher (and updater) while running from a
        // translocated mount — Gatekeeper Path Randomization will keep
        // bouncing the user between the Downloads copy and /Applications.
        guard AppTranslocation.guardLaunchLocation() else { return }

        let waiter = AccessibilityWaiter()
        waiter.onTrusted = { [weak self] in
            self?.bootController()
        }
        waiter.start()
        axWaiter = waiter

        let secureMonitor = SecureInputMonitor()
        secureMonitor.start()
        secureInputMonitor = secureMonitor

        Task { @MainActor in
            // Touch the singleton so it boots its scheduled auto-check task,
            // then perform an opportunistic non-forced check at launch.
            _ = GitHubUpdater.shared
            await GitHubUpdater.shared.checkForUpdates(force: false)
        }
    }

    private func bootController() {
        guard controller == nil else { return }
        let c = SwitcherController()
        c.start()
        controller = c
    }

    /// Adds or removes the status item to match `hideMenuBarIcon`. Safe to call
    /// repeatedly — it only acts when the current state differs.
    private func updateStatusItem() {
        if Preferences.shared.hideMenuBarIcon {
            if let item = statusItem {
                NSStatusBar.system.removeStatusItem(item)
                statusItem = nil
            }
            return
        }
        guard statusItem == nil else { return }
        installStatusItem()
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "command", accessibilityDescription: "BetterCmdTab")
            button.image?.isTemplate = true
        }
        let menu = NSMenu()

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit BetterCmdTab", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        item.menu = menu
        statusItem = item
    }

    @objc private func openSettings() {
        SettingsWindowPresenter.shared.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Fired when the user launches the already-running app again (e.g. from
    /// Spotlight). The app is accessory with no dock icon, so reopening surfaces
    /// Settings — the only entry point when the menu bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowPresenter.shared.show()
        return true
    }
}
