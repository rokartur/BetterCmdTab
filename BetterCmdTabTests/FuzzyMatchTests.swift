import Testing
@testable import BetterCmdTab

@Suite("FuzzyMatch")
struct FuzzyMatchTests {

    @Test("empty query matches everything")
    func emptyQuery() {
        #expect(FuzzyMatch.matches(query: "", appName: "Safari", windowTitle: "Apple"))
        #expect(FuzzyMatch.matches(query: "   ", appName: "Safari", windowTitle: ""))
    }

    @Test("subsequence matches against app name")
    func appNameSubsequence() {
        #expect(FuzzyMatch.matches(query: "gh", appName: "GitHub", windowTitle: ""))
        #expect(FuzzyMatch.matches(query: "sfri", appName: "Safari", windowTitle: ""))
    }

    @Test("matches against window title when app name does not match")
    func windowTitleSubsequence() {
        #expect(FuzzyMatch.matches(query: "invoice", appName: "Preview", windowTitle: "Invoice 2026.pdf"))
        #expect(!FuzzyMatch.matches(query: "invoice", appName: "Preview", windowTitle: "Receipt.pdf"))
    }

    @Test("case and diacritics are ignored")
    func caseAndDiacritics() {
        #expect(FuzzyMatch.matches(query: "CAFE", appName: "Café", windowTitle: ""))
        #expect(FuzzyMatch.matches(query: "café", appName: "cafe bar", windowTitle: ""))
    }

    @Test("whitespace in the query is ignored")
    func whitespaceIgnored() {
        #expect(FuzzyMatch.matches(query: "git hub", appName: "GitHub", windowTitle: ""))
    }

    @Test("non-subsequence does not match")
    func noMatch() {
        #expect(!FuzzyMatch.matches(query: "xyz", appName: "Safari", windowTitle: "Terminal"))
        // Out-of-order characters are not a subsequence.
        #expect(!FuzzyMatch.matches(query: "bha", appName: "Safari", windowTitle: ""))
    }

    // MARK: - Ranking (scoreFolded)

    private func score(_ query: String, app: String, title: String = "") -> Int? {
        FuzzyMatch.scoreFolded(
            foldedQuery: FuzzyMatch.fold(query),
            foldedAppName: FuzzyMatch.fold(app),
            foldedWindowTitle: FuzzyMatch.fold(title)
        )
    }

    /// Regression guard for the reported bug: typing "team" selected Chrome and
    /// buried Microsoft Teams. The closest match must rank first.
    @Test("ranks the closest match first: team → Teams > Telegram > Chrome")
    func ranksBestMatchFirst() throws {
        let teams = try #require(score("team", app: "Microsoft Teams"))
        let telegram = try #require(score("team", app: "Telegram"))
        // Chrome only matches via a scattered subsequence of its window title.
        let chrome = try #require(score("team", app: "Google Chrome", title: "Stream a movie"))
        #expect(teams > telegram)
        #expect(telegram > chrome)
    }

    @Test("no match scores nil")
    func noMatchScoresNil() {
        #expect(score("bha", app: "Safari") == nil)
        #expect(score("xyz", app: "Safari", title: "Terminal") == nil)
    }

    @Test("a contiguous substring outranks a scattered subsequence")
    func substringBeatsSubsequence() throws {
        let substring = try #require(score("team", app: "Microsoft Teams"))
        let subsequence = try #require(score("team", app: "Telegram"))
        #expect(substring > subsequence)
    }

    @Test("an app-name match outranks a window-title-only match")
    func appNameBeatsTitleOnly() throws {
        let appHit = try #require(score("doc", app: "Docs"))
        let titleHit = try #require(score("doc", app: "Photos", title: "my document"))
        #expect(appHit > titleHit)
    }

    @Test("prefix and word-boundary matches outrank a mid-word substring")
    func prefixAndBoundaryOutrankMidWord() throws {
        let prefix = try #require(score("saf", app: "Safari"))
        let midWord = try #require(score("ari", app: "Safari"))
        #expect(prefix > midWord)

        let boundary = try #require(score("teams", app: "Microsoft Teams"))
        let plain = try #require(score("soft", app: "Microsoft Teams"))
        #expect(boundary > plain)
    }

    @Test("whitespace ignored; empty query is neutral")
    func scoreWhitespaceAndEmpty() throws {
        #expect(score("git hub", app: "GitHub") != nil)
        #expect(score("", app: "Safari", title: "Apple") == 0)
    }
}
