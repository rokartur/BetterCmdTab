import AppKit
import Combine

/// Settings for what the switcher lists, how search behaves, and per-app
/// exclusion/pinning. Split out of General so the trigger/app-level prefs and
/// the switcher's own content/search options live under their own tab.
@MainActor
final class SwitcherSettingsViewController: NSViewController {

    // Contents
    private let minimizedSwitch = NSSwitch()
    private let hiddenSwitch = NSSwitch()
    private let windowlessSwitch = NSSwitch()
    private let badgesSwitch = NSSwitch()
    private let recentlyClosedSwitch = NSSwitch()
    private let recentlyClosedLimitPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let recentlyClosedLimits: [Int] = [3, 5, 10, 15, 20]

    // Search
    private let letterHintsSwitch = NSSwitch()
    private let fuzzySwitch = NSSwitch()
    private let launcherSwitch = NSSwitch()
    private let searchModePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let searchDismissModes: [SearchDismissMode] = SearchDismissMode.allCases

    // Navigation
    private let scrollSwitch = NSSwitch()
    private let scrollReverseSwitch = NSSwitch()
    private let scrollReverseRow = SettingsRowView(
        title: "Reverse scroll direction",
        subtitle: "Scroll up to move forward instead of down."
    )

    // Apps
    private let excludedButton = NSButton(title: "Manage apps", target: nil, action: nil)
    private let pinnedButton = NSButton(title: "Manage apps", target: nil, action: nil)
    private let excludedRow = SettingsRowView(
        title: "Excluded apps",
        description: "Never shown in the switcher."
    )
    private let pinnedRow = SettingsRowView(
        title: "Pinned apps",
        description: "Always shown first, before recents."
    )
    private var appsSheet: AppsPickerSheetWindowController?

    private var cancellables = Set<AnyCancellable>()

