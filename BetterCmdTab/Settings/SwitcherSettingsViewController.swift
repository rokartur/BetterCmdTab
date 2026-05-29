import AppKit
import BetterSettings
import Combine

/// Settings for what the switcher lists, how search behaves, and per-app
/// exclusion/pinning. Split out of General so the trigger/app-level prefs and
/// the switcher's own content/search options live under their own tab.
@MainActor
final class SwitcherSettingsViewController: SettingsTabViewController {

    // Contents
    private let minimizedSwitch = NSSwitch()
    private let hiddenSwitch = NSSwitch()
    private let windowlessSwitch = NSSwitch()
    private let badgesSwitch = NSSwitch()
    private let currentSpaceSwitch = NSSwitch()
    private let recentlyClosedSwitch = NSSwitch()
    private let recentlyClosedLimitPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let recentlyClosedLimits: [Int] = [3, 5, 10, 15, 20]
    private let sortOrderPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sortOrders: [SwitcherSortOrder] = SwitcherSortOrder.allCases

    // Search
    private let letterHintsSwitch = NSSwitch()
    private let fuzzySwitch = NSSwitch()
    private let launcherSwitch = NSSwitch()
    private let searchModePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let searchDismissModes: [SearchDismissMode] = SearchDismissMode.allCases

