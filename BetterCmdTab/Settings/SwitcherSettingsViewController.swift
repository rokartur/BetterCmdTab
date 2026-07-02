import AppKit
import BetterSettings
import Combine

/// Behavior pane — which display it opens on, what it lists (Contents), tab
/// drill-in, type-to-filter search, selection navigation, and hover actions.
/// The visual options live under the Appearance tab; per-app rules and pinning
/// live under the Apps tab.
@MainActor
final class SwitcherSettingsViewController: SettingsTabViewController {

    // Display
    private let displayMonitorPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let displayModes: [SwitcherDisplayMode] = SwitcherDisplayMode.allCases

    // Contents — what apps/windows the switcher lists (moved here from Appearance:
    // these decide *which* windows show, which is behavior, not look).
    private let minimizedSwitch = NSSwitch()
    private let hiddenSwitch = NSSwitch()
    private let windowlessSwitch = NSSwitch()
    private let applicationsOnlySwitch = NSSwitch()
    private let badgesSwitch = NSSwitch()
    private let spaceScopePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let spaceScopes: [SpaceScope] = SpaceScope.allCases
    private let recentlyClosedSwitch = NSSwitch()
    private let recentlyClosedLimitPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let recentlyClosedLimits: [Int] = [3, 5, 10, 15, 20]
    private let sortOrderPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sortOrders: [SwitcherSortOrder] = SwitcherSortOrder.allCases

    // Tabs
    private let tabDrillSwitch = NSSwitch()
    private let expandTabsSwitch = NSSwitch()
    private let expandBrowserTabsSwitch = NSSwitch()

    // Search
    private let letterHintsSwitch = NSSwitch()
    private let letterTimeoutSlider = NSSlider()
    private let letterTimeoutValueLabel = NSTextField(labelWithString: "")
    private let fuzzySwitch = NSSwitch()
    private let launcherSwitch = NSSwitch()
    private let searchModePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let searchDismissModes: [SearchDismissMode] = SearchDismissMode.allCases

    // Navigation
    private let stayOpenSwitch = NSSwitch()
    private let shiftTapBackSwitch = NSSwitch()
    private let scrollSwitch = NSSwitch()
    private let scrollReverseSwitch = NSSwitch()
    private let clickDismissSwitch = NSSwitch()
    private let vimNavSwitch = NSSwitch()
    private let hoverSelectSwitch = NSSwitch()
    private let clickSelectSwitch = NSSwitch()

    // Hover actions
    private let hoverSwitch = NSSwitch()
    private let hoverCloseSwitch = NSSwitch()
    private let hoverMinimizeSwitch = NSSwitch()
    private let hoverMaximizeSwitch = NSSwitch()
    private let hoverHideSwitch = NSSwitch()
    private let hoverQuitSwitch = NSSwitch()
    private let hoverForceQuitSwitch = NSSwitch()

    private var cancellables = Set<AnyCancellable>()