    override func loadView() {
        // Switcher contents section — what kinds of windows/apps appear.
        let contents = SettingsSectionView(header: "Contents")
        configureSwitch(minimizedSwitch, action: #selector(toggleMinimized(_:)))
        contents.addContent(SettingsRowView(
            title: "Show minimized windows",
            accessory: minimizedSwitch
        ))
        configureSwitch(hiddenSwitch, action: #selector(toggleHidden(_:)))
        contents.addContent(SettingsRowView(
            title: "Show hidden apps",
            accessory: hiddenSwitch
        ))
        configureSwitch(windowlessSwitch, action: #selector(toggleWindowless(_:)))
        contents.addContent(SettingsRowView(
            title: "Show apps without windows",
            subtitle: "Running apps with no open windows.",
            accessory: windowlessSwitch
        ))
        configureSwitch(badgesSwitch, action: #selector(toggleBadges(_:)))
        contents.addContent(SettingsRowView(
            title: "Show unread badges",
            subtitle: "Show each app's Dock badge count (e.g. Mail's unread mail) on its row.",
            accessory: badgesSwitch
        ))
        configureSwitch(recentlyClosedSwitch, action: #selector(toggleRecentlyClosed(_:)))
        contents.addContent(SettingsRowView(
            title: "Show recently closed apps",
            subtitle: "Lists apps and windows you just closed so you can reopen them.",
            accessory: recentlyClosedSwitch
        ))

        recentlyClosedLimitPopup.controlSize = .small
        recentlyClosedLimitPopup.translatesAutoresizingMaskIntoConstraints = false
        recentlyClosedLimitPopup.setContentHuggingPriority(.required, for: .horizontal)
        recentlyClosedLimitPopup.removeAllItems()
        recentlyClosedLimitPopup.addItems(withTitles: recentlyClosedLimits.map(String.init))
        recentlyClosedLimitPopup.target = self
        recentlyClosedLimitPopup.action = #selector(recentlyClosedLimitChanged)
        contents.addContent(SettingsRowView(
            title: "Recently closed to show",
            subtitle: "How many recently closed items to list.",
            accessory: recentlyClosedLimitPopup
        ))

        // Search section — type-to-filter behavior.
        let search = SettingsSectionView(header: "Search")
        configureSwitch(letterHintsSwitch, action: #selector(toggleLetterHints(_:)))
        search.addContent(SettingsRowView(
            title: "Letter hints",
            subtitle: "Show a letter on each window and jump to it by typing that letter.",
            accessory: letterHintsSwitch
        ))
        configureSwitch(fuzzySwitch, action: #selector(toggleFuzzy(_:)))
        search.addContent(SettingsRowView(
            title: "Type-to-filter search",
            subtitle: "Press / in the switcher to filter by app or window name.",
            accessory: fuzzySwitch
        ))
        configureSwitch(launcherSwitch, action: #selector(toggleLauncher(_:)))
        search.addContent(SettingsRowView(
            title: "Launch apps from search",
            subtitle: "Also show matching apps that aren't running yet.",
            accessory: launcherSwitch
        ))

        searchModePopup.controlSize = .small
        searchModePopup.translatesAutoresizingMaskIntoConstraints = false
        searchModePopup.setContentHuggingPriority(.required, for: .horizontal)
        searchModePopup.removeAllItems()
        searchModePopup.addItems(withTitles: searchDismissModes.map(\.displayName))
        searchModePopup.target = self
        searchModePopup.action = #selector(searchModeChanged)
        search.addContent(SettingsRowView(
            title: "When searching",
            subtitle: "Hold ⌘: release to pick. Stay open: pick with Return or the mouse.",
            accessory: searchModePopup
        ))

        // Navigation section — alternative ways to move the selection.
        let navigation = SettingsSectionView(header: "Navigation")
        configureSwitch(scrollSwitch, action: #selector(toggleScroll(_:)))
        navigation.addContent(SettingsRowView(
            title: "Switch with mouse scroll",
            subtitle: "Scroll up/down on a mouse wheel to move the selection while the switcher is open. Trackpads use the three-finger swipe instead.",
            accessory: scrollSwitch
        ))
        configureSwitch(scrollReverseSwitch, action: #selector(toggleScrollReverse(_:)))
        scrollReverseRow.setAccessory(scrollReverseSwitch)
        navigation.addContent(scrollReverseRow)

        // App lists section — exclusion and pinning, each via a picker sheet.
        let appLists = SettingsSectionView(header: "Apps")
        configureManageButton(excludedButton, action: #selector(manageExcluded))
        excludedRow.setAccessory(excludedButton)
        appLists.addContent(excludedRow)
        configureManageButton(pinnedButton, action: #selector(managePinned))
        pinnedRow.setAccessory(pinnedButton)
        appLists.addContent(pinnedRow)

        view = SettingsLayout.makeScrollingTab(sections: [contents, search, navigation, appLists])
    }

    private func configureSwitch(_ toggle: NSSwitch, action: Selector) {
        toggle.controlSize = .small
        toggle.target = self
        toggle.action = action
    }

    private func configureManageButton(_ button: NSButton, action: Selector) {
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.target = self
        button.action = action
    }

    override func viewWillAppear() {
        super.viewWillAppear()

        let prefs = Preferences.shared
        minimizedSwitch.state = prefs.showMinimizedWindows ? .on : .off
        hiddenSwitch.state = prefs.showHiddenApps ? .on : .off
        windowlessSwitch.state = prefs.showWindowlessApps ? .on : .off
        badgesSwitch.state = prefs.showUnreadBadges ? .on : .off
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
        updateAppListCounts()

        prefs.$searchDismissMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.selectSearchMode($0) }
            .store(in: &cancellables)

        prefs.$excludedBundleIDs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.excludedRow.rowDescription = Self.countDescription($0.count, suffix: "never shown in the switcher.") }
            .store(in: &cancellables)
        prefs.$pinnedBundleIDs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.pinnedRow.rowDescription = Self.countDescription($0.count, suffix: "always shown first.") }
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

    @objc private func manageExcluded() {
        presentAppsSheet(
            title: "Excluded Apps",
            prompt: "Selected apps are hidden from the switcher entirely.",
            selected: Preferences.shared.excludedBundleIDs
        ) { selection in
            Preferences.shared.excludedBundleIDs = selection
        }
    }

    @objc private func managePinned() {
        presentAppsSheet(
            title: "Pinned Apps",
            prompt: "Selected apps are forced to the front of the switcher, before recents.",
            selected: Set(Preferences.shared.pinnedBundleIDs)
        ) { selection in
            // Preserve existing pin order; append newly-checked apps at the end.
            let current = Preferences.shared.pinnedBundleIDs
            var order = current.filter { selection.contains($0) }
            for bid in selection where !order.contains(bid) { order.append(bid) }
            Preferences.shared.pinnedBundleIDs = order
        }
    }

    private func presentAppsSheet(
        title: String,
        prompt: String,
        selected: Set<String>,
        onDone: @escaping (Set<String>) -> Void
    ) {
        guard let window = view.window, appsSheet == nil else { return }
        let controller = AppsPickerSheetWindowController(
            title: title,
            prompt: prompt,
            selectedBundleIDs: selected,
            onDone: onDone
        )
        controller.onDidDismiss = { [weak self] in
            self?.appsSheet = nil
            self?.updateAppListCounts()
        }
        appsSheet = controller
        controller.present(asSheetFor: window)
    }

    private func updateAppListCounts() {
        let prefs = Preferences.shared
        excludedRow.rowDescription = Self.countDescription(prefs.excludedBundleIDs.count, suffix: "never shown in the switcher.")
        pinnedRow.rowDescription = Self.countDescription(prefs.pinnedBundleIDs.count, suffix: "always shown first.")
    }

    private static func countDescription(_ count: Int, suffix: String) -> String {
        let prefix = count == 0 ? "None" : "\(count) app\(count == 1 ? "" : "s")"
        return "\(prefix) — \(suffix)"
    }
}
