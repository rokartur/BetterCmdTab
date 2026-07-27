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
        #expect(prefs.panelScalePercent == 120)
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

    @Test("pre-#105 panel preset import replaces a local continuous scale")
    func legacyPanelScaleImport() throws {
        let prefs = Preferences.shared
        let saved = prefs.panelScalePercent
        defer { prefs.panelScalePercent = saved }

        prefs.panelScalePercent = 73
        try prefs.importSettings(from: envelope([
            Preferences.Keys.panelSize: "standard"
        ]))
        #expect(prefs.panelScalePercent == 120)
        #expect(UserDefaults.standard.object(forKey: Preferences.Keys.panelSize) == nil)
        #expect(UserDefaults.standard.integer(forKey: Preferences.Keys.panelScalePercent) == 120)

        try prefs.importSettings(from: envelope([
            Preferences.Keys.panelSize: "small",
            Preferences.Keys.panelScalePercent: 61,
        ]))
        #expect(prefs.panelScalePercent == 61)
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
