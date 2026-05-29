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

    @Test("SearchDismissMode round-trips through its raw value")
    func searchDismissModeRawValues() {
        for mode in SearchDismissMode.allCases {
            #expect(SearchDismissMode(rawValue: mode.rawValue) == mode)
            #expect(!mode.displayName.isEmpty)
        }
        // Unknown raw value yields nil so callers fall back to the default.
        #expect(SearchDismissMode(rawValue: "nonsense") == nil)
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
    @Test("allCases lists the switcher triggers plus the direct-activation slots")
    func allCases() {
        let names = BetterShortcuts.Name.allCases
        #expect(names.contains(.switchApps))
        #expect(names.contains(.switchWindows))
        #expect(BetterShortcuts.Name.directActivate.count == BetterShortcuts.Name.directActivateSlotCount)
        #expect(names.count == 2 + BetterShortcuts.Name.directActivateSlotCount + BetterShortcuts.Name.scopedSwitchSlotCount)
        #expect(names.contains(.scopedSwitch.first!))
    }
}
