import Testing
@testable import BetterCmdTab

@Suite("Quick-jump mappings")
struct QuickJumpMappingTests {
    @Test func normalizesCaseAndWhitespace() throws {
        let mapping = try #require(QuickJumpMapping(bundleID: "com.apple.Safari", letter: " S "))
        #expect(mapping.letter == "s")
        #expect(mapping.dictionary == ["bundleID": "com.apple.Safari", "letter": "s"])
    }

    @Test func rejectsNonAsciiOrMultipleCharacters() {
        #expect(QuickJumpMapping(bundleID: "com.apple.Safari", letter: "ss") == nil)
        #expect(QuickJumpMapping(bundleID: "com.apple.Safari", letter: "é") == nil)
        #expect(QuickJumpMapping(bundleID: "", letter: "s") == nil)
    }

    @Test func normalizationKeepsFirstUniqueAppAndLetter() throws {
        let safari = try #require(QuickJumpMapping(bundleID: "com.apple.Safari", letter: "s"))
        let safariAgain = try #require(QuickJumpMapping(bundleID: "com.apple.Safari", letter: "v"))
        let slack = try #require(QuickJumpMapping(bundleID: "com.tinyspeck.slackmacgap", letter: "s"))
        let vscode = try #require(QuickJumpMapping(bundleID: "com.microsoft.VSCode", letter: "v"))
        #expect(Preferences.normalizeQuickJumpMappings([safari, safariAgain, slack, vscode]) == [safari, vscode])
    }
}
