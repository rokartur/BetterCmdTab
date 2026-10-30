import AppKit
import BetterSettings

/// Trackpad pane — the swipe gesture that drives the switcher or Spaces.
@MainActor
final class TrackpadSettingsViewController: SettingsTabViewController {

    private let swipeSwitch = NSSwitch()
    private let swipeModePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let swipeModes: [SwipeMode] = SwipeMode.allCases
    private let swipeFingersPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let swipeFingerCounts = Array(Preferences.swipeFingerCountRange)
    private let reverseSwitch = PreferenceSwitch(bind: \.swipeReverseDirection)
    private let commitSwitch = PreferenceSwitch(bind: \.swipeCommitOnRelease)
    private let sensitivitySlider = NSSlider()
    private let sensitivityValueLabel = NSTextField(labelWithString: "")

    override func setupContent() {
        buildSwipeSection()
    }

    private func buildSwipeSection() {
        let swipe = addSection(title: String(localized: "Trackpad swipe"), anchor: SettingsAnchor.swipe)
        addRow(to: swipe, icon: "flask.fill",
               title: String(localized: "These features are unstable"),
               subtitle: String(localized: "Off by default. They may change or break."))

        configureSwitch(swipeSwitch, action: #selector(toggleSwipe(_:)))
        addRow(to: swipe, title: String(localized: "Swipe gesture"),
               subtitle: String(localized: "Slide the number of fingers set below horizontally across the trackpad. Reads the trackpad directly, so no system setting is needed."),
               accessory: swipeSwitch, searchItemID: SearchID.swipe)

        configurePopup(swipeFingersPopup, titles: swipeFingerCounts.map(String.init), action: #selector(swipeFingersChanged))
        addRow(to: swipe, title: String(localized: "Fingers"),
               subtitle: String(localized: "Use four to keep three-finger drag for moving windows."),
               accessory: swipeFingersPopup, searchItemID: SearchID.swipeFingers)

        configurePopup(swipeModePopup, titles: swipeModes.map(\.displayName), action: #selector(swipeModeChanged))
        addRow(to: swipe, title: String(localized: "Swipe action"),
               subtitle: String(localized: "Open switcher: scrub through apps (commit with Return/click, Esc to cancel). Switch Spaces: jump to the Space on that side, one per step. Quick switch: flip to your last app, like a quick ⌘Tab tap — swipe again to flip back."),
               accessory: swipeModePopup, searchItemID: SearchID.swipeMode)

        addRow(to: swipe, title: String(localized: "Reverse swipe direction"),
               subtitle: String(localized: "Slide right to move left and left to move right."),
               accessory: reverseSwitch, searchItemID: SearchID.reverseSwipe)
        addRow(to: swipe, title: String(localized: "Switch on release"),
               subtitle: String(localized: "Lift your fingers to switch to the highlighted app. When off, pick with a click or Return."),
               accessory: commitSwitch, searchItemID: SearchID.switchOnRelease)

        addRow(to: swipe, title: String(localized: "Swipe sensitivity"),
               subtitle: String(localized: "How far to slide to move one app. Higher means a shorter slide steps further."),
               accessory: makeSensitivityControl(), searchItemID: SearchID.sensitivity)
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
        if let index = swipeModes.firstIndex(of: prefs.swipeMode) { swipeModePopup.selectItem(at: index) }
        if let index = swipeFingerCounts.firstIndex(of: prefs.swipeFingerCount) { swipeFingersPopup.selectItem(at: index) }
        reverseSwitch.sync()
        commitSwitch.sync()
        applySensitivity(prefs.swipeSensitivity)
        setSwipeSubOptionsEnabled(prefs.experimentalSwipeTrigger)
    }

    @objc private func toggleSwipe(_ sender: NSSwitch) {
        let on = (sender.state == .on)
        Preferences.shared.experimentalSwipeTrigger = on
        setSwipeSubOptionsEnabled(on)
    }

    @objc private func swipeModeChanged() {
        let idx = swipeModePopup.indexOfSelectedItem
        guard swipeModes.indices.contains(idx) else { return }
        Preferences.shared.swipeMode = swipeModes[idx]
        setSwipeSubOptionsEnabled(Preferences.shared.experimentalSwipeTrigger)
    }

    @objc private func swipeFingersChanged() {
        let idx = swipeFingersPopup.indexOfSelectedItem
        guard swipeFingerCounts.indices.contains(idx) else { return }
        Preferences.shared.swipeFingerCount = swipeFingerCounts[idx]
    }

    @objc private func sensitivityChanged(_ sender: NSSlider) {
        Preferences.shared.swipeSensitivity = sender.integerValue
        sensitivityValueLabel.stringValue = "\(sender.integerValue)/\(Preferences.swipeSensitivityRange.upperBound)"
    }

    private func applySensitivity(_ level: Int) {
        if sensitivitySlider.integerValue != level { sensitivitySlider.integerValue = level }
        sensitivityValueLabel.stringValue = "\(level)/\(Preferences.swipeSensitivityRange.upperBound)"
    }

    /// The reverse/commit/sensitivity controls only make sense while the swipe
    /// is enabled.
    private func setSwipeSubOptionsEnabled(_ enabled: Bool) {
        // Commit-on-release and sensitivity only apply to the continuous
        // "open switcher" scrub. Direction has no meaning for the quick-switch
        // flip (any swipe just toggles), so reverse is off there too.
        let scrub = Preferences.shared.swipeMode == .openSwitcher
        let directional = Preferences.shared.swipeMode != .quickSwitch
        swipeModePopup.isEnabled = enabled
        swipeFingersPopup.isEnabled = enabled
        reverseSwitch.isEnabled = enabled && directional
        commitSwitch.isEnabled = enabled && scrub
        sensitivitySlider.isEnabled = enabled && scrub
    }
}
