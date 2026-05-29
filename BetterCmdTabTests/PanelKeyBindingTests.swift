import Foundation
import Testing
@testable import BetterCmdTab

/// Tests for rebindable in-panel action keys (#5): the default keycodes (must
/// stay W/M/H/Q so existing users see no change) and the normalize/load helpers
/// that keep the stored map complete and tolerant of junk.
@MainActor
@Suite("Panel key bindings")
struct PanelKeyBindingTests {

    @Test("defaults are the historical W/M/H/Q keycodes")
    func defaults() {
        #expect(PanelKeyAction.close.defaultKeyCode == 13)    // W
        #expect(PanelKeyAction.minimize.defaultKeyCode == 46) // M
        #expect(PanelKeyAction.hide.defaultKeyCode == 4)      // H
        #expect(PanelKeyAction.quit.defaultKeyCode == 12)     // Q
        #expect(PanelKeyAction.allCases.count == 4)
    }

    @Test("normalize fills every missing action with its default")
    func normalizeFills() {
        let result = Preferences.normalizePanelKeys([.close: 99])
        #expect(result.count == 4)
        #expect(result[.close] == 99)
        #expect(result[.minimize] == PanelKeyAction.minimize.defaultKeyCode)
        #expect(result[.hide] == PanelKeyAction.hide.defaultKeyCode)
        #expect(result[.quit] == PanelKeyAction.quit.defaultKeyCode)
    }

    @Test("loadPanelKeys parses raw dict and drops unknown keys")
    func loadParses() {
        let result = Preferences.loadPanelKeys(["close": 7, "bogus": 1, "quit": 8])
        #expect(result[.close] == 7)
        #expect(result[.quit] == 8)
        // Unspecified actions fall back to defaults; "bogus" is ignored.
        #expect(result[.minimize] == PanelKeyAction.minimize.defaultKeyCode)
        #expect(result.count == 4)
    }

    @Test("loadPanelKeys handles nil as all-default")
    func loadNil() {
        let result = Preferences.loadPanelKeys(nil)
        #expect(result.count == 4)
        for action in PanelKeyAction.allCases {
            #expect(result[action] == action.defaultKeyCode)
        }
    }
}
