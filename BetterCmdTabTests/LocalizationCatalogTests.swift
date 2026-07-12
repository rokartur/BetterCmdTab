import Foundation
import Testing

/// Guards the Localizable.xcstrings contract: every key ships translated in all
/// five locales with matching format specifiers, so catalog drift fails the
/// suite instead of silently rendering English in shipped builds (#95).
@Suite("Localization catalog")
struct LocalizationCatalogTests {

    private static let locales = ["de", "es", "fr", "pl", "zh-Hans"]

    private struct CatalogError: Error, CustomStringConvertible {
        let description: String
    }

    /// The .xcstrings is not copied into the test bundle; read it off the
    /// checkout relative to this source file (repo-root/BetterCmdTab/…).
    private static func catalog() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("BetterCmdTab/Localizable.xcstrings")
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CatalogError(description: "catalog root is not a JSON object")
        }
        return root
    }

    private static func strings() throws -> [String: [String: Any]] {
        guard let strings = try catalog()["strings"] as? [String: [String: Any]] else {
            throw CatalogError(description: "catalog has no strings dictionary")
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
        let root = try Self.catalog()
        #expect(root["sourceLanguage"] as? String == "en")
        let strings = try Self.strings()
        #expect(!strings.isEmpty)
        for (key, entry) in strings {
            for locale in Self.locales {
                if let value = Self.translation(entry, locale) {
                    #expect(!value.isEmpty, "empty \(locale) translation for \(key)")
                }
            }
        }
    }

    @Test("every key is translated in all five locales")
    func allLocalesFullyTranslated() throws {
        let strings = try Self.strings()
        for locale in Self.locales {
            let missing = strings
                .filter { Self.translation($0.value, locale) == nil }
                .keys.sorted()
            #expect(missing.isEmpty, "\(locale) is missing \(missing.count) keys, e.g. \(missing.prefix(5))")
        }
    }

    @Test("format specifiers match the source key in every locale")
    func formatSpecifiersMatchAcrossLocales() throws {
        let strings = try Self.strings()
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
