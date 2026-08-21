import Testing
@testable import BetterCmdTab

/// Covers apps left out of letter-hint generation (#183 follow-up): an excluded
/// app gets no label and reserves no letter, and the list is normalized the same
/// way the other bundle-ID lists are.
@Suite("Letter-hint exclusions")
struct LetterHintExclusionTests {

    private func input(
        _ appName: String,
        _ windowTitle: String = "",
        bundleID: String? = nil
    ) -> RowLabels.Input {
        RowLabels.Input(appName: appName, windowTitle: windowTitle, bundleID: bundleID)
    }

    @Test("an excluded app gets an empty label")
    func excludedAppHasNoLabel() {
        let labels = RowLabels.labels(
            forInputs: [
                input("Safari", bundleID: "com.apple.Safari"),
                input("Alacritty", bundleID: "org.alacritty"),
            ],
            excludedBundleIDs: ["org.alacritty"]
        )
        #expect(labels[0] == "s")
        #expect(labels[1] == "")
    }

    @Test("excluding one side of a collision frees the letter for the other")
    func exclusionFreesTheLetter() {
        // Alfred and Alacritty both want "a"; without exclusion both fall to two
        // letters. Excluding Alacritty leaves Alfred a bare "a".
        let collided = RowLabels.labels(forInputs: [
            input("Alfred", bundleID: "com.runningwithcrayons.Alfred"),
            input("Alacritty", bundleID: "org.alacritty"),
        ])
        #expect(collided[0].count > 1)
        #expect(collided[1].count > 1)

        let freed = RowLabels.labels(
            forInputs: [
                input("Alfred", bundleID: "com.runningwithcrayons.Alfred"),
                input("Alacritty", bundleID: "org.alacritty"),
            ],
            excludedBundleIDs: ["org.alacritty"]
        )
        #expect(freed[0] == "a")
        #expect(freed[1] == "")
    }

    @Test("an explicit custom letter wins over exclusion")
    func customMappingBeatsExclusion() {
        let labels = RowLabels.labels(
            forInputs: [input("Alacritty", bundleID: "org.alacritty")],
            customMappings: ["org.alacritty": "q"],
            excludedBundleIDs: ["org.alacritty"]
        )
        #expect(labels[0] == "q")
    }

    @Test("a row with no bundle ID is never excluded")
    func rowWithoutBundleIDUnaffected() {
        let labels = RowLabels.labels(
            forInputs: [input("Safari", bundleID: nil)],
            excludedBundleIDs: ["com.apple.Safari"]
        )
        #expect(labels[0] == "s")
    }

    @Test("the exclusion list trims blanks and drops duplicates, keeping order")
    func normalizationTrimsAndDedupes() {
        let normalized = Preferences.normalizeBundleIDList([
            " org.alacritty ", "com.apple.Safari", "org.alacritty", "   ", "",
        ])
        #expect(normalized == ["org.alacritty", "com.apple.Safari"])
    }
}
