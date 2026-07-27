import Foundation

/// Export/import of all user settings to a portable JSON file (no iCloud, no
/// network — a plain file the user saves and restores or shares between Macs),
/// and the on-disk shape of the live config file (#117).
///
/// The payload is the whole `Switcher.*` `UserDefaults` namespace, read
/// generically rather than key-by-key, so every preference is covered —
/// including app rules, pinned apps, sort order, and any keys added later —
/// without this code having to enumerate them. The switcher *trigger* hotkeys
/// (⌘Tab / ⌘`) live under the BetterShortcuts package's own keys and are not
/// part of this namespace, so they are intentionally not carried over.
///
/// Two formats are read; one is written. Writing produces a **flat** JSON
/// object of `key → value` pairs with the `Switcher.` prefix stripped —
/// human-editable, the same shape for the export panel and
/// `~/.config/bettercmdtab/config.json`. Reading also accepts the legacy
/// `.cmdtab` envelope (`{app, schemaVersion, values}`) that pre-#117 exports
/// used, so old backups keep importing.
extension Preferences {
    /// Legacy-envelope schema gate. Importing an envelope with a higher
    /// version than we understand is refused (forward-incompat); a lower or
    /// equal version is read. The flat format is deliberately unversioned:
    /// unknown keys are tolerated and absent keys keep their current value,
    /// so it can grow in both directions without a version gate.
    nonisolated static let exportSchemaVersion = 1

    /// Every persisted setting lives under this `UserDefaults` key prefix.
    nonisolated static let exportKeyPrefix = "Switcher."

    /// `Switcher.*` keys excluded from both export and import.
    /// `disabledSymbolicHotKeys` is the crash-heal record of which native
    /// hotkeys THIS machine has disabled (importing another Mac's record could
    /// leave native ⌘Tab dead after a crash); `recentlyClosed` is session
    /// history; the custom sound file lives only in this Mac's Application
    /// Support directory. The accent keys were retired in 26.7 (the switcher
    /// always follows the macOS accent) — skipping them on import keeps old
    /// exports from re-planting dead keys.
    nonisolated static let exportExcludedKeys: Set<String> = [
        "Switcher.disabledSymbolicHotKeys",
        "Switcher.recentlyClosed",
        "Switcher.accentChoice",
        "Switcher.customAccentHex",
        "Switcher.customCommitSoundFilename",
        // `$schema` is the editor's schema pointer in the config file, not a
        // setting — never store or re-export it.
        "Switcher.$schema",
    ]

    /// File extension of legacy exported settings documents. Still accepted by
    /// the import panel; no longer written.
    nonisolated static let exportFileExtension = "cmdtab"

    /// Identifier of the exported UTI declared in Info.plist
    /// (`UTExportedTypeDeclarations`). Kept so old `.cmdtab` files retain their
    /// icon and stay openable in the import panel.
    nonisolated static let exportUTIIdentifier = "pro.bettercmdtab.settings"

