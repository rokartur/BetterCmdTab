import Testing
@testable import BetterCmdTab

@Suite("RowLabels")
struct RowLabelsTests {

    private func input(
        _ appName: String,
        _ windowTitle: String = "",
        bundleID: String? = nil
    ) -> RowLabels.Input {
        RowLabels.Input(appName: appName, windowTitle: windowTitle, bundleID: bundleID)
    }

    @Test("unique first letters produce single-letter labels")
    func uniqueFirstLetter() {
        let labels = RowLabels.labels(forInputs: [
            input("Safari"),
            input("Terminal"),
            input("Notes")
        ])
        #expect(labels == ["s", "t", "n"])
    }

    @Test("colliding first letters expand to two-letter labels using app name fallback")
    func collisionViaAppName() {
        let labels = RowLabels.labels(forInputs: [
            input("Slack"),
            input("Safari")
        ])
        // Both start with "s" → secondary letter from app name (Slack→l, Safari→a)
        #expect(labels[0].first == "s")
        #expect(labels[1].first == "s")
        #expect(labels[0].count == 2)
        #expect(labels[1].count == 2)
        #expect(labels[0] != labels[1])
    }

    @Test("collision prefers window-title letter when available")
    func collisionPrefersWindowTitle() {
        let labels = RowLabels.labels(forInputs: [
            input("Safari", "GitHub"),
            input("Slack")
        ])
        // "Safari" + window "GitHub" → secondary from "g" (first letter of title)
        #expect(labels[0] == "sg")
    }

    @Test("reserved letters (w m h q) skipped when picking first letter")
    func reservedFirstSkipped() {
        let labels = RowLabels.labels(forInputs: [
            input("Mail"),  // m is reserved → falls through to "a"
            input("Word")   // w is reserved → falls through to "o"
        ])
        #expect(labels == ["a", "o"])
    }

    @Test("f is reserved (⌘F full screen) and never a letter-chain target")
    func fReservedSkipped() {
        let labels = RowLabels.labels(forInputs: [
            input("Figma"),  // f is reserved → falls through to "i"
            input("Notes")   // n
        ])
        #expect(labels == ["i", "n"])
    }

    @Test("diacritics fold to ASCII counterparts")
    func diacriticFolding() {
        // .diacriticInsensitive strips combining marks but not ligatures or
        // strokes. "Café" → "Cafe" (é→e), but "Łódź" keeps Ł, ó, ź. The first
        // ASCII letter wins, so behavior is letter-skip + fold combined.
        let labels = RowLabels.labels(forInputs: [
            input("Café"),       // é folds → c
            input("Naïve")       // ï folds → n
        ])
        #expect(labels == ["c", "n"])
    }

    @Test("name with no usable letters returns empty label")
    func noLetters() {
        let labels = RowLabels.labels(forInputs: [
            input("123 456"),
            input("---")
        ])
        #expect(labels == ["", ""])
    }

    @Test("secondary letter skips reserved chars too")
    func secondaryAvoidsReserved() {
        // Both start with "s"; secondary from "smh" should skip 'm','h' (reserved) → 's' for both
        // Edge case: when secondary candidates all reserved, falls back to single letter.
        let labels = RowLabels.labels(forInputs: [
            input("Smhw"),
            input("Sxy")
        ])
        // First: 's', then 'm','h','w' all reserved → no secondary → "s"
        // Second: 's' available, secondary 'x'
        #expect(labels[0] == "s")
        #expect(labels[1] == "sx")
    }

    @Test("empty input array returns empty array")
    func empty() {
        let labels = RowLabels.labels(forInputs: [])
        #expect(labels.isEmpty)
    }

    @Test("custom mapping stays exact when another app would choose the same letter")
    func customMappingReservesItsLetter() {
        let labels = RowLabels.labels(
            forInputs: [
                input("Safari", bundleID: "com.apple.Safari"),
                input("Slack", bundleID: "com.tinyspeck.slackmacgap"),
            ],
            customMappings: ["com.apple.Safari": "s"]
        )
        #expect(labels[0] == "s")
        #expect(labels[1] == "l")
    }

    @Test("only the first window of a mapped app receives the stable letter")
    func customMappingTargetsFirstAppRow() {
        let labels = RowLabels.labels(
            forInputs: [
                input("Safari", "First", bundleID: "com.apple.Safari"),
                input("Safari", "Second", bundleID: "com.apple.Safari"),
            ],
            customMappings: ["com.apple.Safari": "s"]
        )
        #expect(labels[0] == "s")
        #expect(labels[1] != "s")
        #expect(!labels[1].hasPrefix("s"))
    }

    @Test("custom mapping may deliberately use an action-reserved letter")
    func customMappingCanUseReservedLetter() {
        let labels = RowLabels.labels(
            forInputs: [input("WhatsApp", bundleID: "net.whatsapp.WhatsApp")],
            customMappings: ["net.whatsapp.WhatsApp": "w"]
        )
        #expect(labels == ["w"])
    }
}
