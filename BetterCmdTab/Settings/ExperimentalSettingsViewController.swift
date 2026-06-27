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
    private let mruWindowsSortSwitch = NSSwitch()
    private let browserTabMRUSwitch = NSSwitch()

    override func setupContent() {
        // Experimental section — off by default, clearly flagged as unstable.
        let experimental = addSection(title: String(localized: "Experimental"), anchor: SettingsAnchor.experimental)

        addRow(to: experimental, title: String(localized: "These features are unstable"),
               subtitle: String(localized: "Off by default. They may change or break."))
        addDivider(to: experimental)

        configureSwitch(swipeSwitch, action: #selector(toggleSwipe(_:)))
        addRow(to: experimental, title: String(localized: "Three-finger swipe"),
               subtitle: String(localized: "Slide three fingers horizontally across the trackpad. Reads the trackpad directly, so no system setting is needed."),
               accessory: swipeSwitch, searchItemID: SearchID.swipe)

        swipeModePopup.controlSize = .small
        swipeModePopup.translatesAutoresizingMaskIntoConstraints = false
        swipeModePopup.setContentHuggingPriority(.required, for: .horizontal)
        swipeModePopup.removeAllItems()
        swipeModePopup.addItems(withTitles: swipeModes.map(\.displayName))
        swipeModePopup.target = self
        swipeModePopup.action = #selector(swipeModeChanged)
        addRow(to: experimental, title: String(localized: "Swipe action"),
               subtitle: String(localized: "Open switcher: scrub through apps (commit with Return/click, Esc to cancel). Switch Spaces: jump to the Space on that side, one per step. Quick switch: flip to your last app, like a quick ⌘Tab tap — swipe again to flip back."),
               accessory: swipeModePopup, searchItemID: SearchID.swipeMode)

        configureSwitch(reverseSwitch, action: #selector(toggleReverse(_:)))
        addRow(to: experimental, title: String(localized: "Reverse swipe direction"),
               subtitle: String(localized: "Slide right to move left and left to move right."),
               accessory: reverseSwitch, searchItemID: SearchID.reverseSwipe)
        configureSwitch(commitSwitch, action: #selector(toggleCommit(_:)))
        addRow(to: experimental, title: String(localized: "Switch on release"),
               subtitle: String(localized: "Lift your fingers to switch to the highlighted app. When off, pick with a click or Return."),
               accessory: commitSwitch, searchItemID: SearchID.switchOnRelease)

        addRow(to: experimental, title: String(localized: "Swipe sensitivity"),
               subtitle: String(localized: "How far to slide to move one app. Higher means a shorter slide steps further."),
               accessory: makeSensitivityControl(), searchItemID: SearchID.sensitivity)

        addDivider(to: experimental)
        configureSwitch(instantSpaceSwitch, action: #selector(toggleInstantSpace(_:)))
        addRow(to: experimental, title: String(localized: "Switch Spaces without animation"),
               subtitle: String(localized: "Picking an app on another Space or in full screen jumps there instantly, with no slide animation. Applies to keyboard switching too."),
               accessory: instantSpaceSwitch, searchItemID: SearchID.instantSpace)

        addDivider(to: experimental)
        configureSwitch(mruWindowsSortSwitch, action: #selector(toggleMRUWindowsSort(_:)))
        addRow(to: experimental, title: String(localized: "Most recent (windows) sort order"),
               subtitle: String(localized: "Orders the list by when you last focused each window, across all apps."),
               accessory: mruWindowsSortSwitch, searchItemID: SearchID.mruWindowsSort)

        configureSwitch(browserTabMRUSwitch, action: #selector(toggleBrowserTabMRU(_:)))
        addRow(to: experimental, title: String(localized: "Track browser tabs in recency"),
               subtitle: String(localized: "With “Show browser tabs as separate entries” and the windows sort order on, ⌘Tab returns to the tab you last used, not just the last window. Needs always-on monitoring of your browsers, so it costs a little energy."),
               accessory: browserTabMRUSwitch, searchItemID: SearchID.browserTabMRU)
        // "Show switcher on" (multi-monitor placement) and the `\` tab peek + tab
        // expansion graduated to the Switcher tab once stable — see its "Display"
        // and "Tabs" sections.
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
        mruWindowsSortSwitch.state = prefs.sortOrder == .mruWindows ? .on : .off
        browserTabMRUSwitch.state = prefs.experimentalBrowserTabMRU ? .on : .off
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

    @objc private func toggleBrowserTabMRU(_ sender: NSSwitch) {
        Preferences.shared.experimentalBrowserTabMRU = (sender.state == .on)
    }

    @objc private func toggleMRUWindowsSort(_ sender: NSSwitch) {
        if sender.state == .on {
            Preferences.shared.sortOrder = .mruWindows
        } else if Preferences.shared.sortOrder == .mruWindows {
            // Only revert if we own the current value — leave any other order
            // the user picked in the Switcher popup untouched.
            Preferences.shared.sortOrder = .mru
        }
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
        reverseSwitch.isEnabled = enabled && directional
        commitSwitch.isEnabled = enabled && scrub
        sensitivitySlider.isEnabled = enabled && scrub
    }
}
