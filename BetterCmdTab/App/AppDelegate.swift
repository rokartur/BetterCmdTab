import AppKit
import os

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: SwitcherController?
    private var statusItem: NSStatusItem?
    private var axWaiter: AccessibilityWaiter?

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
        installStatusItem()

        let missing = PrivateAPI.selfCheck()
        if !missing.isEmpty {
            Log.priv.warning("Missing private symbols: \(missing.joined(separator: ", "), privacy: .public)")
        }

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
}
