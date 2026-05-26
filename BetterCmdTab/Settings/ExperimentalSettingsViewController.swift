import AppKit
import Combine

/// Unstable, off-by-default features kept on their own tab so the distinction
/// between stable and experimental settings is explicit.
@MainActor
final class ExperimentalSettingsViewController: NSViewController {

    private let swipeSwitch = NSSwitch()
    private let reverseSwitch = NSSwitch()
    private let reverseRow = SettingsRowView(
        title: "Reverse swipe direction",
        subtitle: "Slide right to move left and left to move right."
    )
    private let commitSwitch = NSSwitch()
    private let commitRow = SettingsRowView(
        title: "Switch on release",
        subtitle: "Lift your fingers to switch to the highlighted app. When off, pick with a click or Return."
    )
    private let sensitivitySlider = NSSlider()
    private let sensitivityValueLabel = NSTextField(labelWithString: "")
    private let sensitivityRow = SettingsRowView(
        title: "Swipe sensitivity",
        subtitle: "How far to slide to move one app. Higher means a shorter slide steps further."
    )
    private let instantSpaceSwitch = NSSwitch()
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
            title: "Open with three-finger swipe",
            subtitle: "Slide three fingers across the trackpad to open the switcher and scrub through apps — keep sliding to move further. Pick with Return or a click, Esc to cancel. Reads the trackpad directly, so no system setting is needed.",
            accessory: swipeSwitch
        ))
        configureSwitch(reverseSwitch, action: #selector(toggleReverse(_:)))
        reverseRow.setAccessory(reverseSwitch)
        experimental.addContent(reverseRow)
        configureSwitch(commitSwitch, action: #selector(toggleCommit(_:)))
        commitRow.setAccessory(commitSwitch)
        experimental.addContent(commitRow)

        sensitivityRow.setAccessory(makeSensitivityControl())
        experimental.addContent(sensitivityRow)

        experimental.addDivider()
        configureSwitch(instantSpaceSwitch, action: #selector(toggleInstantSpace(_:)))
        experimental.addContent(SettingsRowView(
            title: "Switch Spaces without animation",
            subtitle: "Picking an app on another Space or in full screen jumps there instantly, with no slide animation. Applies to keyboard switching too.",
            accessory: instantSpaceSwitch
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

    /// Slider (1–10) plus a value label, matching the reveal-delay control.
    private func makeSensitivityControl() -> NSView {
        sensitivitySlider.minValue = Double(Preferences.swipeSensitivityRange.lowerBound)
        sensitivitySlider.maxValue = Double(Preferences.swipeSensitivityRange.upperBound)
        sensitivitySlider.numberOfTickMarks = Preferences.swipeSensitivityRange.count
        sensitivitySlider.allowsTickMarkValuesOnly = true
        sensitivitySlider.isContinuous = true
        sensitivitySlider.controlSize = .small
        sensitivitySlider.target = self
        sensitivitySlider.action = #selector(sensitivityChanged(_:))
        sensitivitySlider.translatesAutoresizingMaskIntoConstraints = false

        sensitivityValueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        sensitivityValueLabel.textColor = .secondaryLabelColor
        sensitivityValueLabel.alignment = .right
        sensitivityValueLabel.translatesAutoresizingMaskIntoConstraints = false
        sensitivityValueLabel.setContentHuggingPriority(.required, for: .horizontal)

        let stack = NSStackView(views: [sensitivitySlider, sensitivityValueLabel])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        NSLayoutConstraint.activate([
            sensitivitySlider.widthAnchor.constraint(equalToConstant: 140),
            sensitivityValueLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 40),
        ])
        return stack
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        let prefs = Preferences.shared
        swipeSwitch.state = prefs.experimentalSwipeTrigger ? .on : .off
        reverseSwitch.state = prefs.swipeReverseDirection ? .on : .off
        commitSwitch.state = prefs.swipeCommitOnRelease ? .on : .off
        applySensitivity(prefs.swipeSensitivity)
        instantSpaceSwitch.state = prefs.experimentalInstantSpaceSwitch ? .on : .off
        badgesSwitch.state = prefs.experimentalUnreadBadges ? .on : .off
        setSwipeSubOptionsEnabled(prefs.experimentalSwipeTrigger)
    }

    @objc private func toggleSwipe(_ sender: NSSwitch) {
        let on = (sender.state == .on)
        Preferences.shared.experimentalSwipeTrigger = on
        setSwipeSubOptionsEnabled(on)
    }

    @objc private func toggleReverse(_ sender: NSSwitch) {
        Preferences.shared.swipeReverseDirection = (sender.state == .on)
    }

    @objc private func toggleCommit(_ sender: NSSwitch) {
        Preferences.shared.swipeCommitOnRelease = (sender.state == .on)
    }

    @objc private func sensitivityChanged(_ sender: NSSlider) {
        Preferences.shared.swipeSensitivity = sender.integerValue
        sensitivityValueLabel.stringValue = "\(sender.integerValue)/\(Preferences.swipeSensitivityRange.upperBound)"
    }

    private func applySensitivity(_ level: Int) {
        if sensitivitySlider.integerValue != level { sensitivitySlider.integerValue = level }
        sensitivityValueLabel.stringValue = "\(level)/\(Preferences.swipeSensitivityRange.upperBound)"
    }

    @objc private func toggleInstantSpace(_ sender: NSSwitch) {
        Preferences.shared.experimentalInstantSpaceSwitch = (sender.state == .on)
    }

    @objc private func toggleBadges(_ sender: NSSwitch) {
        Preferences.shared.experimentalUnreadBadges = (sender.state == .on)
    }

    /// The reverse/commit/sensitivity controls only make sense while the swipe
    /// is enabled.
    private func setSwipeSubOptionsEnabled(_ enabled: Bool) {
        reverseSwitch.isEnabled = enabled
        commitSwitch.isEnabled = enabled
        sensitivitySlider.isEnabled = enabled
    }
}
