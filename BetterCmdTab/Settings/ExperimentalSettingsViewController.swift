import AppKit
import BetterSettings
import Combine

/// Unstable, off-by-default features kept on their own tab so the distinction
/// between stable and experimental settings is explicit.
@MainActor
final class ExperimentalSettingsViewController: SettingsTabViewController {

    private let swipeSwitch = NSSwitch()
    private let swipeModePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let swipeModes: [SwipeMode] = SwipeMode.allCases
    private let reverseSwitch = NSSwitch()
    private let commitSwitch = NSSwitch()
    private let sensitivitySlider = NSSlider()
    private let sensitivityValueLabel = NSTextField(labelWithString: "")
    private let instantSpaceSwitch = NSSwitch()
    private let moveToSpaceSwitch = NSSwitch()

    override func setupContent() {
        // Experimental section — off by default, clearly flagged as unstable.
        let experimental = addSection(title: "Experimental", anchor: SettingsAnchor.experimental)

        addRow(to: experimental, title: "These features are unstable",
               subtitle: "Off by default. They may change or break.")
        addDivider(to: experimental)

        configureSwitch(swipeSwitch, action: #selector(toggleSwipe(_:)))
        addRow(to: experimental, title: "Three-finger swipe",
               subtitle: "Slide three fingers horizontally across the trackpad. Reads the trackpad directly, so no system setting is needed.",
               accessory: swipeSwitch, searchItemID: SearchID.swipe)

        swipeModePopup.controlSize = .small
        swipeModePopup.translatesAutoresizingMaskIntoConstraints = false
        swipeModePopup.setContentHuggingPriority(.required, for: .horizontal)
        swipeModePopup.removeAllItems()
        swipeModePopup.addItems(withTitles: swipeModes.map(\.displayName))
        swipeModePopup.target = self
        swipeModePopup.action = #selector(swipeModeChanged)
        addRow(to: experimental, title: "Swipe action",
               subtitle: "Open switcher: scrub through apps (commit with Return/click, Esc to cancel). Switch Spaces: jump to the Space on that side, one per step.",
               accessory: swipeModePopup, searchItemID: SearchID.swipeMode)

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

        configureSwitch(moveToSpaceSwitch, action: #selector(toggleMoveToSpace(_:)))
        addRow(to: experimental, title: "Move window to adjacent Space",
               subtitle: "While the switcher is open, ⌘⌥← / ⌘⌥→ move the highlighted window to the Space on that side and follow it there. (⌘⌥↑ / ⌘⌥↓ always move it to the next display.) Uses private APIs.",
               accessory: moveToSpaceSwitch, searchItemID: SearchID.moveToSpace)
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
        if let i = swipeModes.firstIndex(of: prefs.swipeMode) { swipeModePopup.selectItem(at: i) }
        reverseSwitch.state = prefs.swipeReverseDirection ? .on : .off
        commitSwitch.state = prefs.swipeCommitOnRelease ? .on : .off
        applySensitivity(prefs.swipeSensitivity)
        instantSpaceSwitch.state = prefs.experimentalInstantSpaceSwitch ? .on : .off
        moveToSpaceSwitch.state = prefs.experimentalMoveToSpace ? .on : .off
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

    @objc private func toggleMoveToSpace(_ sender: NSSwitch) {
        Preferences.shared.experimentalMoveToSpace = (sender.state == .on)
    }

    /// The reverse/commit/sensitivity controls only make sense while the swipe
    /// is enabled.
    private func setSwipeSubOptionsEnabled(_ enabled: Bool) {
        let spaces = Preferences.shared.swipeMode == .switchSpaces
        swipeModePopup.isEnabled = enabled
        reverseSwitch.isEnabled = enabled
        commitSwitch.isEnabled = enabled && !spaces
        sensitivitySlider.isEnabled = enabled && !spaces
    }
}