    override func setupContent() {
        // Display section — which monitor the switcher panel opens on (graduated
        // from Experimental once stable).
        let display = addSection(title: String(localized: "Display"), anchor: SettingsAnchor.display)
        displayMonitorPopup.controlSize = .small
        displayMonitorPopup.translatesAutoresizingMaskIntoConstraints = false
        displayMonitorPopup.setContentHuggingPriority(.required, for: .horizontal)
        displayMonitorPopup.removeAllItems()
        displayMonitorPopup.addItems(withTitles: displayModes.map(\.displayName))
        displayMonitorPopup.target = self
        displayMonitorPopup.action = #selector(displayModeChanged)
        addRow(to: display, title: String(localized: "Show switcher on"),
               subtitle: String(localized: "Choose which monitor the switcher opens on when you have more than one display."),
               accessory: displayMonitorPopup, searchItemID: SearchID.displayMonitor)

        // Contents section — what kinds of windows/apps appear in the switcher.
        let contents = addSection(title: String(localized: "Contents"), anchor: SettingsAnchor.contents)
        configureSwitch(minimizedSwitch, action: #selector(toggleMinimized(_:)))
        addRow(to: contents, title: String(localized: "Show minimized windows"), accessory: minimizedSwitch,
               searchItemID: SearchID.showMinimized)
        configureSwitch(hiddenSwitch, action: #selector(toggleHidden(_:)))
        addRow(to: contents, title: String(localized: "Show hidden apps"), accessory: hiddenSwitch,
               searchItemID: SearchID.showHidden)
        configureSwitch(windowlessSwitch, action: #selector(toggleWindowless(_:)))
        addRow(to: contents, title: String(localized: "Show apps without windows"),
               subtitle: String(localized: "Running apps with no open windows."),
               accessory: windowlessSwitch, searchItemID: SearchID.showWindowless)
        configureSwitch(applicationsOnlySwitch, action: #selector(toggleApplicationsOnly(_:)))
        addRow(to: contents, title: String(localized: "Applications only"),
               subtitle: String(localized: "Show one row per app instead of one per window — classic ⌘Tab."),
               accessory: applicationsOnlySwitch, searchItemID: SearchID.applicationsOnly)
        configureSwitch(badgesSwitch, action: #selector(toggleBadges(_:)))
        addRow(to: contents, title: String(localized: "Show unread badges"),
               subtitle: String(localized: "Show each app's Dock badge count (e.g. Mail's unread mail) on its row."),
               accessory: badgesSwitch, searchItemID: SearchID.showBadges)
        configurePopup(spaceScopePopup, titles: spaceScopes.map(\.displayName), action: #selector(spaceScopeChanged))
        addRow(to: contents, title: String(localized: "Show windows from"),
               subtitle: String(localized: "All Spaces shows everything; Current Space only the Space you're viewing; Visible Spaces what's on screen across all your displays."),
               accessory: spaceScopePopup, searchItemID: SearchID.spaceScope)
        configurePopup(sortOrderPopup, titles: sortOrders.map(\.displayName), action: #selector(sortOrderChanged))
        addRow(to: contents, title: String(localized: "Sort order"),
               subtitle: String(localized: "Most recent keeps the classic ⌘Tab order; Most recent (windows) interleaves windows from all apps by last focus; the others stay put as you switch."),
               accessory: sortOrderPopup, searchItemID: SearchID.sortOrder)
        configureSwitch(recentlyClosedSwitch, action: #selector(toggleRecentlyClosed(_:)))
        addRow(to: contents, title: String(localized: "Show recently closed apps"),
               subtitle: String(localized: "Lists apps and windows you just closed so you can reopen them."),
               accessory: recentlyClosedSwitch, searchItemID: SearchID.showRecentlyClosed)
        configurePopup(recentlyClosedLimitPopup, titles: recentlyClosedLimits.map(String.init), action: #selector(recentlyClosedLimitChanged))
        addRow(to: contents, title: String(localized: "Recently closed to show"),
               subtitle: String(localized: "How many recently closed items to list."),
               accessory: recentlyClosedLimitPopup, searchItemID: SearchID.recentlyClosedLimit)

        // Tabs section — how windows that use native system tabs (Finder,
        // Terminal, TextEdit, …) are surfaced. Browsers (Safari/Chromium) can't
        // expand to rows, but the `\` peek still drills their tabs.
        let tabs = addSection(title: String(localized: "Tabs"), anchor: SettingsAnchor.tabs)
        configureSwitch(tabDrillSwitch, action: #selector(toggleTabDrill(_:)))
        addRow(to: tabs, title: String(localized: "Peek tabs with \\"),
               subtitle: String(localized: "Press \\ on a window that has tabs to reveal a strip below the switcher and pick a tab. Native tabs use Accessibility; browsers use Apple Events."),
               accessory: tabDrillSwitch, searchItemID: SearchID.tabDrill)
        configureSwitch(expandTabsSwitch, action: #selector(toggleExpandTabs(_:)))
        addRow(to: tabs, title: String(localized: "Show tabs as separate entries"),
               subtitle: String(localized: "List each tab of a native-tab window (Finder, Terminal, TextEdit, …) as its own row instead of one collapsed window. Off keeps one row per window — peek its tabs with \\."),
               accessory: expandTabsSwitch, searchItemID: SearchID.expandTabs)
        configureSwitch(expandBrowserTabsSwitch, action: #selector(toggleExpandBrowserTabs(_:)))
        addRow(to: tabs, title: String(localized: "Show browser tabs as separate entries"),
               subtitle: String(localized: "List each tab of a browser window (Safari, Chrome, Arc, Brave, Edge, …) as its own row alongside the other windows, instead of one collapsed window. Needs Apple Events access (below); off keeps one row per window — peek its tabs with \\."),
               accessory: expandBrowserTabsSwitch, searchItemID: SearchID.expandBrowserTabs)

        let grantButton = NSButton(title: String(localized: "Grant permissions…"), target: self, action: #selector(grantBrowserPermissions))
        grantButton.bezelStyle = .rounded
        grantButton.controlSize = .small
        addRow(to: tabs, title: String(localized: "Browser tab access"),
               subtitle: String(localized: "Browsers need Apple Events consent to list their tabs. Click to prompt for each running browser (Safari, Chrome, Arc, Brave, Edge…). Must be done with this window open."),
               accessory: grantButton, searchItemID: SearchID.tabPermissions)

        // Search section — type-to-filter behavior.
        let search = addSection(title: String(localized: "Search"), anchor: SettingsAnchor.search)
        configureSwitch(letterHintsSwitch, action: #selector(toggleLetterHints(_:)))
        addRow(to: search, title: String(localized: "Letter hints"),
               subtitle: String(localized: "Show a letter on each window and jump to it by typing that letter."),
               accessory: letterHintsSwitch, searchItemID: SearchID.letterHints)

        letterTimeoutSlider.minValue = Double(Preferences.letterChainTimeoutRange.lowerBound)
        letterTimeoutSlider.maxValue = Double(Preferences.letterChainTimeoutRange.upperBound)
        letterTimeoutSlider.isContinuous = true
        letterTimeoutSlider.controlSize = .small
        letterTimeoutSlider.target = self
        letterTimeoutSlider.action = #selector(letterTimeoutChanged(_:))
        letterTimeoutSlider.translatesAutoresizingMaskIntoConstraints = false
        letterTimeoutValueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        letterTimeoutValueLabel.textColor = .secondaryLabelColor
        letterTimeoutValueLabel.alignment = .right
        letterTimeoutValueLabel.translatesAutoresizingMaskIntoConstraints = false
        letterTimeoutValueLabel.setContentHuggingPriority(.required, for: .horizontal)
        let letterTimeoutStack = NSStackView(views: [letterTimeoutSlider, letterTimeoutValueLabel])
        letterTimeoutStack.orientation = .horizontal
        letterTimeoutStack.spacing = 8
        letterTimeoutStack.alignment = .centerY
        NSLayoutConstraint.activate([
            letterTimeoutSlider.widthAnchor.constraint(equalToConstant: 140),
            letterTimeoutValueLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 52),
        ])
        addRow(to: search, title: String(localized: "Letter chain timeout"),
               subtitle: String(localized: "How long a typed letter sequence stays active. When it expires, the highlight clears and the list returns to its original order."),
               accessory: letterTimeoutStack, searchItemID: SearchID.letterChainTimeout)

        configureSwitch(fuzzySwitch, action: #selector(toggleFuzzy(_:)))
        addRow(to: search, title: String(localized: "Type-to-filter search"),
               subtitle: String(localized: "Press / in the switcher to filter by app or window name."),
               accessory: fuzzySwitch, searchItemID: SearchID.fuzzy)
        configureSwitch(launcherSwitch, action: #selector(toggleLauncher(_:)))
        addRow(to: search, title: String(localized: "Launch apps from search"),
               subtitle: String(localized: "Also show matching apps that aren't running yet."),
               accessory: launcherSwitch, searchItemID: SearchID.launcher)

        searchModePopup.controlSize = .small
        searchModePopup.translatesAutoresizingMaskIntoConstraints = false
        searchModePopup.setContentHuggingPriority(.required, for: .horizontal)
        searchModePopup.removeAllItems()
        searchModePopup.addItems(withTitles: searchDismissModes.map(\.displayName))
        searchModePopup.target = self
        searchModePopup.action = #selector(searchModeChanged)
        addRow(to: search, title: String(localized: "When searching"),
               subtitle: String(localized: "Hold ⌘: release to pick. Stay open: pick with Return or the mouse."),
               accessory: searchModePopup, searchItemID: SearchID.searchMode)

        // Navigation section — alternative ways to move the selection.
        let navigation = addSection(title: String(localized: "Navigation"), anchor: SettingsAnchor.navigation)
        configureSwitch(stayOpenSwitch, action: #selector(toggleStayOpen(_:)))
        addRow(to: navigation, title: String(localized: "Stay open after releasing the modifier"),
               subtitle: String(localized: "Keep the switcher on screen when you let go of the trigger — pick with Return, a quick-jump letter, or the mouse; Esc dismisses. A quick tap still switches instantly."),
               accessory: stayOpenSwitch, searchItemID: SearchID.stayOpen)
        configureSwitch(shiftTapBackSwitch, action: #selector(toggleShiftTapBack(_:)))
        addRow(to: navigation, title: String(localized: "Tap Shift to step backwards"),
               subtitle: String(localized: "While the switcher is open, a tap of the Shift key steps the selection backwards and holding Shift keeps stepping back until you let go — just like a held Tab. Turn this off to step back only with Shift held as you press the switch key (⌘⇧Tab)."),
               accessory: shiftTapBackSwitch, searchItemID: SearchID.shiftTapBack)
        configureSwitch(scrollSwitch, action: #selector(toggleScroll(_:)))
        addRow(to: navigation, title: String(localized: "Switch with mouse scroll"),
               subtitle: String(localized: "Scroll up/down on a mouse wheel to move the selection while the switcher is open. Trackpads use the three-finger swipe instead."),
               accessory: scrollSwitch, searchItemID: SearchID.scroll)
        configureSwitch(scrollReverseSwitch, action: #selector(toggleScrollReverse(_:)))
        addRow(to: navigation, title: String(localized: "Reverse scroll direction"),
               subtitle: String(localized: "Scroll up to move forward instead of down."),
               accessory: scrollReverseSwitch, searchItemID: SearchID.scrollReverse)
        configureSwitch(clickDismissSwitch, action: #selector(toggleClickDismiss(_:)))
        addRow(to: navigation, title: String(localized: "Click outside to dismiss"),
               subtitle: String(localized: "Click anywhere outside the switcher to close it, leaving the current window focused."),
               accessory: clickDismissSwitch, searchItemID: SearchID.clickDismiss)
        configureSwitch(vimNavSwitch, action: #selector(toggleVimNavigation(_:)))
        addRow(to: navigation, title: String(localized: "Vim keys (h j k l)"),
               subtitle: String(localized: "Use h / j / k / l like the arrow keys while the switcher is open. h overrides the Hide binding and j / k / l override letter-jump; search mode still types those letters."),
               accessory: vimNavSwitch, searchItemID: SearchID.vimNavigation)
        configureSwitch(hoverSelectSwitch, action: #selector(toggleHoverSelect(_:)))
        addRow(to: navigation, title: String(localized: "Select window on hover"),
               subtitle: String(localized: "Move the selection to the row your pointer is over. Off keeps the keyboard selection put so the mouse can't change it by accident."),
               accessory: hoverSelectSwitch)
        configureSwitch(clickSelectSwitch, action: #selector(toggleClickSelect(_:)))
        addRow(to: navigation, title: String(localized: "Select window on click"),
               subtitle: String(localized: "Click a row to switch to that window. Off ignores clicks inside the switcher so the mouse can't pick a window — the tab strip and hover actions still work."),
               accessory: clickSelectSwitch)

        // Hover actions section — buttons revealed on a row under the pointer.
        let actions = addSection(title: String(localized: "Hover actions"), anchor: SettingsAnchor.actions)
        configureSwitch(hoverSwitch, action: #selector(toggleHover(_:)))
        addRow(to: actions, title: String(localized: "Action buttons on hover"),
               subtitle: String(localized: "Reveal quick buttons on the row your pointer is over."),
               accessory: hoverSwitch, searchItemID: SearchID.hoverActions)
        configureSwitch(hoverCloseSwitch, action: #selector(toggleHoverClose(_:)))
        addRow(to: actions, title: String(localized: "Close window"), accessory: hoverCloseSwitch)
        configureSwitch(hoverMinimizeSwitch, action: #selector(toggleHoverMinimize(_:)))
        addRow(to: actions, title: String(localized: "Minimize window"), accessory: hoverMinimizeSwitch)
        configureSwitch(hoverMaximizeSwitch, action: #selector(toggleHoverMaximize(_:)))
        addRow(to: actions, title: String(localized: "Zoom window"), accessory: hoverMaximizeSwitch)
        configureSwitch(hoverHideSwitch, action: #selector(toggleHoverHide(_:)))
        addRow(to: actions, title: String(localized: "Hide app"), accessory: hoverHideSwitch)
        configureSwitch(hoverQuitSwitch, action: #selector(toggleHoverQuit(_:)))
        addRow(to: actions, title: String(localized: "Quit app"), accessory: hoverQuitSwitch)
        configureSwitch(hoverForceQuitSwitch, action: #selector(toggleHoverForceQuit(_:)))
        addRow(to: actions, title: String(localized: "Force quit app"),
               subtitle: String(localized: "Sends SIGKILL — for hung apps that ignore Quit. ⌘+⌥+Q always works regardless."),
               accessory: hoverForceQuitSwitch)

        // Per-app rules (hide / ⌘Tab) and pinned apps now live in the Apps tab.
    }

    private func configureSwitch(_ toggle: NSSwitch, action: Selector) {
        toggle.controlSize = .small
        toggle.target = self
        toggle.action = action
    }

    private func configurePopup(_ popup: NSPopUpButton, titles: [String], action: Selector) {
        popup.controlSize = .small
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.setContentHuggingPriority(.required, for: .horizontal)
        popup.removeAllItems()
        popup.addItems(withTitles: titles)
        popup.target = self
        popup.action = action
    }

    override func viewWillAppear() {
        super.viewWillAppear()

        let prefs = Preferences.shared
        if let i = displayModes.firstIndex(of: prefs.switcherDisplayMode) { displayMonitorPopup.selectItem(at: i) }
        minimizedSwitch.state = prefs.showMinimizedWindows ? .on : .off
        hiddenSwitch.state = prefs.showHiddenApps ? .on : .off
        windowlessSwitch.state = prefs.showWindowlessApps ? .on : .off
        applicationsOnlySwitch.state = prefs.applicationsOnly ? .on : .off
        badgesSwitch.state = prefs.showUnreadBadges ? .on : .off
        if let i = spaceScopes.firstIndex(of: prefs.spaceScope) { spaceScopePopup.selectItem(at: i) }
        selectSortOrder(prefs.sortOrder)
        recentlyClosedSwitch.state = prefs.showRecentlyClosed ? .on : .off
        selectRecentlyClosedLimit(prefs.recentlyClosedLimit)
        recentlyClosedLimitPopup.isEnabled = prefs.showRecentlyClosed
        tabDrillSwitch.state = prefs.tabDrillEnabled ? .on : .off
        expandTabsSwitch.state = prefs.expandTabsAsWindows ? .on : .off
        expandBrowserTabsSwitch.state = prefs.expandBrowserTabsAsWindows ? .on : .off
        letterHintsSwitch.state = prefs.letterHintsEnabled ? .on : .off
        applyLetterTimeout(prefs.letterChainTimeoutMs)
        letterTimeoutSlider.isEnabled = prefs.letterHintsEnabled
        fuzzySwitch.state = prefs.fuzzySearchEnabled ? .on : .off
        launcherSwitch.state = prefs.searchIncludesLaunchableApps ? .on : .off
        selectSearchMode(prefs.searchDismissMode)
        stayOpenSwitch.state = prefs.stayOpenOnRelease ? .on : .off
        shiftTapBackSwitch.state = prefs.shiftTapStepsBackward ? .on : .off
        scrollSwitch.state = prefs.scrollToSwitch ? .on : .off
        scrollReverseSwitch.state = prefs.scrollReverseDirection ? .on : .off
        scrollReverseSwitch.isEnabled = prefs.scrollToSwitch
        clickDismissSwitch.state = prefs.clickOutsideToDismiss ? .on : .off
        vimNavSwitch.state = prefs.vimNavigationEnabled ? .on : .off
        hoverSelectSwitch.state = prefs.mouseHoverSelectionEnabled ? .on : .off
        clickSelectSwitch.state = prefs.mouseClickSelectionEnabled ? .on : .off
        hoverSwitch.state = prefs.hoverActionsEnabled ? .on : .off
        hoverCloseSwitch.state = prefs.hoverShowClose ? .on : .off
        hoverMinimizeSwitch.state = prefs.hoverShowMinimize ? .on : .off
        hoverMaximizeSwitch.state = prefs.hoverShowMaximize ? .on : .off
        hoverHideSwitch.state = prefs.hoverShowHide ? .on : .off
        hoverQuitSwitch.state = prefs.hoverShowQuit ? .on : .off
        hoverForceQuitSwitch.state = prefs.hoverShowForceQuit ? .on : .off
        setHoverSubOptionsEnabled(prefs.hoverActionsEnabled)

        prefs.$searchDismissMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.selectSearchMode($0) }
            .store(in: &cancellables)
        // Keep the slider in sync if the value changes underneath us (e.g. a
        // settings import calls reloadFromDefaults while this pane is open).
        prefs.$letterChainTimeoutMs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.applyLetterTimeout($0) }
            .store(in: &cancellables)
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        cancellables.removeAll()
    }

    @objc private func displayModeChanged() {
        let idx = displayMonitorPopup.indexOfSelectedItem
        guard displayModes.indices.contains(idx) else { return }
        Preferences.shared.switcherDisplayMode = displayModes[idx]
    }

    @objc private func toggleTabDrill(_ sender: NSSwitch) {
        let on = (sender.state == .on)
        Preferences.shared.tabDrillEnabled = on
        // Opting in while Settings is foreground is the right moment to ask for
        // Apple Events consent — TCC needs that UI context to surface the prompt.
        if on { BrowserTabs.requestPermissionForRunningBrowsers() }
    }

    @objc private func toggleExpandTabs(_ sender: NSSwitch) {
        Preferences.shared.expandTabsAsWindows = (sender.state == .on)
    }

    @objc private func toggleExpandBrowserTabs(_ sender: NSSwitch) {
        let on = (sender.state == .on)
        Preferences.shared.expandBrowserTabsAsWindows = on
        // Listing browser tabs needs Apple Events consent; opting in while
        // Settings is foreground is the moment TCC can surface the prompt.
        if on { BrowserTabs.requestPermissionForRunningBrowsers() }
    }

    @objc private func grantBrowserPermissions() {
        BrowserTabs.requestPermissionForRunningBrowsers()
    }

    @objc private func toggleLetterHints(_ sender: NSSwitch) {
        let on = (sender.state == .on)
        Preferences.shared.letterHintsEnabled = on
        // The chain timeout only matters while letter-jump is on (typing a letter
        // is a no-op otherwise), so gray it out to match.
        letterTimeoutSlider.isEnabled = on
    }

    @objc private func letterTimeoutChanged(_ sender: NSSlider) {
        Preferences.shared.letterChainTimeoutMs = sender.integerValue
        applyLetterTimeout(sender.integerValue)
    }

    private func applyLetterTimeout(_ ms: Int) {
        if Int(letterTimeoutSlider.intValue) != ms { letterTimeoutSlider.integerValue = ms }
        letterTimeoutValueLabel.stringValue = String(format: "%.1f s", Double(ms) / 1000.0)
    }

    @objc private func toggleFuzzy(_ sender: NSSwitch) {
        Preferences.shared.fuzzySearchEnabled = (sender.state == .on)
    }

    @objc private func toggleLauncher(_ sender: NSSwitch) {
        Preferences.shared.searchIncludesLaunchableApps = (sender.state == .on)
    }

    @objc private func toggleStayOpen(_ sender: NSSwitch) {
        Preferences.shared.stayOpenOnRelease = (sender.state == .on)
    }

    @objc private func toggleShiftTapBack(_ sender: NSSwitch) {
        Preferences.shared.shiftTapStepsBackward = (sender.state == .on)
    }

    @objc private func toggleScroll(_ sender: NSSwitch) {
        let on = (sender.state == .on)
        Preferences.shared.scrollToSwitch = on
        scrollReverseSwitch.isEnabled = on
    }

    @objc private func toggleScrollReverse(_ sender: NSSwitch) {
        Preferences.shared.scrollReverseDirection = (sender.state == .on)
    }

    @objc private func toggleClickDismiss(_ sender: NSSwitch) {
        Preferences.shared.clickOutsideToDismiss = (sender.state == .on)
    }

    @objc private func toggleVimNavigation(_ sender: NSSwitch) {
        Preferences.shared.vimNavigationEnabled = (sender.state == .on)
    }

    @objc private func toggleHoverSelect(_ sender: NSSwitch) {
        Preferences.shared.mouseHoverSelectionEnabled = (sender.state == .on)
    }

    @objc private func toggleClickSelect(_ sender: NSSwitch) {
        Preferences.shared.mouseClickSelectionEnabled = (sender.state == .on)
    }

    @objc private func toggleHover(_ sender: NSSwitch) {
        let on = (sender.state == .on)
        Preferences.shared.hoverActionsEnabled = on
        setHoverSubOptionsEnabled(on)
    }

    @objc private func toggleHoverClose(_ sender: NSSwitch) {
        Preferences.shared.hoverShowClose = (sender.state == .on)
    }

    @objc private func toggleHoverMinimize(_ sender: NSSwitch) {
        Preferences.shared.hoverShowMinimize = (sender.state == .on)
    }

    @objc private func toggleHoverMaximize(_ sender: NSSwitch) {
        Preferences.shared.hoverShowMaximize = (sender.state == .on)
    }

    @objc private func toggleHoverHide(_ sender: NSSwitch) {
        Preferences.shared.hoverShowHide = (sender.state == .on)
    }

    @objc private func toggleHoverQuit(_ sender: NSSwitch) {
        Preferences.shared.hoverShowQuit = (sender.state == .on)
    }

    @objc private func toggleHoverForceQuit(_ sender: NSSwitch) {
        Preferences.shared.hoverShowForceQuit = (sender.state == .on)
    }

    /// The per-button toggles only matter while hover actions are enabled.
    private func setHoverSubOptionsEnabled(_ enabled: Bool) {
        hoverCloseSwitch.isEnabled = enabled
        hoverMinimizeSwitch.isEnabled = enabled
        hoverMaximizeSwitch.isEnabled = enabled
        hoverHideSwitch.isEnabled = enabled
        hoverQuitSwitch.isEnabled = enabled
        hoverForceQuitSwitch.isEnabled = enabled
    }

    @objc private func searchModeChanged() {
        let idx = searchModePopup.indexOfSelectedItem
        guard searchDismissModes.indices.contains(idx) else { return }
        Preferences.shared.searchDismissMode = searchDismissModes[idx]
    }

    private func selectSearchMode(_ mode: SearchDismissMode) {
        if let i = searchDismissModes.firstIndex(of: mode) { searchModePopup.selectItem(at: i) }
    }

    // MARK: - Contents

    @objc private func toggleMinimized(_ sender: NSSwitch) {
        Preferences.shared.showMinimizedWindows = (sender.state == .on)
    }

    @objc private func toggleHidden(_ sender: NSSwitch) {
        Preferences.shared.showHiddenApps = (sender.state == .on)
    }

    @objc private func toggleWindowless(_ sender: NSSwitch) {
        Preferences.shared.showWindowlessApps = (sender.state == .on)
    }

    @objc private func toggleApplicationsOnly(_ sender: NSSwitch) {
        Preferences.shared.applicationsOnly = (sender.state == .on)
    }

    @objc private func toggleBadges(_ sender: NSSwitch) {
        Preferences.shared.showUnreadBadges = (sender.state == .on)
    }

    @objc private func spaceScopeChanged() {
        let idx = spaceScopePopup.indexOfSelectedItem
        guard spaceScopes.indices.contains(idx) else { return }
        Preferences.shared.spaceScope = spaceScopes[idx]
    }

    @objc private func sortOrderChanged() {
        let idx = sortOrderPopup.indexOfSelectedItem
        guard sortOrders.indices.contains(idx) else { return }
        Preferences.shared.sortOrder = sortOrders[idx]
    }

    private func selectSortOrder(_ order: SwitcherSortOrder) {
        if let i = sortOrders.firstIndex(of: order) { sortOrderPopup.selectItem(at: i) }
    }

    @objc private func toggleRecentlyClosed(_ sender: NSSwitch) {
        let on = (sender.state == .on)
        Preferences.shared.showRecentlyClosed = on
        recentlyClosedLimitPopup.isEnabled = on
    }

    @objc private func recentlyClosedLimitChanged() {
        let idx = recentlyClosedLimitPopup.indexOfSelectedItem
        guard recentlyClosedLimits.indices.contains(idx) else { return }
        Preferences.shared.recentlyClosedLimit = recentlyClosedLimits[idx]
    }

    private func selectRecentlyClosedLimit(_ value: Int) {
        // Snap to the closest offered value if a stored limit isn't in the list.
        if let exact = recentlyClosedLimits.firstIndex(of: value) {
            recentlyClosedLimitPopup.selectItem(at: exact)
        } else if let nearest = recentlyClosedLimits.enumerated().min(by: { abs($0.element - value) < abs($1.element - value) }) {
            recentlyClosedLimitPopup.selectItem(at: nearest.offset)
        }
    }
}
