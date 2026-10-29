import Foundation
import Testing

@testable import BetterCmdTab

/// Guards the checked-in copy of the config schema against the app that
/// generates it. `web/src/docs/config-schema.json` is copied by hand out of a
/// generated `~/.config/bettercmdtab/schema.json` (#117), so a reworded
/// description or a new documented key silently ships a docs page describing a
/// build nobody runs. Compare the copy to `ConfigSchemaDocs` instead of by eye.
@Suite("Config schema docs")
struct ConfigSchemaDocsTests {

    private struct SchemaError: Error, CustomStringConvertible {
        let description: String
    }

    /// The docs copy is not in the test bundle; read it off the checkout
    /// relative to this source file (repo-root/web/…), like the xcstrings.
    private static func publishedProperties() throws -> [String: [String: Any]] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("web/src/docs/config-schema.json")
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let properties = (root as? [String: Any])?["properties"] as? [String: [String: Any]] else {
            throw SchemaError(description: "published schema has no properties object")
        }
        return properties
    }

    /// Per-value labels are the Settings UI's localized `displayName`, so they
    /// depend on the generating Mac's language and are not part of the
    /// contract. Everything else in a fragment is.
    private static func stable(_ fragment: [String: Any]) -> NSDictionary {
        var out = fragment
        out.removeValue(forKey: "enumDescriptions")
        for (key, value) in out {
            if let nested = value as? [String: Any] { out[key] = stable(nested) }
        }
        return out as NSDictionary
    }

    @Test("every documented key ships in the published schema, byte for byte")
    func documentedKeysArePublished() throws {
        let published = try Self.publishedProperties()
        for (key, doc) in ConfigSchemaDocs.byKey {
            guard let property = published[key] else {
                Issue.record("\(key) is documented in ConfigSchemaDocs but missing from config-schema.json")
                continue
            }
            #expect(
                Self.stable(doc.fragment) == Self.stable(property),
                "\(key) drifted: regenerate the schema and copy it into web/src/docs/config-schema.json"
            )
        }
    }

    /// The other direction: a key deleted from the app must not linger in the
    /// docs. Undocumented keys are legitimate — `settingsSchema` types them off
    /// the generating Mac's snapshot — but they carry a type and nothing else.
    @Test("the published schema documents nothing the app no longer has")
    func publishedKeysAreDocumented() throws {
        for (key, property) in try Self.publishedProperties()
        where key != "$schema" && ConfigSchemaDocs.byKey[key] == nil {
            #expect(
                Array(property.keys) == ["type"],
                "\(key) has docs in config-schema.json but no ConfigSchemaDocs entry — stale copy"
            )
        }
    }
}
