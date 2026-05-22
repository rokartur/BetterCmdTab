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

        let checkUpdatesItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(checkForUpdates),
            keyEquivalent: ""
        )
        checkUpdatesItem.target = self
        menu.addItem(checkUpdatesItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit BetterCmdTab", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        item.menu = menu
        statusItem = item
    }

    @objc private func checkForUpdates() {
        Task { @MainActor in
            await GitHubUpdater.shared.checkForUpdates(force: true)

            // On manual check, surface up-to-date / error states the user
            // would otherwise miss (auto-check silently returns to .idle).
            switch GitHubUpdater.shared.state {
            case .upToDate:
                let alert = NSAlert()
                alert.messageText = "You're up to date!"
                alert.informativeText = "BetterCmdTab \(AppInfo.appVersion) is the latest version available."
                alert.alertStyle = .informational
                alert.addButton(withTitle: "OK")
                alert.runModal()
                GitHubUpdater.shared.resetToIdle()
            case .error(let message):
                let alert = NSAlert()
                alert.messageText = "Update check failed"
                alert.informativeText = message
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
                GitHubUpdater.shared.resetToIdle()
            default:
                break
            }
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
