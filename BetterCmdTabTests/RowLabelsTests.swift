import Testing
@testable import BetterCmdTab

@Suite("RowLabels")
struct RowLabelsTests {

    @Test("home-row pool gives each window its own single letter in panel order")
    func homeRowSingleLetters() {
        let rows = [
            RowLabels.Input(appName: "Arc", windowTitle: "GitHub"),
            RowLabels.Input(appName: "Arc", windowTitle: "Docs"),
            RowLabels.Input(appName: "Xcode", windowTitle: "Project"),
        ]
        let labels = RowLabels.labels(forInputs: rows, homeRowLetters: Array("asdfjkl"))
        #expect(labels == ["a", "s", "d"])
    }

    @Test("home-row pool skips reserved letters and custom app letters")
    func homeRowSkipsReservedAndCustom() {
        let rows = [
            RowLabels.Input(appName: "Arc", windowTitle: "", bundleID: "company.thebrowser.Browser"),
            RowLabels.Input(appName: "Notes", windowTitle: ""),
            RowLabels.Input(appName: "Mail", windowTitle: ""),
        ]
        // "f" is reserved by default for full screen.
        let labels = RowLabels.labels(
            forInputs: rows,
            customMappings: ["company.thebrowser.Browser": "s"],
            homeRowLetters: Array("fsad")
        )
        #expect(labels == ["s", "a", "d"])
    }

    @Test("rows past the end of the home-row pool get no hint")
    func homeRowPoolExhausted() {
        let rows = (0..<3).map { RowLabels.Input(appName: "App", windowTitle: "\($0)") }
        let labels = RowLabels.labels(forInputs: rows, homeRowLetters: Array("as"))
        #expect(labels == ["a", "s", ""])
    }

    @Test("without a home-row pool, windows of one app keep two-letter hints")
    func appNameHintsUnchanged() {
        let rows = [
            RowLabels.Input(appName: "Arc", windowTitle: "GitHub"),
            RowLabels.Input(appName: "Arc", windowTitle: "Docs"),
        ]
        #expect(RowLabels.labels(forInputs: rows) == ["ag", "ad"])
    }
}
