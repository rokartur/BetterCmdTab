import AppKit
import BetterShortcuts
import Testing
@testable import BetterCmdTab

@Suite("Preferences enums")
struct PreferencesEnumTests {

    @Test("PanelSize scale ordering: small < standard < large")
    func panelSizeOrdering() {
        // Scale remap (2026-05-28): small=1.0, standard=1.2, large=1.5.
        #expect(PanelSize.small.scale < PanelSize.standard.scale)
        #expect(PanelSize.standard.scale == 1.2)
        #expect(PanelSize.standard.scale < PanelSize.large.scale)
    }

    @MainActor
    @Test("clampDelay keeps values inside the allowed range")
    func clampDelay() {
        #expect(Preferences.clampDelay(10) == Preferences.revealDelayRange.lowerBound)
        #expect(Preferences.clampDelay(9999) == Preferences.revealDelayRange.upperBound)
        #expect(Preferences.clampDelay(150) == 150)
    }

    @MainActor
    @Test("clampGridColumns / clampRecentlyClosedLimit reject out-of-range imports")
    func clampGridAndRecentlyClosed() {
        // A hand-edited / corrupted `.cmdtab` import must not land a negative or
        // absurd value in these live prefs (other consumers defang it today, but
        // the contract should hold at the source).
        #expect(Preferences.clampGridColumns(-5) == Preferences.gridMaxColumnsRange.lowerBound)
        #expect(Preferences.clampGridColumns(9999) == Preferences.gridMaxColumnsRange.upperBound)
        #expect(Preferences.clampGridColumns(0) == 0)   // 0 = automatic, valid
        #expect(Preferences.clampGridColumns(4) == 4)

        #expect(Preferences.clampRecentlyClosedLimit(-1) == Preferences.recentlyClosedLimitRange.lowerBound)
        #expect(Preferences.clampRecentlyClosedLimit(9999) == Preferences.recentlyClosedLimitRange.upperBound)
        #expect(Preferences.clampRecentlyClosedLimit(5) == 5)
    }

    @Test("SearchDismissMode round-trips through its raw value")
    func searchDismissModeRawValues() {
        for mode in SearchDismissMode.allCases {
            #expect(SearchDismissMode(rawValue: mode.rawValue) == mode)
            #expect(!mode.displayName.isEmpty)
        }
        // Unknown raw value yields nil so callers fall back to the default.
        #expect(SearchDismissMode(rawValue: "nonsense") == nil)
    }

    @Test("SwitcherDisplayMode raw values round-trip and unknown falls back")
    func switcherDisplayModeRoundTrip() {
        for mode in SwitcherDisplayMode.allCases {
            #expect(SwitcherDisplayMode(rawValue: mode.rawValue) == mode)
        }
        #expect(SwitcherDisplayMode(rawValue: "garbage") == nil)
        // Stable raw values (persisted to UserDefaults / exported settings).
        #expect(SwitcherDisplayMode.mouseCursor.rawValue == "mouseCursor")
        #expect(SwitcherDisplayMode.activeWindow.rawValue == "activeWindow")
        #expect(SwitcherDisplayMode.mainDisplay.rawValue == "mainDisplay")
    }

    @Test("PreviewTitleAlignment raw values round-trip and unknown falls back")
    func previewTitleAlignmentRoundTrip() {
        for alignment in PreviewTitleAlignment.allCases {
            #expect(PreviewTitleAlignment(rawValue: alignment.rawValue) == alignment)
            #expect(!alignment.displayName.isEmpty)
        }
        #expect(PreviewTitleAlignment(rawValue: "garbage") == nil)
        // Stable raw values (persisted to UserDefaults / exported settings).
        #expect(PreviewTitleAlignment.leading.rawValue == "leading")
        #expect(PreviewTitleAlignment.center.rawValue == "center")
        #expect(PreviewTitleAlignment.trailing.rawValue == "trailing")
    }