    // Navigation
    private let scrollSwitch = NSSwitch()
    private let scrollReverseSwitch = NSSwitch()
    private let clickDismissSwitch = NSSwitch()

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
        // Switcher contents section — what kinds of windows/apps appear.
        let contents = addSection(title: "Contents", anchor: SettingsAnchor.contents)
        configureSwitch(minimizedSwitch, action: #selector(toggleMinimized(_:)))
        addRow(to: contents, title: "Show minimized windows", accessory: minimizedSwitch,
               searchItemID: SearchID.showMinimized)
        configureSwitch(hiddenSwitch, action: #selector(toggleHidden(_:)))
        addRow(to: contents, title: "Show hidden apps", accessory: hiddenSwitch,
               searchItemID: SearchID.showHidden)
        configureSwitch(windowlessSwitch, action: #selector(toggleWindowless(_:)))
        addRow(to: contents, title: "Show apps without windows",
               subtitle: "Running apps with no open windows.",
               accessory: windowlessSwitch, searchItemID: SearchID.showWindowless)
        configureSwitch(badgesSwitch, action: #selector(toggleBadges(_:)))
        addRow(to: contents, title: "Show unread badges",
               subtitle: "Show each app's Dock badge count (e.g. Mail's unread mail) on its row.",
               accessory: badgesSwitch, searchItemID: SearchID.showBadges)
        configureSwitch(currentSpaceSwitch, action: #selector(toggleCurrentSpace(_:)))
        addRow(to: contents, title: "Only current Space",
               subtitle: "Show only windows on the Space you're currently viewing.",
               accessory: currentSpaceSwitch, searchItemID: SearchID.currentSpaceOnly)

        sortOrderPopup.controlSize = .small
        sortOrderPopup.translatesAutoresizingMaskIntoConstraints = false
        sortOrderPopup.setContentHuggingPriority(.required, for: .horizontal)
        sortOrderPopup.removeAllItems()
        sortOrderPopup.addItems(withTitles: sortOrders.map(\.displayName))
        sortOrderPopup.target = self
        sortOrderPopup.action = #selector(sortOrderChanged)
        addRow(to: contents, title: "Sort order",
               subtitle: "Most recent keeps the classic ⌘Tab order; the others stay put as you switch.",
               accessory: sortOrderPopup, searchItemID: SearchID.sortOrder)
        configureSwitch(recentlyClosedSwitch, action: #selector(toggleRecentlyClosed(_:)))
        addRow(to: contents, title: "Show recently closed apps",
               subtitle: "Lists apps and windows you just closed so you can reopen them.",
               accessory: recentlyClosedSwitch, searchItemID: SearchID.showRecentlyClosed)

        recentlyClosedLimitPopup.controlSize = .small
        recentlyClosedLimitPopup.translatesAutoresizingMaskIntoConstraints = false
        recentlyClosedLimitPopup.setContentHuggingPriority(.required, for: .horizontal)
        recentlyClosedLimitPopup.removeAllItems()
        recentlyClosedLimitPopup.addItems(withTitles: recentlyClosedLimits.map(String.init))
        recentlyClosedLimitPopup.target = self
        recentlyClosedLimitPopup.action = #selector(recentlyClosedLimitChanged)
        addRow(to: contents, title: "Recently closed to show",
               subtitle: "How many recently closed items to list.",
               accessory: recentlyClosedLimitPopup, searchItemID: SearchID.recentlyClosedLimit)

        // Search section — type-to-filter behavior.
        let search = addSection(title: "Search", anchor: SettingsAnchor.search)
        configureSwitch(letterHintsSwitch, action: #selector(toggleLetterHints(_:)))
        addRow(to: search, title: "Letter hints",
               subtitle: "Show a letter on each window and jump to it by typing that letter.",
               accessory: letterHintsSwitch, searchItemID: SearchID.letterHints)
        configureSwitch(fuzzySwitch, action: #selector(toggleFuzzy(_:)))
        addRow(to: search, title: "Type-to-filter search",
               subtitle: "Press / in the switcher to filter by app or window name.",
               accessory: fuzzySwitch, searchItemID: SearchID.fuzzy)
        configureSwitch(launcherSwitch, action: #selector(toggleLauncher(_:)))
        addRow(to: search, title: "Launch apps from search",
               subtitle: "Also show matching apps that aren't running yet.",
               accessory: launcherSwitch, searchItemID: SearchID.launcher)

        searchModePopup.controlSize = .small
        searchModePopup.translatesAutoresizingMaskIntoConstraints = false
        searchModePopup.setContentHuggingPriority(.required, for: .horizontal)
        searchModePopup.removeAllItems()
        searchModePopup.addItems(withTitles: searchDismissModes.map(\.displayName))
        searchModePopup.target = self
        searchModePopup.action = #selector(searchModeChanged)
        addRow(to: search, title: "When searching",
               subtitle: "Hold ⌘: release to pick. Stay open: pick with Return or the mouse.",
               accessory: searchModePopup, searchItemID: SearchID.searchMode)

        // Navigation section — alternative ways to move the selection.
        let navigation = addSection(title: "Navigation", anchor: SettingsAnchor.navigation)
        configureSwitch(scrollSwitch, action: #selector(toggleScroll(_:)))
        addRow(to: navigation, title: "Switch with mouse scroll",
               subtitle: "Scroll up/down on a mouse wheel to move the selection while the switcher is open. Trackpads use the three-finger swipe instead.",
               accessory: scrollSwitch, searchItemID: SearchID.scroll)
        configureSwitch(scrollReverseSwitch, action: #selector(toggleScrollReverse(_:)))
        addRow(to: navigation, title: "Reverse scroll direction",
               subtitle: "Scroll up to move forward instead of down.",
               accessory: scrollReverseSwitch, searchItemID: SearchID.scrollReverse)
        configureSwitch(clickDismissSwitch, action: #selector(toggleClickDismiss(_:)))
        addRow(to: navigation, title: "Click outside to dismiss",
               subtitle: "Click anywhere outside the switcher to close it, leaving the current window focused.",
               accessory: clickDismissSwitch, searchItemID: SearchID.clickDismiss)

        // Hover actions section — buttons revealed on a row under the pointer.
        let actions = addSection(title: "Hover actions", anchor: SettingsAnchor.actions)
        configureSwitch(hoverSwitch, action: #selector(toggleHover(_:)))
        addRow(to: actions, title: "Action buttons on hover",
               subtitle: "Reveal quick buttons on the row your pointer is over.",
               accessory: hoverSwitch, searchItemID: SearchID.hoverActions)
        configureSwitch(hoverCloseSwitch, action: #selector(toggleHoverClose(_:)))
        addRow(to: actions, title: "Close window", accessory: hoverCloseSwitch)
        configureSwitch(hoverMinimizeSwitch, action: #selector(toggleHoverMinimize(_:)))
        addRow(to: actions, title: "Minimize window", accessory: hoverMinimizeSwitch)
        configureSwitch(hoverMaximizeSwitch, action: #selector(toggleHoverMaximize(_:)))
        addRow(to: actions, title: "Zoom window", accessory: hoverMaximizeSwitch)
        configureSwitch(hoverHideSwitch, action: #selector(toggleHoverHide(_:)))
        addRow(to: actions, title: "Hide app", accessory: hoverHideSwitch)
        configureSwitch(hoverQuitSwitch, action: #selector(toggleHoverQuit(_:)))
        addRow(to: actions, title: "Quit app", accessory: hoverQuitSwitch)
        configureSwitch(hoverForceQuitSwitch, action: #selector(toggleHoverForceQuit(_:)))
        addRow(to: actions, title: "Force quit app",
               subtitle: "Sends SIGKILL — for hung apps that ignore Quit. ⌘+⌥+Q always works regardless.",
               accessory: hoverForceQuitSwitch)

        // Per-app rules (hide / ⌘Tab) and pinned apps now live in the Apps tab.
    }

    private func configureSwitch(_ toggle: NSSwitch, action: Selector) {
        toggle.controlSize = .small
        toggle.target = self
        toggle.action = action
    }

    override func viewWillAppear() {
        super.viewWillAppear()

        let prefs = Preferences.shared
        minimizedSwitch.state = prefs.showMinimizedWindows ? .on : .off
        hiddenSwitch.state = prefs.showHiddenApps ? .on : .off
        windowlessSwitch.state = prefs.showWindowlessApps ? .on : .off
        badgesSwitch.state = prefs.showUnreadBadges ? .on : .off
        currentSpaceSwitch.state = prefs.currentSpaceOnly ? .on : .off
        selectSortOrder(prefs.sortOrder)
        letterHintsSwitch.state = prefs.letterHintsEnabled ? .on : .off
        fuzzySwitch.state = prefs.fuzzySearchEnabled ? .on : .off
        launcherSwitch.state = prefs.searchIncludesLaunchableApps ? .on : .off
        recentlyClosedSwitch.state = prefs.showRecentlyClosed ? .on : .off
        selectRecentlyClosedLimit(prefs.recentlyClosedLimit)
        recentlyClosedLimitPopup.isEnabled = prefs.showRecentlyClosed
        selectSearchMode(prefs.searchDismissMode)
        scrollSwitch.state = prefs.scrollToSwitch ? .on : .off
        scrollReverseSwitch.state = prefs.scrollReverseDirection ? .on : .off
        scrollReverseSwitch.isEnabled = prefs.scrollToSwitch
        clickDismissSwitch.state = prefs.clickOutsideToDismiss ? .on : .off
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
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        cancellables.removeAll()
    }

    @objc private func toggleMinimized(_ sender: NSSwitch) {
        Preferences.shared.showMinimizedWindows = (sender.state == .on)
    }

    @objc private func toggleHidden(_ sender: NSSwitch) {
        Preferences.shared.showHiddenApps = (sender.state == .on)
    }

    @objc private func toggleWindowless(_ sender: NSSwitch) {
        Preferences.shared.showWindowlessApps = (sender.state == .on)
    }

    @objc private func toggleBadges(_ sender: NSSwitch) {
        Preferences.shared.showUnreadBadges = (sender.state == .on)
    }

    @objc private func toggleCurrentSpace(_ sender: NSSwitch) {
        Preferences.shared.currentSpaceOnly = (sender.state == .on)
    }

    @objc private func sortOrderChanged() {
        let idx = sortOrderPopup.indexOfSelectedItem
        guard sortOrders.indices.contains(idx) else { return }
        Preferences.shared.sortOrder = sortOrders[idx]
    }

    private func selectSortOrder(_ order: SwitcherSortOrder) {
        if let i = sortOrders.firstIndex(of: order) { sortOrderPopup.selectItem(at: i) }
    }

    @objc private func toggleLetterHints(_ sender: NSSwitch) {
        Preferences.shared.letterHintsEnabled = (sender.state == .on)
    }

    @objc private func toggleFuzzy(_ sender: NSSwitch) {
        Preferences.shared.fuzzySearchEnabled = (sender.state == .on)
    }

    @objc private func toggleLauncher(_ sender: NSSwitch) {
        Preferences.shared.searchIncludesLaunchableApps = (sender.state == .on)
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

    @objc private func searchModeChanged() {
        let idx = searchModePopup.indexOfSelectedItem
        guard searchDismissModes.indices.contains(idx) else { return }
        Preferences.shared.searchDismissMode = searchDismissModes[idx]
    }

    private func selectSearchMode(_ mode: SearchDismissMode) {
        if let i = searchDismissModes.firstIndex(of: mode) { searchModePopup.selectItem(at: i) }
    }
}
