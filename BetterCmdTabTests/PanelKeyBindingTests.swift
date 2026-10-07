import Carbon.HIToolbox
import Testing
import BetterShortcuts
@testable import BetterCmdTab

/// Pure-logic coverage for the per-profile in-panel keys (#5) after search and
/// tab drill-in joined them (#169).
@Suite("Panel key bindings")
struct PanelKeyBindingTests {
    private func names(_ storageKey: String) -> [String] {
        BetterShortcuts.Name.profilePanelKeys(for: storageKey).map(\.name.rawValue)
    }

    @Test func searchAndTabDrill_areProfilePanelKeys() {
        // Settings renders this list verbatim, so membership is what puts the two
        // recorders in the "In-panel keys" card.
        #expect(names("apps").contains("panelSearch@apps"))
        #expect(names("apps").contains("panelTabDrill@apps"))
        #expect(names("apps").count == 11)
    }

    @Test func customArrowKeys_shipUnbound() {
        // A default would claim that key in-panel for every existing user.
        let arrows: [BetterShortcuts.Name] = [.panelLeft(for: "apps"), .panelRight(for: "apps"), .panelUp(for: "apps"), .panelDown(for: "apps")]
        #expect(arrows.allSatisfy { $0.defaultShortcut == nil })
        #expect(Set(arrows.map(\.rawValue)).isSubset(of: Set(names("apps"))))
    }

    @Test func panelKeyNames_areScopedPerProfile() {
        // Two profiles must never share storage, or rebinding one moves both.
        #expect(Set(names("apps")).isDisjoint(with: Set(names("windows"))))
    }

    @Test func shippedDefaults_areSlashAndBackslash() {
        // These keycodes are also hardcoded in `HotkeyTap.defaultSearchKey` /
        // `defaultTabDrillKey`, which decide whether the layout-agnostic `/` and
        // `\` character fallbacks (#141) still apply. Changing a default here
        // without moving those constants would leave the fallback matching the
        // old key.
        let search = BetterShortcuts.Name.panelSearch(for: "apps").defaultShortcut
        let drill = BetterShortcuts.Name.panelTabDrill(for: "apps").defaultShortcut
        #expect(search?.carbonKeyCode == kVK_ANSI_Slash)      // 44
        #expect(drill?.carbonKeyCode == kVK_ANSI_Backslash)  // 42
        // ⌘ is held the whole time the panel is up; the recorded modifier is
        // ignored in-panel but still shows in the recorder.
        #expect(search?.carbonModifiers == cmdKey)
        #expect(drill?.carbonModifiers == cmdKey)
    }
}
