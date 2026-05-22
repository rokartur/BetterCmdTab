import Foundation

enum RowLabels {
    static let reserved: Set<Character> = ["w", "m", "h", "q"]
    static let suffixAlphabet: [Character] = Array("abcdefgijklnoprstuvxyz")

    struct Input {
        let appName: String
        let windowTitle: String
    }

    static func labels(for rows: [SwitcherRow]) -> [String] {
        labels(forInputs: rows.map { Input(appName: $0.appName, windowTitle: $0.windowTitle) })
    }

    static func labels(forInputs rows: [Input]) -> [String] {
        var labels = [String](repeating: "", count: rows.count)
        guard !rows.isEmpty else { return labels }

        var firstLetterCount: [Character: Int] = [:]
        var firstLetters = [Character?](repeating: nil, count: rows.count)
        for i in 0..<rows.count {
            let c = firstAvailableLetter(rows[i].appName)
            firstLetters[i] = c
            if let c { firstLetterCount[c, default: 0] += 1 }
        }

        for i in 0..<rows.count {
            guard let first = firstLetters[i] else {
                labels[i] = ""
                continue
            }
            if (firstLetterCount[first] ?? 0) == 1 {
                labels[i] = String(first)
            } else if let secondary = secondaryLetter(rows[i], skipping: first) {
                labels[i] = String(first) + String(secondary)
            } else {
                labels[i] = String(first)
            }
        }

        disambiguateDuplicates(&labels)
        return labels
    }

    private static func disambiguateDuplicates(_ labels: inout [String]) {
        var groups: [String: [Int]] = [:]
        for (i, l) in labels.enumerated() where !l.isEmpty {
            groups[l, default: []].append(i)
        }
        for (base, indices) in groups where indices.count > 1 {
            let groupSet = Set(indices)
            var used = Set<String>()
            for (j, l) in labels.enumerated() {
                if groupSet.contains(j) { continue }
                if !l.isEmpty { used.insert(l) }
            }
            for idx in indices {
                for suffix in suffixAlphabet {
                    let candidate = base + String(suffix)
                    if !used.contains(candidate) {
                        labels[idx] = candidate
                        used.insert(candidate)
                        break
                    }
                }
            }
        }
    }

    private static func firstAvailableLetter(_ raw: String) -> Character? {
        let folded = raw.folding(options: .diacriticInsensitive, locale: nil).lowercased()
        for c in folded {
            if c.isASCII, c.isLetter, !reserved.contains(c) { return c }
        }
        return nil
    }

    private static func secondaryLetter(_ row: Input, skipping first: Character) -> Character? {
        if !row.windowTitle.isEmpty {
            let folded = row.windowTitle.folding(options: .diacriticInsensitive, locale: nil).lowercased()
            for c in folded {
                if c.isASCII, c.isLetter, c != first, !reserved.contains(c) { return c }
            }
        }
        let appFolded = row.appName.folding(options: .diacriticInsensitive, locale: nil).lowercased()
        var seenFirst = false
        for c in appFolded {
            if c.isASCII, c.isLetter, !reserved.contains(c) {
                if !seenFirst { seenFirst = true; continue }
                if c != first { return c }
            }
        }
        return nil
    }
}
