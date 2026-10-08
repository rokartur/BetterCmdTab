import AppKit
import ApplicationServices
import Testing
@testable import BetterCmdTab

@Suite("Handoff suggestion")
struct HandoffTests {
    private let element = AXUIElementCreateApplication(getpid())
    private let finderURL = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")

    private func suggestion() -> HandoffSuggestion {
        DockBadgeReader.handoffSuggestion(title: "Finder", deviceType: "com.apple.macstudio",
                                          dockAppURLs: ["Finder": finderURL], installedAppURLs: [:], element: element)!
    }

    private var runningRow: SwitcherRow {
        SwitcherRow(app: .current, window: nil, windowTitle: "", isMinimized: false)
    }

    private var closedRow: SwitcherRow {
        SwitcherRow(recentlyClosed: RecentEntry(bundleID: "com.apple.TextEdit", appName: "TextEdit", title: "Finder notes",
                                                documentPath: nil, closedAt: .distantPast))
    }

    @Test("the Dock app with the Handoff item's title gives the bundle ID, and the model ID gives the device name")
    func resolvesFromDockApp() {
        let s = suggestion()
        #expect(s.appName == "Finder")
        #expect(s.bundleID == "com.apple.finder")
        #expect(s.deviceName == "Mac Studio")
    }

    @Test("an app missing from the Dock is found among the installed apps by display name")
    func resolvesInstalledApp() {
        let s = DockBadgeReader.handoffSuggestion(title: "Finder", deviceType: "com.apple.iphone",
                                                  dockAppURLs: [:], installedAppURLs: ["Finder": finderURL], element: element)
        #expect(s?.bundleID == "com.apple.finder")
        #expect(s?.deviceName == "iPhone")
    }

