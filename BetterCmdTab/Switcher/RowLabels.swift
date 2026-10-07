import Foundation
import os

enum RowLabels {
    /// Letters reserved for in-panel action keys (close/minimize/hide/quit) plus
    /// the fixed ⌘F full-screen key — never assigned as letter-chain hints, so a
    /// hint is always reachable by typing it. Driven by the user's actual in-panel
    /// key bindings: `SwitcherController.pushPanelKeyBindings` recomputes it on
    /// launch and on every shortcut change (via `HotkeyTap.onReservedLettersChanged`),
    /// so rebinding an action frees its old letter back into the hint pool and
    /// reserves the new one. Defaults mirror the shipped bindings (w/m/h/q) + f
    /// until the first push. Lock-guarded: written on main, read during label
    /// generation which can run off-main.
    private static let reservedStore = OSAllocatedUnfairLock<Set<Character>>(
        initialState: ["w", "m", "h", "q", "f"]
    )
    static var reserved: Set<Character> { reservedStore.withLock { $0 } }
    static func setReserved(_ letters: Set<Character>) {
        reservedStore.withLock { $0 = letters }
    }

    /// User-chosen app mappings, mirrored from Preferences once on launch and
    /// whenever they change. Keeping a lock-backed snapshot here avoids a
    /// UserDefaults/main-actor read in the repeated row-label generation path.
    private static let customStore = OSAllocatedUnfairLock<[String: Character]>(initialState: [:])
    static func setCustomMappings(_ mappings: [String: Character]) {
        customStore.withLock { $0 = mappings }
    }

    /// Bundle IDs the user removed from letter hints, mirrored from Preferences
    /// the same way as `customStore`. A row for one of these apps gets an empty
    /// label — no hint, no reserved letter — so its letter stays free for others.
    private static let excludedStore = OSAllocatedUnfairLock<Set<String>>(initialState: [])
    static func setExcludedBundleIDs(_ ids: Set<String>) {
        excludedStore.withLock { $0 = ids }
    }

    /// Letters off the hand holding the trigger while one-hand hints are on (#198),
    /// set by `SwitcherController` for each switch session, empty otherwise.
    private static let offHandStore = OSAllocatedUnfairLock<Set<Character>>(initialState: [])
    static func setOffHandLetters(_ letters: Set<Character>) {
        offHandStore.withLock { $0 = letters }
    }

    /// Full a–z pool for disambiguation suffixes; reserved letters are filtered
    /// out at the point of use so the pool tracks the dynamic reservation.
    static let suffixAlphabet: [Character] = Array("abcdefghijklmnopqrstuvwxyz")

    struct Input {
        let appName: String
        let windowTitle: String
        let bundleID: String?

        init(appName: String, windowTitle: String, bundleID: String? = nil) {
            self.appName = appName
            self.windowTitle = windowTitle
            self.bundleID = bundleID
        }
    }

    static func labels(for rows: [SwitcherRow]) -> [String] {
        let mappings = customStore.withLock { $0 }
        let excluded = excludedStore.withLock { $0 }
        let offHand = offHandStore.withLock { $0 }
        return labels(
            forInputs: rows.map {
                Input(appName: $0.appName, windowTitle: $0.windowTitle, bundleID: $0.bundleIdentifier)
            },
            customMappings: mappings,
            excludedBundleIDs: excluded,
            offHandLetters: offHand
        )
    }

