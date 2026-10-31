import Foundation
import Testing

/// Guards the string-catalog contract: every key ships translated in all supported
/// locales with matching format specifiers, so catalog drift fails the suite instead
/// of silently rendering English in shipped builds (#95).
@Suite("Localization catalog")
struct LocalizationCatalogTests {

    private static let locales = ["de", "es", "fr", "ja", "pl", "ru", "zh-Hans"]
    private static let catalogNames = ["Localizable", "InfoPlist"]

    private struct CatalogError: Error, CustomStringConvertible {
        let description: String
    }

    /// Catalogs are not copied into the test bundle; read them off the checkout
    /// relative to this source file.
    private static func repoFile(_ path: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(path)
    }

    private static func catalog(named name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: repoFile("BetterCmdTab/\(name).xcstrings"))
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CatalogError(description: "catalog root is not a JSON object")
        }
        return root
    }

    private static func strings(named name: String) throws -> [String: [String: Any]] {
        guard let strings = try catalog(named: name)["strings"] as? [String: [String: Any]] else {
            throw CatalogError(description: "\(name) catalog has no strings dictionary")
        }
        return strings
    }

    private static func translation(_ entry: [String: Any], _ locale: String) -> String? {
        guard let localizations = entry["localizations"] as? [String: Any],
              let localization = localizations[locale] as? [String: Any],
              let unit = localization["stringUnit"] as? [String: Any] else { return nil }
        return unit["value"] as? String
    }

    /// C-style format specifiers as Xcode extracts them (%lld, %@, positional %1$@, …).
    private static func specifiers(in string: String) -> [String] {
        let pattern = "%(?:\\d+\\$)?(?:lld|llu|ld|lu|[@dDuUxXoOfeEgGcCsSpaAF])"
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(string.startIndex..., in: string)
        return regex.matches(in: string, range: range)
            .map { (string as NSString).substring(with: $0.range) }
            .sorted()
    }

    @Test("catalog shape is sane")
    func catalogShapeIsSane() throws {
        for name in Self.catalogNames {
            let root = try Self.catalog(named: name)
            #expect(root["sourceLanguage"] as? String == "en", "\(name) sourceLanguage")
            #expect(!(try Self.strings(named: name)).isEmpty, "\(name) has no strings")
        }
        // A usage description keyed by its English sentence compiles and silently never
        // resolves; only document-type names are legitimately keyed by value.
        let valueKeyed: Set = ["BetterCmdTab Settings"]
        for key in try Self.strings(named: "InfoPlist").keys where !valueKeyed.contains(key) {
            #expect(!key.contains(" "), "InfoPlist key \(key) looks value-keyed; use the plist key name")
        }
    }

    @Test("every key is translated in all supported locales")
    func allLocalesFullyTranslated() throws {
        for name in Self.catalogNames {
            let strings = try Self.strings(named: name)
            // Without an "en" entry Xcode emits the key as its own value, so the prompt reads
            // "NSAppleEventsUsageDescription".
            let required = name == "InfoPlist" ? ["en"] + Self.locales : Self.locales
            for locale in required {
                let missing = strings
                    .filter { Self.translation($0.value, locale)?.isEmpty ?? true }
                    .keys.sorted()
                #expect(missing.isEmpty, "\(name): \(locale) is missing \(missing.count) keys, e.g. \(missing.prefix(5))")
            }
        }
    }

    /// `en.lproj/InfoPlist.strings` overrides Info.plist, so an edit to the build setting
    /// alone is a no-op for English users and nothing else would catch it.
    @Test("the English usage description matches the build setting")
    func englishUsageDescriptionMatchesBuildSetting() throws {
        let key = "NSAppleEventsUsageDescription"
        guard let entry = try Self.strings(named: "InfoPlist")[key],
              let english = Self.translation(entry, "en") else {
            throw CatalogError(description: "InfoPlist catalog has no en entry for \(key)")
        }
        let project = try String(contentsOf: Self.repoFile("BetterCmdTab.xcodeproj/project.pbxproj"), encoding: .utf8)
        let settings = project
            .split(separator: "\n")
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("INFOPLIST_KEY_\(key) = \""), trimmed.hasSuffix("\";") else { return nil }
                return String(trimmed.dropFirst("INFOPLIST_KEY_\(key) = \"".count).dropLast(2))
            }
        #expect(settings.count == 2, "expected one INFOPLIST_KEY_\(key) per configuration, found \(settings.count)")
        for setting in settings {
            #expect(setting == english, "build setting and catalog en value have drifted")
        }
    }

    @Test("format specifiers match the source key in every locale")
    func formatSpecifiersMatchAcrossLocales() throws {
        let strings = try Self.strings(named: "Localizable")
        for (key, entry) in strings {
            let expected = Self.specifiers(in: key)
            for locale in Self.locales {
                guard let value = Self.translation(entry, locale) else { continue }
                #expect(
                    Self.specifiers(in: value) == expected,
                    "\(locale) format specifiers differ from source for \(key)"
                )
            }
        }
    }
}
