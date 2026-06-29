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

    /// `Switcher.*` keys that are machine-local state, not preferences —
    /// excluded from both export and import. `disabledSymbolicHotKeys` is the
    /// crash-heal record of which native hotkeys THIS machine has disabled
    /// (importing another Mac's record could leave native ⌘Tab dead after a
    /// crash); `recentlyClosed` is session history.
    static let exportExcludedKeys: Set<String> = [
        "Switcher.disabledSymbolicHotKeys",
        "Switcher.recentlyClosed",
    ]

    /// File extension for exported settings documents.
    static let exportFileExtension = "cmdtab"

    /// Identifier of the exported UTI declared in Info.plist
    /// (`UTExportedTypeDeclarations`). Used to drive the save/open panels so the
    /// system appends the right extension exactly once and shows the doc icon.
    static let exportUTIIdentifier = "pro.bettercmdtab.settings"

    /// Default file name (no extension — the save panel appends `.cmdtab` from
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

    /// A versioned, JSON-serializable snapshot of every stored setting.
    func exportedSettings() -> [String: Any] {
        let defaults = UserDefaults.standard
        var values: [String: Any] = [:]
        for (key, value) in defaults.dictionaryRepresentation()
        where key.hasPrefix(Self.exportKeyPrefix) && !Self.exportExcludedKeys.contains(key) {
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
        reloadFromDefaults()
        // The import may have introduced scoped shortcuts with ids that didn't
        // exist at launch; install their Carbon handlers now (idempotent) so a
        // freshly-recorded trigger actually opens the switcher instead of being
        // registered with no handler — a dead, key-swallowing combo until relaunch.
        ScopedSwitch.installHandlers()
    }
}
