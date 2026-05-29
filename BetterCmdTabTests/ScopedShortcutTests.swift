import Foundation
import Testing
@testable import BetterCmdTab

/// Persistence-contract tests for scoped custom shortcuts (#3): the `SwitchScope`
/// raw values (must stay stable — they're stored) and the slot-array
/// normalization used when loading/saving the per-slot scopes.
@MainActor
@Suite("Scoped shortcuts")
struct ScopedShortcutTests {

    @Test("SwitchScope raw values are stable")
    func rawValuesStable() {
        #expect(SwitchScope.allAppsAllSpaces.rawValue == "allAppsAllSpaces")
        #expect(SwitchScope.allAppsCurrentSpace.rawValue == "allAppsCurrentSpace")
        #expect(SwitchScope.currentAppWindows.rawValue == "currentAppWindows")
        #expect(SwitchScope.minimizedOnly.rawValue == "minimizedOnly")
        #expect(SwitchScope.allCases.count == 4)
    }

    @Test("normalizeScopes pads short arrays with the default scope")
    func normalizePads() {
        let result = Preferences.normalizeScopes([.minimizedOnly])
        #expect(result.count == Preferences.scopedShortcutSlotCount)
        #expect(result[0] == .minimizedOnly)
        #expect(result.dropFirst().allSatisfy { $0 == .allAppsAllSpaces })
    }

    @Test("normalizeScopes truncates over-long arrays")
    func normalizeTruncates() {
        let many = Array(repeating: SwitchScope.minimizedOnly, count: Preferences.scopedShortcutSlotCount + 5)
        let result = Preferences.normalizeScopes(many)
        #expect(result.count == Preferences.scopedShortcutSlotCount)
    }

    @Test("loadScopes parses raw strings and falls back for unknowns")
    func loadParses() {
        let result = Preferences.loadScopes(["currentAppWindows", "bogus", "minimizedOnly"])
        #expect(result.count == Preferences.scopedShortcutSlotCount)
        #expect(result[0] == .currentAppWindows)
        #expect(result[1] == .allAppsAllSpaces) // unknown → default
        #expect(result[2] == .minimizedOnly)
    }

    @Test("loadScopes handles nil as all-default")
    func loadNil() {
        let result = Preferences.loadScopes(nil)
        #expect(result.count == Preferences.scopedShortcutSlotCount)
        #expect(result.allSatisfy { $0 == .allAppsAllSpaces })
    }
}
