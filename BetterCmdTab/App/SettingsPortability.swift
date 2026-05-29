import Foundation

/// Export/import of all user settings to a portable JSON file (no iCloud, no
/// network — a plain file the user saves and restores or shares between Macs).
///
/// The payload is the whole `Switcher.*` `UserDefaults` namespace, read
/// generically rather than key-by-key, so every preference is covered —
/// including app rules, pinned apps, sort order, and any keys added later —
/// without this code having to enumerate them. The switcher *trigger* hotkeys
/// (⌘Tab / ⌘`) live under the BetterShortcuts package's own keys and are not
/// part of this namespace, so they are intentionally not carried over.
extension Preferences {
    /// Bumped only on a breaking change to the envelope shape. Importing a file
    /// with a higher version than we understand is refused (forward-incompat);
    /// a lower or equal version is read.
    static let exportSchemaVersion = 1

    /// Every persisted setting lives under this `UserDefaults` key prefix.
    static let exportKeyPrefix = "Switcher."

    /// File extension for exported settings documents.
    static let exportFileExtension = "bettercmdtab"

    enum SettingsImportError: LocalizedError {
        /// Not JSON, not our envelope, or the values block is missing.
        case malformed
        /// The file was written by a newer app version using a format this
        /// build can't safely read.
        case unsupportedVersion(Int)

        var errorDescription: String? {
            switch self {
            case .malformed:
                return "This file isn't a valid BetterCmdTab settings export."
            case .unsupportedVersion(let v):
                return "This settings file uses a newer format (version \(v)) than this version of BetterCmdTab can read. Update the app and try again."
            }
        }
    }

    /// A versioned, JSON-serializable snapshot of every stored setting.
    func exportedSettings() -> [String: Any] {
        let defaults = UserDefaults.standard
        var values: [String: Any] = [:]
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix(Self.exportKeyPrefix) {
            // Guard against any non-JSON value sneaking in (shouldn't happen for
            // our plist-typed keys, but keep the export robust).
            if JSONSerialization.isValidJSONObject([value]) {
                values[key] = value
            }
        }
        return [
            "app": "BetterCmdTab",
            "schemaVersion": Self.exportSchemaVersion,
            "values": values,
        ]
    }

    /// Pretty-printed, key-sorted JSON for writing to a file.
    func exportedJSONData() throws -> Data {
        try JSONSerialization.data(
            withJSONObject: exportedSettings(),
            options: [.prettyPrinted, .sortedKeys]
        )
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
        let version = (root["schemaVersion"] as? Int) ?? 0
        guard version >= 1 else { throw SettingsImportError.malformed }
        guard version <= Self.exportSchemaVersion else {
            throw SettingsImportError.unsupportedVersion(version)
        }
        guard let values = root["values"] as? [String: Any] else {
            throw SettingsImportError.malformed
        }

        let defaults = UserDefaults.standard
        for (key, value) in values where key.hasPrefix(Self.exportKeyPrefix) {
            defaults.set(value, forKey: key)
        }
        reloadFromDefaults()
    }
}
