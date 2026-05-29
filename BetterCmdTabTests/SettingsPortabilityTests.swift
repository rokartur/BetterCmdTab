import Foundation
import Testing
@testable import BetterCmdTab

/// Round-trip + validation tests for settings export/import (#12). These drive
/// the JSON envelope directly (`importSettings(from:)` / `exportedJSONData()`).
///
/// `.serialized`: every test here mutates the shared `Preferences.shared`
/// singleton (its only entry point), so they must run one at a time rather than
/// racing each other on the same UserDefaults-backed state.
@MainActor
@Suite("Settings portability", .serialized)
struct SettingsPortabilityTests {

    /// A valid envelope at the current schema version with the given values.
    private func envelope(_ values: [String: Any], version: Int = Preferences.exportSchemaVersion) -> Data {
        let root: [String: Any] = ["app": "BetterCmdTab", "schemaVersion": version, "values": values]
        return try! JSONSerialization.data(withJSONObject: root)
    }

    @Test("export produces a versioned envelope with a values block")
    func exportEnvelopeShape() throws {
        let prefs = Preferences.shared
        let data = try prefs.exportedJSONData()
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root["schemaVersion"] as? Int == Preferences.exportSchemaVersion)
        #expect(root["values"] is [String: Any])
        // Every exported key is in the Switcher.* namespace.
        let values = root["values"] as? [String: Any] ?? [:]
        #expect(values.keys.allSatisfy { $0.hasPrefix(Preferences.exportKeyPrefix) })
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
        defer {
            try? prefs.importSettings(from: envelope([
                Preferences.Keys.sortOrder: savedSort.rawValue,
                Preferences.Keys.showMinimizedWindows: savedMin,
                Preferences.Keys.panelOpacity: savedOpacity,
                Preferences.Keys.pinnedBundleIDs: savedPinned,
            ]))
        }

        // Flip a few values away from their current state, import, verify.
        let target: SwitcherSortOrder = savedSort == .alphabetical ? .launchOrder : .alphabetical
        try prefs.importSettings(from: envelope([
            Preferences.Keys.sortOrder: target.rawValue,
            Preferences.Keys.showMinimizedWindows: false,
            Preferences.Keys.panelOpacity: 55,
            Preferences.Keys.pinnedBundleIDs: ["com.apple.finder", "com.apple.Safari"],
        ]))
        #expect(prefs.sortOrder == target)
        #expect(prefs.showMinimizedWindows == false)
        #expect(prefs.panelOpacity == 55)
        #expect(prefs.pinnedBundleIDs == ["com.apple.finder", "com.apple.Safari"])
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
