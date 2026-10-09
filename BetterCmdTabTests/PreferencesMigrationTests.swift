import Foundation
import Testing
@testable import BetterCmdTab

@Suite("Preferences migrations")
struct PreferencesMigrationTests {

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
}
