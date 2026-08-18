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
        return labels(
            forInputs: rows.map {
                Input(appName: $0.appName, windowTitle: $0.windowTitle, bundleID: $0.bundleIdentifier)
            },
            customMappings: mappings
        )
    }

    static func labels(
        forInputs rows: [Input],
        customMappings: [String: Character] = [:]
    ) -> [String] {
        var labels = [String](repeating: "", count: rows.count)
        guard !rows.isEmpty else { return labels }

        // Snapshot the reserved set once per call (one lock acquisition) and thread
        // it through the per-character loops below. Custom letters also stay out
        // of dynamically-generated labels, so opening another app can never steal
        // a persistent mapping.
        let reserved = Self.reserved.union(customMappings.values)

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

        var firstLetterCount: [Character: Int] = [:]
        var firstLetters = [Character?](repeating: nil, count: rows.count)
        for i in rows.indices where !customIndices.contains(i) {
            let c = firstAvailableLetter(rows[i].appName, reserved: reserved)
            firstLetters[i] = c
            if let c { firstLetterCount[c, default: 0] += 1 }
        }

        for i in rows.indices where !customIndices.contains(i) {
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

    private static func firstAvailableLetter(_ raw: String, reserved: Set<Character>) -> Character? {
        let folded = raw.folding(options: .diacriticInsensitive, locale: nil).lowercased()
        for c in folded {
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
