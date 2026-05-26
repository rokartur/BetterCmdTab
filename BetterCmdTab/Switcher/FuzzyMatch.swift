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
}
