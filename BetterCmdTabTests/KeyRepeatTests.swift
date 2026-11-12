import Testing

@testable import BetterCmdTab

@Suite("Held-key repeat under Secure Event Input (#291)")
struct KeyRepeatTests {
    @Test func navigationStepsRepeat() {
        let steps: [HotkeyTap.Event] = [
            .nextRow, .prevRow, .spatialLeft, .spatialRight,
            .tabNext, .tabPrev, .nextApp, .prevApp, .nextWindow, .prevWindow,
        ]
        for event in steps {
            #expect(HotkeyTap.repeatsWhileHeld(event), "\(event)")
        }
    }

    @Test func actionsFireOncePerPress() {
        let actions: [HotkeyTap.Event] = [
            .commit, .commitTab, .escape, .closeWindow, .quitApp, .forceQuitApp,
            .toggleSearch, .enterTabDrill, .exitTabDrill, .letterInputKey(0),
        ]
        for event in actions {
            #expect(!HotkeyTap.repeatsWhileHeld(event), "\(event)")
        }
    }

    @Test func systemKeyRepeatOffStartsNoRepeat() {
        #expect(HotkeyTap.repeatCadence(initialTicks: 15, repeatTicks: 300) == nil)
        #expect(HotkeyTap.repeatCadence(initialTicks: 15, repeatTicks: 2) != nil)
    }
}
