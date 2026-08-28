import Foundation
import Testing
@testable import BetterCmdTab

/// Round-trip + validation tests for settings export/import (#12) in both
/// formats — flat config JSON (#117) and the legacy `.cmdtab` envelope —
/// driven directly (`importSettings(from:)` / `exportedJSONData()`).
///
/// `.serialized`: every test here mutates the shared `Preferences.shared`
/// singleton (its only entry point), so they must run one at a time rather than
/// racing each other on the same UserDefaults-backed state.
@MainActor
@Suite("Settings portability", .serialized)
struct SettingsPortabilityTests {

    /// A legacy `.cmdtab` envelope at the given schema version.
    private func envelope(_ values: [String: Any], version: Int? = nil) -> Data {
        let schemaVersion = version ?? Preferences.exportSchemaVersion
        let root: [String: Any] = ["app": "BetterCmdTab", "schemaVersion": schemaVersion, "values": values]
        return try! JSONSerialization.data(withJSONObject: root)
    }

    /// A flat config-format file (bare keys, no envelope).
    private func flat(_ values: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: values)
    }

    @Test("export produces a flat, prefix-free object (no envelope)")
    func exportFlatShape() throws {
        let data = try Preferences.exportedJSONData()
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root["schemaVersion"] == nil)
        #expect(root["values"] == nil)
        #expect(root["app"] == nil)
        #expect(root.keys.allSatisfy { !$0.hasPrefix(Preferences.exportKeyPrefix) })
        #expect(!root.isEmpty)
    }

    @Test("flat import applies bare keys to the published properties")
    func flatImport() throws {
        let prefs = Preferences.shared
        let savedSort = prefs.sortOrder
        let savedOpacity = prefs.panelOpacity
        defer {
            try? prefs.importSettings(from: flat([
                "sortOrder": savedSort.rawValue,
                "panelOpacity": savedOpacity,
            ]))
        }
        let target: SwitcherSortOrder = savedSort == .alphabetical ? .launchOrder : .alphabetical
        try prefs.importSettings(from: flat([
            "sortOrder": target.rawValue,
            "panelOpacity": 55,
        ]))
        #expect(prefs.sortOrder == target)
        #expect(prefs.panelOpacity == 55)
    }

    /// The add-preference contract: a new `Switcher.*` key must export and
    /// re-import with no portability edits (#159's `sinkMinimizedWindows`).
    @Test("sinkMinimizedWindows survives an export → import round trip")
    func sinkMinimizedWindowsRoundTrip() throws {
        let prefs = Preferences.shared
        let key = Preferences.Keys.sinkMinimizedWindows
        let savedRaw = UserDefaults.standard.object(forKey: key)
        let saved = prefs.sinkMinimizedWindows
        defer {
            // Restore the published property for the rest of the serialized suite,
            // then drop the key again if this host never had it — writing it back
            // unconditionally would leave the default pinned for good.
            prefs.sinkMinimizedWindows = saved
            if savedRaw == nil { UserDefaults.standard.removeObject(forKey: key) }
        }

        // Export the non-default value — it must appear, bare, in the payload.
        prefs.sinkMinimizedWindows = false
        let data = try Preferences.exportedJSONData()
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root["sinkMinimizedWindows"] as? Bool == false)

        // Flip away, re-import, and confirm the published property follows.
        prefs.sinkMinimizedWindows = true
        try prefs.importSettings(from: data)
        #expect(prefs.sinkMinimizedWindows == false)
    }

    /// Default-true is what makes #159 upgrade-safe: it reproduces the historical
    /// unconditional sink, so a `?? false` typo would silently change behavior
    /// for every existing user. Pins the two reachable fallbacks: the raw-key
    /// read in `CatalogFilter.config()` and `Preferences.reloadFromDefaults()`.
    /// The fallback in `Preferences.init` is *not* covered — `Preferences.shared`
    /// is already built before any test runs — so a wrong default there would
    /// ship a wrong first-launch value with this suite still green.
    @Test("sinkMinimizedWindows defaults to true when the key is absent")
    func sinkMinimizedWindowsDefaultsToTrue() {
        let defaults = UserDefaults.standard
        let key = Preferences.Keys.sinkMinimizedWindows
        let saved = defaults.object(forKey: key)
        defer {
            if let saved { defaults.set(saved, forKey: key) } else { defaults.removeObject(forKey: key) }
            // Put the published property back in step with the restored key for
            // the rest of the serialized suite.
            Preferences.shared.reloadFromDefaults()
        }

        defaults.removeObject(forKey: key)
        #expect(CatalogFilter.config().sinkMinimizedWindows == true)
        // The switcher reads the published property, not the key, so its own
        // absent-key fallback has to default true as well.
        Preferences.shared.reloadFromDefaults()
        #expect(Preferences.shared.sinkMinimizedWindows == true)
    }

    /// The grid reads this through `EffectiveSettings` on every reveal, so a
    /// missing `reloadFromDefaults()` line would leave an imported "off" invisible
    /// until the next launch. Default-true reproduces the shipped behavior, which
    /// is also what the macOS switcher does.
    @Test("gridSingleRow round-trips and defaults to true when the key is absent")
    func gridSingleRowRoundTrip() throws {
        let prefs = Preferences.shared
        let key = Preferences.Keys.gridSingleRow
        let savedRaw = UserDefaults.standard.object(forKey: key)
        let saved = prefs.gridSingleRow
        defer {
            prefs.gridSingleRow = saved
            if savedRaw == nil { UserDefaults.standard.removeObject(forKey: key) }
        }

        prefs.gridSingleRow = false
        let data = try Preferences.exportedJSONData()
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root["gridSingleRow"] as? Bool == false)

        prefs.gridSingleRow = true
        try prefs.importSettings(from: data)
        #expect(prefs.gridSingleRow == false)

        UserDefaults.standard.removeObject(forKey: key)
        prefs.reloadFromDefaults()
        #expect(prefs.gridSingleRow == true)
    }

    @Test("flat import accepts keys that already carry the Switcher. prefix")
    func flatImportPrefixLeniency() throws {
        let prefs = Preferences.shared
        let saved = prefs.panelOpacity
        defer { prefs.panelOpacity = saved }
        try prefs.importSettings(from: flat([
            Preferences.Keys.panelOpacity: 60
        ]))
        #expect(prefs.panelOpacity == 60)
    }

    @Test("flat import runs the legacy key migrations")
    func flatImportLegacyMigrations() throws {
        let prefs = Preferences.shared
        let savedScope = prefs.spaceScope
        let savedScale = prefs.panelScalePercent
        defer {
            prefs.spaceScope = savedScope
            prefs.panelScalePercent = savedScale
        }
        // Pre-#57: only the legacy bool, stale local enum must not shadow it.
        prefs.spaceScope = .visibleSpaces
        try prefs.importSettings(from: flat(["currentSpaceOnly": true]))
        #expect(prefs.spaceScope == .currentSpace)
        // Pre-#105: only the preset string, local continuous value must yield.
        prefs.panelScalePercent = 73
        try prefs.importSettings(from: flat(["panelSize": "standard"]))
        #expect(prefs.panelScalePercent == 100)
    }

    @Test("a flat file with a null value skips the key, applies the rest")
    func flatNullValueSkipped() throws {
        let prefs = Preferences.shared
        let saved = prefs.panelOpacity
        defer { prefs.panelOpacity = saved }
        try prefs.importSettings(from: flat([
            "bogusNull": NSNull(),
            "panelOpacity": 65,
        ] as [String: Any]))
        #expect(UserDefaults.standard.object(forKey: "Switcher.bogusNull") == nil)
        #expect(prefs.panelOpacity == 65)
    }

    @Test("a top-level JSON array is rejected")
    func flatArrayRejected() {
        let prefs = Preferences.shared
        let data = try! JSONSerialization.data(withJSONObject: [["sortOrder": "mru"]])
        #expect(throws: Preferences.SettingsImportError.self) {
            try prefs.importSettings(from: data)
        }
    }

    @Test("round-trip: imported values reload into the published properties")
    func roundTrip() throws {
        let prefs = Preferences.shared
        // Snapshot the live values so the shared singleton is left exactly as
        // found regardless of what the rest of the run expects.
        let savedSort = prefs.sortOrder
        let savedMin = prefs.showMinimizedWindows
        let savedOpacity = prefs.panelOpacity
        let savedPinned = prefs.pinnedBundleIDs
        let savedSoundName = prefs.commitSoundName
        defer {
            try? prefs.importSettings(from: envelope([
                Preferences.Keys.sortOrder: savedSort.rawValue,
                Preferences.Keys.showMinimizedWindows: savedMin,
                Preferences.Keys.panelOpacity: savedOpacity,
                Preferences.Keys.pinnedBundleIDs: savedPinned,
                Preferences.Keys.commitSoundName: savedSoundName,
            ]))
        }

        // Flip a few values away from their current state, import, verify.
        let target: SwitcherSortOrder = savedSort == .alphabetical ? .launchOrder : .alphabetical
        try prefs.importSettings(from: envelope([
            Preferences.Keys.sortOrder: target.rawValue,
            Preferences.Keys.showMinimizedWindows: false,
            Preferences.Keys.panelOpacity: 55,
            Preferences.Keys.pinnedBundleIDs: ["com.apple.finder", "com.apple.Safari"],
            Preferences.Keys.commitSoundName: savedSoundName == "Ping" ? "Pop" : "Ping",
        ]))
        #expect(prefs.sortOrder == target)
        #expect(prefs.showMinimizedWindows == false)
        #expect(prefs.panelOpacity == 55)
        #expect(prefs.pinnedBundleIDs == ["com.apple.finder", "com.apple.Safari"])
        #expect(prefs.commitSoundName == (savedSoundName == "Ping" ? "Pop" : "Ping"))
    }

    @Test("pre-#57 import (legacy currentSpaceOnly bool, no spaceScope) applies through the fallback")
    func legacySpaceScopeImport() throws {
        let prefs = Preferences.shared
        let saved = prefs.spaceScope
        defer {
            try? prefs.importSettings(from: envelope([
                Preferences.Keys.spaceScope: saved.rawValue,
                Preferences.Keys.currentSpaceOnly: saved == .currentSpace,
            ]))
        }

        // Local state has the new enum key set to a non-legacy value…
        prefs.spaceScope = .visibleSpaces
        // …then an old export carrying only the legacy bool is imported. The
        // stale local enum key must not shadow the imported bool.
        try prefs.importSettings(from: envelope([
            Preferences.Keys.currentSpaceOnly: true
        ]))
        #expect(prefs.spaceScope == .currentSpace)

        // Same with the bool off → all Spaces.
        prefs.spaceScope = .visibleSpaces
        try prefs.importSettings(from: envelope([
            Preferences.Keys.currentSpaceOnly: false
        ]))
        #expect(prefs.spaceScope == .allSpaces)

        // A new-format export carries both keys; the enum wins.
        try prefs.importSettings(from: envelope([
            Preferences.Keys.spaceScope: SpaceScope.visibleSpaces.rawValue,
            Preferences.Keys.currentSpaceOnly: false,
        ]))
        #expect(prefs.spaceScope == .visibleSpaces)
    }

    @Test("pre-graduation tab-MRU import (legacy key only) applies through the fallback")
    func legacyBrowserTabMRUImport() throws {
        let prefs = Preferences.shared
        let savedRaw = UserDefaults.standard.object(forKey: Preferences.Keys.browserTabMRU)
        let savedLegacy = UserDefaults.standard.object(forKey: Preferences.Keys.legacyBrowserTabMRU)
        defer {
            // Restore both keys to their raw pre-test state — `set(nil:)` removes
            // one this host never had. This is the only test that writes the
            // legacy key, and leaving it planted would ride along in every later
            // export and config.json write-back on the developer's machine.
            UserDefaults.standard.set(savedRaw, forKey: Preferences.Keys.browserTabMRU)
            UserDefaults.standard.set(savedLegacy, forKey: Preferences.Keys.legacyBrowserTabMRU)
            prefs.reloadFromDefaults()
        }

        // Local state has the graduated key stored…
        prefs.browserTabMRU = true
        // …then a pre-graduation export carrying only the experimental key is
        // imported. The stale local key must not shadow the imported value.
        try prefs.importSettings(from: flat(["experimentalBrowserTabMRU": false]))
        #expect(prefs.browserTabMRU == false)

        // Same the other way round: legacy-only import turns it back on.
        try prefs.importSettings(from: flat(["experimentalBrowserTabMRU": true]))
        #expect(prefs.browserTabMRU == true)

        // A post-graduation export carries the new key; it wins.
        try prefs.importSettings(from: flat([
            "browserTabMRU": false,
            "experimentalBrowserTabMRU": true,
        ]))
        #expect(prefs.browserTabMRU == false)
    }

    @Test("pre-graduation instant-Space import (legacy key only) applies through the fallback")
    func legacyInstantSpaceSwitchImport() throws {
        let prefs = Preferences.shared
        let savedRaw = UserDefaults.standard.object(forKey: Preferences.Keys.instantSpaceSwitch)
        let savedLegacy = UserDefaults.standard.object(forKey: Preferences.Keys.legacyInstantSpaceSwitch)
        defer {
            // Restore both keys to their raw pre-test state — `set(nil:)` removes
            // one this host never had. This is the only test that writes the
            // legacy key, and leaving it planted would ride along in every later
            // export and config.json write-back on the developer's machine.
            UserDefaults.standard.set(savedRaw, forKey: Preferences.Keys.instantSpaceSwitch)
            UserDefaults.standard.set(savedLegacy, forKey: Preferences.Keys.legacyInstantSpaceSwitch)
            prefs.reloadFromDefaults()
        }

        // Local state has the graduated key stored… (via a forced transition, so
        // the mirroring didSet runs even on a host that already had this on).
        prefs.instantSpaceSwitch = false
        prefs.instantSpaceSwitch = true
        // Every change also writes the pre-graduation key, so a downgraded build
        // sharing this config.json keeps reading the same value.
        #expect(UserDefaults.standard.object(forKey: Preferences.Keys.legacyInstantSpaceSwitch) as? Bool == true)
        prefs.instantSpaceSwitch = false
        #expect(UserDefaults.standard.object(forKey: Preferences.Keys.legacyInstantSpaceSwitch) as? Bool == false)
        prefs.instantSpaceSwitch = true

        // …then a pre-graduation export carrying only the experimental key is
        // imported. The stale local key must not shadow the imported value.
        try prefs.importSettings(from: flat(["experimentalInstantSpaceSwitch": false]))
        #expect(prefs.instantSpaceSwitch == false)

        try prefs.importSettings(from: flat(["experimentalInstantSpaceSwitch": true]))
        #expect(prefs.instantSpaceSwitch == true)

        // A post-graduation export carries the new key; it wins.
        try prefs.importSettings(from: flat([
            "instantSpaceSwitch": false,
            "experimentalInstantSpaceSwitch": true,
        ]))
        #expect(prefs.instantSpaceSwitch == false)

        // A hand-written legacy value that isn't a bool must not drop the
        // graduated key: importSettings matches on `as? Bool`, not on mere
        // presence, so the local opt-in survives instead of reading back false.
        prefs.instantSpaceSwitch = true
        try prefs.importSettings(from: flat(["experimentalInstantSpaceSwitch": "yes"]))
        #expect(prefs.instantSpaceSwitch == true)
    }

    @Test("pre-graduation Previews-capture import (legacy keys only) applies through the fallback")
    func legacyPreviewCaptureImport() throws {
        let prefs = Preferences.shared
        let saved = [
            Preferences.Keys.browserTabPreviews, Preferences.Keys.legacyBrowserTabPreviews,
            Preferences.Keys.livePreviews, Preferences.Keys.legacyLivePreviews,
        ].map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer {
            // Restore all four keys to their raw pre-test state — `set(nil:)`
            // removes one this host never had. Leaving a legacy key planted would
            // ride along in every later export and config.json write-back on the
            // developer's machine. Restoring twice is deliberate: reloading in
            // between resyncs the published properties, but its mirroring didSet
            // re-plants both keys whenever that resync flips a value.
            for (key, value) in saved { UserDefaults.standard.set(value, forKey: key) }
            prefs.reloadFromDefaults()
            for (key, value) in saved { UserDefaults.standard.set(value, forKey: key) }
        }

        // Local state has the graduated keys stored… (forced transition, so the
        // mirroring didSet runs even on a host that already had these on).
        prefs.browserTabPreviews = false
        prefs.livePreviews = false
        prefs.browserTabPreviews = true
        prefs.livePreviews = true
        // Every change also writes the pre-graduation key, so a downgraded build
        // sharing this config.json keeps reading the same value.
        #expect(UserDefaults.standard.object(forKey: Preferences.Keys.legacyBrowserTabPreviews) as? Bool == true)
        #expect(UserDefaults.standard.object(forKey: Preferences.Keys.legacyLivePreviews) as? Bool == true)
        // Opting back out has to mirror too: a legacy key stuck on `true` would
        // leave a downgraded build still capturing after the user turned it off.
        prefs.browserTabPreviews = false
        prefs.livePreviews = false
        #expect(UserDefaults.standard.object(forKey: Preferences.Keys.legacyBrowserTabPreviews) as? Bool == false)
        #expect(UserDefaults.standard.object(forKey: Preferences.Keys.legacyLivePreviews) as? Bool == false)
        prefs.browserTabPreviews = true
        prefs.livePreviews = true

        // …then a pre-graduation export carrying only the experimental keys is
        // imported. The stale local keys must not shadow the imported values.
        try prefs.importSettings(from: flat([
            "experimentalBrowserTabPreviews": false,
            "experimentalLivePreviews": false,
        ]))
        #expect(prefs.browserTabPreviews == false)
        #expect(prefs.livePreviews == false)

        // Same the other way round: legacy-only import turns them back on.
        try prefs.importSettings(from: flat([
            "experimentalBrowserTabPreviews": true,
            "experimentalLivePreviews": true,
        ]))
        #expect(prefs.browserTabPreviews == true)
        #expect(prefs.livePreviews == true)

        // A post-graduation export carries both keys; the graduated one wins.
        try prefs.importSettings(from: flat([
            "browserTabPreviews": false,
            "experimentalBrowserTabPreviews": true,
            "livePreviews": false,
            "experimentalLivePreviews": true,
        ]))
        #expect(prefs.browserTabPreviews == false)
        #expect(prefs.livePreviews == false)

        // A hand-written legacy value that isn't a bool must not drop the
        // graduated key: importSettings matches on `as? Bool`, not on mere
        // presence, so the local opt-in survives instead of reading back false.
        prefs.browserTabPreviews = true
        prefs.livePreviews = true
        try prefs.importSettings(from: flat([
            "experimentalBrowserTabPreviews": "yes",
            "experimentalLivePreviews": "yes",
        ]))
        #expect(prefs.browserTabPreviews == true)
        #expect(prefs.livePreviews == true)
    }

    @Test("pre-#105 panel preset import replaces a local continuous scale")
    func legacyPanelScaleImport() throws {
        let prefs = Preferences.shared
        let saved = prefs.panelScalePercent
        defer { prefs.panelScalePercent = saved }

        prefs.panelScalePercent = 73
        try prefs.importSettings(from: envelope([
            Preferences.Keys.panelSize: "standard"
        ]))
        #expect(prefs.panelScalePercent == 100)
        #expect(UserDefaults.standard.object(forKey: Preferences.Keys.panelSize) == nil)
        #expect(UserDefaults.standard.integer(forKey: Preferences.Keys.panelScalePercent) == 100)

        try prefs.importSettings(from: envelope([
            Preferences.Keys.panelSize: "small",
            Preferences.Keys.panelScalePercent: 61,
        ]))
        #expect(prefs.panelScalePercent == 61)
    }

    /// `config.json` written before #170 carries percentages that meant something 1.5x
    /// smaller, and it is re-imported a moment *after* launch already migrated the
    /// defaults — so left alone, the config-file user writes those numbers straight
    /// back over the finished migration and keeps the oversized panel #170 is about.
    /// What the launch migrated *from* is the only version signal a settings file has.
    @Test("the config that was migrated from is re-based once; anything else is verbatim")
    func panelScaleRebaseOnImport() throws {
        let prefs = Preferences.shared
        let defaults = UserDefaults.standard
        let saved = prefs.panelScalePercent
        let savedFlag = defaults.object(forKey: Preferences.Keys.panelScaleRebased)
        let savedToken = Preferences.preRebasePanelScales
        let savedOverrides = defaults.object(forKey: Preferences.Keys.shortcutOverrides)
        defer {
            Preferences.preRebasePanelScales = savedToken
            prefs.panelScalePercent = saved
            if let savedFlag { defaults.set(savedFlag, forKey: Preferences.Keys.panelScaleRebased) }
            else { defaults.removeObject(forKey: Preferences.Keys.panelScaleRebased) }
            if let savedOverrides { defaults.set(savedOverrides, forKey: Preferences.Keys.shortcutOverrides) }
            else { defaults.removeObject(forKey: Preferences.Keys.shortcutOverrides) }
            prefs.reloadFromDefaults()
        }
        let oldOverrides = [["target": "switchWindows", "panelScalePercent": "150"]]

        // The upgrade sequence, in order: launch migrates this Mac's stored values,
        // then the config file's deferred import lands still carrying the old ones.
        Preferences.preRebasePanelScales = nil
        defaults.set(120, forKey: Preferences.Keys.panelScalePercent)
        defaults.set(oldOverrides, forKey: Preferences.Keys.shortcutOverrides)
        defaults.removeObject(forKey: Preferences.Keys.panelScaleRebased)
        Preferences.rebasePanelScalesIfNeeded(defaults)
        prefs.reloadFromDefaults()
        #expect(prefs.panelScalePercent == 100)
        #expect(prefs.override(for: .switchWindows).panelScalePercent == 125)

        try prefs.importSettings(from: flat(["panelScalePercent": 120, "shortcutOverrides": oldOverrides]),
                                 mayPredateNativeSizing: true)
        #expect(prefs.panelScalePercent == 100)
        #expect(prefs.override(for: .switchWindows).panelScalePercent == 125)

        // That dates one read, not the whole launch. A second read carrying the same
        // number is ambiguous — either the write-back failed and this is the old file
        // again, or the user has since typed that number meaning the new scale — and
        // honoring it is the safer half: an oversized panel is visible and fixable in
        // Settings, whereas re-basing silently shrinks what they typed and persists it.
        try prefs.importSettings(from: flat(["panelScalePercent": 120]), mayPredateNativeSizing: true)
        #expect(prefs.panelScalePercent == 120)

        // A config already re-based on another Mac and synced here carries numbers this
        // migration never produced, so it is honored instead of being shrunk twice —
        // as is a hand-written or templated one, which is the documented dotfiles use.
        Preferences.preRebasePanelScales = (percent: 120, overrides: ["switchWindows": 150])
        try prefs.importSettings(
            from: flat(["panelScalePercent": 100,
                        "shortcutOverrides": [["target": "switchWindows", "panelScalePercent": "125"]]]),
            mayPredateNativeSizing: true
        )
        #expect(prefs.panelScalePercent == 100)
        #expect(prefs.override(for: .switchWindows).panelScalePercent == 125)

        // The import panel never re-bases, not even mid-migration: a file the user
        // picked is applied as written, and an export of the running build round-trips.
        Preferences.preRebasePanelScales = (percent: 140, overrides: [:])
        prefs.panelScalePercent = 140
        try prefs.importSettings(from: Preferences.exportedJSONData())
        #expect(prefs.panelScalePercent == 140)
    }

    /// The arithmetic of `rebasedPanelScalePercent` is covered in PreferencesEnumTests;
    /// this drives the *gate* through the real `UserDefaults` path, which is what
    /// decides whether an upgrading user's panel changes size.
    @Test("the panel-scale re-base runs exactly once")
    func panelScaleRebaseIsOneShot() {
        let defaults = UserDefaults.standard
        let prefs = Preferences.shared
        let saved = prefs.panelScalePercent
        let savedFlag = defaults.object(forKey: Preferences.Keys.panelScaleRebased)
        let savedPreset = defaults.object(forKey: Preferences.Keys.panelSize)
        let savedToken = Preferences.preRebasePanelScales
        defer {
            Preferences.preRebasePanelScales = savedToken
            prefs.panelScalePercent = saved
            if let savedFlag { defaults.set(savedFlag, forKey: Preferences.Keys.panelScaleRebased) }
            else { defaults.removeObject(forKey: Preferences.Keys.panelScaleRebased) }
            if let savedPreset { defaults.set(savedPreset, forKey: Preferences.Keys.panelSize) }
            else { defaults.removeObject(forKey: Preferences.Keys.panelSize) }
        }

        // (a) An upgrading user: the old default, no flag yet.
        defaults.set(120, forKey: Preferences.Keys.panelScalePercent)
        defaults.removeObject(forKey: Preferences.Keys.panelScaleRebased)
        Preferences.rebasePanelScalesIfNeeded(defaults)
        prefs.reloadFromDefaults()
        #expect(prefs.panelScalePercent == 100)
        #expect(defaults.bool(forKey: Preferences.Keys.panelScaleRebased))

        // (b) Idempotent: a second launch must not re-base 100 down to 83.
        Preferences.rebasePanelScalesIfNeeded(defaults)
        prefs.reloadFromDefaults()
        #expect(prefs.panelScalePercent == 100)
        #expect(defaults.integer(forKey: Preferences.Keys.panelScalePercent) == 100)

        // (c) `legacyPanelScalePercent` already returns post-#170 numbers, so a user
        // still on the pre-#105 preset must not be re-based on top of that.
        defaults.removeObject(forKey: Preferences.Keys.panelScalePercent)
        defaults.removeObject(forKey: Preferences.Keys.panelScaleRebased)
        defaults.set("standard", forKey: Preferences.Keys.panelSize)
        Preferences.rebasePanelScalesIfNeeded(defaults)
        prefs.reloadFromDefaults()
        #expect(prefs.panelScalePercent == 100)
    }

    /// A per-shortcut override carries its own percentage, under the same old
    /// baseline, so that shortcut would keep opening an oversized panel.
    @Test("per-shortcut override percentages are re-based by the same one-shot")
    func panelScaleRebaseCoversOverrides() {
        let defaults = UserDefaults.standard
        let prefs = Preferences.shared
        let savedOverrides = defaults.object(forKey: Preferences.Keys.shortcutOverrides)
        let savedFlag = defaults.object(forKey: Preferences.Keys.panelScaleRebased)
        let savedScale = prefs.panelScalePercent
        let savedToken = Preferences.preRebasePanelScales
        defer {
            Preferences.preRebasePanelScales = savedToken
            if let savedOverrides { defaults.set(savedOverrides, forKey: Preferences.Keys.shortcutOverrides) }
            else { defaults.removeObject(forKey: Preferences.Keys.shortcutOverrides) }
            if let savedFlag { defaults.set(savedFlag, forKey: Preferences.Keys.panelScaleRebased) }
            else { defaults.removeObject(forKey: Preferences.Keys.panelScaleRebased) }
            prefs.panelScalePercent = savedScale
            prefs.reloadFromDefaults()
        }

        defaults.set([["target": "switchWindows", "panelScalePercent": "150"]],
                     forKey: Preferences.Keys.shortcutOverrides)
        defaults.removeObject(forKey: Preferences.Keys.panelScaleRebased)
        Preferences.rebasePanelScalesIfNeeded(defaults)
        prefs.reloadFromDefaults()
        #expect(prefs.override(for: .switchWindows).panelScalePercent == 125)

        // Idempotent here too: a second launch must not shrink it again.
        Preferences.rebasePanelScalesIfNeeded(defaults)
        prefs.reloadFromDefaults()
        #expect(prefs.override(for: .switchWindows).panelScalePercent == 125)
    }

    @Test("round-trip: switcherDisplayMode survives export/import")
    func displayModeRoundTrip() throws {
        let prefs = Preferences.shared
        let saved = prefs.switcherDisplayMode
        defer {
            try? prefs.importSettings(from: envelope([
                Preferences.Keys.switcherDisplayMode: saved.rawValue
            ]))
        }
        // Set a non-default value, export, flip live, then import the export back.
        prefs.switcherDisplayMode = .activeWindow
        let data = try Preferences.exportedJSONData()
        prefs.switcherDisplayMode = .mainDisplay
        try prefs.importSettings(from: data)
        #expect(prefs.switcherDisplayMode == .activeWindow)
    }

    @Test("round-trip: shortcutOverrides survive export/import")
    func shortcutOverridesRoundTrip() throws {
        let prefs = Preferences.shared
        let saved = prefs.shortcutOverrides
        defer { prefs.shortcutOverrides = saved }
        var ov = ShortcutOverride()
        ov.spaceScope = .allSpaces
        ov.sortOrder = .alphabetical
        ov.panelOpacity = 70
        prefs.shortcutOverrides = [SwitchTarget.switchWindows.storageKey: ov]
        let data = try Preferences.exportedJSONData()
        prefs.shortcutOverrides = [:] // flip live, then restore from the export
        try prefs.importSettings(from: data)
        let restored = prefs.override(for: .switchWindows)
        #expect(restored.spaceScope == .allSpaces)
        #expect(restored.sortOrder == .alphabetical)
        #expect(restored.panelOpacity == 70)
    }

    @Test("round-trip: shiftTapStepsBackward survives export/import")
    func shiftTapStepsBackwardRoundTrip() throws {
        let prefs = Preferences.shared
        let saved = prefs.shiftTapStepsBackward
        defer {
            try? prefs.importSettings(from: envelope([
                Preferences.Keys.shiftTapStepsBackward: saved
            ]))
        }
        // Flip away from the default (on), export, flip live back, import.
        prefs.shiftTapStepsBackward = false
        let data = try Preferences.exportedJSONData()
        prefs.shiftTapStepsBackward = true
        try prefs.importSettings(from: data)
        #expect(prefs.shiftTapStepsBackward == false)
    }

    @Test("import missing shiftTapStepsBackward leaves the current value untouched")
    func shiftTapStepsBackwardPartialImport() throws {
        let prefs = Preferences.shared
        let saved = prefs.shiftTapStepsBackward
        defer { prefs.shiftTapStepsBackward = saved }
        prefs.shiftTapStepsBackward = false
        // Envelope without the key (partial-import contract).
        try prefs.importSettings(from: envelope([
            Preferences.Keys.panelOpacity: 100
        ]))
        #expect(prefs.shiftTapStepsBackward == false)
    }

    @Test("round-trip: backtickReversesAppSwitching survives export/import")
    func backtickReversesAppSwitchingRoundTrip() throws {
        let prefs = Preferences.shared
        let saved = prefs.backtickReversesAppSwitching
        defer {
            try? prefs.importSettings(from: envelope([
                Preferences.Keys.backtickReversesAppSwitching: saved
            ]))
        }
        // Flip away from the default (off), export, flip live back, import.
        prefs.backtickReversesAppSwitching = true
        let data = try Preferences.exportedJSONData()
        prefs.backtickReversesAppSwitching = false
        try prefs.importSettings(from: data)
        #expect(prefs.backtickReversesAppSwitching == true)
    }

    @Test("import missing switcherDisplayMode leaves the current value untouched")
    func displayModePartialImport() throws {
        let prefs = Preferences.shared
        let saved = prefs.switcherDisplayMode
        defer { prefs.switcherDisplayMode = saved }
        prefs.switcherDisplayMode = .activeWindow
        // Envelope without the display-mode key (partial-import contract).
        try prefs.importSettings(from: envelope([
            Preferences.Keys.panelOpacity: 100
        ]))
        #expect(prefs.switcherDisplayMode == .activeWindow)
    }

    @Test("malformed JSON is rejected")
    func malformedRejected() {
        let prefs = Preferences.shared
        #expect(throws: Preferences.SettingsImportError.self) {
            try prefs.importSettings(from: Data("not json".utf8))
        }
    }

    @Test("missing values block is rejected")
    func missingValuesRejected() {
        let prefs = Preferences.shared
        let data = try! JSONSerialization.data(withJSONObject: ["schemaVersion": 1])
        #expect(throws: Preferences.SettingsImportError.self) {
            try prefs.importSettings(from: data)
        }
    }

    @Test("a newer schema version is refused")
    func newerVersionRefused() {
        let prefs = Preferences.shared
        let data = envelope([:], version: Preferences.exportSchemaVersion + 1)
        #expect(throws: Preferences.SettingsImportError.self) {
            try prefs.importSettings(from: data)
        }
    }

    @Test("a non-plist value (JSON null) is skipped, not crashed on")
    func nullValueSkipped() throws {
        let prefs = Preferences.shared
        // JSON null bridges to NSNull, which UserDefaults.set would reject with an
        // uncatchable exception — import must skip it and apply the rest.
        let root: [String: Any] = [
            "app": "BetterCmdTab",
            "schemaVersion": Preferences.exportSchemaVersion,
            "values": [
                "Switcher.bogusNull": NSNull(),
                Preferences.Keys.letterHintsEnabled: true,
            ] as [String: Any],
        ]
        let data = try JSONSerialization.data(withJSONObject: root)
        // Must not throw / crash.
        try prefs.importSettings(from: data)
        #expect(UserDefaults.standard.object(forKey: "Switcher.bogusNull") == nil)
    }

    @Test("machine-local keys are excluded from export and import")
    func machineLocalKeysExcluded() throws {
        let prefs = Preferences.shared
        let defaults = UserDefaults.standard
        let key = "Switcher.disabledSymbolicHotKeys"
        let customSoundKey = Preferences.Keys.customCommitSoundFilename
        let saved = defaults.object(forKey: key)
        let savedCustomSound = prefs.customCommitSoundFilename
        defer {
            if let saved { defaults.set(saved, forKey: key) } else { defaults.removeObject(forKey: key) }
            prefs.customCommitSoundFilename = savedCustomSound
        }
        defaults.set([55], forKey: key)
        prefs.customCommitSoundFilename = "local.aiff"

        // Export must not carry this machine's crash-heal record — under
        // neither the bare nor the prefixed spelling.
        let data = try Preferences.exportedJSONData()
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root[key] == nil)
        #expect(root["disabledSymbolicHotKeys"] == nil)
        #expect(root["recentlyClosed"] == nil)
        #expect(root["customCommitSoundFilename"] == nil)

        // Import must not overwrite this machine's record with the file's.
        try prefs.importSettings(from: envelope([key: [1, 2], customSoundKey: "another-mac.aiff"]))
        #expect(defaults.array(forKey: key) as? [Int] == [55])
        #expect(defaults.string(forKey: customSoundKey) == "local.aiff")
    }

    @Test("generated schema types every snapshot key and stays open-ended")
    func schemaShape() throws {
        let schema = Preferences.settingsSchema(
            for: [
                "aBool": true,
                "anInt": 42,
                "aDouble": 0.5,
                "aString": "x",
                "anArray": ["a"],
                "anObject": ["k": "v"],
            ],
            version: "26.7"
        )
        // Open-ended by design: a file from another version must still validate.
        #expect(schema["additionalProperties"] as? Bool == true)
        #expect(schema["required"] == nil)
        let properties = try #require(schema["properties"] as? [String: [String: Any]])
        #expect(properties["aBool"]?["type"] as? String == "boolean")
        #expect(properties["anInt"]?["type"] as? String == "integer")
        #expect(properties["aDouble"]?["type"] as? String == "number")
        #expect(properties["aString"]?["type"] as? String == "string")
        #expect(properties["anArray"]?["type"] as? String == "array")
        #expect(properties["anObject"]?["type"] as? String == "object")
        #expect(properties["$schema"]?["type"] as? String == "string")
    }

    @Test("documented keys carry a description, their enum cases and their clamp range")
    func schemaDocuments() throws {
        // Documented independently of the snapshot: a key this Mac has never
        // stored still has to complete and hover in an editor.
        let schema = Preferences.settingsSchema(for: [:], version: "26.7")
        let properties = try #require(schema["properties"] as? [String: [String: Any]])

        for (key, doc) in ConfigSchemaDocs.byKey {
            let property = try #require(properties[key], "schema is missing documented \(key)")
            #expect(property["type"] as? String == doc.type)
            #expect((property["description"] as? String)?.isEmpty == false, "\(key) has no description")
        }
        // Enum cases come from the live type, so a renamed case can't drift.
        #expect(properties["layoutMode"]?["enum"] as? [String] == SwitcherLayoutMode.allCases.map(\.rawValue))
        #expect(properties["spaceScope"]?["enum"] as? [String] == SpaceScope.allCases.map(\.rawValue))
        // …and ranges from the clamp the app applies anyway.
        #expect(properties["panelOpacity"]?["minimum"] as? Int == Preferences.panelOpacityRange.lowerBound)
        #expect(properties["panelOpacity"]?["maximum"] as? Int == Preferences.panelOpacityRange.upperBound)
        // 0 means unlimited, so the floor is 0 rather than the clamp's own 2.
        #expect(properties["browserTabRowLimit"]?["minimum"] as? Int == 0)
        #expect(properties["browserTabRowLimit"]?["maximum"] as? Int == Preferences.browserTabRowLimitRange.upperBound)
        // Every enum case an editor offers is labelled with what Settings calls
        // it — one label per value, none blank.
        #expect(
            properties["layoutMode"]?["enumDescriptions"] as? [String]
                == SwitcherLayoutMode.allCases.map(\.displayName)
        )
        for (key, doc) in ConfigSchemaDocs.byKey {
            guard let labels = doc.values?.labels else { continue }
            #expect(labels.count == doc.values?.raw.count, "\(key) labels don't line up with its values")
            #expect(labels.allSatisfy { !$0.isEmpty }, "\(key) has a blank value label")
        }
    }

    @Test("array settings type their elements, down to the stored dictionaries")
    func schemaTypesArrayElements() throws {
        let schema = Preferences.settingsSchema(for: [:], version: "26.7")
        let properties = try #require(schema["properties"] as? [String: [String: Any]])

        // Fixed-length slot arrays declare their length.
        #expect(properties["directActivationBindings"]?["maxItems"] as? Int == Preferences.directActivationSlotCount)

        // No array may leave its elements as a bare "type": every one is
        // constrained to a value set, a pattern, or typed object properties.
        for (key, property) in properties where property["type"] as? String == "array" {
            let items = try #require(property["items"] as? [String: Any], "\(key) has untyped elements")
            #expect(
                items["enum"] != nil || items["pattern"] != nil || items["properties"] != nil,
                "\(key) elements are only \(items["type"] ?? "?") — constrain them"
            )
        }

        // Per-app rules: a typed object, closed to unknown keys.
        let rule = try #require(properties["appExceptions"]?["items"] as? [String: Any])
        let ruleProperties = try #require(rule["properties"] as? [String: [String: Any]])
        #expect(rule["required"] as? [String] == ["bundleID"])
        #expect(rule["additionalProperties"] as? Bool == false)
        #expect(ruleProperties["hide"]?["enum"] as? [String] == HideWindowsMode.allCases.map(\.rawValue))
        #expect(ruleProperties["ignore"]?["enum"] as? [String] == IgnoreShortcutsMode.allCases.map(\.rawValue))
        let titleFragments = try #require(ruleProperties["windowTitleContains"])
        #expect(titleFragments["type"] as? String == "array")
        #expect((titleFragments["items"] as? [String: Any])?["type"] as? String == "string")

        // Overrides are a plist [String: String]: every value is the *string*
        // form of the global setting, and unknown keys are carried through.
        let override = try #require(properties["shortcutOverrides"]?["items"] as? [String: Any])
        let overrideProperties = try #require(override["properties"] as? [String: [String: Any]])
        #expect(override["additionalProperties"] as? Bool == true)
        #expect(override["required"] as? [String] == ["target"])
        #expect(overrideProperties["showMinimized"]?["type"] as? String == "string")
        #expect(overrideProperties["showMinimized"]?["enum"] as? [String] == ["true", "false"])
        #expect(overrideProperties["panelOpacity"]?["type"] as? String == "string")
        #expect(overrideProperties["panelOpacity"]?["pattern"] as? String == "^-?[0-9]+$")
        #expect(overrideProperties["layoutMode"]?["enum"] as? [String] == SwitcherLayoutMode.allCases.map(\.rawValue))
        #expect(overrideProperties["spaceScope"]?["enum"] as? [String] == SpaceScopeOverride.allCases.map(\.rawValue))
        // Every field the app can write has to be described — a new one added
        // to ShortcutOverride fails here until it is.
        for child in Mirror(reflecting: ShortcutOverride()).children {
            guard let field = child.label, field != "passthrough" else { continue }
            #expect(overrideProperties[field] != nil, "override field \(field) is undocumented")
        }
        // Excluded-from-export keys must not be advertised as settings
        // (`$schema` is the pointer itself, documented as "not a setting").
        for key in Preferences.exportExcludedKeys where key != "Switcher.$schema" {
            #expect(properties[String(key.dropFirst(Preferences.exportKeyPrefix.count))] == nil)
        }
    }

    @Test("live snapshot keys all appear in the generated schema")
    func schemaCoversSnapshot() throws {
        let data = try Preferences.settingsSchemaData(version: "test")
        let schema = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        for key in Preferences.flatSettingsSnapshot().keys {
            #expect(properties[key] != nil, "schema is missing \(key)")
        }
    }

    @Test("the config file's $schema pointer is not imported as a setting")
    func schemaRefIgnoredOnImport() throws {
        let prefs = Preferences.shared
        // A build predating the pointer stores it as a plain setting (it has no
        // exclusion for it) and can share this defaults domain, so start clean.
        UserDefaults.standard.removeObject(forKey: "Switcher.$schema")
        try prefs.importSettings(from: flat(["$schema": "./schema.json"]))
        #expect(UserDefaults.standard.object(forKey: "Switcher.$schema") == nil)
        // …and so it can never come back out in an export.
        let root = try #require(
            try JSONSerialization.jsonObject(with: Preferences.exportedJSONData()) as? [String: Any])
        #expect(root["$schema"] == nil)
    }

    @Test("keys outside the Switcher namespace are ignored on import")
    func foreignKeysIgnored() throws {
        let prefs = Preferences.shared
        // Should not throw and should not write the foreign key.
        try prefs.importSettings(from: envelope([
            "Foreign.someKey": "x",
            Preferences.Keys.letterHintsEnabled: true,
        ]))
        #expect(UserDefaults.standard.object(forKey: "Foreign.someKey") == nil)
    }
}
