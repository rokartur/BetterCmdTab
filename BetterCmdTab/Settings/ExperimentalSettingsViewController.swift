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
    private let browserTabMRUSwitch = NSSwitch()
    private let livePreviewSwitch = NSSwitch()
    private let rankResultsSwitch = NSSwitch()
    private let searchTabsSwitch = NSSwitch()

    override func setupContent() {
        // Untitled intro card — the unstable warning applies to the whole tab,
        // so it sits above the per-feature sections.
        let notice = addSection(anchor: SettingsAnchor.experimental)
        addRow(to: notice, title: String(localized: "These features are unstable"),
               subtitle: String(localized: "Off by default. They may change or break."))

        // Trackpad swipe section — the three-finger gesture and its sub-options.
        let swipe = addSection(title: String(localized: "Trackpad swipe"), anchor: SettingsAnchor.experimentalSwipe)

        configureSwitch(swipeSwitch, action: #selector(toggleSwipe(_:)))
        addRow(to: swipe, title: String(localized: "Three-finger swipe"),
               subtitle: String(localized: "Slide three fingers horizontally across the trackpad. Reads the trackpad directly, so no system setting is needed."),
               accessory: swipeSwitch, searchItemID: SearchID.swipe)

        swipeModePopup.controlSize = .small
        swipeModePopup.translatesAutoresizingMaskIntoConstraints = false
        swipeModePopup.setContentHuggingPriority(.required, for: .horizontal)
        swipeModePopup.removeAllItems()
        swipeModePopup.addItems(withTitles: swipeModes.map(\.displayName))
        swipeModePopup.target = self
        swipeModePopup.action = #selector(swipeModeChanged)
        addRow(to: swipe, title: String(localized: "Swipe action"),
               subtitle: String(localized: "Open switcher: scrub through apps (commit with Return/click, Esc to cancel). Switch Spaces: jump to the Space on that side, one per step. Quick switch: flip to your last app, like a quick ⌘Tab tap — swipe again to flip back."),
               accessory: swipeModePopup, searchItemID: SearchID.swipeMode)

        configureSwitch(reverseSwitch, action: #selector(toggleReverse(_:)))
        addRow(to: swipe, title: String(localized: "Reverse swipe direction"),
               subtitle: String(localized: "Slide right to move left and left to move right."),
               accessory: reverseSwitch, searchItemID: SearchID.reverseSwipe)
        configureSwitch(commitSwitch, action: #selector(toggleCommit(_:)))
        addRow(to: swipe, title: String(localized: "Switch on release"),
               subtitle: String(localized: "Lift your fingers to switch to the highlighted app. When off, pick with a click or Return."),
               accessory: commitSwitch, searchItemID: SearchID.switchOnRelease)

        addRow(to: swipe, title: String(localized: "Swipe sensitivity"),
               subtitle: String(localized: "How far to slide to move one app. Higher means a shorter slide steps further."),
               accessory: makeSensitivityControl(), searchItemID: SearchID.sensitivity)

        // Spaces section.
        let spaces = addSection(title: String(localized: "Spaces"), anchor: SettingsAnchor.experimentalSpaces)
        configureSwitch(instantSpaceSwitch, action: #selector(toggleInstantSpace(_:)))
        addRow(to: spaces, title: String(localized: "Switch Spaces without animation"),
               subtitle: String(localized: "Picking an app on another Space or in full screen jumps there instantly, with no slide animation. Applies to keyboard switching too."),
               accessory: instantSpaceSwitch, searchItemID: SearchID.instantSpace)

        // Browser tabs section.
        let browserTabs = addSection(title: String(localized: "Browser tabs"), anchor: SettingsAnchor.experimentalTabs)
        configureSwitch(browserTabMRUSwitch, action: #selector(toggleBrowserTabMRU(_:)))
        addRow(to: browserTabs, title: String(localized: "Track browser tabs in recency"),
               subtitle: String(localized: "With “Show browser tabs as separate entries” and the “Most recent (windows)” sort order on, ⌘Tab returns to the tab you last used, not just the last window. Needs always-on monitoring of your browsers, so it costs a little energy."),
               accessory: browserTabMRUSwitch, searchItemID: SearchID.browserTabMRU)

        // Search section.
        let searchSection = addSection(title: String(localized: "Search"), anchor: SettingsAnchor.experimentalSearch)
        configureSwitch(rankResultsSwitch, action: #selector(toggleRankResults(_:)))
        addRow(to: searchSection, title: String(localized: "Rank search"),
               subtitle: String(localized: "Order results by how well they match instead of by recent use, so the closest match is selected first."),
               accessory: rankResultsSwitch, searchItemID: SearchID.rankResults)
        configureSwitch(searchTabsSwitch, action: #selector(toggleSearchExpandsTabs(_:)))
        addRow(to: searchSection, title: String(localized: "Search browser tabs"),
               subtitle: String(localized: "Type-to-search matches any browser tab by its title, not just each window's active tab. Matching tabs appear as temporary rows while the search field is active and disappear when you leave search. Already covered by “Show browser tabs as separate entries.”"),
               accessory: searchTabsSwitch, searchItemID: SearchID.searchExpandsBrowserTabs)

        // Previews section (the window-preview layout).
        let previews = addSection(title: String(localized: "Previews"), anchor: SettingsAnchor.experimentalPreviews)
        configureSwitch(livePreviewSwitch, action: #selector(toggleLivePreviews(_:)))
        addRow(to: previews, title: String(localized: "Live window previews"),
               subtitle: String(localized: "In the Previews layout, thumbnails keep refreshing while the switcher is open, so they show what is happening in each window right now. Uses extra CPU and GPU while the panel is up."),
               accessory: livePreviewSwitch, searchItemID: SearchID.livePreviews)
        // "Show switcher on" (multi-monitor placement), the `\` tab peek + tab
        // expansion, and the "Most recent (windows)" sort graduated to the
        // Behavior tab once stable — see its "Display" and "Contents" sections.
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
        browserTabMRUSwitch.state = prefs.experimentalBrowserTabMRU ? .on : .off
        livePreviewSwitch.state = prefs.experimentalLivePreviews ? .on : .off
        rankResultsSwitch.state = prefs.fuzzySearchRankBestMatchFirst ? .on : .off
        searchTabsSwitch.state = prefs.searchExpandsBrowserTabs ? .on : .off
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

    @objc private func toggleLivePreviews(_ sender: NSSwitch) {
        Preferences.shared.experimentalLivePreviews = (sender.state == .on)
    }

    @objc private func toggleRankResults(_ sender: NSSwitch) {
        Preferences.shared.fuzzySearchRankBestMatchFirst = (sender.state == .on)
    }

    @objc private func toggleSearchExpandsTabs(_ sender: NSSwitch) {
        Preferences.shared.searchExpandsBrowserTabs = (sender.state == .on)
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