    static func labels(
        forInputs rows: [Input],
        customMappings: [String: Character] = [:],
        excludedBundleIDs: Set<String> = [],
        offHandLetters: Set<Character> = []
    ) -> [String] {
        var labels = [String](repeating: "", count: rows.count)
        guard !rows.isEmpty else { return labels }

        // Snapshot the reserved set once per call (one lock acquisition) and thread
        // it through the per-character loops below. Custom letters also stay out
        // of dynamically-generated labels, so opening another app can never steal
        // a persistent mapping.
        let reserved = Self.reserved.union(customMappings.values).union(offHandLetters)

        // A mapping targets the first (most-recent) row for its app. Other
        // windows of the same app keep ordinary dynamic labels, avoiding a
        // prefix chain that would delay the one-letter app jump.
        var customIndexByBundleID: [String: Int] = [:]
        for (index, row) in rows.enumerated() {
            guard let bundleID = row.bundleID,
                  customMappings[bundleID] != nil,
                  customIndexByBundleID[bundleID] == nil else { continue }
            customIndexByBundleID[bundleID] = index
        }
        let customIndices = Set(customIndexByBundleID.values)
        for (bundleID, index) in customIndexByBundleID {
            if let letter = customMappings[bundleID] { labels[index] = String(letter) }
        }

        // Excluded apps drop out of hint generation: their label stays empty and
        // they never enter the dynamic passes, so no letter is reserved on their
        // behalf and their first letter stays available to another app. A row the
        // user also gave a custom letter keeps that letter — an explicit mapping
        // wins over exclusion.
        var excludedIndices = Set<Int>()
        if !excludedBundleIDs.isEmpty {
            for (index, row) in rows.enumerated() where !customIndices.contains(index) {
                if let bundleID = row.bundleID, excludedBundleIDs.contains(bundleID) {
                    excludedIndices.insert(index)
                }
            }
        }
        let skipIndices = customIndices.union(excludedIndices)

        var firstLetterCount: [Character: Int] = [:]
        var firstLetters = [Character?](repeating: nil, count: rows.count)
        for i in rows.indices where !skipIndices.contains(i) {
            let c = firstAvailableLetter(rows[i].appName, reserved: reserved)
            firstLetters[i] = c
            if let c { firstLetterCount[c, default: 0] += 1 }
        }

        for i in rows.indices where !skipIndices.contains(i) {
            guard let first = firstLetters[i] else {
                labels[i] = ""
                continue
            }
            if (firstLetterCount[first] ?? 0) == 1 {
                labels[i] = String(first)
            } else if let secondary = secondaryLetter(rows[i], skipping: first, reserved: reserved) {
                labels[i] = String(first) + String(secondary)
            } else {
                labels[i] = String(first)
            }
        }

        disambiguateDuplicates(&labels, reserved: reserved)
        if !offHandLetters.isEmpty {
            assignFreeLetters(&labels, skipping: skipIndices, reserved: reserved)
        }
        return labels
    }

    private static func disambiguateDuplicates(_ labels: inout [String], reserved: Set<Character>) {
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
                for suffix in suffixAlphabet where !reserved.contains(suffix) {
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

    /// One-hand mode leaves names like "Hulu" with no on-hand letter; give each such
    /// row a letter no other label starts with, so every row stays reachable.
    private static func assignFreeLetters(_ labels: inout [String], skipping skipIndices: Set<Int>, reserved: Set<Character>) {
        let usedFirstLetters = Set(labels.compactMap(\.first))
        var freeLetters = suffixAlphabet.filter { !reserved.contains($0) && !usedFirstLetters.contains($0) }.makeIterator()
        for i in labels.indices where labels[i].isEmpty && !skipIndices.contains(i) {
            guard let letter = freeLetters.next() else { return }
            labels[i] = String(letter)
        }
    }

    /// Labels are rebuilt on every reveal and a transliteration costs ~30 µs per
    /// name, so each name is transliterated once.
    private static let latinNameStore = OSAllocatedUnfairLock<[String: String]>(initialState: [:])

    /// A name still non-ASCII after folding ("微信", "QQ音乐") hints by its
    /// transliteration, pinyin for Chinese (#187).
    private static func foldedAppName(_ raw: String) -> String {
        let folded = raw.folding(options: .diacriticInsensitive, locale: nil).lowercased()
        if folded.allSatisfy(\.isASCII) { return folded }
        if let cached = latinNameStore.withLock({ $0[raw] }) { return cached }
        guard let latin = raw.applyingTransform(.toLatin, reverse: false) else { return folded }
        let latinFolded = latin.folding(options: .diacriticInsensitive, locale: nil).lowercased()
        latinNameStore.withLock { $0[raw] = latinFolded }
        return latinFolded
    }

    private static func firstAvailableLetter(_ raw: String, reserved: Set<Character>) -> Character? {
        for c in foldedAppName(raw) {
            if c.isASCII, c.isLetter, !reserved.contains(c) { return c }
        }
        return nil
    }

    private static func secondaryLetter(_ row: Input, skipping first: Character, reserved: Set<Character>) -> Character? {
        if !row.windowTitle.isEmpty {
            let folded = row.windowTitle.folding(options: .diacriticInsensitive, locale: nil).lowercased()
            for c in folded {
                if c.isASCII, c.isLetter, c != first, !reserved.contains(c) { return c }
            }
        }
        var seenFirst = false
        for c in foldedAppName(row.appName) {
            if c.isASCII, c.isLetter, !reserved.contains(c) {
                if !seenFirst { seenFirst = true; continue }
                if c != first { return c }
            }
        }
        return nil
    }
}
