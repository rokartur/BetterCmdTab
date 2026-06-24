import Foundation

enum FuzzyMatch {
    /// True when every character of `query` appears, in order but not
    /// necessarily contiguous, within `appName` OR `windowTitle`. Case- and
    /// diacritic-insensitive; whitespace in the query is ignored so "git hub"
    /// still matches "GitHub". An empty query matches everything.
    static func matches(query: String, appName: String, windowTitle: String) -> Bool {
        matchesFolded(
            foldedQuery: fold(query),
            foldedAppName: fold(appName),
            foldedWindowTitle: fold(windowTitle)
        )
    }

    /// Same test as `matches`, but with every string already `fold`-ed by the
    /// caller. The search hot path folds each row's fields once when the row
    /// set changes and reuses them across keystrokes, instead of re-folding all
    /// rows on every character typed.
    static func matchesFolded(foldedQuery: String, foldedAppName: String, foldedWindowTitle: String) -> Bool {
        let q = foldedQuery.filter { !$0.isWhitespace }
        guard !q.isEmpty else { return true }
        return isSubsequence(q, of: foldedAppName) || isSubsequence(q, of: foldedWindowTitle)
    }

    static func fold(_ s: String) -> String {
        s.folding(options: .diacriticInsensitive, locale: nil).lowercased()
    }

    /// Whether `needle`'s characters appear in order within `haystack`.
    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        guard !needle.isEmpty else { return true }
        var iterator = needle.makeIterator()
        var current = iterator.next()
        for ch in haystack where ch == current {
            current = iterator.next()
            if current == nil { return true }
        }
        return current == nil
    }

    // MARK: - Ranking

    // Tier bases for `scoreFolded`. Gaps are a uniform 1000 so the intra-tier
    // refinement (clamped to 0..<1000) can never push one tier past another.
    // A contiguous substring deliberately dominates a scattered subsequence —
    // that's what separates "microsoft teams" (substring "team") from
    // "telegram" (subsequence only) for the query "team".
    private static let appPrefixBase = 7000
    private static let appWordSubstrBase = 6000
    private static let appSubstrBase = 5000
    private static let titleWordSubstrBase = 4000
    private static let titleSubstrBase = 3000
    private static let appSubseqBase = 2000
    private static let titleSubseqBase = 1000

    /// Ranking score for `foldedQuery` against one row's folded fields, or nil
    /// if it matches neither. Higher = better. Same fold/whitespace contract as
    /// `matchesFolded`; an empty query is neutral (0). Caller folds once so the
    /// search hot path doesn't re-fold every row on each keystroke.
    ///
    /// Scoring a whole row set per keystroke should use `prepareQuery` once and
    /// call `scoreFolded(preparedQuery:foldedAppName:foldedWindowTitle:)` per row
    /// instead — this overload re-strips and re-arrays the query on every call.
    static func scoreFolded(foldedQuery: String, foldedAppName: String, foldedWindowTitle: String) -> Int? {
        scoreFolded(preparedQuery: prepareQuery(foldedQuery),
                    foldedAppName: foldedAppName, foldedWindowTitle: foldedWindowTitle)
    }

    /// A folded query stripped of whitespace, plus its characters as an array —
    /// the per-keystroke-invariant inputs `scoreFolded` needs. Build once before
    /// scoring a row set so the strip + `Array` allocation isn't repeated per row.
    typealias PreparedQuery = (q: String, qChars: [Character])

    static func prepareQuery(_ foldedQuery: String) -> PreparedQuery {
        let q = foldedQuery.filter { !$0.isWhitespace }
        return (q, Array(q))
    }

    /// Hot-path ranking: scores one row against a query already prepared with
    /// `prepareQuery`, avoiding the per-row whitespace-strip + `Array` allocation.
    static func scoreFolded(preparedQuery: PreparedQuery, foldedAppName: String, foldedWindowTitle: String) -> Int? {
        let (q, qChars) = preparedQuery
        guard !q.isEmpty else { return 0 }
        let app = fieldScore(q, qChars, in: foldedAppName,
                             prefixBase: appPrefixBase, wordSubstrBase: appWordSubstrBase,
                             substrBase: appSubstrBase, subseqBase: appSubseqBase)
        let title = fieldScore(q, qChars, in: foldedWindowTitle,
                               // A title prefix lands in the title word-boundary tier;
                               // app matches always outrank title matches of the same shape.
                               prefixBase: titleWordSubstrBase, wordSubstrBase: titleWordSubstrBase,
                               substrBase: titleSubstrBase, subseqBase: titleSubseqBase)
        if let app, let title { return max(app, title) }
        return app ?? title
    }

    /// Best tier `q` reaches within one field, plus a bounded refinement, or nil
    /// if `q` isn't even a subsequence of `haystack`.
    private static func fieldScore(_ q: String, _ qChars: [Character], in haystack: String,
                                   prefixBase: Int, wordSubstrBase: Int,
                                   substrBase: Int, subseqBase: Int) -> Int? {
        guard !haystack.isEmpty else { return nil }
        if let r = haystack.range(of: q, options: [.literal]) {
            let start = haystack.distance(from: haystack.startIndex, to: r.lowerBound)
            let refine = refinement(startIndex: start, consecutiveRun: qChars.count - 1)
            if start == 0 { return prefixBase + refine }
            let before = haystack[haystack.index(before: r.lowerBound)]
            return (isWordBoundary(before) ? wordSubstrBase : substrBase) + refine
        }
        guard let refine = subsequenceRefinement(qChars, in: haystack) else { return nil }
        return subseqBase + refine
    }

    /// Greedy left-to-right subsequence walk that also reports the first-match
    /// position and how many matched characters were adjacent, for refinement.
    /// Returns nil if not a subsequence.
    private static func subsequenceRefinement(_ needle: [Character], in haystack: String) -> Int? {
        guard !needle.isEmpty else { return 0 }
        var nIdx = 0
        var firstPos = -1
        var prevMatchPos = -2
        var consecutive = 0
        var pos = 0
        for ch in haystack {
            if ch == needle[nIdx] {
                if firstPos < 0 { firstPos = pos }
                if pos == prevMatchPos + 1 { consecutive += 1 }
                prevMatchPos = pos
                nIdx += 1
                if nIdx == needle.count { break }
            }
            pos += 1
        }
        guard nIdx == needle.count else { return nil }
        return refinement(startIndex: firstPos, consecutiveRun: consecutive)
    }

    /// Intra-tier ordering: earlier matches and more-adjacent runs rank higher.
    /// Clamped to 0..<1000 so it stays inside a single tier gap.
    private static func refinement(startIndex: Int, consecutiveRun: Int) -> Int {
        let positionBonus = max(0, 300 - startIndex * 10)
        let runBonus = min(consecutiveRun * 100, 600)
        return min(positionBonus + runBonus, 999)
    }

    /// On folded (lowercased) strings a word boundary is any non-alphanumeric
    /// char (space, "-", "/", …). camelCase boundaries are lost to folding.
    private static func isWordBoundary(_ c: Character) -> Bool {
        !c.isLetter && !c.isNumber
    }
}
