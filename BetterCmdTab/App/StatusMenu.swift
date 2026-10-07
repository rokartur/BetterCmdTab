import AppKit
import BetterUpdater

/// The menu bar extra's menu, rebuilt from live state on every open.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    let menu = NSMenu()

    override init() {
        super.init()
        menu.delegate = self
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if !AccessibilityCheck.isTrusted {
            addItem(to: menu, String(localized: "Open Accessibility Settings"), #selector(openAccessibilitySettings))
            menu.addItem(.separator())
        }
        addItem(to: menu, String(localized: "Check for Updates"), #selector(checkForUpdates))
        addItem(to: menu, String(localized: "Settings"), #selector(openSettings), keyEquivalent: ",")
        addItem(to: menu, String(localized: "Quit BetterCmdTab"), #selector(quit), keyEquivalent: "q")
    }

    private func addItem(to menu: NSMenu, _ title: String, _ action: Selector, keyEquivalent: String = "") {
        menu.addItem(withTitle: title, action: action, keyEquivalent: keyEquivalent).target = self
    }

    @objc private func openAccessibilitySettings() {
        AccessibilityCheck.openSystemSettings()
    }

    /// Opens About, whose update pill shows the check's progress and result.
    @objc private func checkForUpdates() {
        SettingsWindowPresenter.shared.show(selecting: SettingsTabID.about)
        let updater = GitHubUpdater.shared
        switch updater.state {
        case .idle, .upToDate, .error:
            Task { await updater.checkForUpdates(force: true) }
        case .checking, .available, .downloading, .installing, .readyToInstall:
            break
        }
    }

    @objc private func openSettings() {
        SettingsWindowPresenter.shared.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

