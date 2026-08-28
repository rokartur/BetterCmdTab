import AppKit
import BetterShortcuts
import Testing
@testable import BetterCmdTab

@Suite("Preferences enums")
struct PreferencesEnumTests {

    @MainActor
    @Test("system commit sounds include the historical Tink default")
    func systemCommitSounds() {
        let names = CommitFeedback.systemSoundNames()
        #expect(names.contains(Preferences.defaultCommitSoundName))
        #expect(names.count > 1)
        #expect(names == names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
    }

    @MainActor
    @Test("custom commit sound is copied and can be replaced")
    func customCommitSoundCopy() throws {
        let sounds = URL(fileURLWithPath: "/System/Library/Sounds", isDirectory: true)
        let candidates = try FileManager.default.contentsOfDirectory(at: sounds, includingPropertiesForKeys: nil)
        let source = try #require(candidates.first { NSSound(contentsOf: $0, byReference: true) != nil })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }

        let installed = try CommitFeedback.copyCustomSound(from: source, to: directory)
        #expect(try Data(contentsOf: installed) == Data(contentsOf: source))
        #expect(try CommitFeedback.copyCustomSound(from: source, to: directory) == installed)
        #expect(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count == 1)
    }

    @Test("storedSpaceScope prefers the enum key, falls back to the legacy bool")
    func storedSpaceScopeMigration() throws {
        let defaults = try #require(UserDefaults(suiteName: "storedSpaceScopeMigrationTests"))
        defer { defaults.removePersistentDomain(forName: "storedSpaceScopeMigrationTests") }

        // Fresh install: neither key → all Spaces.
        #expect(Preferences.storedSpaceScope(defaults) == .allSpaces)

        // Legacy bool only (pre-#57 upgrade / old settings import).
        defaults.set(true, forKey: Preferences.Keys.currentSpaceOnly)
        #expect(Preferences.storedSpaceScope(defaults) == .currentSpace)
        defaults.set(false, forKey: Preferences.Keys.currentSpaceOnly)
        #expect(Preferences.storedSpaceScope(defaults) == .allSpaces)

        // Enum key wins over a contradicting legacy bool.
        defaults.set(true, forKey: Preferences.Keys.currentSpaceOnly)
        defaults.set(SpaceScope.visibleSpaces.rawValue, forKey: Preferences.Keys.spaceScope)
        #expect(Preferences.storedSpaceScope(defaults) == .visibleSpaces)

        // Garbage enum value falls back to the legacy bool.
        defaults.set("bogus", forKey: Preferences.Keys.spaceScope)
        #expect(Preferences.storedSpaceScope(defaults) == .currentSpace)
    }

    /// Covers every graduated preference, so a newly added case is tested the
    /// moment it joins `allCases` — badges shipped without this and lost their
    /// legacy fallback in `reloadFromDefaults` unnoticed.
    @Test("every graduated preference prefers its own key and falls back to the experimental one",
          arguments: Preferences.GraduatedPreference.allCases)
    func graduatedMigration(_ pref: Preferences.GraduatedPreference) throws {
        let suite = "graduatedMigrationTests.\(pref.key)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let optOut = !pref.fallback

        // Fresh install: neither key → the graduation default.
        #expect(Preferences.stored(pref, defaults) == pref.fallback)

        // Pre-graduation key only — an upgrade, or an import/config.json still
        // carrying the experimental name: the choice must survive, including a
        // deliberate opt-out of a preference that now defaults on.
        defaults.set(optOut, forKey: pref.legacyKey)
        #expect(Preferences.stored(pref, defaults) == optOut)

        // The graduated key wins over a contradicting legacy one, both ways round.
        defaults.set(pref.fallback, forKey: pref.key)
        #expect(Preferences.stored(pref, defaults) == pref.fallback)

        defaults.set(pref.fallback, forKey: pref.legacyKey)
        defaults.set(optOut, forKey: pref.key)
        #expect(Preferences.stored(pref, defaults) == optOut)
    }