    @Test("an unknown app or a missing title gives no suggestion")
    func unresolvable() {
        #expect(DockBadgeReader.handoffSuggestion(title: "No Such App 7f3", deviceType: "com.apple.macstudio",
                                                  dockAppURLs: [:], installedAppURLs: [:], element: element) == nil)
        #expect(DockBadgeReader.handoffSuggestion(title: nil, deviceType: "com.apple.macstudio",
                                                  dockAppURLs: ["Finder": finderURL], installedAppURLs: [:], element: element) == nil)
    }

    @Test("a device model this macOS does not know still gives a suggestion, from another device")
    func unknownDevice() {
        let s = DockBadgeReader.handoffSuggestion(title: "Finder", deviceType: "com.example.nodevice",
                                                  dockAppURLs: ["Finder": finderURL], installedAppURLs: [:], element: element)
        #expect(s?.deviceName == nil)
        #expect(s.map { SwitcherRow(handoff: $0).handoffSubtitle } == "from another device")
        #expect(s.map { SwitcherRow(handoff: $0).handoffAccessibilityLabel } == "Finder from another device")
    }

    @Test("a Handoff row stands for the app, with the device as its title")
    func row() {
        let row = SwitcherRow(handoff: suggestion())
        #expect(row.identity == .handoff("com.apple.finder"))
        #expect(row.appName == "Finder")
        #expect(row.windowTitle == "Mac Studio")
        #expect(row.bundleIdentifier == "com.apple.finder")
        #expect(row.app == nil)
        #expect(row.handoff != nil)
        #expect(row.titleSlot(showAppNames: true) == "from Mac Studio")
        #expect(row.previewTitleSlot(showAppNames: true) == "Finder — from Mac Studio")
        #expect(row.handoffAccessibilityLabel == "Finder from Mac Studio")
    }

    @Test("first puts the Handoff row on top and moves the selection with its row")
    func placeFirst() {
        let rows = [runningRow, runningRow]
        let placed = SwitcherController.placingHandoff(SwitcherRow(handoff: suggestion()), in: rows, index: 1, placement: .first)
        #expect(placed.rows.map { $0.handoff != nil } == [true, false, false])
        #expect(placed.index == 2)
    }

    @Test("last puts the Handoff row after the running rows and keeps the selection")
    func placeLast() {
        let rows = [runningRow, runningRow]
        let placed = SwitcherController.placingHandoff(SwitcherRow(handoff: suggestion()), in: rows, index: 1, placement: .last)
        #expect(placed.rows.map { $0.handoff != nil } == [false, false, true])
        #expect(placed.index == 1)
    }

    @Test("off or no suggestion leaves the rows alone")
    func placeNothing() {
        let rows = [runningRow]
        #expect(SwitcherController.placingHandoff(SwitcherRow(handoff: suggestion()), in: rows, index: 0, placement: .off).rows.count == 1)
        #expect(SwitcherController.placingHandoff(nil, in: rows, index: 0, placement: .first).rows.count == 1)
    }

    @Test("with no other rows there is no Handoff row, so a quick tap opens nothing")
    func placeAlone() {
        let placed = SwitcherController.placingHandoff(SwitcherRow(handoff: suggestion()), in: [], index: 0, placement: .first)
        #expect(placed.rows.isEmpty)
        #expect(placed.index == 0)
    }

    @Test("a Handoff tile gets no letter")
    func handoffHasNoLetter() {
        #expect(RowLabels.labels(for: [SwitcherRow(handoff: suggestion())]) == [""])
    }

    @Test("a row that takes no letter leaves its app's custom letter on the running row")
    func noLetterRowLeavesCustomLetter() {
        let running = RowLabels.Input(appName: "Finder", windowTitle: "", bundleID: "com.apple.finder")
        let handoff = RowLabels.Input(appName: "Finder", windowTitle: "Mac Studio", bundleID: "com.apple.finder", takesLetter: false)
        let mappings: [String: Character] = ["com.apple.finder": "x"]
        #expect(RowLabels.labels(forInputs: [running, handoff], customMappings: mappings) == ["x", ""])
        #expect(RowLabels.labels(forInputs: [handoff, running], customMappings: mappings) == ["", "x"])
    }

    @Test("a selected recently closed row stays selected when a Handoff row appears above it")
    func windowlessSelectionSurvivesInsert() {
        let rows = [SwitcherRow(handoff: suggestion()), runningRow, closedRow]
        #expect(SwitcherController.windowlessSelectionIndex(in: rows, selected: closedRow) == 2)
    }

    @Test("a selected Handoff row is not moved onto a different suggestion")
    func handoffSelectionNeedsSameApp() {
        let other = HandoffSuggestion(appName: "Safari", bundleID: "com.apple.Safari", appURL: finderURL,
                                      deviceName: "iPhone", element: element)
        let rows = [runningRow, SwitcherRow(handoff: other)]
        #expect(SwitcherController.windowlessSelectionIndex(in: rows, selected: SwitcherRow(handoff: suggestion())) == nil)
    }

    @Test("a press that succeeded or timed out counts as opened; a refused one does not")
    func pressOpened() {
        #expect(Activator.handoffPressOpened(.success))
        #expect(Activator.handoffPressOpened(.cannotComplete))
        #expect(!Activator.handoffPressOpened(.invalidUIElement))
    }

    @Test("search keeps a Handoff row whose device matches the query, after the recently closed rows")
    func searchTailMatchesDevice() {
        let handoff = SwitcherRow(handoff: suggestion())
        let tail = SwitcherController.searchTail(closed: [closedRow], handoff: handoff, foldedQuery: "studio",
                                                 preparedQuery: FuzzyMatch.prepareQuery("studio"), rankBest: false)
        #expect(tail.map(\.identity) == [closedRow.identity, handoff.identity])
    }

    @Test("search drops a Handoff row that does not match the query")
    func searchTailDropsMiss() {
        let tail = SwitcherController.searchTail(closed: [], handoff: SwitcherRow(handoff: suggestion()), foldedQuery: "zzz",
                                                 preparedQuery: FuzzyMatch.prepareQuery("zzz"), rankBest: false)
        #expect(tail.isEmpty)
    }

    @Test("ranked search puts an app-name match ahead of a title match")
    func searchTailRanks() {
        let handoff = SwitcherRow(handoff: suggestion())
        let tail = SwitcherController.searchTail(closed: [closedRow], handoff: handoff, foldedQuery: "finder",
                                                 preparedQuery: FuzzyMatch.prepareQuery("finder"), rankBest: true)
        #expect(tail.map(\.identity) == [handoff.identity, closedRow.identity])
    }

    @Test("outside search, last puts the Handoff row after the recently closed rows and first puts it on top")
    func combinedRowsPlacement() {
        let handoff = SwitcherRow(handoff: suggestion())
        let last = SwitcherController.combinedRows(base: [runningRow], recentlyClosed: [closedRow], handoff: handoff, placement: .last)
        #expect(last.map(\.identity) == [runningRow.identity, closedRow.identity, handoff.identity])
        let first = SwitcherController.combinedRows(base: [runningRow], recentlyClosed: [closedRow], handoff: handoff, placement: .first)
        #expect(first.map(\.identity) == [handoff.identity, runningRow.identity, closedRow.identity])
    }

    @Test("an app outside the home folder wins a display-name clash, in either scan order")
    func urlsByNamePrefersAppsOutsideHome() {
        let system = InstalledApp(name: "Safari", bundleID: "com.apple.Safari", url: URL(fileURLWithPath: "/Applications/Safari.app"))
        let user = InstalledApp(name: "Safari", bundleID: "com.example.safari",
                                url: URL(fileURLWithPath: "/Users/test/Applications/Safari.app"))
        #expect(InstalledAppsIndex.urlsByName([system, user], home: "/Users/test")["Safari"] == system.url)
        #expect(InstalledAppsIndex.urlsByName([user, system], home: "/Users/test")["Safari"] == system.url)
    }

    @Test("the divider sits in the gap toward the neighbor: vertical in a row, horizontal in a column, none across a wrap")
    func dividerFrame() {
        let tile = NSSize(width: 100, height: 100)
        let row = [NSRect(origin: .zero, size: tile), NSRect(x: 110, y: 0, width: 50, height: 100)]
        let vertical = SwitcherView.handoffDividerFrame(handoffIndex: 0, frames: row)
        #expect(vertical?.midX == 105)
        #expect(vertical?.width == 1)

        let column = [NSRect(x: 0, y: 40, width: 300, height: 60),
                      NSRect(x: 0, y: 0, width: 300, height: 30)]
        let horizontal = SwitcherView.handoffDividerFrame(handoffIndex: 1, frames: column)
        #expect(horizontal?.midY == 35)
        #expect(horizontal?.height == 1)

        let wrapped = [NSRect(origin: NSPoint(x: 110, y: 110), size: tile), NSRect(origin: .zero, size: tile)]
        #expect(SwitcherView.handoffDividerFrame(handoffIndex: 1, frames: wrapped) == nil)
        #expect(SwitcherView.handoffDividerFrame(handoffIndex: nil, frames: row) == nil)
    }
}
