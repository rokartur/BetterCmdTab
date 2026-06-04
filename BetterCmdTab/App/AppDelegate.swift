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
    private var cancellables = Set<AnyCancellable>()

    /// Process-lifetime App Nap opt-out. A `.accessory` app is always fully
    /// occluded, so macOS App-Naps it after a quiet spell — throttling the main
    /// run loop and coalescing the reveal `Timer`, which is exactly why the first
    /// ⌘Tab after idle appears slower than one during active use. The switcher is
    /// fully event-driven when idle (catalog updates ride AX observers, title
    /// callbacks are gated on panel visibility, no polling), so holding this
    /// assertion adds ~no idle CPU/RAM — it only removes the throttle, keeping
    /// reveal latency constant. `…AllowingIdleSystemSleep` still lets the Mac
    /// idle-sleep and never disables display sleep: we opt out of App Nap only.
    private var antiNapActivity: NSObjectProtocol?

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
        // Re-enable any native symbolic hotkey a previous run left disabled
        // (crash / SIGKILL / power loss) and arm the crash-restore guard for this
        // session. Done here — before the Accessibility-gated controller boot —
        // because the WindowServer IPC needs no Accessibility: a crash-then-revoke
        // must still restore the user's native ⌘Tab even while AX is untrusted.
        SymbolicHotkeyGuard.install()
        SwitcherController.healStaleSymbolicHotkeyDisable()

        BetterShortcuts.installDisplayNames()
        DirectActivation.installHandlers()
        ScopedSwitch.installHandlers()
        WindowManagement.installHandlers()
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
        waiter.onTrustChanged = { [weak self] trusted in
            self?.handleAccessibilityTrustChange(trusted)
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
        // Hold the App Nap opt-out only once the switcher is live (held for the
        // remaining process lifetime — never ended). Booting untrusted leaves
        // the switcher inert, where napping is harmless anyway.
        if antiNapActivity == nil {
            antiNapActivity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "Keep ⌘Tab reveal latency constant (opt out of App Nap)"
            )
        }
    }

    /// Whether the "Accessibility was revoked" alert is currently being shown,
    /// so a repeating poll doesn't stack duplicate alerts.
    private var accessibilityLostShown = false

    /// React to a runtime Accessibility trust transition surfaced by
    /// `AccessibilityWaiter`. On re-grant, boot the controller (if the app
    /// launched untrusted) or re-arm the now-dead CGEvent tap. On revoke, tell
    /// the user — otherwise ⌘Tab just stops working with no explanation.
    private func handleAccessibilityTrustChange(_ trusted: Bool) {
        if trusted {
            accessibilityLostShown = false
            if controller == nil {
                bootController()
            } else {
                controller?.reinstallHotkeyTap()
                // Re-assert the native-shortcut override we dropped on revoke so
                // the always-armed symbolic-⌘Tab suppression comes back.
                controller?.reassertNativeOverrideAfterRegrant()
            }
        } else {
            // Re-enable the native symbolic ⌘Tab before anything else: with AX
            // gone our tap is dead and Activator can't raise windows, so the
            // user's only working switcher is macOS's own — which stays disabled
            // unless we restore it here (the IPC needs no AX).
            controller?.handleAccessibilityRevoked()
            notifyAccessibilityRevoked()
        }
    }

    private func notifyAccessibilityRevoked() {
        guard !accessibilityLostShown else { return }
        accessibilityLostShown = true
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = String(localized: "Accessibility access was turned off")
        alert.informativeText = String(localized: "BetterCmdTab needs Accessibility permission to handle ⌘Tab. Re-enable it in System Settings and the switcher reactivates automatically.")
        alert.addButton(withTitle: String(localized: "Open Accessibility Settings"))
        alert.addButton(withTitle: String(localized: "Later"))
        let response = alert.runModal()
        // Re-arm the prompt for the next revoke regardless of choice; if trust is
        // still off, the next poll won't re-fire (no transition), so clearing the
        // flag here is safe and only matters after a future re-grant cycle.
        if response == .alertFirstButtonReturn {
            AccessibilityCheck.openSystemSettings()
        }
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
            title: String(localized: "Settings…"),
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: String(localized: "Quit BetterCmdTab"), action: #selector(quit), keyEquivalent: "q")
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

    /// Restore OS-level state on quit. Disabling the native ⌘Tab symbolic hotkey
    /// (so the switcher works under Secure Event Input) persists after the app
    /// exits, so it must be re-enabled here or macOS's own ⌘Tab stays dead.
    func applicationWillTerminate(_ notification: Notification) {
        controller?.shutdown()
    }

    /// Fired when the user launches the already-running app again (e.g. from
    /// Spotlight). The app is accessory with no dock icon, so reopening surfaces
    /// Settings — the only entry point when the menu bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowPresenter.shared.show()
        return true
    }
}