    @Test("panel scale clamps and migrates every legacy preset")
    func panelScaleMigration() {
        // Floor dropped to 35 in #170: a percentage now buys 1.5x what it used to,
        // so the old 50 % floor no longer reaches the small panel it used to mean.
        #expect(Preferences.clampPanelScalePercent(1) == 35)
        #expect(Preferences.clampPanelScalePercent(125) == 125)
        #expect(Preferences.clampPanelScalePercent(999) == 150)
        // Re-pointed in #170 when 100% became the native Cmd+Tab size: the presets
        // keep their old ratios to each other (5/6, 1, 5/4), not their old numbers.
        #expect(Preferences.legacyPanelScalePercent("small") == 83)
        #expect(Preferences.legacyPanelScalePercent("standard") == 100)
        #expect(Preferences.legacyPanelScalePercent("large") == 125)
        #expect(Preferences.legacyPanelScalePercent("unknown") == nil)
    }

    @Test("pre-#170 percentages keep their ratio to the default when re-based")
    func panelScaleRebase() {
        // The old default has to land exactly on the new one, or an untouched slider
        // would come back reading a number the user never picked. This preserves the
        // ratio to the default, not the absolute size: the old scale was
        // clamp(screenWidth/1440, 1.0, 1.8) x percent/100 against a flat 1.5 x
        // percent/100 now, so the panel only keeps its size at a screen width of
        // 1800 pt — a 14" MacBook grows ~19 % and a 5K shrinks ~30 %, the latter being
        // #170 itself.
        #expect(Preferences.rebasedPanelScalePercent(120) == 100)
        // Ratios to the default survive: 5/4 of the old default is 5/4 of the new.
        #expect(Preferences.rebasedPanelScalePercent(150) == 125)
        #expect(Preferences.rebasedPanelScalePercent(60) == 50)
        // Somebody who wanted the smallest possible panel keeps reaching it: the old
        // floor re-bases to 42, which the new 35 floor leaves untouched.
        #expect(Preferences.rebasedPanelScalePercent(50) == 42)
        // Anything below the old floor still has to land inside the new range.
        #expect(Preferences.panelScalePercentRange.contains(Preferences.rebasedPanelScalePercent(1)))
        #expect(Preferences.panelScalePercentRange.contains(Preferences.rebasedPanelScalePercent(999)))
    }

    @Test("panel appearance raw values round-trip")
    func panelAppearanceRoundTrip() {
        for appearance in PanelAppearance.allCases {
            #expect(PanelAppearance(rawValue: appearance.rawValue) == appearance)
            #expect(!appearance.displayName.isEmpty)
        }
        #expect(PanelAppearance(rawValue: "sepia") == nil)
    }

    @MainActor
    @Test("clampDelay keeps values inside the allowed range")
    func clampDelay() {
        #expect(Preferences.clampDelay(10) == Preferences.revealDelayRange.lowerBound)
        #expect(Preferences.clampDelay(9999) == Preferences.revealDelayRange.upperBound)
        #expect(Preferences.clampDelay(150) == 150)
    }

    @MainActor
    @Test("clampTitleRefreshInterval keeps values inside the allowed range")
    func clampTitleRefreshInterval() {
        #expect(Preferences.clampTitleRefreshInterval(0) == Preferences.titleRefreshIntervalRange.lowerBound)
        #expect(Preferences.clampTitleRefreshInterval(99999) == Preferences.titleRefreshIntervalRange.upperBound)
        #expect(Preferences.clampTitleRefreshInterval(Preferences.defaultTitleRefreshIntervalMs) == Preferences.defaultTitleRefreshIntervalMs)
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
            #expect(!mode.displayName.isEmpty)
        }
        #expect(SwitcherDisplayMode(rawValue: "garbage") == nil)
        // Stable raw values (persisted to UserDefaults / exported settings).
        // `activeWindow` predates the label "Monitor with the active app" and is
        // deliberately NOT renamed — renaming it would reset every stored pref.
        #expect(SwitcherDisplayMode.mouseCursor.rawValue == "mouseCursor")
        #expect(SwitcherDisplayMode.activeWindow.rawValue == "activeWindow")
        #expect(SwitcherDisplayMode.mainDisplay.rawValue == "mainDisplay")
        // A new case must come with its own title, not inherit one. This count is
        // the reminder to add it above.
        #expect(SwitcherDisplayMode.allCases.count == 3)
        #expect(Set(SwitcherDisplayMode.allCases.map(\.displayName)).count == 3)
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

