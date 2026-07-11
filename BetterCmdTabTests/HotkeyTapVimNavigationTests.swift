import Testing
import CoreGraphics
@testable import BetterCmdTab

/// Pure-logic coverage for the h/j/k/l → nav event mapping that the hotkey tap
/// applies when the user opts into vim-style navigation. The mapping has to
/// mirror the bare arrow keys exactly — h↔←, l↔→, k↔↑, j↔↓ — so this pins each
/// pair and makes sure no unrelated character starts behaving like an arrow.
@Suite("Vim navigation key mapping")
struct HotkeyTapVimNavigationTests {

    /// Tag each navigation `Event` case the vim mapping can produce so the
    /// tests can compare without the enum having to conform to `Equatable`
    /// (the real enum carries associated-value cases that don't).
    private enum NavTag {
        case left, right, up, down
    }

    private static func tag(_ event: HotkeyTap.Event?) -> NavTag? {
        guard let event else { return nil }
        switch event {
        case .spatialLeft:  return .left
        case .spatialRight: return .right
        case .prevRow:      return .up
        case .nextRow:      return .down
        default:            return nil
        }
    }

    @Test func leftArrowMirror_h() {
        #expect(Self.tag(HotkeyTap.vimNavigationEvent(for: "h")) == .left)
    }

    @Test func rightArrowMirror_l() {
        #expect(Self.tag(HotkeyTap.vimNavigationEvent(for: "l")) == .right)
    }

    @Test func upArrowMirror_k() {
        #expect(Self.tag(HotkeyTap.vimNavigationEvent(for: "k")) == .up)
    }

    @Test func downArrowMirror_j() {
        #expect(Self.tag(HotkeyTap.vimNavigationEvent(for: "j")) == .down)
    }

    /// Everything else has to fall through so the existing panel-action and
    /// letter-jump branches still get their shot. Uppercase counts too — the
    /// tap lowercases before consulting the mapping, and the helper itself
    /// stays case-sensitive so a stray capital can't trigger nav.
    @Test func nonVimKeysReturnNil() {
        for character: Character in ["a", "g", "i", "m", "q", "w", "z",
                                     "0", "9", " ", "/", "\\", "\n",
                                     "H", "J", "K", "L"] {
            #expect(HotkeyTap.vimNavigationEvent(for: character) == nil,
                    "\(character) should not be a vim navigation key")
        }
    }

    /// While vim is on, h/j/k/l must be reserved on top of the bound action
    /// letters so `RowLabels` never hands out a hint the tap would silently
    /// swallow as motion. With vim off the bound set passes through untouched.
    @Test func reservedSetUnionsVimLettersWhenEnabled() {
        let bound: Set<Character> = ["w", "m", "h", "q", "f"]
        #expect(HotkeyTap.reservedSet(boundLetters: bound, vimEnabled: false) == bound)
        let on = HotkeyTap.reservedSet(boundLetters: bound, vimEnabled: true)
        #expect(on == bound.union(["j", "k", "l"]))   // j/k/l were the missing ones
        #expect(on.isSuperset(of: HotkeyTap.vimNavigationLetters))
    }

    /// Hide rebound off `h` (e.g. to `x`): vim must still reserve every one of
    /// h/j/k/l, so none of them can leak out as a letter-jump hint.
    @Test func reservedSetReservesAllVimLettersEvenWhenHideRebound() {
        let bound: Set<Character> = ["w", "m", "x", "q", "f"]
        let on = HotkeyTap.reservedSet(boundLetters: bound, vimEnabled: true)
        #expect(on.isSuperset(of: ["h", "j", "k", "l"]))
    }

    /// The actual bug PR #24 shipped with: toggling vim must re-derive the
    /// reserved-letter set and re-push it to the hint generator, not merely flip
    /// an internal flag. Drive it through the public API and capture what gets
    /// pushed via `onReservedLettersChanged`. (A fresh tap has no bound action
    /// keys, so the reserved set is exactly the vim union when on and empty when
    /// off.)
    @MainActor
    @Test func togglingVimRepushesReservedLetters() {
        let tap = HotkeyTap()
        var pushed: Set<Character>?
        tap.onReservedLettersChanged = { pushed = $0 }

        tap.setVimNavigationEnabled(true)
        #expect(pushed?.isSuperset(of: HotkeyTap.vimNavigationLetters) == true)

        tap.setVimNavigationEnabled(false)
        #expect(pushed?.isDisjoint(with: ["j", "k", "l"]) == true)
    }

    /// The modifier gate must be relative to the *configured* trigger
    /// modifier, not hardcoded to ⌘ (issue #71: an ⌥Tab trigger holds ⌥ the
    /// whole time the panel is open, which used to kill h/j/k/l entirely).
    @Test func triggerModifierDoesNotBlockVimNav() {
        // Default ⌘Tab trigger: held ⌘ passes, anything extra blocks.
        #expect(HotkeyTap.onlyTriggerModifiersHeld(
            .maskCommand, heldTriggerModifiers: .maskCommand))
        #expect(!HotkeyTap.onlyTriggerModifiersHeld(
            [.maskCommand, .maskShift], heldTriggerModifiers: .maskCommand))
        #expect(!HotkeyTap.onlyTriggerModifiersHeld(
            [.maskCommand, .maskAlternate], heldTriggerModifiers: .maskCommand))
        // ⌥Tab trigger (issue #71): held ⌥ passes, ⌥ + extra blocks.
        #expect(HotkeyTap.onlyTriggerModifiersHeld(
            .maskAlternate, heldTriggerModifiers: .maskAlternate))
        #expect(!HotkeyTap.onlyTriggerModifiersHeld(
            [.maskAlternate, .maskControl], heldTriggerModifiers: .maskAlternate))
        // Sticky/stay-open panel with no trigger modifier down: bare keys only.
        #expect(HotkeyTap.onlyTriggerModifiersHeld([], heldTriggerModifiers: []))
        #expect(!HotkeyTap.onlyTriggerModifiersHeld(
            .maskShift, heldTriggerModifiers: []))
        // Raw event flags carry system bits (fn etc.) that must never affect
        // the comparison.
        #expect(HotkeyTap.onlyTriggerModifiersHeld(
            [.maskAlternate, .maskSecondaryFn], heldTriggerModifiers: .maskAlternate))
    }
}
