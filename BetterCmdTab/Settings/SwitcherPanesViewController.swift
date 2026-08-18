import AppKit
import BetterSettings
import BetterShortcuts
import Combine

/// Backs three sibling panes that all edit the switcher's global defaults, so
/// they share one set of controls and one `viewWillAppear` sync:
///
/// - **Switcher** — what the panel lists (Contents) and its two timing knobs.
/// - **Controls** — how you drive the open panel: keys, letter jump, search,
///   mouse, hover actions.
/// - **Tabs** — native window tabs and browser tabs.
///
/// Global hotkeys live under Shortcuts, the look under Appearance, per-app
/// rules under Apps, and the Apple Events consent browser tabs need under
/// Privacy.
@MainActor
final class SwitcherPanesViewController: SettingsTabViewController {

    /// Which of the three panes this instance builds.
    enum Pane { case switcher, controls, tabs }

    private let pane: Pane

    init(pane: Pane) {
        self.pane = pane
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Timing
    private let delaySlider = NSSlider()
    private let delayValueField = NSTextField()
    private let titleRefreshSlider = NSSlider()
    private let titleRefreshValueField = NSTextField()

    // Contents — what apps/windows the switcher lists (moved here from Appearance:
    // these decide *which* windows show, which is behavior, not look).
    private let minimizedSwitch = NSSwitch()
    private let hiddenSwitch = NSSwitch()
    private let sinkHiddenSwitch = PreferenceSwitch(bind: \.sinkHiddenApps)
    private let sinkMinimizedSwitch = PreferenceSwitch(bind: \.sinkMinimizedWindows)
    /// Kept so the row can visibly lock (dim + tooltip) while its prerequisite
    /// "Show hidden apps" is off — mirrors `stayOpenQuickTapRow`.
    private var sinkHiddenRow: SettingsRowView?
    /// Same, gated on "Show minimized windows" instead.
    private var sinkMinimizedRow: SettingsRowView?
    private let windowlessSwitch = PreferenceSwitch(bind: \.showWindowlessApps)
    private let applicationsOnlySwitch = PreferenceSwitch(bind: \.applicationsOnly)
    private let badgesSwitch = PreferenceSwitch(bind: \.showUnreadBadges)
    private let spaceScopePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let spaceScopes: [SpaceScope] = SpaceScope.allCases
    private let recentlyClosedSwitch = NSSwitch()
    private let recentlyClosedLimitField = NSTextField()
    private let sortOrderPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sortOrders: [SwitcherSortOrder] = SwitcherSortOrder.allCases
    private let instantSpaceRowSwitch = PreferenceSwitch(bind: \.instantSpaceSwitch)

    private let windowDrillSwitch = PreferenceSwitch(bind: \.windowDrillEnabled)

    // Tabs
    private let tabDrillSwitch = NSSwitch()
    /// Kept so `viewWillAppear` can re-render the subtitle after a rebind.
    private var tabDrillRow: SettingsRowView?
    private let expandTabsSwitch = PreferenceSwitch(bind: \.expandTabsAsWindows)
    private let expandBrowserTabsSwitch = NSSwitch()
    private let browserTabLimitField = NSTextField()
    private let browserIconOnTabsSwitch = PreferenceSwitch(bind: \.showBrowserIconOnTabs)
    private let browserTabMRUSwitch = PreferenceSwitch(bind: \.browserTabMRU)
    private let browserTabPreviewsSwitch = PreferenceSwitch(bind: \.browserTabPreviews)
    /// Kept so the row can visibly lock (dim + tooltip) while its prerequisite
    /// "Type-to-filter search" — owned by the Controls pane — is off.
    private var searchTabsRow: SettingsRowView?

    // Search
    private let letterHintsSwitch = NSSwitch()
    /// Kept so `viewWillAppear` can re-render the subtitle after a rebind.
    private var letterHintsRow: SettingsRowView?
    private var quickJumpMappingsRow: SettingsRowView?
    private var quickJumpMappingsSheet: QuickJumpMappingsSheetWindowController?
    private let letterTimeoutSlider = NSSlider()
    private let letterTimeoutValueField = NSTextField()
    private let fuzzySwitch = NSSwitch()
    /// Kept so `viewWillAppear` can re-render the subtitle after a rebind.
    private var fuzzyRow: SettingsRowView?
    private let rankResultsSwitch = PreferenceSwitch(bind: \.fuzzySearchRankBestMatchFirst)
    private let launcherSwitch = PreferenceSwitch(bind: \.searchIncludesLaunchableApps)
    private let searchTabsSwitch = NSSwitch()
    private let searchModePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let searchDismissModes: [SearchDismissMode] = SearchDismissMode.allCases

    // Keyboard
    private let stayOpenSwitch = NSSwitch()
    private let stayOpenQuickTapSwitch = PreferenceSwitch(bind: \.stayOpenOnQuickTap)
    /// Kept so the quick-tap row can visibly lock (dim + tooltip) while its
    /// prerequisite "Stay open after releasing the modifier" is off.
    private var stayOpenQuickTapRow: SettingsRowView?
    private let shiftTapBackSwitch = PreferenceSwitch(bind: \.shiftTapStepsBackward)
    private let backtickReverseSwitch = PreferenceSwitch(bind: \.backtickReversesAppSwitching)
    private let vimNavSwitch = PreferenceSwitch(bind: \.vimNavigationEnabled)

    // Mouse
    private let scrollSwitch = NSSwitch()
    private let scrollReverseSwitch = PreferenceSwitch(bind: \.scrollReverseDirection)
    private let clickDismissSwitch = PreferenceSwitch(bind: \.clickOutsideToDismiss)
    private let hoverSelectSwitch = PreferenceSwitch(bind: \.mouseHoverSelectionEnabled)
    private let clickSelectSwitch = PreferenceSwitch(bind: \.mouseClickSelectionEnabled)

    // Mouse — hover actions
    private let hoverSwitch = NSSwitch()
    private let hoverCloseSwitch = PreferenceSwitch(bind: \.hoverShowClose)
    private let hoverMinimizeSwitch = PreferenceSwitch(bind: \.hoverShowMinimize)
    private let hoverMaximizeSwitch = PreferenceSwitch(bind: \.hoverShowMaximize)
    private let hoverHideSwitch = PreferenceSwitch(bind: \.hoverShowHide)
    private let hoverQuitSwitch = PreferenceSwitch(bind: \.hoverShowQuit)
    private let hoverForceQuitSwitch = PreferenceSwitch(bind: \.hoverShowForceQuit)

    private var cancellables = Set<AnyCancellable>()

    override func setupContent() {
        switch pane {
        case .switcher:
            addGlobalDefaultNote()
            buildContentsSection()
            buildTimingSection()
        case .controls:
            addGlobalDefaultNote()
            buildKeyboardSection()
            buildLetterJumpSection()
            buildSearchSection()
            buildMouseSection()
        case .tabs:
            buildNativeTabsSection()
            buildBrowserTabsSection()
        }
    }

    /// Timing — when the panel appears and how fast its titles catch up. Both
    /// are about *when*, not how it looks, so they sit here and not under
    /// Appearance.
    private func buildTimingSection() {
        let timing = addSection(title: String(localized: "Timing"), anchor: SettingsAnchor.timing)

        let quickSwitchDelayTitle = String(localized: "Quick-switch delay")
        let delayStack = makeValueSlider(delaySlider, field: delayValueField,
                                         range: Preferences.revealDelayRange, unit: "ms",
                                         label: quickSwitchDelayTitle,
                                         sliderAction: #selector(delayChanged(_:)),
                                         fieldAction: #selector(delayValueCommitted(_:)))
        addRow(to: timing, title: quickSwitchDelayTitle,
               subtitle: String(localized: "Tap to switch instantly; hold longer to open the switcher."),
               accessory: delayStack, searchItemID: SearchID.quickSwitchDelay)

        let titleRefreshDelayTitle = String(localized: "Title refresh delay")
        let titleRefreshStack = makeValueSlider(titleRefreshSlider, field: titleRefreshValueField,
                                                range: Preferences.titleRefreshIntervalRange, unit: "ms",
                                                label: titleRefreshDelayTitle,
                                                sliderAction: #selector(titleRefreshChanged(_:)),
                                                fieldAction: #selector(titleRefreshValueCommitted(_:)))
        addRow(to: timing, title: titleRefreshDelayTitle,
               subtitle: String(localized: "How quickly window titles in the open switcher update after an app changes them. Lower is more responsive; higher saves work when titles change rapidly."),
               accessory: titleRefreshStack, searchItemID: SearchID.titleRefreshInterval)
    }

    /// Contents — what kinds of windows/apps appear in the switcher.
    private func buildContentsSection() {
        let contents = addSection(title: String(localized: "Contents"), anchor: SettingsAnchor.contents)
        configureSwitch(minimizedSwitch, action: #selector(toggleMinimized(_:)))
        addRow(to: contents, title: String(localized: "Show minimized windows"), accessory: minimizedSwitch,
               searchItemID: SearchID.showMinimized)
        configureSwitch(hiddenSwitch, action: #selector(toggleHidden(_:)))
        addRow(to: contents, title: String(localized: "Show hidden apps"), accessory: hiddenSwitch,
               searchItemID: SearchID.showHidden)
        sinkHiddenRow = addRow(to: contents, title: String(localized: "Move hidden apps to the bottom"),
               subtitle: String(localized: "Groups hidden apps at the end of the list. Turn off to leave them in their normal position instead."),
               accessory: sinkHiddenSwitch, searchItemID: SearchID.sinkHiddenApps)
        sinkMinimizedRow = addRow(to: contents, title: String(localized: "Move minimized windows to the bottom"),
               subtitle: String(localized: "Groups minimized windows at the end of the list. Turn off to leave them in their most-recently-used position instead."),
               accessory: sinkMinimizedSwitch, searchItemID: SearchID.sinkMinimizedWindows)
        addRow(to: contents, title: String(localized: "Show apps without windows"),
               subtitle: String(localized: "Running apps with no open windows."),
               accessory: windowlessSwitch, searchItemID: SearchID.showWindowless)
        addRow(to: contents, title: String(localized: "Applications only"),
               subtitle: String(localized: "Show one row per app instead of one per window — classic ⌘Tab."),
               accessory: applicationsOnlySwitch, searchItemID: SearchID.applicationsOnly)
        addRow(to: contents, title: String(localized: "Peek windows with ↓"),
               subtitle: String(localized: "In applications-only mode, press ↓ or \\ on an app with several windows to show its windows in a strip below the switcher and pick one."),
               accessory: windowDrillSwitch, searchItemID: SearchID.windowDrill)
        addRow(to: contents, title: String(localized: "Show unread badges"),
               subtitle: String(localized: "Show each app's Dock badge count (e.g. Mail's unread mail) on its row."),
               accessory: badgesSwitch, searchItemID: SearchID.showBadges)
        configurePopup(spaceScopePopup, titles: spaceScopes.map(\.displayName), action: #selector(spaceScopeChanged))
        addRow(to: contents, title: String(localized: "Show windows from"),
               subtitle: String(localized: "All Spaces shows everything; Current Space only the Space you're viewing; Visible Spaces what's on screen across all your displays."),
               accessory: spaceScopePopup, searchItemID: SearchID.spaceScope)
        addRow(to: contents, title: String(localized: "Switch Spaces without animation"),
               subtitle: String(localized: "Picking an app on another Space or in full screen jumps there instantly, with no slide animation. Applies to keyboard switching too."),
               accessory: instantSpaceRowSwitch, searchItemID: SearchID.instantSpace)
        configurePopup(sortOrderPopup, titles: sortOrders.map(\.displayName), action: #selector(sortOrderChanged))
        addRow(to: contents, title: String(localized: "Sort order"),
               subtitle: String(localized: "Most recent keeps the classic ⌘Tab order; Most recent (windows) interleaves windows from all apps by last focus; the others stay put as you switch."),
               accessory: sortOrderPopup, searchItemID: SearchID.sortOrder)
        configureSwitch(recentlyClosedSwitch, action: #selector(toggleRecentlyClosed(_:)))
        addRow(to: contents, title: String(localized: "Show recently closed apps"),
               subtitle: String(localized: "Lists apps and windows you just closed so you can reopen them."),
               accessory: recentlyClosedSwitch, searchItemID: SearchID.showRecentlyClosed)
        let recentlyClosedLimitTitle = String(localized: "Recently closed to show")
        configureIntegerField(recentlyClosedLimitField,
                              action: #selector(recentlyClosedLimitCommitted(_:)),
                              accessibilityLabel: recentlyClosedLimitTitle)
        addRow(to: contents, title: recentlyClosedLimitTitle,
               subtitle: String(localized: "How many recently closed items to list."),
               accessory: recentlyClosedLimitField, searchItemID: SearchID.recentlyClosedLimit)
    }

    /// Native tabs — windows that use macOS system tabs (Finder, Terminal,
    /// TextEdit, …). The Peek tabs key drills native and browser tabs alike, so
    /// it heads the pane.
    private func buildNativeTabsSection() {
        let tabs = addSection(title: String(localized: "Native tabs"), anchor: SettingsAnchor.nativeTabs)
        configureSwitch(tabDrillSwitch, action: #selector(toggleTabDrill(_:)))
        tabDrillRow = addRow(to: tabs, title: String(localized: "Peek tabs"),
                             subtitle: Self.tabDrillSubtitle(),
                             accessory: tabDrillSwitch, searchItemID: SearchID.tabDrill)
        addRow(to: tabs, title: String(localized: "Show tabs as separate entries"),
               subtitle: String(localized: "List each tab of a native-tab window (Finder, Terminal, TextEdit, …) as its own row instead of one collapsed window. Off keeps one row per window — peek its tabs instead."),
               accessory: expandTabsSwitch, searchItemID: SearchID.expandTabs)
    }

    /// Browser tabs — expansion, per-window cap, icon badge, recency, previews
    /// and search. All of it rides on the Apple Events consent granted under
    /// Privacy › Permissions.
    private func buildBrowserTabsSection() {
        let tabs = addSection(title: String(localized: "Browser tabs"), anchor: SettingsAnchor.browserTabs)
        configureSwitch(expandBrowserTabsSwitch, action: #selector(toggleExpandBrowserTabs(_:)))
        addRow(to: tabs, title: String(localized: "Show browser tabs as separate entries"),
               subtitle: String(localized: "List each tab of a browser window (Safari, Chrome, Arc, Brave, Edge, …) as its own row alongside the other windows, instead of one collapsed window. Needs Apple Events access, granted under Privacy › Permissions; off keeps one row per window — peek its tabs instead."),
               accessory: expandBrowserTabsSwitch, searchItemID: SearchID.expandBrowserTabs)
        let browserTabLimitTitle = String(localized: "Browser tabs to show")
        configureIntegerField(browserTabLimitField,
                              action: #selector(browserTabLimitCommitted(_:)),
                              accessibilityLabel: browserTabLimitTitle)
        addRow(to: tabs, title: browserTabLimitTitle,
               subtitle: String(localized: "At most this many tab entries per browser window (2–16), keeping the active tab visible. Set to 0 to show every tab."),
               accessory: browserTabLimitField, searchItemID: SearchID.browserTabLimit)
        addRow(to: tabs, title: String(localized: "Show browser icon on tab entries"),
               subtitle: String(localized: "Badge each tab entry's favicon with the source browser's app icon, so you can tell which browser a tab belongs to when the same site is open in more than one."),
               accessory: browserIconOnTabsSwitch, searchItemID: SearchID.browserIconOnTabs)
        addRow(to: tabs, title: String(localized: "Track browser tabs in recency"),
               subtitle: String(localized: "With “Show browser tabs as separate entries” and the “Most recent (windows)” sort order on, ⌘Tab returns to the tab you last used, not just the last window. Needs always-on monitoring of your browsers, so it costs a little energy."),
               accessory: browserTabMRUSwitch, searchItemID: SearchID.browserTabMRU)
        addRow(to: tabs, title: String(localized: "Browser tab previews"),
               subtitle: String(localized: "Capture the active browser tab for the Previews layout. Background tabs use an earlier cached image or their favicon."),
               accessory: browserTabPreviewsSwitch, searchItemID: SearchID.browserTabPreviews)
        configureSwitch(searchTabsSwitch, action: #selector(toggleSearchExpandsTabs(_:)))
        searchTabsRow = addRow(to: tabs, title: String(localized: "Search browser tabs"),
               subtitle: String(localized: "Searching matches any browser tab by its title, not just each window's active tab. Matching tabs appear as temporary rows while the search field is active and disappear when you leave search. Not needed if “Show browser tabs as separate entries” already lists every tab."),
               accessory: searchTabsSwitch, searchItemID: SearchID.searchExpandsBrowserTabs)
    }

    /// Letter jump — typing a letter to hop straight to a row.
    private func buildLetterJumpSection() {
        let jump = addSection(title: String(localized: "Letter jump"), anchor: SettingsAnchor.letterJump)
        configureSwitch(letterHintsSwitch, action: #selector(toggleLetterHints(_:)))
        letterHintsRow = addRow(to: jump, title: String(localized: "Letter hints"),
               subtitle: Self.letterHintsSubtitle(),
               accessory: letterHintsSwitch, searchItemID: SearchID.letterHints)

        let mappingsButton = NSButton(
            title: String(localized: "Manage…"),
            target: self,
            action: #selector(manageQuickJumpMappings)
        )
        mappingsButton.bezelStyle = .rounded
        mappingsButton.controlSize = .small
        quickJumpMappingsRow = addRow(
            to: jump,
            title: String(localized: "Custom app mappings"),
            subtitle: Self.quickJumpMappingsSubtitle(Preferences.shared.quickJumpMappings.count),
            accessory: mappingsButton,
            searchItemID: SearchID.quickJumpMappings
        )

        let letterTimeoutTitle = String(localized: "Letter chain timeout")
        let letterTimeoutStack = makeValueSlider(letterTimeoutSlider, field: letterTimeoutValueField,
                                                 range: Preferences.letterChainTimeoutRange, unit: "ms",
                                                 label: letterTimeoutTitle,
                                                 sliderAction: #selector(letterTimeoutChanged(_:)),
                                                 fieldAction: #selector(letterTimeoutValueCommitted(_:)))
        addRow(to: jump, title: letterTimeoutTitle,
               subtitle: String(localized: "How long a typed letter sequence stays active. When it expires, the highlight clears and the list returns to its original order."),
               accessory: letterTimeoutStack, searchItemID: SearchID.letterChainTimeout)
    }

    /// Search — type-to-filter behavior. “Search browser tabs” lives with the
    /// other browser-tab rows under Tabs.
    private func buildSearchSection() {
        let search = addSection(title: String(localized: "Search"), anchor: SettingsAnchor.search)
        configureSwitch(fuzzySwitch, action: #selector(toggleFuzzy(_:)))
        fuzzyRow = addRow(to: search, title: String(localized: "Type-to-filter search"),
               subtitle: Self.fuzzySubtitle(),
               accessory: fuzzySwitch, searchItemID: SearchID.fuzzy)
        addRow(to: search, title: String(localized: "Rank search"),
               subtitle: String(localized: "Order results by how well they match instead of by recent use, so the closest match is selected first."),
               accessory: rankResultsSwitch, searchItemID: SearchID.rankResults)
        addRow(to: search, title: String(localized: "Launch apps from search"),
               subtitle: String(localized: "Also show matching apps that aren't running yet."),
               accessory: launcherSwitch, searchItemID: SearchID.launcher)
        configurePopup(searchModePopup, titles: searchDismissModes.map(\.displayName), action: #selector(searchModeChanged))
        addRow(to: search, title: String(localized: "When searching"),
               subtitle: String(localized: "Hold ⌘: release to pick. Stay open: pick with Return or the mouse."),
               accessory: searchModePopup, searchItemID: SearchID.searchMode)
    }

    /// Keyboard — key-driven ways to move and commit the selection.
    private func buildKeyboardSection() {
        let keyboard = addSection(title: String(localized: "Keyboard"), anchor: SettingsAnchor.keyboard)
        configureSwitch(stayOpenSwitch, action: #selector(toggleStayOpen(_:)))
        addRow(to: keyboard, title: String(localized: "Stay open after releasing the modifier"),
               subtitle: String(localized: "Keep the switcher on screen when you let go of the trigger — pick with Return, a quick-jump letter, or the mouse; Esc dismisses. A quick tap still switches instantly."),
               accessory: stayOpenSwitch, searchItemID: SearchID.stayOpen)
        stayOpenQuickTapRow = addRow(to: keyboard, title: String(localized: "Also stay open after a quick tap"),
               subtitle: String(localized: "Keep the switcher on screen even when the shortcut is pressed and released in one quick tap — for shortcuts mapped to mouse buttons or gestures. Requires \u{201C}Stay open after releasing the modifier\u{201D}."),
               accessory: stayOpenQuickTapSwitch, searchItemID: SearchID.stayOpenQuickTap)
        addRow(to: keyboard, title: String(localized: "Tap Shift to step backwards"),
               subtitle: String(localized: "While the switcher is open, a tap of the Shift key steps the selection backwards and holding Shift keeps stepping back until you let go — just like a held Tab. Turn this off to step back only with Shift held as you press the switch key (⌘⇧Tab)."),
               accessory: shiftTapBackSwitch, searchItemID: SearchID.shiftTapBack)
        addRow(to: keyboard, title: String(localized: "Use window-switch shortcut to step backwards"),
               subtitle: String(localized: "While the app switcher is open, press your window-switch shortcut (⌘` by default) to move backwards through apps. Opening the switcher with that shortcut still cycles windows."),
               accessory: backtickReverseSwitch, searchItemID: SearchID.backtickReverse)
        addRow(to: keyboard, title: String(localized: "Vim keys (h j k l)"),
               subtitle: String(localized: "Use h / j / k / l like the arrow keys while the switcher is open. h overrides the Hide binding and j / k / l override letter-jump; search mode still types those letters."),
               accessory: vimNavSwitch, searchItemID: SearchID.vimNavigation)

    }

    /// Mouse — pointer-driven selection, dismissal and scrolling, then the
    /// hover action buttons in their own section.
    private func buildMouseSection() {
        let mouse = addSection(title: String(localized: "Mouse"), anchor: SettingsAnchor.mouse)
        configureSwitch(scrollSwitch, action: #selector(toggleScroll(_:)))
        addRow(to: mouse, title: String(localized: "Switch with mouse scroll"),
               subtitle: String(localized: "Scroll up/down on a mouse wheel to move the selection while the switcher is open. Trackpads use the three-finger swipe instead."),
               accessory: scrollSwitch, searchItemID: SearchID.scroll)
        addRow(to: mouse, title: String(localized: "Reverse scroll direction"),
               subtitle: String(localized: "Scroll up to move forward instead of down."),
               accessory: scrollReverseSwitch, searchItemID: SearchID.scrollReverse)
        addRow(to: mouse, title: String(localized: "Click outside to dismiss"),
               subtitle: String(localized: "Click anywhere outside the switcher to close it, leaving the current window focused."),
               accessory: clickDismissSwitch, searchItemID: SearchID.clickDismiss)
        addRow(to: mouse, title: String(localized: "Select window on hover"),
               subtitle: String(localized: "Move the selection to the row your pointer is over. Off keeps the keyboard selection put so the mouse can't change it by accident."),
               accessory: hoverSelectSwitch, searchItemID: SearchID.selectOnHover)
        addRow(to: mouse, title: String(localized: "Select window on click"),
               subtitle: String(localized: "Click a row to switch to that window. Off ignores clicks inside the switcher so the mouse can't pick a window — the tab strip and hover actions still work."),
               accessory: clickSelectSwitch, searchItemID: SearchID.selectOnClick)

        // Hover actions — buttons revealed on a row under the pointer.
        let hover = addSection(title: String(localized: "Hover actions"), anchor: SettingsAnchor.hoverActions)
        configureSwitch(hoverSwitch, action: #selector(toggleHover(_:)))
        addRow(to: hover, title: String(localized: "Action buttons on hover"),
               subtitle: String(localized: "Reveal quick buttons on the row your pointer is over."),
               accessory: hoverSwitch, searchItemID: SearchID.hoverActions)
        addRow(to: hover, title: String(localized: "Close window"), accessory: hoverCloseSwitch)
        addRow(to: hover, title: String(localized: "Minimize window"), accessory: hoverMinimizeSwitch)
        addRow(to: hover, title: String(localized: "Zoom window"), accessory: hoverMaximizeSwitch)
        addRow(to: hover, title: String(localized: "Hide app"), accessory: hoverHideSwitch)
        addRow(to: hover, title: String(localized: "Quit app"), accessory: hoverQuitSwitch)
        addRow(to: hover, title: String(localized: "Force quit app"),
               subtitle: String(localized: "Sends SIGKILL — for hung apps that ignore Quit. ⌘+⌥+Q always works regardless."),
               accessory: hoverForceQuitSwitch)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // Every control below belongs to exactly one pane, and only that pane's
        // controls were ever added to a view. Sync and subscribe per pane so a
        // preference change wakes one handler, not three.
        switch pane {
        case .switcher: syncSwitcherPane()
        case .controls: syncControlsPane()
        case .tabs: syncTabsPane()
        }
    }

    /// Contents and Timing.
    private func syncSwitcherPane() {
        let prefs = Preferences.shared
        applyDelay(prefs.revealDelayMs)
        applyTitleRefresh(prefs.titleRefreshIntervalMs)
        minimizedSwitch.state = prefs.showMinimizedWindows ? .on : .off
        hiddenSwitch.state = prefs.showHiddenApps ? .on : .off
        sinkHiddenSwitch.sync()
        sinkMinimizedSwitch.sync()
        syncSinkHiddenRow()
        syncSinkMinimizedRow()
        windowlessSwitch.sync()
        applicationsOnlySwitch.sync()
        windowDrillSwitch.sync()
        badgesSwitch.sync()
        if let index = spaceScopes.firstIndex(of: prefs.spaceScope) { spaceScopePopup.selectItem(at: index) }
        instantSpaceRowSwitch.sync()
        selectSortOrder(prefs.sortOrder)
        recentlyClosedSwitch.state = prefs.showRecentlyClosed ? .on : .off
        applyRecentlyClosedLimit(prefs.recentlyClosedLimit)
        recentlyClosedLimitField.isEnabled = prefs.showRecentlyClosed

        // Each sink row's prerequisite can also flip from outside this pane (a
        // settings import or the config.json watcher), which would leave it
        // enabled with nothing left to sink.
        prefs.$showHiddenApps
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.hiddenSwitch.state = $0 ? .on : .off
                self?.syncSinkHiddenRow()
            }
            .store(in: &cancellables)
        prefs.$showMinimizedWindows
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.minimizedSwitch.state = $0 ? .on : .off
                self?.syncSinkMinimizedRow()
            }
            .store(in: &cancellables)
        // Keep the sliders and fields in sync if the values change underneath
        // us (e.g. a settings import calls reloadFromDefaults while open).
        prefs.$revealDelayMs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.applyDelay($0) }
            .store(in: &cancellables)
        prefs.$titleRefreshIntervalMs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.applyTitleRefresh($0) }
            .store(in: &cancellables)
        prefs.$recentlyClosedLimit
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.applyRecentlyClosedLimit($0) }
            .store(in: &cancellables)
    }

    /// Keyboard, Letter jump, Search, Mouse and Hover actions.
    private func syncControlsPane() {
        let prefs = Preferences.shared
        stayOpenSwitch.state = prefs.stayOpenOnRelease ? .on : .off
        stayOpenQuickTapSwitch.sync()
        syncStayOpenQuickTapRow()
        shiftTapBackSwitch.sync()
        backtickReverseSwitch.sync()
        vimNavSwitch.sync()

        letterHintsSwitch.state = prefs.letterHintsEnabled ? .on : .off
        letterHintsRow?.update(subtitle: Self.letterHintsSubtitle())
        applyLetterTimeout(prefs.letterChainTimeoutMs)
        letterTimeoutSlider.isEnabled = prefs.letterHintsEnabled
        letterTimeoutValueField.isEnabled = prefs.letterHintsEnabled

        fuzzySwitch.state = prefs.fuzzySearchEnabled ? .on : .off
        fuzzyRow?.update(subtitle: Self.fuzzySubtitle())
        rankResultsSwitch.sync()
        launcherSwitch.sync()
        selectSearchMode(prefs.searchDismissMode)
        syncSearchOptionRows()

        scrollSwitch.state = prefs.scrollToSwitch ? .on : .off
        scrollReverseSwitch.sync()
        scrollReverseSwitch.isEnabled = prefs.scrollToSwitch
        clickDismissSwitch.sync()
        hoverSelectSwitch.sync()
        clickSelectSwitch.sync()
        hoverSwitch.state = prefs.hoverActionsEnabled ? .on : .off
        hoverCloseSwitch.sync()
        hoverMinimizeSwitch.sync()
        hoverMaximizeSwitch.sync()
        hoverHideSwitch.sync()
        hoverQuitSwitch.sync()
        hoverForceQuitSwitch.sync()
        setHoverSubOptionsEnabled(prefs.hoverActionsEnabled)

        prefs.$searchDismissMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.selectSearchMode($0) }
            .store(in: &cancellables)
        prefs.$fuzzySearchEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.fuzzySwitch.state = $0 ? .on : .off
                self?.syncSearchOptionRows()
            }
            .store(in: &cancellables)
        prefs.$letterChainTimeoutMs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.applyLetterTimeout($0) }
            .store(in: &cancellables)
        prefs.$quickJumpMappings
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mappings in
                self?.quickJumpMappingsRow?.update(
                    subtitle: Self.quickJumpMappingsSubtitle(mappings.count)
                )
            }
            .store(in: &cancellables)
    }

    /// Native tabs and Browser tabs.
    private func syncTabsPane() {
        let prefs = Preferences.shared
        tabDrillSwitch.state = prefs.tabDrillEnabled ? .on : .off
        tabDrillRow?.update(subtitle: Self.tabDrillSubtitle())
        expandTabsSwitch.sync()
        expandBrowserTabsSwitch.state = prefs.expandBrowserTabsAsWindows ? .on : .off
        applyBrowserTabLimit(prefs.browserTabRowLimit)
        browserIconOnTabsSwitch.sync()
        browserTabMRUSwitch.sync()
        browserTabPreviewsSwitch.sync()
        searchTabsSwitch.state = prefs.searchExpandsBrowserTabs ? .on : .off
        syncBrowserTabRows()

        prefs.$expandBrowserTabsAsWindows
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.expandBrowserTabsSwitch.state = $0 ? .on : .off
                self?.syncBrowserTabRows()
            }
            .store(in: &cancellables)
        // "Search browser tabs" is gated on type-to-filter instead, and that
        // switch lives a pane away under Controls — so watch it from here too.
        prefs.$fuzzySearchEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncBrowserTabRows() }
            .store(in: &cancellables)
        prefs.$browserTabRowLimit
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.applyBrowserTabLimit($0) }
            .store(in: &cancellables)
        prefs.$browserTabPreviews
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.browserTabPreviewsSwitch.sync() }
            .store(in: &cancellables)
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        cancellables.removeAll()
    }

    @objc private func delayChanged(_ sender: NSSlider) {
        let ms = Preferences.clampDelay(sender.integerValue)
        Preferences.shared.revealDelayMs = ms
        applyDelay(ms)
    }

    @objc private func delayValueCommitted(_ sender: NSTextField) {
        guard let value = committedInteger(from: sender) else {
            applyDelay(Preferences.shared.revealDelayMs)
            return
        }
        let ms = Preferences.clampDelay(value)
        Preferences.shared.revealDelayMs = ms
        applyDelay(ms)
    }

    private func applyDelay(_ ms: Int) {
        if Int(delaySlider.intValue) != ms { delaySlider.integerValue = ms }
        let value = String(ms)
        if delayValueField.stringValue != value { delayValueField.stringValue = value }
    }

    @objc private func titleRefreshChanged(_ sender: NSSlider) {
        let ms = Preferences.clampTitleRefreshInterval(sender.integerValue)
        Preferences.shared.titleRefreshIntervalMs = ms
        applyTitleRefresh(ms)
    }

    @objc private func titleRefreshValueCommitted(_ sender: NSTextField) {
        guard let value = committedInteger(from: sender) else {
            applyTitleRefresh(Preferences.shared.titleRefreshIntervalMs)
            return
        }
        let ms = Preferences.clampTitleRefreshInterval(value)
        Preferences.shared.titleRefreshIntervalMs = ms
        applyTitleRefresh(ms)
    }

    private func applyTitleRefresh(_ ms: Int) {
        if Int(titleRefreshSlider.intValue) != ms { titleRefreshSlider.integerValue = ms }
        let value = String(ms)
        if titleRefreshValueField.stringValue != value { titleRefreshValueField.stringValue = value }
    }

    /// Names the bound chord so the copy survives a rebind. Every profile has its
    /// own binding but this row is global, so it shows the ⌘Tab one.
    /// The Open search key is rebindable, so name the live binding rather than
    /// the `⌘/` default. Same per-profile caveat as `tabDrillSubtitle()`.
    private static func searchChord() -> String {
        BetterShortcuts.getShortcut(for: .panelSearch(for: SwitchTarget.switchApps.storageKey))?.description
            ?? String(localized: "the Open search key")
    }

    private static func fuzzySubtitle() -> String {
        String(localized: "Press \(searchChord()) in the switcher to filter by app or window name.")
    }

    private static func letterHintsSubtitle() -> String {
        let chord = searchChord()
        return String(localized: "Show a letter on each window and jump to it by typing that letter. Turn it off to start typing and filter the list instead, without pressing \(chord) — bound action keys like ⌘W or ⌘Q still act on the highlighted window; press \(chord) first to type those letters.")
    }

    private static func quickJumpMappingsSubtitle(_ count: Int) -> String {
        if count == 0 {
            return String(localized: "Assign stable in-switcher letters to apps. This is separate from global Direct Activation shortcuts.")
        }
        return String(localized: "Mappings configured: \(count). A mapped letter wins over a same-key panel action while that app is visible.")
    }

    private static func tabDrillSubtitle() -> String {
        let chord = BetterShortcuts.getShortcut(for: .panelTabDrill(for: SwitchTarget.switchApps.storageKey))?.description
            ?? String(localized: "the Peek tabs key")
        return String(localized: "Press \(chord) to pick a tab from a strip below the switcher. Native tabs use Accessibility; browsers use Apple Events.")
    }

    @objc private func toggleTabDrill(_ sender: NSSwitch) {
        let on = (sender.state == .on)
        Preferences.shared.tabDrillEnabled = on
        // Opting in while Settings is foreground is the right moment to ask for
        // Apple Events consent — TCC needs that UI context to surface the prompt.
        if on { BrowserTabs.requestPermissionForRunningBrowsers() }
    }

    @objc private func toggleExpandBrowserTabs(_ sender: NSSwitch) {
        let on = (sender.state == .on)
        Preferences.shared.expandBrowserTabsAsWindows = on
        syncBrowserTabRows()
        // Listing browser tabs needs Apple Events consent; opting in while
        // Settings is foreground is the moment TCC can surface the prompt.
        if on { BrowserTabs.requestPermissionForRunningBrowsers() }
    }

    @objc private func browserTabLimitCommitted(_ sender: NSTextField) {
        guard let value = committedInteger(from: sender) else {
            applyBrowserTabLimit(Preferences.shared.browserTabRowLimit)
            return
        }
        let limit = Preferences.clampBrowserTabRowLimit(value)
        Preferences.shared.browserTabRowLimit = limit
        applyBrowserTabLimit(limit)
    }

    private func applyBrowserTabLimit(_ value: Int) {
        let text = String(value)
        if browserTabLimitField.stringValue != text {
            browserTabLimitField.stringValue = text
        }
    }

    @objc private func toggleLetterHints(_ sender: NSSwitch) {
        let on = (sender.state == .on)
        Preferences.shared.letterHintsEnabled = on
        // The chain timeout only matters while letter-jump is on (typing a letter
        // is a no-op otherwise), so gray it out to match.
        letterTimeoutSlider.isEnabled = on
        letterTimeoutValueField.isEnabled = on
    }

    @objc private func manageQuickJumpMappings() {
        guard let window = view.window, quickJumpMappingsSheet == nil else { return }
        let controller = QuickJumpMappingsSheetWindowController()
        controller.onDidDismiss = { [weak self] in self?.quickJumpMappingsSheet = nil }
        quickJumpMappingsSheet = controller
        trackForRelease(controller)
        controller.present(asSheetFor: window)
    }

    @objc private func letterTimeoutChanged(_ sender: NSSlider) {
        Preferences.shared.letterChainTimeoutMs = sender.integerValue
        applyLetterTimeout(sender.integerValue)
    }

    @objc private func letterTimeoutValueCommitted(_ sender: NSTextField) {
        guard let value = committedInteger(from: sender) else {
            applyLetterTimeout(Preferences.shared.letterChainTimeoutMs)
            return
        }
        let ms = Preferences.clampLetterChainTimeout(value)
        Preferences.shared.letterChainTimeoutMs = ms
        applyLetterTimeout(ms)
    }

    private func applyLetterTimeout(_ ms: Int) {
        if Int(letterTimeoutSlider.intValue) != ms { letterTimeoutSlider.integerValue = ms }
        let value = String(ms)
        if letterTimeoutValueField.stringValue != value { letterTimeoutValueField.stringValue = value }
    }

    @objc private func toggleFuzzy(_ sender: NSSwitch) {
        Preferences.shared.fuzzySearchEnabled = (sender.state == .on)
        syncSearchOptionRows()
    }

    /// The three rows below "Type-to-filter search" only do anything once a
    /// search is running, and `enterSearch()` refuses to start one while
    /// type-to-filter is off — so disable them rather than leave live-looking
    /// dead controls. A fourth, "Search browser tabs", hangs off the same
    /// prerequisite from the Tabs pane; `syncBrowserTabRows` handles that one.
    private func syncSearchOptionRows() {
        let on = Preferences.shared.fuzzySearchEnabled
        rankResultsSwitch.isEnabled = on
        launcherSwitch.isEnabled = on
        searchModePopup.isEnabled = on
    }

    @objc private func toggleSearchExpandsTabs(_ sender: NSSwitch) {
        let on = (sender.state == .on)
        Preferences.shared.searchExpandsBrowserTabs = on
        // Searching tabs needs Apple Events consent; opting in while Settings is
        // foreground is the moment TCC can surface the prompt.
        if on { BrowserTabs.requestPermissionForRunningBrowsers() }
    }

    @objc private func toggleStayOpen(_ sender: NSSwitch) {
        Preferences.shared.stayOpenOnRelease = (sender.state == .on)
        syncStayOpenQuickTapRow()
    }

    /// Quick-tap stay-open only takes effect while stay-open itself is on
    /// (#91).
    private func syncStayOpenQuickTapRow() {
        lockRow(stayOpenQuickTapRow, control: stayOpenQuickTapSwitch,
                unlocked: Preferences.shared.stayOpenOnRelease,
                hint: String(localized: "Turn on \u{201C}Stay open after releasing the modifier\u{201D} above first."))
    }

    @objc private func toggleScroll(_ sender: NSSwitch) {
        let on = (sender.state == .on)
        Preferences.shared.scrollToSwitch = on
        scrollReverseSwitch.isEnabled = on
    }

    @objc private func toggleHover(_ sender: NSSwitch) {
        let on = (sender.state == .on)
        Preferences.shared.hoverActionsEnabled = on
        setHoverSubOptionsEnabled(on)
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
        if let index = searchDismissModes.firstIndex(of: mode) { searchModePopup.selectItem(at: index) }
    }

    // MARK: - Contents

    @objc private func toggleMinimized(_ sender: NSSwitch) {
        Preferences.shared.showMinimizedWindows = (sender.state == .on)
        syncSinkMinimizedRow()
    }

    @objc private func toggleHidden(_ sender: NSSwitch) {
        Preferences.shared.showHiddenApps = (sender.state == .on)
        syncSinkHiddenRow()
    }

    /// Moving hidden apps to the bottom only matters while they're shown at all.
    private func syncSinkHiddenRow() {
        lockRow(sinkHiddenRow, control: sinkHiddenSwitch,
                unlocked: Preferences.shared.showHiddenApps,
                hint: String(localized: "Turn on \u{201C}Show hidden apps\u{201D} above first."))
    }

    /// Both rows below the browser-tab switch are dead without it: the cap has
    /// no rows to cap, and tab recency only reorders rows the expansion
    /// produced — its browser observers would burn energy for no visible
    /// effect. The prerequisite can also flip from outside this pane, so this
    /// runs from a sink too.
    private func syncBrowserTabRows() {
        // These two sit directly under their prerequisite, so the dependency
        // reads off the layout and a plain gray switch explains itself.
        let expanded = Preferences.shared.expandBrowserTabsAsWindows
        browserTabLimitField.isEnabled = expanded
        browserTabMRUSwitch.isEnabled = expanded

        // "Search browser tabs" hangs off type-to-filter instead, which lives a
        // pane away under Controls — so name it in the tooltip.
        lockRow(searchTabsRow, control: searchTabsSwitch,
                unlocked: Preferences.shared.fuzzySearchEnabled,
                hint: String(localized: "Turn on \u{201C}Type-to-filter search\u{201D} under Controls first."))
    }

    /// Same gate for the minimized sink, keyed on its own prerequisite.
    private func syncSinkMinimizedRow() {
        lockRow(sinkMinimizedRow, control: sinkMinimizedSwitch,
                unlocked: Preferences.shared.showMinimizedWindows,
                hint: String(localized: "Turn on \u{201C}Show minimized windows\u{201D} above first."))
    }

    /// Locks a row whose control is dead until some other preference is on. A
    /// grayed switch alone doesn't say *why*, so dim the whole row and name the
    /// missing prerequisite in a tooltip.
    private func lockRow(_ row: SettingsRowView?, control: NSControl, unlocked: Bool, hint: String) {
        control.isEnabled = unlocked
        row?.alphaValue = unlocked ? 1 : 0.45
        row?.toolTip = unlocked ? nil : hint
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
        if let index = sortOrders.firstIndex(of: order) { sortOrderPopup.selectItem(at: index) }
    }

    @objc private func toggleRecentlyClosed(_ sender: NSSwitch) {
        let on = (sender.state == .on)
        Preferences.shared.showRecentlyClosed = on
        recentlyClosedLimitField.isEnabled = on
    }

    @objc private func recentlyClosedLimitCommitted(_ sender: NSTextField) {
        guard let value = committedInteger(from: sender) else {
            applyRecentlyClosedLimit(Preferences.shared.recentlyClosedLimit)
            return
        }
        let limit = Preferences.clampRecentlyClosedLimit(value)
        Preferences.shared.recentlyClosedLimit = limit
        applyRecentlyClosedLimit(limit)
    }

    private func applyRecentlyClosedLimit(_ value: Int) {
        let text = String(value)
        if recentlyClosedLimitField.stringValue != text {
            recentlyClosedLimitField.stringValue = text
        }
    }
}