    /// Default file name (no extension — the save panel appends `.json` from
    /// the content type) like `bettercmdtab-settings-2026-05-29`.
    static var exportDefaultBaseName: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "bettercmdtab-settings-\(formatter.string(from: Date()))"
    }

    enum SettingsImportError: LocalizedError {
        /// Not JSON, not our envelope, or the values block is missing.
        case malformed
        /// The file was written by a newer app version using a format this
        /// build can't safely read.
        case unsupportedVersion(Int)

        var errorDescription: String? {
            switch self {
            case .malformed:
                return String(localized: "This file isn't a valid BetterCmdTab settings export.")
            case .unsupportedVersion(let v):
                return String(localized: "This settings file uses a newer format (version \(v)) than this version of BetterCmdTab can read. Update the app and try again.")
            }
        }
    }

    /// Every stored setting as a flat `key → value` map with the `Switcher.`
    /// prefix stripped. `nonisolated` because the config-file sync serializes
    /// on a background queue; this touches only `UserDefaults` (thread-safe).
    nonisolated static func flatSettingsSnapshot() -> [String: Any] {
        let defaults = UserDefaults.standard
        var values: [String: Any] = [:]
        for (key, value) in defaults.dictionaryRepresentation()
        where key.hasPrefix(exportKeyPrefix) && !exportExcludedKeys.contains(key) {
            // Guard against any non-JSON value sneaking in (shouldn't happen for
            // our plist-typed keys, but keep the export robust).
            if JSONSerialization.isValidJSONObject([value]) {
                values[String(key.dropFirst(exportKeyPrefix.count))] = value
            }
        }
        return values
    }

    /// Pretty-printed, key-sorted flat JSON for the export panel and the
    /// config file. `.sortedKeys` keeps the bytes deterministic — the config
    /// sync's echo guard compares raw data.
    nonisolated static func exportedJSONData() throws -> Data {
        try JSONSerialization.data(
            withJSONObject: flatSettingsSnapshot(),
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    /// JSON Schema (draft 2020-12) for the flat config format, derived from a
    /// snapshot instead of a hand-written key table: a schema generated by the
    /// build that writes the file cannot drift from it, and a new preference
    /// needs no schema edit. `additionalProperties` stays open and nothing is
    /// `required`, so a file written by any other version still validates —
    /// import tolerates unknown keys and keeps current values for absent ones.
    ///
    /// Descriptions, allowed values and clamp ranges come from
    /// `ConfigSchemaDocs`, so a documented key is completable and hoverable
    /// even when this Mac has never stored it. Anything not in that table falls
    /// back to its snapshot type — undocumented, still valid.
    nonisolated static func settingsSchema(for values: [String: Any], version: String) -> [String: Any] {
        var properties: [String: Any] = [
            "$schema": [
                "type": "string",
                "description": "Location of this schema. Ignored as a setting.",
            ],
        ]
        for (key, doc) in ConfigSchemaDocs.byKey {
            properties[key] = doc.fragment
        }
        for (key, value) in values where properties[key] == nil {
            properties[key] = ["type": jsonSchemaType(of: value)]
        }
        return [
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "title": "BetterCmdTab configuration",
            "description": "Generated by BetterCmdTab \(version). Keys mirror the Switcher.* preferences (prefix stripped); unknown keys are ignored, absent keys keep their current value.",
            "type": "object",
            "additionalProperties": true,
            "properties": properties,
        ]
    }

    /// Deterministic bytes for the sidecar schema file.
    nonisolated static func settingsSchemaData(version: String = AppInfo.appVersion) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: settingsSchema(for: flatSettingsSnapshot(), version: version),
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    /// Values reaching here are plist scalars that already passed
    /// `isValidJSONObject`, so the fallthrough is a dictionary.
    private nonisolated static func jsonSchemaType(of value: Any) -> String {
        switch value {
        case let number as NSNumber:
            if CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID() { return "boolean" }
            return CFNumberIsFloatType(number as CFNumber) ? "number" : "integer"
        case is String: return "string"
        case is [Any]: return "array"
        default: return "object"
        }
    }

    /// Replace the stored `Switcher.*` settings with those in `data`, then
    /// refresh the in-memory published values. Unknown keys outside our prefix
    /// are ignored. Throws `SettingsImportError` on a malformed or
    /// newer-than-supported file. Keys absent from the file keep their current
    /// value (a partial import, not a wipe).
    func importSettings(from data: Data) throws {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw SettingsImportError.malformed
        }
        let values: [String: Any]
        if root["values"] != nil || root["schemaVersion"] != nil || root["app"] != nil {
            // Legacy .cmdtab envelope: {app, schemaVersion, values}. No
            // preference is named after any of those three keys, so their
            // presence is the discriminator.
            let version = (root["schemaVersion"] as? Int) ?? 0
            guard version >= 1 else { throw SettingsImportError.malformed }
            guard version <= Self.exportSchemaVersion else {
                throw SettingsImportError.unsupportedVersion(version)
            }
            guard let envelopeValues = root["values"] as? [String: Any] else {
                throw SettingsImportError.malformed
            }
            values = envelopeValues
        } else {
            // Flat format: bare keys get the prefix; already-prefixed keys
            // pass through, so either spelling works in a hand-written file.
            values = Dictionary(
                root.map { key, value in
                    (key.hasPrefix(Self.exportKeyPrefix) ? key : Self.exportKeyPrefix + key, value)
                },
                uniquingKeysWith: { _, new in new }
            )
        }

        let defaults = UserDefaults.standard
        for (key, value) in values
        where key.hasPrefix(Self.exportKeyPrefix) && !Self.exportExcludedKeys.contains(key) {
            // Only write valid property-list values. A hand-crafted or corrupted
            // file can carry a JSON `null` (bridged to `NSNull`) or some other
            // non-plist object; `UserDefaults.set` raises an uncatchable
            // `NSInvalidArgumentException` ("non-property-list object") on those,
            // which would crash the app. Skip anything that isn't plist-safe —
            // the key keeps its current value and the rest of the import applies.
            guard PropertyListSerialization.propertyList(value, isValidFor: .binary) else { continue }
            defaults.set(value, forKey: key)
        }
        // Pre-#57 exports carry only the legacy `currentSpaceOnly` bool. Clear
        // any locally stored `spaceScope` so the reload's legacy fallback
        // derives the scope from the imported bool instead of keeping this
        // machine's stale enum value.
        if values[Preferences.Keys.currentSpaceOnly] != nil, values[Preferences.Keys.spaceScope] == nil {
            defaults.removeObject(forKey: Preferences.Keys.spaceScope)
        }
        // A pre-#105 export has only the preset string. Remove this Mac's newer
        // continuous value so reload migrates the imported preset instead of
        // correctly-but-surprisingly preferring the pre-existing new key.
        if values[Preferences.Keys.panelSize] != nil, values[Preferences.Keys.panelScalePercent] == nil {
            defaults.removeObject(forKey: Preferences.Keys.panelScalePercent)
        }
        reloadFromDefaults()
        // The import may have introduced scoped shortcuts with ids that didn't
        // exist at launch; install their Carbon handlers now (idempotent) so a
        // freshly-recorded trigger actually opens the switcher instead of being
        // registered with no handler — a dead, key-swallowing combo until relaunch.
        ScopedSwitch.installHandlers()
    }
}
