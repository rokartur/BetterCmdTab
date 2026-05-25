import AppKit
import Combine

/// Unstable, off-by-default features kept on their own tab so the distinction
/// between stable and experimental settings is explicit.
@MainActor
final class ExperimentalSettingsViewController: NSViewController {

    private let swipeSwitch = NSSwitch()
    private let badgesSwitch = NSSwitch()

    override func loadView() {
        // Experimental section — off by default, clearly flagged as unstable.
        let experimental = SettingsSectionView(header: "Experimental")

        let intro = SettingsRowView(
            title: "These features are unstable",
            subtitle: "Off by default. They may change or break."
        )
        experimental.addContent(intro)
        experimental.addDivider()

        configureSwitch(swipeSwitch, action: #selector(toggleSwipe(_:)))
        experimental.addContent(SettingsRowView(
            title: "Open with trackpad swipe",
            subtitle: "Three-finger swipe opens the switcher. Pick with Return, click, or Esc. May clash with Mission Control.",
            accessory: swipeSwitch
        ))
        configureSwitch(badgesSwitch, action: #selector(toggleBadges(_:)))
        experimental.addContent(SettingsRowView(
            title: "Show unread badges",
            subtitle: "Reads badge counts from the Dock. May not match every app.",
            accessory: badgesSwitch
        ))

        view = SettingsLayout.makeScrollingTab(sections: [experimental])
    }

    private func configureSwitch(_ toggle: NSSwitch, action: Selector) {
        toggle.controlSize = .small
        toggle.target = self
        toggle.action = action
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        let prefs = Preferences.shared
        swipeSwitch.state = prefs.experimentalSwipeTrigger ? .on : .off
        badgesSwitch.state = prefs.experimentalUnreadBadges ? .on : .off
    }

    @objc private func toggleSwipe(_ sender: NSSwitch) {
        Preferences.shared.experimentalSwipeTrigger = (sender.state == .on)
    }

    @objc private func toggleBadges(_ sender: NSSwitch) {
        Preferences.shared.experimentalUnreadBadges = (sender.state == .on)
    }
}
