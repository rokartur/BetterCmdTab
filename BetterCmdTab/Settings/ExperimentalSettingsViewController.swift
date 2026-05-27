import AppKit
import BetterSettings
import Combine

/// Unstable, off-by-default features kept on their own tab so the distinction
/// between stable and experimental settings is explicit.
@MainActor
final class ExperimentalSettingsViewController: SettingsTabViewController {

    private let swipeSwitch = NSSwitch()
    private let reverseSwitch = NSSwitch()
    private let commitSwitch = NSSwitch()
    private let sensitivitySlider = NSSlider()
    private let sensitivityValueLabel = NSTextField(labelWithString: "")
    private let instantSpaceSwitch = NSSwitch()

    override func setupContent() {
        // Experimental section — off by default, clearly flagged as unstable.
        let experimental = addSection(title: "Experimental", anchor: SettingsAnchor.experimental)

        addRow(to: experimental, title: "These features are unstable",
               subtitle: "Off by default. They may change or break.")
        addDivider(to: experimental)

        configureSwitch(swipeSwitch, action: #selector(toggleSwipe(_:)))
        addRow(to: experimental, title: "Open with three-finger swipe",
               subtitle: "Slide three fingers across the trackpad to open the switcher and scrub through apps — keep sliding to move further. Pick with Return or a click, Esc to cancel. Reads the trackpad directly, so no system setting is needed.",
               accessory: swipeSwitch, searchItemID: SearchID.swipe)
        configureSwitch(reverseSwitch, action: #selector(toggleReverse(_:)))
        addRow(to: experimental, title: "Reverse swipe direction",
               subtitle: "Slide right to move left and left to move right.",
               accessory: reverseSwitch, searchItemID: SearchID.reverseSwipe)
        configureSwitch(commitSwitch, action: #selector(toggleCommit(_:)))
        addRow(to: experimental, title: "Switch on release",
               subtitle: "Lift your fingers to switch to the highlighted app. When off, pick with a click or Return.",
               accessory: commitSwitch, searchItemID: SearchID.switchOnRelease)

        addRow(to: experimental, title: "Swipe sensitivity",
               subtitle: "How far to slide to move one app. Higher means a shorter slide steps further.",
               accessory: makeSensitivityControl(), searchItemID: SearchID.sensitivity)

        addDivider(to: experimental)
        configureSwitch(instantSpaceSwitch, action: #selector(toggleInstantSpace(_:)))
        addRow(to: experimental, title: "Switch Spaces without animation",
               subtitle: "Picking an app on another Space or in full screen jumps there instantly, with no slide animation. Applies to keyboard switching too.",
               accessory: instantSpaceSwitch, searchItemID: SearchID.instantSpace)
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

    /// The reverse/commit/sensitivity controls only make sense while the swipe
    /// is enabled.
    private func setSwipeSubOptionsEnabled(_ enabled: Bool) {
        reverseSwitch.isEnabled = enabled
        commitSwitch.isEnabled = enabled
        sensitivitySlider.isEnabled = enabled
    }
}
