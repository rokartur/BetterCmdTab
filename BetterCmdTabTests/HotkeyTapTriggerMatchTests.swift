import CoreGraphics
import Testing

@testable import BetterCmdTab

/// Exact-chord matching for idle switcher triggers (issues #49/#73/#79):
/// a chord that merely CONTAINS the trigger modifier must not match.
@Suite("HotkeyTap trigger chord match")
struct HotkeyTapTriggerMatchTests {
    @Test func exactCommandMatches() {
        #expect(HotkeyTap.triggerChordMatches(.maskCommand, configured: .maskCommand))
    }

    @Test func extraShiftTolerated() {
        #expect(HotkeyTap.triggerChordMatches([.maskCommand, .maskShift], configured: .maskCommand))
    }

    @Test func extraOptionControlRejected() {
        // ⌘⌥⌃ + trigger key — issue #79's repro chord.
        #expect(!HotkeyTap.triggerChordMatches(
            [.maskCommand, .maskAlternate, .maskControl], configured: .maskCommand))
        #expect(!HotkeyTap.triggerChordMatches(
            [.maskCommand, .maskAlternate], configured: .maskCommand))
    }

    @Test func systemBitsIgnored() {
        // Raw event.flags carry non-modifier bits (non-coalesced, caps lock);
        // they must not break an otherwise exact match.
        let raw: CGEventFlags = [.maskCommand, .maskNonCoalesced, .maskAlphaShift]
        #expect(HotkeyTap.triggerChordMatches(raw, configured: .maskCommand))
    }

    @Test func shiftInConfiguredChordRequired() {
        // A ⌘⇧ trigger must not fire on bare ⌘.
        #expect(!HotkeyTap.triggerChordMatches(
            .maskCommand, configured: [.maskCommand, .maskShift]))
        #expect(HotkeyTap.triggerChordMatches(
            [.maskCommand, .maskShift], configured: [.maskCommand, .maskShift]))
    }

    @Test func optionTriggerRejectsOtherModifiers() {
        // Per-shortcut ⌥-based trigger: ⌘-chords must not match it.
        #expect(!HotkeyTap.triggerChordMatches(.maskCommand, configured: .maskAlternate))
        #expect(HotkeyTap.triggerChordMatches(.maskAlternate, configured: .maskAlternate))
    }
}
