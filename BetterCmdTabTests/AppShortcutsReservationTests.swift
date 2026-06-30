import AppKit
import Carbon.HIToolbox
import Testing
import BetterShortcuts
@testable import BetterCmdTab

/// Pure-logic coverage for the reserved-trigger-chord guard (issue #16): a global
/// slot (direct-activation / scoped-switch / window-management) must never be
/// registered on a chord the always-armed survivor trigger already owns, or
/// `RegisterEventHotKey` rejects the duplicate with `eventHotKeyExistsErr` (-9878).
@Suite("Reserved trigger shortcuts")
struct AppShortcutsReservationTests {
    static let cmdTab = BetterShortcuts.Shortcut(.tab, modifiers: .command)
    static let cmdBacktick = BetterShortcuts.Shortcut(.backtick, modifiers: .command)

    private func withShift(_ s: BetterShortcuts.Shortcut) -> BetterShortcuts.Shortcut {
        BetterShortcuts.Shortcut(carbonKeyCode: s.carbonKeyCode, carbonModifiers: s.carbonModifiers | shiftKey)
    }

    @Test func defaults_reserveCmdTabBacktickAndShiftReverse() {
        let reserved = BetterShortcuts.reservedTriggerShortcuts(app: Self.cmdTab, window: Self.cmdBacktick)
        // The forward chords plus their Shift-reverse — exactly what the survivor
        // (`computeNativeOverridePlan`) registers — and nothing else.
        #expect(reserved.contains(Self.cmdTab))
        #expect(reserved.contains(Self.cmdBacktick))
        #expect(reserved.contains(withShift(Self.cmdTab)))
        #expect(reserved.contains(withShift(Self.cmdBacktick)))
        #expect(reserved.count == 4)
    }

    @Test func remappedTrigger_reservesNewChord_notOldCmdTab() {
        // App switch remapped to ⌥Tab: ⌥Tab (+ Shift) is reserved; ⌘Tab is NOT, so a
        // slot may take ⌘Tab once the trigger no longer owns it.
        let optTab = BetterShortcuts.Shortcut(.tab, modifiers: .option)
        let reserved = BetterShortcuts.reservedTriggerShortcuts(app: optTab, window: nil)
        #expect(reserved.contains(optTab))
        #expect(reserved.contains(withShift(optTab)))
        #expect(!reserved.contains(Self.cmdTab))
    }

    @Test func clearedTrigger_contributesNothing() {
        #expect(BetterShortcuts.reservedTriggerShortcuts(app: nil, window: nil).isEmpty)
        // Only the live trigger contributes; a nil window adds nothing.
        let reserved = BetterShortcuts.reservedTriggerShortcuts(app: Self.cmdTab, window: nil)
        #expect(reserved.count == 2)
    }
}