    @Test("TitleTruncationMode raw values round-trip and map to NSLineBreakMode")
    func titleTruncationModeRoundTrip() {
        for mode in TitleTruncationMode.allCases {
            #expect(TitleTruncationMode(rawValue: mode.rawValue) == mode)
            #expect(!mode.displayName.isEmpty)
        }
        #expect(TitleTruncationMode(rawValue: "garbage") == nil)
        // Stable raw values (persisted to UserDefaults / exported settings).
        #expect(TitleTruncationMode.head.rawValue == "head")
        #expect(TitleTruncationMode.middle.rawValue == "middle")
        #expect(TitleTruncationMode.tail.rawValue == "tail")
        // Exact NSLineBreakMode mapping — this is what the item views apply (#90).
        #expect(TitleTruncationMode.head.lineBreakMode == .byTruncatingHead)
        #expect(TitleTruncationMode.middle.lineBreakMode == .byTruncatingMiddle)
        #expect(TitleTruncationMode.tail.lineBreakMode == .byTruncatingTail)
        // The stored-value fallback in Preferences (init/reloadFromDefaults) is
        // .tail, so a fresh install keeps the historical truncate-at-end look.
        let defaults = UserDefaults(suiteName: "titleTruncationModeRoundTripTests")
        defaults?.removePersistentDomain(forName: "titleTruncationModeRoundTripTests")
        let fresh = defaults?.string(forKey: Preferences.Keys.titleTruncationMode)
            .flatMap(TitleTruncationMode.init(rawValue:)) ?? .tail
        #expect(fresh == .tail)
    }

    @Test("SwitcherFontScale raw values round-trip and multipliers strictly increase")
    func fontScaleRoundTrip() {
        for scale in SwitcherFontScale.allCases {
            #expect(SwitcherFontScale(rawValue: scale.rawValue) == scale)
            #expect(!scale.displayName.isEmpty)
        }
        // allCases is ordered smallest → largest; the multipliers must agree so
        // the settings popup reads as a monotonic size ramp.
        let multipliers = SwitcherFontScale.allCases.map(\.multiplier)
        #expect(multipliers == multipliers.sorted())
        #expect(Set(multipliers).count == multipliers.count)
        #expect(SwitcherFontScale.standard.multiplier == 1.0)
        // Unknown raw value → nil, so the init read falls back to .standard.
        #expect(SwitcherFontScale(rawValue: "huge") == nil)
    }

    @Test("SwitcherFontFace raw values round-trip and map to SystemDesign")
    func fontFaceRoundTrip() {
        for face in SwitcherFontFace.allCases {
            #expect(SwitcherFontFace(rawValue: face.rawValue) == face)
            #expect(!face.displayName.isEmpty)
        }
        #expect(SwitcherFontFace.system.systemDesign == .default)
        #expect(SwitcherFontFace.rounded.systemDesign == .rounded)
        #expect(SwitcherFontFace.serif.systemDesign == .serif)
        #expect(SwitcherFontFace.monospaced.systemDesign == .monospaced)
        #expect(SwitcherFontFace(rawValue: "papyrus") == nil)
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
        let original = AppException(
            bundleID: "com.x",
            hide: .whenNoWindows,
            ignore: .whenFullscreen,
            windowTitleContains: ["Picture-in-Picture", " Inspector ", "picture-in-picture"]
        )
        #expect(original.windowTitleContains == ["Picture-in-Picture", "Inspector"])
        #expect(AppException(dictionary: original.dictionary) == original)

        // Missing modes fall back to the neutral defaults.
        let partial = AppException(dictionary: ["bundleID": "com.y"])
        #expect(partial == AppException(bundleID: "com.y", hide: .dontHide, ignore: .never))

        let malformedTitles = AppException(dictionary: [
            "bundleID": "com.z",
            "windowTitleContains": ["", "   ", "Résumé", "resume"],
        ])
        #expect(malformedTitles?.windowTitleContains == ["Résumé"])

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