    @MainActor
    @Test("titleGroupOriginX places the preview title at the chosen edge")
    func titleGroupOriginX() {
        let tile: CGFloat = 200
        let group: CGFloat = 80   // 120 pt of slack
        #expect(SwitcherPreviewItemView.titleGroupOriginX(alignment: .leading, groupWidth: group, tileWidth: tile) == 0)
        #expect(SwitcherPreviewItemView.titleGroupOriginX(alignment: .center, groupWidth: group, tileWidth: tile) == 60)
        #expect(SwitcherPreviewItemView.titleGroupOriginX(alignment: .trailing, groupWidth: group, tileWidth: tile) == 120)

        // A group wider than the tile never starts off-screen (slack clamps to 0).
        #expect(SwitcherPreviewItemView.titleGroupOriginX(alignment: .trailing, groupWidth: 260, tileWidth: tile) == 0)
        #expect(SwitcherPreviewItemView.titleGroupOriginX(alignment: .center, groupWidth: 260, tileWidth: tile) == 0)
    }

    @Test("HideWindowsMode / IgnoreShortcutsMode round-trip through raw values")
    func exceptionModeRawValues() {
        for mode in HideWindowsMode.allCases {
            #expect(HideWindowsMode(rawValue: mode.rawValue) == mode)
            #expect(!mode.displayName.isEmpty)
        }
        for mode in IgnoreShortcutsMode.allCases {
            #expect(IgnoreShortcutsMode(rawValue: mode.rawValue) == mode)
            #expect(!mode.displayName.isEmpty)
        }
        #expect(HideWindowsMode(rawValue: "nonsense") == nil)
        #expect(IgnoreShortcutsMode(rawValue: "nonsense") == nil)
    }

    @Test("AppException round-trips through its stored dictionary")
    func appExceptionDictionary() {
        let original = AppException(bundleID: "com.x", hide: .whenNoWindows, ignore: .whenFullscreen)
        #expect(AppException(dictionary: original.dictionary) == original)

        // Missing modes fall back to the neutral defaults.
        let partial = AppException(dictionary: ["bundleID": "com.y"])
        #expect(partial == AppException(bundleID: "com.y", hide: .dontHide, ignore: .never))

        // No bundle ID → no exception.
        #expect(AppException(dictionary: ["hide": "always"]) == nil)
        #expect(AppException(dictionary: ["bundleID": ""]) == nil)
    }
}

@Suite("BetterShortcuts integration")
struct BetterShortcutsIntegrationTests {

    @MainActor
    @Test("switcher Names default to Command + Tab / Command + backtick")
    func defaultShortcuts() {
        let apps = BetterShortcuts.Name.switchApps.defaultShortcut
        #expect(apps?.carbonKeyCode == 48) // Tab
        #expect(apps?.modifiers.contains(.command) == true)

        let windows = BetterShortcuts.Name.switchWindows.defaultShortcut
        #expect(windows?.carbonKeyCode == 50) // `
        #expect(windows?.modifiers.contains(.command) == true)
    }

    @MainActor
    @Test("allCases lists every shortcut category")
    func allCases() {
        let names = BetterShortcuts.Name.allCases
        // 2 switcher triggers + direct-activation slots + scoped slots +
        // in-panel action keys + window-management actions + global
        // window-visibility actions (hide-all / show-all).
        let expected = 2
            + BetterShortcuts.Name.directActivateSlotCount
            + BetterShortcuts.Name.scopedSwitchSlotCount
            + BetterShortcuts.Name.panelActionKeys.count
            + BetterShortcuts.Name.windowMgmt.count
            + BetterShortcuts.Name.globalWindowActions.count
        #expect(names.count == expected)
        #expect(names.contains(.switchApps))
        #expect(names.contains(.switchWindows))
        #expect(names.contains(.directActivate.first!))
        #expect(names.contains(.scopedSwitch.first!))
        #expect(names.contains(.panelClose))
        #expect(names.contains(.windowTileLeft))
        #expect(names.contains(.hideAllWindows))
        #expect(names.contains(.showAllWindows))
    }
}
